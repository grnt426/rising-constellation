defmodule Instance.Faction.Government.Rules do
  @moduledoc """
  Per-faction government rules. The Government engine owns the ballot
  lifecycle (open → collect → tick → close); everything faction-specific
  — who may stand, how votes are weighted, what happens when a ballot
  closes, which seats are appointed vs. elected — lives behind this
  behaviour, one module per faction.

  All five faction election systems reduce to "a ballot where voters
  attach a stake to a candidate"; these modules are parameter sets, not
  bespoke engines.

  `ctx` is built by Faction.Agent from live faction state:

      %{
        instance_id: integer,
        faction_id: integer,
        faction_key: atom,
        players: [%Instance.Faction.Player{}],
        constants: %Data.Game.Constant{},
        faction_ideology_income: (-> number)   # lazily computed rate snapshot
      }
  """

  alias Instance.Faction.Government

  @type ctx :: map()
  @type ballot_spec :: map()
  @type event :: map()
  @type result ::
          {:winner, map(), list()}
          | {:approved, list()}
          | {:rejected, list()}
          | {:failed, atom(), list()}

  @doc "Ballot specs for the first election after the founding period."
  @callback initial_ballots(ctx) :: [ballot_spec]

  @doc """
  Ballot specs to re-fill a vacant seat on member request. Return `[]`
  when the seat is not elected in this faction (e.g. appointed council).
  """
  @callback by_election_ballots(atom(), ctx) :: [ballot_spec]

  @doc "Apply a closed ballot's result: fill seats, open follow-ups."
  @callback after_close(%Government{}, Government.Ballot.t(), result, ctx) ::
              {%Government{}, [event]}

  @doc "Leader fills a council seat (direct, or via approval ballot)."
  @callback appoint(%Government{}, integer(), atom(), map(), ctx) ::
              {:ok, %Government{}, [event]} | {:error, atom()}

  @doc "Scheduled mandate renewal, or nil when the faction has none."
  @callback term_spec(ctx) :: nil | %{duration: number(), scope: atom()}

  @doc "Open the renewal ballots when the term expires."
  @callback on_term_expired(%Government{}, ctx) :: {%Government{}, [event]}

  @doc "Faction-specific time-driven behavior (windows, countdowns)."
  @callback tick(%Government{}, number(), ctx) :: {%Government{}, [event]}

  @doc "Ballot spec for deposing the sitting holder of `seat`, or nil."
  @callback deposition_ballot(%Government{}, atom(), ctx) :: nil | ballot_spec

  @doc "Route lex enactment through a faction referendum (Myrmezir)."
  @callback laws_referendum?() :: boolean()

  @doc "Faction snap actions (Synelle cabinet/leader dissolution)."
  @callback snap(%Government{}, integer(), atom(), ctx) ::
              {:ok, %Government{}, [event]} | {:error, atom()}

  @doc "Open a bid-to-challenge against the sitting government (ARK)."
  @callback challenge(%Government{}, integer(), number(), ctx) ::
              {:ok, %Government{}, [event]} | {:error, atom()}

  @doc "Answer an open challenge (ARK seat holders)."
  @callback challenge_match(%Government{}, integer(), number(), boolean(), ctx) ::
              {:ok, %Government{}, [event]} | {:error, atom()}

  @doc """
  Faction identity modifiers on the government economy (user design
  2026-07-09). Multipliers on faction-tree purchase costs and the
  law-change cooldown, plus ARK's credit surcharge. Missing keys default
  to neutral.
  """
  @callback economy_mods() :: map()

  @doc """
  Royal prerogative: the faction-wide income malus (percent) the whole
  faction eats for `government_approval_duration` each time the LEADER
  performs a council seat's action in the holder's stead. Implementing
  it enables the override; leave it out and the leader is bound to
  their own office like everyone else.
  """
  @callback overreach_malus() :: number()

  @optional_callbacks tick: 3,
                      deposition_ballot: 3,
                      laws_referendum?: 0,
                      snap: 4,
                      challenge: 4,
                      challenge_match: 5,
                      economy_mods: 0,
                      overreach_malus: 0

  @economy_mod_defaults %{
    # multiplier on faction patent ("tech") treasury cost
    patent_cost: 1.0,
    # multiplier on faction lex ("policy") treasury cost
    lex_cost: 1.0,
    # multiplier on the active-law change cooldown
    law_cooldown: 1.0,
    # ARK: purchases ALSO cost credit — UNMODIFIED base cost × this factor
    credit_cost_factor: 0
  }

  @doc "The faction's economy modifiers, merged over neutral defaults."
  def economy_mods(faction_key) do
    rules = module_for(faction_key)

    if function_exported?(rules, :economy_mods, 0),
      do: Map.merge(@economy_mod_defaults, rules.economy_mods()),
      else: @economy_mod_defaults
  end

  def module_for(:tetrarchy), do: Instance.Faction.Government.Rules.Tetrarchy
  def module_for(:myrmezir), do: Instance.Faction.Government.Rules.Myrmezir
  def module_for(:synelle), do: Instance.Faction.Government.Rules.Synelle
  def module_for(:cardan), do: Instance.Faction.Government.Rules.Cardan
  def module_for(:ark), do: Instance.Faction.Government.Rules.Ark

  # ----------------------------------------------------------------
  # Shared helpers for the rule modules
  # ----------------------------------------------------------------

  def seats(), do: [:leader, :economy, :military]

  def roster_candidate(players, player_id) do
    case Enum.find(players, &(&1.id == player_id)) do
      nil -> nil
      player -> %{player_id: player.id, name: player.name}
    end
  end

  def all_candidates(players),
    do: Enum.map(players, &%{player_id: &1.id, name: &1.name})

  @doc """
  Standard "winner takes the seat / no winner leaves it vacant" close
  handling shared by every elected seat. Under the small-faction
  relaxation the winner keeps any seat they already hold.
  """
  def seat_from_result(government, ballot, result, ctx) do
    case result do
      {:winner, winner, _totals} ->
        {government, events} =
          Government.fill_seat(government, ballot.seat, winner,
            keep_other_seats: Government.relaxed?(ctx)
          )

        {government, events}

      {:failed, reason, _totals} ->
        {government, [%{type: :election_failed, seat: ballot.seat, reason: reason}]}
    end
  end

  @doc """
  Shared close handling for deposition votes (`question: :depose`): an
  approved (or instant-quorum) deposition vacates the seat and re-opens
  its election immediately; a rebuffed one arms the faction-wide
  deposition cooldown — a failed coup buys the incumbent a quiet spell.
  """
  def settle_deposition(government, ballot, result, ctx) do
    deposed? =
      case result do
        {:approved, _totals} -> true
        # Instant-quorum pledge ballots (Cardan) reach here as a tally
        # win once the loss-of-faith threshold fills.
        {:winner, _target, _totals} -> true
        _ -> false
      end

    target = Map.get(ballot.meta, :target)

    if deposed? do
      {government, vacate_events} = Government.vacate_seat(government, ballot.seat)

      deposed = %{
        type: :deposed,
        seat: ballot.seat,
        player_id: target && target.player_id,
        name: target && target.name
      }

      {government, open_events} =
        case module_for(ctx.faction_key).by_election_ballots(ballot.seat, ctx) do
          [] ->
            {government, []}

          specs ->
            {government, opened} = Government.open_ballots(government, specs)
            {government, [%{type: :elections_opened, seats: [ballot.seat], renewal: true} | opened]}
        end

      {government, [deposed] ++ vacate_events ++ open_events}
    else
      government = Government.arm_depose_cooldown(government, ctx)
      {government, [%{type: :deposition_failed, seat: ballot.seat}]}
    end
  end

  @doc """
  Scoreboard snapshot for ranked voting: faction members ordered by
  scoreboard points (descending). Members without a stats row yet sort
  last with 0 points. Falls back to roster order on any DB trouble —
  an election must never crash the faction agent.

  The stats rows come from a raw SQL query and are STRING-keyed maps.
  """
  def scoreboard(ctx) do
    points_by_id =
      try do
        RC.PlayerStats.get_last_player_stat_by_instance_id(ctx.instance_id)
        |> Enum.filter(&(to_string(Map.get(&1, "faction")) == to_string(ctx.faction_key)))
        |> Map.new(&{Map.get(&1, "player_id"), Map.get(&1, "points") || 0})
      rescue
        _ -> %{}
      end

    ctx.players
    |> Enum.map(fn player -> {player, Map.get(points_by_id, player.id, 0)} end)
    |> Enum.sort_by(fn {_player, points} -> -points end)
  end
end
