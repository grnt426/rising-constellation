defmodule Wave.Budget do
  @moduledoc """
  What the Rebellion's systems may still spend on construction: one credit
  allowance per Wave Defense instance. The Warlord sets it on every pass
  (`Wave.Warlord.construction_allowance/6`), and a rebel system draws from it
  for every build, upgrade or repair its tree orders
  (`Wave.Construction.charge/2`).

  A system must not call its owner from its own tick (the owner may be
  calling the system at that moment), so the allowance sits in a public ETS
  table that both reach without a message. A draw is a compare-and-swap:
  systems ticking at the same moment can never spend the same credit twice.
  The credit itself leaves the bot player by a cast, `{:pay_construction,
  credit}`.

  One row per instance: `{instance_id, remaining, spent}`, in whole credits.
  `spent` is what the systems have drawn, less what came back. The table is
  node-local and not snapshotted: after a restart the Warlord's next pass
  sets the allowance again from what it last saw (`Warlord` field
  `construction`). Until a row exists, a rebel system orders nothing.

  Every read fails safe when the table is missing (a supervisor restart):
  nothing to spend.
  """
  use GenServer

  @table :wave_construction_budget

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end

  @doc "Set what the instance's systems may still spend, keeping what they have spent."
  def put(instance_id, credit) when is_number(credit) do
    remaining = max(trunc(credit), 0)

    unless :ets.update_element(@table, instance_id, {2, remaining}),
      do: :ets.insert_new(@table, {instance_id, remaining, 0}) || put(instance_id, credit)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "What the instance's systems may still spend; nil before the Warlord set anything."
  def available(instance_id) do
    case :ets.lookup(@table, instance_id) do
      [{_, remaining, _spent}] -> remaining
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "What the instance's systems have drawn, less what came back."
  def spent(instance_id) do
    case :ets.lookup(@table, instance_id) do
      [{_, _remaining, spent}] -> spent
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Draw `credit` from the allowance: `:ok` when it covers the whole amount,
  `:insufficient` (and nothing drawn) otherwise.
  """
  def take(_instance_id, credit) when credit <= 0, do: :ok

  def take(instance_id, credit) do
    credit = ceil(credit)

    case :ets.lookup(@table, instance_id) do
      [{_, remaining, spent} = row] when remaining >= credit ->
        if swap(row, {instance_id, remaining - credit, spent + credit}),
          do: :ok,
          else: take(instance_id, credit)

      _ ->
        :insufficient
    end
  rescue
    ArgumentError -> :insufficient
  end

  @doc "Return credit to the allowance: an order that was paid for and did not happen."
  def give_back(_instance_id, credit) when credit <= 0, do: :ok

  def give_back(instance_id, credit) do
    credit = trunc(credit)

    case :ets.lookup(@table, instance_id) do
      [{_, remaining, spent} = row] ->
        unless swap(row, {instance_id, remaining + credit, max(spent - credit, 0)}),
          do: give_back(instance_id, credit)

        :ok

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Forget the instance (its game ended or was deleted)."
  def clear(instance_id) do
    :ets.delete(@table, instance_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Replace `old` with `new` only if the row is still exactly `old`.
  defp swap(old, new), do: :ets.select_replace(@table, [{old, [], [{:const, new}]}]) == 1
end
