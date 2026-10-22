defmodule Wave.BudgetTest do
  use ExUnit.Case, async: true

  setup do
    iid = System.unique_integer([:positive])
    on_exit(fn -> Wave.Budget.clear(iid) end)
    {:ok, iid: iid}
  end

  test "holds nothing until the Warlord sets it", %{iid: iid} do
    assert Wave.Budget.available(iid) == nil
    assert Wave.Budget.spent(iid) == 0
    assert Wave.Budget.take(iid, 1) == :insufficient
  end

  test "a draw takes the whole amount or nothing", %{iid: iid} do
    Wave.Budget.put(iid, 1_000.9)
    assert Wave.Budget.available(iid) == 1_000

    assert Wave.Budget.take(iid, 600) == :ok
    assert Wave.Budget.take(iid, 600) == :insufficient
    assert Wave.Budget.available(iid) == 400
    assert Wave.Budget.spent(iid) == 600

    # a refund goes back to the allowance and off what was spent
    Wave.Budget.give_back(iid, 100)
    assert Wave.Budget.available(iid) == 500
    assert Wave.Budget.spent(iid) == 500
  end

  test "setting the allowance again keeps what was spent", %{iid: iid} do
    Wave.Budget.put(iid, 1_000)
    :ok = Wave.Budget.take(iid, 300)
    Wave.Budget.put(iid, 5_000)

    assert Wave.Budget.available(iid) == 5_000
    assert Wave.Budget.spent(iid) == 300
    Wave.Budget.put(iid, -10)
    assert Wave.Budget.available(iid) == 0
  end

  test "systems drawing at the same moment never spend the same credit twice", %{iid: iid} do
    Wave.Budget.put(iid, 10_000)

    results =
      1..200
      |> Task.async_stream(fn _ -> Wave.Budget.take(iid, 70) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, result} -> result end)

    taken = Enum.count(results, &(&1 == :ok))
    assert taken == div(10_000, 70)
    assert Wave.Budget.available(iid) == 10_000 - taken * 70
    assert Wave.Budget.spent(iid) == taken * 70
  end
end
