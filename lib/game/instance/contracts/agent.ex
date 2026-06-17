defmodule Instance.Contracts.Agent do
  @moduledoc """
  Singleton (`:contracts` / `:master`) TickServer that owns the per-instance contract
  registry. Mirrors `Instance.CharacterMarket.Agent`: the pure logic lives in
  `Instance.Contracts.Contracts` / `Instance.Contracts.Contract`; this agent serializes
  mutations, fetches the absolute game-time, broadcasts the board, and performs the
  side effects a pure module cannot — moving escrowed credits (async, deadlock-safe
  casts) when a contract resolves, pushing text notifications to the parties, and
  writing terminal outcomes to the instance event log. Strikes are applied inside the
  registry.
  """
  use Core.TickServer

  alias Instance.Contracts.{Contract, Contracts}
  alias Portal.Controllers.GlobalChannel
  alias RC.Instances.InstanceEventLog

  @decorate tick()
  def on_call(:get_state, _, state) do
    {:reply, {:ok, state.data}, state}
  end

  @decorate tick()
  def on_call(:get_contracts, _, state) do
    {:reply, {:ok, Contracts.all(state.data)}, state}
  end

  # Register a contract whose bounty the payer's Player.Agent has already escrowed.
  @decorate tick()
  def on_call({:create, payer_id, attrs}, _, state) do
    case Contracts.create(state.data, payer_id, attrs, now(state)) do
      {:ok, data, contract} ->
        broadcast(state, data)
        {:reply, {:ok, contract}, %{state | data: data}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @decorate tick()
  def on_call({:claim, contract_id, performer_id}, _, state) do
    case Contracts.claim(state.data, contract_id, performer_id, now(state)) do
      {:ok, data, contract} ->
        broadcast(state, data)
        notify(state, contract.payer_id, :contract_claimed, %{id: contract.id})
        {:reply, {:ok, contract}, %{state | data: data}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @decorate tick()
  def on_call({:submit_closure, contract_id, submitter_id, raw_intent}, _, state) do
    intent = Contract.parse_closure_intent(raw_intent)

    case Contracts.submit_closure(state.data, contract_id, submitter_id, intent) do
      {:ok, data, contract} ->
        broadcast(state, data)
        notify_counterparty(state, contract, submitter_id, :contract_closure, %{id: contract.id})
        {:reply, {:ok, contract}, %{state | data: data}}

      {:resolved, data, effects} ->
        apply_resolution(state, effects)
        broadcast(state, data)
        {:reply, {:ok, effects.contract}, %{state | data: data}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @decorate tick()
  def on_call({:withdraw_closure, contract_id, submitter_id}, _, state) do
    case Contracts.withdraw_closure(state.data, contract_id, submitter_id) do
      {:ok, data, contract} ->
        broadcast(state, data)
        {:reply, {:ok, contract}, %{state | data: data}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @decorate tick()
  def on_call({:cancel, contract_id, payer_id}, _, state) do
    case Contracts.cancel(state.data, contract_id, payer_id) do
      {:resolved, data, effects} ->
        apply_resolution(state, effects)
        broadcast(state, data)
        {:reply, {:ok, effects.contract}, %{state | data: data}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @decorate tick()
  def on_info(:tick, state) do
    {:noreply, state}
  end

  defp do_next_tick(state, _elapsed) do
    {data, effects_list} = Contracts.next_tick(state.data, now(state))
    Enum.each(effects_list, &apply_resolution(state, &1))
    unless effects_list == [], do: broadcast(state, data)
    {%{state | data: data}, Contracts}
  end

  # Absolute instance game-time (in-game days). Read from Instance.Time rather than
  # accumulating tick deltas, so the clock stays correct even after long idle stretches
  # where this agent's interval was :never (no open contracts to wait on).
  defp now(state) do
    case Game.call(state.instance_id, :time, :master, :get_state) do
      {:ok, time} -> time.now.value
      _ -> 0.0
    end
  end

  # v1: broadcast the whole registry on the global channel. Simple and correct while
  # all contracts are public; revisit (per-party views / pagination) if volume grows.
  defp broadcast(state, data) do
    GlobalChannel.broadcast_change(state.channel, %{global_contracts: Contracts.all(data)})
  end

  # ── resolution side effects: move credits, notify the parties, write the audit log ──
  defp apply_resolution(state, effects) do
    apply_credit(state, effects)
    notify_resolution(state, effects)
    log_resolution(state, effects)
  end

  # Credits only — strikes were already applied inside the registry. Async casts keep
  # us off the Player <-> Player deadlock path (same rationale as the offer market).
  defp apply_credit(state, %{outcome: :paid} = effects),
    do: credit_player(state, effects.contract.performer_id, effects.payout)

  defp apply_credit(state, %{outcome: outcome} = effects) when outcome in [:refunded, :disputed],
    do: credit_player(state, effects.contract.payer_id, effects.refund)

  defp credit_player(_state, nil, _amount), do: :ok
  defp credit_player(_state, _player_id, amount) when amount <= 0, do: :ok

  defp credit_player(state, player_id, amount),
    do: Game.cast(state.instance_id, :player, player_id, {:add_resources, amount, 0, 0})

  # ── notifications (best-effort text toasts; both parties learn the outcome) ──
  defp notify_resolution(state, %{outcome: :paid, contract: c} = effects) do
    notify(state, c.payer_id, :contract_paid, %{id: c.id, amount: effects.payout})
    notify(state, c.performer_id, :contract_paid, %{id: c.id, amount: effects.payout})
  end

  defp notify_resolution(state, %{outcome: :refunded, contract: c} = effects) do
    notify(state, c.payer_id, :contract_refunded, %{id: c.id, amount: effects.refund})
    notify(state, c.performer_id, :contract_refunded, %{id: c.id, amount: effects.refund})
  end

  defp notify_resolution(state, %{outcome: :disputed, contract: c}) do
    notify(state, c.payer_id, :contract_disputed, %{id: c.id})
    notify(state, c.performer_id, :contract_disputed, %{id: c.id})
  end

  defp notify_counterparty(state, contract, submitter_id, key, data) do
    other = if submitter_id == contract.payer_id, do: contract.performer_id, else: contract.payer_id
    notify(state, other, key, data)
  end

  defp notify(_state, nil, _key, _data), do: :ok

  defp notify(state, player_id, key, data) do
    notif = Notification.Text.new(key, nil, data)
    Game.cast(state.instance_id, :player, player_id, {:push_notifs, notif})
  catch
    _, _ -> :ok
  rescue
    _ -> :ok
  end

  # ── audit log: terminal outcome -> instance_event_log (fire-and-forget, best-effort) ──
  defp log_resolution(state, %{contract: c} = effects) do
    InstanceEventLog.emit(state.instance_id, "contract_resolved", %{
      system_id: c.target_system_id,
      character_id: c.target_character_id,
      payload: %{
        contract_id: c.id,
        outcome: effects.outcome,
        action_category: c.action_category,
        payer_id: c.payer_id,
        performer_id: c.performer_id,
        bounty: c.bounty,
        payout: effects.payout,
        refund: effects.refund,
        listing_fee: c.listing_fee,
        closing_fee: c.closing_fee,
        strike: effects.strike
      }
    })
  end
end
