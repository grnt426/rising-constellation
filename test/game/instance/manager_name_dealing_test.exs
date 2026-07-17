defmodule Game.Instance.ManagerNameDealingTest do
  @moduledoc """
  Pure tests for Instance.Manager.deal_names/5 — the faction-sector flavored
  name dealing. Pool wiring and ratios are covered end-to-end in
  system_name_uniqueness_test.exs.
  """
  use ExUnit.Case, async: true

  alias Instance.Manager

  # Spec tuples mirror the manager's {idx, system, sector_key, instance_id, opts}.
  defp spec(idx, sector_key), do: {idx, %{}, sector_key, 0, []}

  test "flavored systems deal from the culture pool, the rest from global, all unique" do
    specs = [spec(0, 1), spec(1, 1), spec(2, 1), spec(3, 1), spec(0, 2)]
    sector_cultures = %{1 => :x}
    flavored_idxs = %{1 => MapSet.new([0, 1, 3])}
    culture_pools = %{x: ["c1", "c2"]}
    # c1/c2 embedded in global: dealt culture names must be skipped, not duplicated.
    global = ["g1", "c1", "c2", "g2", "g3"]

    names = Manager.deal_names(specs, sector_cultures, flavored_idxs, culture_pools, global)

    # idx 3 is flavored but the culture pool is exhausted by then -> global.
    assert names == ["c1", "c2", "g1", "g2", "g3"]
    assert length(Enum.uniq(names)) == length(names)
  end

  test "sectors without a culture deal purely from global" do
    specs = [spec(0, 7), spec(1, 7)]
    names = Manager.deal_names(specs, %{}, %{}, %{}, ["a", "b"])

    assert names == ["a", "b"]
  end
end
