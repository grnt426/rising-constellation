defmodule Instance.Contracts.Contracts do
  @moduledoc """
  The per-instance registry of Agent Contracts, plus each player's permanent broker
  **strike** tally. This is the source of truth for live contracts and is snapshotted
  with the owning `Instance.Contracts.Agent`.

  Like `Instance.Contracts.Contract`, this module is PURE: it mutates only its own
  struct and, on resolution, returns `effects` for the agent to act on (credit casts,
  broadcasts, event-log writes). It never calls other agents.

  Strikes live here, keyed by player_id, and are per-instance — breaking contracts in
  one game never follows a player to another.

  `clock` mirrors the instance game-time as of the last create/claim/tick the agent
  fed in (the agent reads it from `Instance.Time`). `created_at`/`deadline` on each
  contract are stamped from it, and `compute_next_tick_interval/1` measures the next
  expiry against it.
  """
  use TypedStruct

  alias Instance.Contracts.Contract

  def jason(), do: [except: [:instance_id]]

  typedstruct enforce: true do
    field(:by_id, %{integer() => Contract.t()}, default: %{})
    field(:strikes, %{integer() => non_neg_integer()}, default: %{})
    field(:counter, integer(), default: 1)
    field(:clock, float(), default: 0.0)
    field(:instance_id, integer())
  end

  def new(instance_id) do
    %__MODULE__{by_id: %{}, strikes: %{}, counter: 1, clock: 0.0, instance_id: instance_id}
  end

  # ── reads ───────────────────────────────────────────────────────────────────

  def get(state, id), do: Map.get(state.by_id, id)
  def all(state), do: Map.values(state.by_id)

  @doc "A player's permanent broker strike count in this instance (0 if never struck)."
  def strikes(state, player_id), do: Map.get(state.strikes, player_id, 0)

  defp put(state, %Contract{} = c), do: %{state | by_id: Map.put(state.by_id, c.id, c)}

  defp add_strike(state, player_id),
    do: %{state | strikes: Map.update(state.strikes, player_id, 1, &(&1 + 1))}

  # ── create ──────────────────────────────────────────────────────────────────

  @doc """
  Register a new listed contract for `payer_id`. The caller (the payer's Player.Agent)
  has already escrowed `attrs.bounty`. The id counter only advances on success.

  Returns `{:ok, state, contract} | {:error, reason}`.
  """
  def create(state, payer_id, attrs, now) do
    case Contract.new(state.counter, payer_id, attrs, now) do
      {:ok, contract} ->
        {:ok, %{put(state, contract) | counter: state.counter + 1, clock: now * 1.0}, contract}

      {:error, _} = err ->
        err
    end
  end

  # ── claim ───────────────────────────────────────────────────────────────────

  @doc """
  Claim a listed contract for `performer_id`, locking the fee snapshot from both
  parties' current strike counts. Returns `{:ok, state, contract} | {:error, reason}`.
  """
  def claim(state, id, performer_id, now) do
    case get(state, id) do
      nil ->
        {:error, :contract_not_found}

      c ->
        case Contract.claim(c, performer_id, strikes(state, c.payer_id), strikes(state, performer_id), now) do
          {:ok, updated} -> {:ok, %{put(state, updated) | clock: now * 1.0}, updated}
          {:error, _} = err -> err
        end
    end
  end

  # ── closures ────────────────────────────────────────────────────────────────

  @doc """
  Record a closure intent. If both sides have now submitted, the contract resolves
  immediately. Returns one of:

    * `{:ok, state, contract}`      — recorded, not yet resolved
    * `{:resolved, state, effects}` — recorded and resolved; the agent applies `effects`
    * `{:error, reason}`
  """
  def submit_closure(state, id, submitter_id, intent) do
    case get(state, id) do
      nil ->
        {:error, :contract_not_found}

      c ->
        case Contract.submit_closure(c, submitter_id, intent) do
          {:ok, updated} ->
            state = put(state, updated)
            if Contract.ready_to_resolve?(updated), do: finalize(state, updated), else: {:ok, state, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Retract a previously-submitted closure intent. `{:ok, state, contract} | {:error, reason}`."
  def withdraw_closure(state, id, submitter_id) do
    case get(state, id) do
      nil ->
        {:error, :contract_not_found}

      c ->
        case Contract.withdraw_closure(c, submitter_id) do
          {:ok, updated} -> {:ok, put(state, updated), updated}
          {:error, _} = err -> err
        end
    end
  end

  @doc "Issuer voids a still-unclaimed listing. `{:resolved, state, effects} | {:error, reason}`."
  def cancel(state, id, payer_id) do
    case get(state, id) do
      nil ->
        {:error, :contract_not_found}

      c ->
        case Contract.cancel(c, payer_id) do
          {:ok, effects} -> {:resolved, apply_effects(state, effects), effects}
          {:error, _} = err -> err
        end
    end
  end

  # ── tick / expiry ─────────────────────────────────────────────────────────--

  @doc """
  Advance the clock to `now` and resolve every contract whose deadline has passed.
  Returns `{state, effects_list}` — the agent applies each effect (credit + broadcast +
  event log). `effects_list` is empty when nothing expired.
  """
  def next_tick(state, now) do
    state = %{state | clock: now * 1.0}

    state
    |> all()
    |> Enum.filter(&Contract.expired?(&1, state.clock))
    |> Enum.reduce({state, []}, fn c, {st, acc} ->
      {:ok, effects} = Contract.resolve(c)
      {apply_effects(st, effects), [effects | acc]}
    end)
  end

  @doc """
  Game-time units until the next contract expires, or `:never` if none are open. Uses
  the term-ordering trick (numbers sort before atoms) so `:never` is the max sentinel.
  """
  def compute_next_tick_interval(state) do
    ticks =
      state
      |> all()
      |> Enum.reject(&Contract.terminal?/1)
      |> Enum.map(fn c -> max(c.deadline - state.clock, 0.0) end)

    Enum.min([:never | ticks])
  end

  # ── internal ──────────────────────────────────────────────────────────────--

  defp finalize(state, contract) do
    {:ok, effects} = Contract.resolve(contract)
    {:resolved, apply_effects(state, effects), effects}
  end

  # Store the terminal contract and, on a dispute, add the permanent strike to BOTH
  # parties. Credit movements are NOT done here (the registry is pure) — they ride out
  # in `effects` for the agent to cast to the Player.Agents.
  defp apply_effects(state, effects) do
    state = put(state, effects.contract)

    if effects.strike == 1 do
      state
      |> add_strike(effects.contract.payer_id)
      |> add_strike(effects.contract.performer_id)
    else
      state
    end
  end
end
