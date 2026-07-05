defmodule Instance.Diplomacy.Diplomacy do
  use TypedStruct
  use Util.MakeEnumerable

  alias Instance.Diplomacy.Diplomacy

  @moduledoc """
  Inter-faction diplomacy, v2 (design: docs/faction-government.md §4).

  One agent per instance holds the authoritative relation matrix.
  Relations are PUBLIC knowledge; only the ability to act is gated
  (faction Leaders, checked by the faction agent).

  Stances per faction pair:
    * `:cold_war`       — the default in 3+ faction games. Everything is
      permitted, but conquest, removal (of governors) and bombardment
      build TENSION on the victim's side: a public, slowly-decaying
      ledger of who is harming whom. Symbolic for now, by design.
    * `:war`            — declared unilaterally; the default (and
      starting) stance in 2-faction games. Cross-faction market trade is
      embargoed. Each side tracks three war sentiments (see below).
    * `:non_aggression` — mutual (proposal + acceptance). Cold-war rules
      with DOUBLED tension for aggression: betraying a pact you signed
      reads twice as loud.

  War sentiments (per side, clamped 0..100 — symbolic v1, designed to
  later punish "down-punching" raiding that doesn't pursue victory):
    * exhaustion — starts 0, +1 per game-day of war; taking enemy
      systems reduces it. A war without conquests wears the home front.
    * momentum   — starts 50; destroying/sabotaging fleets and removing
      enemy field agents sustains the war machine.
    * frenzy     — starts 100; the willingness to keep committing (and
      absorbing) atrocities. Your own pillage/bombardment/destabilize/
      governor-removal SPENDS it; suffering the same replenishes it
      (double for bombardment and conquest).

  Failed attempts generate half of every effect.
  """

  @kinds [:non_aggression, :peace]

  # One game-day, in ut (1 ut = 3 min of game time at legacy speed).
  @ut_per_day 480

  # Tension per successful cold-war aggression (failure = half; ×2 under
  # a non-aggression pact), and its decay per game-day.
  @tension_gain 10
  @tension_decay_per_day 2

  # War sentiment deltas (base 5; doubled where the design says so) and
  # the daily exhaustion drip.
  @war_effects %{
    conquest: [{:aggressor, :exhaustion, -10}, {:victim, :frenzy, +10}],
    bombardment: [{:aggressor, :frenzy, -5}, {:victim, :frenzy, +10}],
    pillage: [{:aggressor, :frenzy, -5}, {:victim, :frenzy, +5}],
    destabilize: [{:aggressor, :frenzy, -5}, {:victim, :frenzy, +5}],
    removal: [{:aggressor, :frenzy, -5}, {:victim, :frenzy, +5}],
    agent_removal: [{:aggressor, :momentum, +5}],
    sabotage: [{:aggressor, :momentum, +5}],
    fleet_destroyed: [{:aggressor, :momentum, +5}]
  }
  # Removal covers both flavors: a seduced or assassinated governor OR
  # field agent is equally gone.
  @tension_kinds [:conquest, :removal, :agent_removal, :bombardment]
  @exhaustion_per_day 1
  @initial_meters %{exhaustion: 0, momentum: 50, frenzy: 100}

  def jason(), do: [except: [:instance_id]]

  typedstruct enforce: true do
    field(:factions, [map()])
    # %{"minId:maxId" => :war | :non_aggression} — :cold_war is absent
    field(:relations, map())
    field(:proposals, [map()])
    # %{"victimId>aggressorId" => float} — who is harming whom
    field(:tension, map())
    # %{"minId:maxId" => %{"factionId" => %{exhaustion, momentum, frenzy}}}
    # (string faction-id keys: the whole struct is JSON-broadcast as-is)
    field(:wars, map())
    field(:counter, integer())
    field(:instance_id, integer())
  end

  def new(factions, instance_id) do
    # Accept both the runtime faction struct (key: atom) and the DB
    # row (faction_ref: string) — the manager hands us whichever shape
    # its boot path has at that step.
    factions =
      Enum.map(factions, fn faction ->
        key = Map.get(faction, :key) || String.to_existing_atom(faction.faction_ref)
        %{id: faction.id, key: key}
      end)

    state = %Diplomacy{
      factions: factions,
      relations: %{},
      proposals: [],
      tension: %{},
      wars: %{},
      counter: 1,
      instance_id: instance_id
    }

    # A two-faction galaxy has no third party to posture for: the war is
    # the game, and it starts on day one.
    case factions do
      [%{id: a}, %{id: b}] -> open_war(state, a, b)
      _ -> state
    end
  end

  # Fields added after the first diplomacy snapshots existed. Wars
  # declared before the meters existed get them retroactively, at their
  # starting values.
  def backfill(state) do
    state = state |> Map.put_new(:tension, %{}) |> Map.put_new(:wars, %{})

    wars =
      state.relations
      |> Enum.filter(fn {_pair, stance} -> stance == :war end)
      |> Enum.reduce(state.wars, fn {pair, _}, wars ->
        [a, b] = String.split(pair, ":")
        Map.put_new(wars, pair, %{a => @initial_meters, b => @initial_meters})
      end)

    %{state | wars: wars}
  end

  def pair_key(a, b), do: "#{min(a, b)}:#{max(a, b)}"
  defp tension_key(victim, aggressor), do: "#{victim}>#{aggressor}"

  def stance(%Diplomacy{} = state, a, b),
    do: Map.get(state.relations, pair_key(a, b), :cold_war)

  @doc "Non-cold-war stances seen from one faction — the faction agent's cache."
  def stances_for(%Diplomacy{} = state, faction_id) do
    state.factions
    |> Enum.reject(&(&1.id == faction_id))
    |> Enum.reduce(%{}, fn other, acc ->
      case stance(state, faction_id, other.id) do
        :cold_war -> acc
        stance -> Map.put(acc, other.id, stance)
      end
    end)
  end

  defp faction?(%Diplomacy{} = state, id), do: Enum.any?(state.factions, &(&1.id == id))

  defp validate_pair(state, from, to) do
    cond do
      from == to -> {:error, :cannot_target_self}
      not faction?(state, from) or not faction?(state, to) -> {:error, :unknown_faction}
      true -> :ok
    end
  end

  defp open_war(state, a, b) do
    %{
      state
      | relations: Map.put(state.relations, pair_key(a, b), :war),
        wars:
          Map.put(state.wars, pair_key(a, b), %{
            to_string(a) => @initial_meters,
            to_string(b) => @initial_meters
          }),
        # war makes the harm ledger redundant — the war meters take over
        tension:
          state.tension
          |> Map.delete(tension_key(a, b))
          |> Map.delete(tension_key(b, a)),
        proposals: drop_pair_proposals(state.proposals, a, b)
    }
  end

  @doc "War is unilateral: any leader may plunge two factions into it."
  def declare_war(%Diplomacy{} = state, from, to) do
    with :ok <- validate_pair(state, from, to) do
      case stance(state, from, to) do
        :war -> {:error, :already_at_war}
        _ -> {:ok, open_war(state, from, to), [%{type: :war_declared, from: from, to: to}]}
      end
    end
  end

  @doc """
  Mutual agreements start as proposals: `:non_aggression` from cold war,
  `:peace` from war. One pending proposal per pair and kind.
  """
  def propose(%Diplomacy{} = state, from, to, kind) when kind in @kinds do
    with :ok <- validate_pair(state, from, to) do
      current = stance(state, from, to)

      cond do
        kind == :non_aggression and current != :cold_war ->
          {:error, :requires_cold_war}

        kind == :peace and current != :war ->
          {:error, :requires_war}

        Enum.any?(state.proposals, fn p ->
          p.kind == kind and pair_key(p.from, p.to) == pair_key(from, to)
        end) ->
          {:error, :already_proposed}

        true ->
          proposal = %{id: state.counter, kind: kind, from: from, to: to}

          state = %{
            state
            | counter: state.counter + 1,
              proposals: state.proposals ++ [proposal]
          }

          {:ok, state, [%{type: :pact_proposed, proposal: proposal}]}
      end
    end
  end

  def propose(%Diplomacy{}, _from, _to, _kind), do: {:error, :unknown_kind}

  @doc "Only the proposal's target may accept; acceptance applies the stance."
  def accept(%Diplomacy{} = state, proposal_id, by) do
    case Enum.find(state.proposals, &(&1.id == proposal_id)) do
      nil ->
        {:error, :proposal_not_found}

      %{to: to} when to != by ->
        {:error, :not_the_recipient}

      proposal ->
        pair = pair_key(proposal.from, proposal.to)

        relations =
          case proposal.kind do
            :non_aggression -> Map.put(state.relations, pair, :non_aggression)
            :peace -> Map.delete(state.relations, pair)
          end

        state = %{
          state
          | relations: relations,
            # peace archives nothing yet: the meters simply end with the war
            wars: if(proposal.kind == :peace, do: Map.delete(state.wars, pair), else: state.wars),
            proposals: drop_pair_proposals(state.proposals, proposal.from, proposal.to)
        }

        {:ok, state, [%{type: :pact_accepted, proposal: proposal}]}
    end
  end

  def reject(%Diplomacy{} = state, proposal_id, by) do
    case Enum.find(state.proposals, &(&1.id == proposal_id)) do
      nil ->
        {:error, :proposal_not_found}

      %{to: to} when to != by ->
        {:error, :not_the_recipient}

      proposal ->
        state = %{state | proposals: Enum.reject(state.proposals, &(&1.id == proposal_id))}
        {:ok, state, [%{type: :pact_rejected, proposal: proposal}]}
    end
  end

  @doc "Breaking a pact is unilateral, public, and audited. Costs come later."
  def break_pact(%Diplomacy{} = state, from, to) do
    with :ok <- validate_pair(state, from, to) do
      case stance(state, from, to) do
        :non_aggression ->
          state = %{state | relations: Map.delete(state.relations, pair_key(from, to))}
          {:ok, state, [%{type: :pact_broken, from: from, to: to}]}

        _ ->
          {:error, :no_pact}
      end
    end
  end

  @doc """
  Apply a reported hostile action. Returns {state, changed?}.

  Cold war / pact: the tension kinds build the victim's harm ledger
  (×2 under a pact — betrayal reads louder). War: the sentiment table
  applies to both sides' meters. Failures halve everything.
  """
  def handle_action(%Diplomacy{} = state, %{kind: kind, aggressor: a, victim: v} = event) do
    success = Map.get(event, :success, true)
    factor = if success, do: 1, else: 0.5

    cond do
      a == nil or v == nil or a == v or not faction?(state, a) or not faction?(state, v) ->
        {state, false}

      stance(state, a, v) == :war ->
        apply_war_effects(state, kind, a, v, factor)

      kind in @tension_kinds ->
        pact_factor = if stance(state, a, v) == :non_aggression, do: 2, else: 1
        gain = @tension_gain * factor * pact_factor
        key = tension_key(v, a)
        tension = Map.update(state.tension, key, gain, &min(&1 + gain, 100))
        {%{state | tension: tension}, true}

      true ->
        {state, false}
    end
  end

  defp apply_war_effects(state, kind, aggressor, victim, factor) do
    case Map.get(@war_effects, kind) do
      nil ->
        {state, false}

      effects ->
        pair = pair_key(aggressor, victim)
        meters = Map.get(state.wars, pair)

        if meters == nil do
          {state, false}
        else
          meters =
            Enum.reduce(effects, meters, fn {side, meter, delta}, meters ->
              faction_id = if side == :aggressor, do: aggressor, else: victim

              Map.update!(meters, to_string(faction_id), fn side_meters ->
                Map.update!(side_meters, meter, &clamp(&1 + delta * factor))
              end)
            end)

          {%{state | wars: Map.put(state.wars, pair, meters)}, true}
        end
    end
  end

  @doc """
  Time passage: tension decays toward zero; every warring side's
  exhaustion drips upward. Returns {state, changed?}.
  """
  def advance(%Diplomacy{} = state, elapsed_time) do
    days = elapsed_time / @ut_per_day

    {tension, tension_changed} =
      Enum.reduce(state.tension, {%{}, false}, fn {key, value}, {acc, changed} ->
        remaining = value - @tension_decay_per_day * days

        if remaining > 0.1,
          do: {Map.put(acc, key, remaining), changed or remaining != value},
          else: {acc, true}
      end)

    {wars, wars_changed} =
      Enum.reduce(state.wars, {%{}, false}, fn {pair, meters}, {acc, changed} ->
        new_meters =
          Map.new(meters, fn {faction_id, side_meters} ->
            {faction_id,
             Map.update!(side_meters, :exhaustion, &clamp(&1 + @exhaustion_per_day * days))}
          end)

        {Map.put(acc, pair, new_meters), changed or new_meters != meters}
      end)

    {%{state | tension: tension, wars: wars}, tension_changed or wars_changed}
  end

  defp clamp(value), do: value |> max(0) |> min(100)

  defp drop_pair_proposals(proposals, a, b) do
    Enum.reject(proposals, fn p -> pair_key(p.from, p.to) == pair_key(a, b) end)
  end

  def faction_key(%Diplomacy{} = state, id) do
    case Enum.find(state.factions, &(&1.id == id)) do
      nil -> nil
      faction -> faction.key
    end
  end

  def compute_next_tick_interval(_state), do: 5

  # ----------------------------------------------------------------
  # Reporting API for game actions
  # ----------------------------------------------------------------

  @doc """
  Fire-and-forget report of a hostile act from any game action:

      Instance.Diplomacy.Diplomacy.report(iid, :conquest, aggressor_fid, victim_fid, success?)

  Kinds: #{inspect(Map.keys(@war_effects))}. Safe to call with nil or
  same-faction ids (dropped agent-side); never blocks the caller.
  """
  def report(instance_id, kind, aggressor_faction_id, victim_faction_id, success \\ true)

  def report(_instance_id, _kind, a, v, _success) when a == nil or v == nil or a == v, do: :ok

  def report(instance_id, kind, aggressor_faction_id, victim_faction_id, success) do
    Game.cast(
      instance_id,
      :diplomacy,
      :master,
      {:action,
       %{
         kind: kind,
         aggressor: aggressor_faction_id,
         victim: victim_faction_id,
         success: success
       }}
    )
  end
end
