defmodule RC.Discord.RoleSyncTest do
  @moduledoc """
  Pure-planner tests for role reconciliation. RoleSync's GenServer is
  :ignore'd in :test (no gateway); `sync_plan/2` is the diff core the
  event-driven syncs, activation bulk sync, and the 10-minute drift
  pass all share — these pin that only *needed* writes are planned.
  """

  use ExUnit.Case, async: true

  alias RC.Discord.RoleSync

  @tet_role 111
  @myr_role 222

  test "adds the active faction's role only when the member lacks it" do
    states = [{"tetrarchy", @tet_role, :active}, {"myrmezir", @myr_role, :none}]

    assert RoleSync.sync_plan(states, []) ==
             %{add: [{"tetrarchy", @tet_role}], remove: []}

    assert RoleSync.sync_plan(states, [@tet_role]) == %{add: [], remove: []}
  end

  test "removes roles for factions the player is not (or no longer) in" do
    states = [{"tetrarchy", @tet_role, :none}, {"myrmezir", @myr_role, :inactive}]

    assert RoleSync.sync_plan(states, [@tet_role, @myr_role]) ==
             %{add: [], remove: [{"tetrarchy", @tet_role}, {"myrmezir", @myr_role}]}

    # Roles the member doesn't carry produce no remove calls — half the
    # 2026-08-22 403 noise was blind removes of never-held roles.
    assert RoleSync.sync_plan(states, []) == %{add: [], remove: []}
  end

  test "a faction switch plans one add and one remove" do
    states = [{"tetrarchy", @tet_role, :none}, {"myrmezir", @myr_role, :active}]

    assert RoleSync.sync_plan(states, [@tet_role]) ==
             %{add: [{"myrmezir", @myr_role}], remove: [{"tetrarchy", @tet_role}]}
  end

  test "an unresolved role id is skipped in both directions" do
    states = [{"tetrarchy", nil, :active}, {"myrmezir", nil, :none}]

    assert RoleSync.sync_plan(states, [@tet_role]) == %{add: [], remove: []}
  end

  test "unrelated member roles are never touched" do
    states = [{"tetrarchy", @tet_role, :active}]
    mod_role = 999

    assert RoleSync.sync_plan(states, [mod_role]) ==
             %{add: [{"tetrarchy", @tet_role}], remove: []}
  end
end
