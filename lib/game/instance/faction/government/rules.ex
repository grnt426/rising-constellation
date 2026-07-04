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
  handling shared by every elected seat.
  """
  def seat_from_result(government, ballot, result) do
    case result do
      {:winner, winner, _totals} ->
        {government, events} = Government.fill_seat(government, ballot.seat, winner)
        {government, events}

      {:failed, reason, _totals} ->
        {government, [%{type: :election_failed, seat: ballot.seat, reason: reason}]}
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
