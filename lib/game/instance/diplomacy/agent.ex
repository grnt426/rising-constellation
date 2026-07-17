defmodule Instance.Diplomacy.Agent do
  use Core.TickServer

  alias Instance.Diplomacy.Diplomacy
  alias Portal.Controllers.FactionChannel

  require Logger

  @moduledoc """
  Per-instance diplomacy agent. Holds the authoritative relation matrix
  (see `Instance.Diplomacy.Diplomacy`), participates in instance
  snapshots like every other agent, and settles all side effects of a
  diplomatic act itself: stance-cache pushes to the involved faction
  agents, per-faction filtered view broadcasts, event cards, and both
  factions' audit-log entries.

  VISIBILITY (user rule 2026-07-09): standings are pairwise-private —
  every faction receives only the pairs it belongs to, pushed on ITS
  faction channel (`faction_diplomacy`). Nothing diplomacy-shaped rides
  the global channel anymore.

  Callers are the involved factions' agents, which gate every action on
  their government's Leader before forwarding here.
  """

  @decorate tick()
  def on_call(:get_state, _from, state) do
    state = hydrate(state)
    {:reply, {:ok, Diplomacy.backfill(state.data)}, state}
  end

  # Cheap stance probe (used by the market's war embargo). Read-only:
  # no settle, no broadcast.
  @decorate tick()
  def on_call({:stance, a, b}, _from, state) do
    {:reply, {:ok, Diplomacy.stance(Diplomacy.backfill(state.data), a, b)}, state}
  end

  @decorate tick()
  def on_call({:declare_war, from, to}, _, state),
    do: run(state, &Diplomacy.declare_war(&1, from, to))

  @decorate tick()
  def on_call({:propose, from, to, kind}, _, state),
    do: run(state, &Diplomacy.propose(&1, from, to, kind))

  @decorate tick()
  def on_call({:accept, proposal_id, by}, _, state),
    do: run(state, &Diplomacy.accept(&1, proposal_id, by))

  @decorate tick()
  def on_call({:reject, proposal_id, by}, _, state),
    do: run(state, &Diplomacy.reject(&1, proposal_id, by))

  @decorate tick()
  def on_call({:break_pact, from, to}, _, state),
    do: run(state, &Diplomacy.break_pact(&1, from, to))

  # Hostile-action reports from the character-action pipeline (see
  # Diplomacy.report/5). Fire-and-forget: invalid pairs are dropped by
  # handle_action, and only real changes hit the wire.
  @decorate tick()
  def on_cast({:action, event}, state) do
    state = hydrate(state)
    {data, changed} = Diplomacy.handle_action(Diplomacy.backfill(state.data), event)
    state = %{state | data: data}

    state =
      if changed do
        push_views(state, [event.aggressor, event.victim])
        log_action(state, event)
        persist(state)
      else
        state
      end

    {:noreply, state}
  end

  # Once per process lifetime: adopt the DB write-through copy when its
  # revision is ahead of what this process restored from — a crashed
  # diplomacy agent must not forget who is at war (see
  # RC.Instances.GovernmentStates and the faction agent's counterpart).
  defp hydrate(state) do
    if Process.get(:diplomacy_hydrated) do
      state
    else
      Process.put(:diplomacy_hydrated, true)

      case RC.Instances.GovernmentStates.fetch(state.instance_id, 0, "diplomacy") do
        {rev, data} when is_map(data) ->
          if rev > (Map.get(state.data, :rev) || 0),
            do: %{state | data: data},
            else: state

        _ ->
          state
      end
    end
  end

  # Write-through after any mutation; best-effort, never raises.
  defp persist(state) do
    data = Map.put(state.data, :rev, (Map.get(state.data, :rev) || 0) + 1)

    RC.Instances.GovernmentStates.persist(
      state.instance_id,
      0,
      "diplomacy",
      Map.get(data, :rev),
      data
    )

    %{state | data: data}
  end

  defp run(state, op) do
    state = hydrate(state)

    case op.(Diplomacy.backfill(state.data)) do
      {:ok, data, events} ->
        state = %{state | data: data}
        Enum.each(events, &settle(state, &1))
        state = persist(state)

        # Pairwise-private: every faction gets ITS view on ITS channel.
        push_views(state)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Push each faction's filtered view on its own channel. With
  # `only_involving`, skip factions whose view didn't change (hostile
  # actions touch exactly one pair).
  defp push_views(state, only_involving \\ nil) do
    data = Diplomacy.backfill(state.data)

    data.factions
    |> Enum.filter(fn faction ->
      only_involving == nil or faction.id in only_involving
    end)
    |> Enum.each(fn faction ->
      FactionChannel.broadcast_change(
        "instance:faction:#{state.instance_id}:#{faction.id}",
        %{faction_diplomacy: Diplomacy.public_view(data, faction.id)}
      )
    end)
  end

  # Hostile actions land in BOTH factions' audit logs — the panel's
  # "actions from either side" feed.
  defp log_action(state, event) do
    payload = %{
      kind: event.kind,
      aggressor: event.aggressor,
      victim: event.victim,
      success: Map.get(event, :success, true)
    }

    Enum.each([event.aggressor, event.victim], fn faction_id ->
      case RC.Instances.FactionEventLogs.record(%{
             instance_id: state.instance_id,
             faction_id: faction_id,
             actor_profile_id: nil,
             target_profile_id: nil,
             event_type: "diplomacy_action",
             payload: payload
           }) do
        {:ok, _} -> :ok
        {:error, changeset} -> Logger.warning("diplomacy action log failed: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp settle(state, %{type: :war_declared, from: from, to: to}) do
    push_stances(state, [from, to])
    global_event(state, "diplomacy_war", from, to)
    audit(state, [from, to], %{event: :war_declared, from: from, to: to})
  end

  defp settle(state, %{type: :pact_accepted, proposal: %{kind: :non_aggression} = p}) do
    push_stances(state, [p.from, p.to])
    global_event(state, "diplomacy_pact", p.from, p.to)
    audit(state, [p.from, p.to], %{event: :pact_signed, from: p.from, to: p.to})
  end

  defp settle(state, %{type: :pact_accepted, proposal: %{kind: :peace} = p}) do
    push_stances(state, [p.from, p.to])
    global_event(state, "diplomacy_peace", p.from, p.to)
    audit(state, [p.from, p.to], %{event: :peace_signed, from: p.from, to: p.to})
  end

  defp settle(state, %{type: :pact_broken, from: from, to: to}) do
    push_stances(state, [from, to])
    global_event(state, "diplomacy_pact_broken", from, to)
    audit(state, [from, to], %{event: :pact_broken, from: from, to: to})
  end

  # Proposals and rejections stay between the two governments: no global
  # card, but both factions' logs record them.
  defp settle(state, %{type: type, proposal: p}) when type in [:pact_proposed, :pact_rejected] do
    audit(state, [p.from, p.to], %{event: type, kind: p.kind, from: p.from, to: p.to})
  end

  defp settle(_state, _event), do: :ok

  defp push_stances(state, faction_ids) do
    Enum.each(faction_ids, fn faction_id ->
      Game.cast(
        state.instance_id,
        :faction,
        faction_id,
        {:update_diplomacy, Diplomacy.stances_for(state.data, faction_id)}
      )
    end)
  end

  # Event cards go to the two INVOLVED factions only (pairwise privacy,
  # user rule 2026-07-09) — a third party doesn't learn that two rivals
  # went to war from their newspaper.
  defp global_event(state, key, from, to) do
    from_key = Diplomacy.faction_key(state.data, from)
    to_key = Diplomacy.faction_key(state.data, to)
    from_data = Data.Querier.one(Data.Game.Faction, state.instance_id, from_key)
    to_data = Data.Querier.one(Data.Game.Faction, state.instance_id, to_key)

    data =
      Jason.encode!(%{
        from_faction: from_key,
        from_theme: from_data && from_data.theme,
        to_faction: to_key,
        to_theme: to_data && to_data.theme
      })

    Enum.each([from, to], fn faction_id ->
      RC.PlayerEvents.create(%{
        type: "faction",
        key: key,
        data: data,
        instance_id: state.instance_id,
        faction_id: faction_id
      })
    end)
  end

  defp audit(state, faction_ids, payload) do
    Enum.each(faction_ids, fn faction_id ->
      case RC.Instances.FactionEventLogs.record(%{
             instance_id: state.instance_id,
             faction_id: faction_id,
             actor_profile_id: nil,
             target_profile_id: nil,
             event_type: "diplomacy_changed",
             payload: payload
           }) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning("diplomacy audit insert failed: #{inspect(changeset.errors)}")
      end
    end)
  end

  # The 5-ut timer armed by compute_next_tick_interval lands here; the
  # decorator does all the work (advance + reschedule). Without this
  # clause the default on_info throws :not_implemented and kills the
  # agent on its very first tick.
  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  # Time passage: tension decays, warring sides' exhaustion drips up.
  # Fractions move every tick but players only care about whole points,
  # so the broadcast fires when the rounded projection changes (roughly
  # once per game-day during a quiet war).
  defp do_next_tick(state, elapsed_time) do
    state = hydrate(state)
    data = Diplomacy.backfill(state.data)
    {new_data, changed} = Diplomacy.advance(data, elapsed_time)
    push? = visible(new_data) != visible(data)

    state = %{state | data: new_data}
    if push?, do: push_views(state)
    state = if changed, do: persist(state), else: state

    {state, Diplomacy}
  end

  defp visible(data) do
    {
      Map.new(data.tension, fn {k, v} -> {k, round(v)} end),
      Map.new(data.wars, fn {pair, meters} ->
        {pair,
         Map.new(meters, fn {fid, side} ->
           {fid, Map.new(side, fn {k, v} -> {k, round(v)} end)}
         end)}
      end)
    }
  end
end
