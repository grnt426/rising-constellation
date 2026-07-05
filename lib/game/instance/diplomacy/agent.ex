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
  agents, the public global broadcast, global event cards, and both
  factions' audit-log entries.

  Callers are the involved factions' agents, which gate every action on
  their government's Leader before forwarding here.
  """

  @decorate tick()
  def on_call(:get_state, _from, state) do
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
    {data, changed} = Diplomacy.handle_action(Diplomacy.backfill(state.data), event)
    state = %{state | data: data}

    if changed,
      do: FactionChannel.broadcast_change(state.channel, %{global_diplomacy: data})

    {:noreply, state}
  end

  defp run(state, op) do
    case op.(Diplomacy.backfill(state.data)) do
      {:ok, data, events} ->
        state = %{state | data: data}
        Enum.each(events, &settle(state, &1))

        # Public knowledge: every player sees the diplomatic map move.
        FactionChannel.broadcast_change(state.channel, %{global_diplomacy: data})

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  defp global_event(state, key, from, to) do
    from_key = Diplomacy.faction_key(state.data, from)
    to_key = Diplomacy.faction_key(state.data, to)
    from_data = Data.Querier.one(Data.Game.Faction, state.instance_id, from_key)
    to_data = Data.Querier.one(Data.Game.Faction, state.instance_id, to_key)

    RC.PlayerEvents.create(%{
      type: "global",
      key: key,
      data:
        Jason.encode!(%{
          from_faction: from_key,
          from_theme: from_data && from_data.theme,
          to_faction: to_key,
          to_theme: to_data && to_data.theme
        }),
      instance_id: state.instance_id
    })
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
    data = Diplomacy.backfill(state.data)
    {new_data, _changed} = Diplomacy.advance(data, elapsed_time)

    if visible(new_data) != visible(data),
      do: FactionChannel.broadcast_change(state.channel, %{global_diplomacy: new_data})

    {%{state | data: new_data}, Diplomacy}
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
