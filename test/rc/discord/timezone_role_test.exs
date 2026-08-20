defmodule RC.Discord.TimezoneRoleTest do
  use ExUnit.Case, async: true

  # Pure planning logic for the on-demand timezone role tags. The
  # Nostrum-effect side is deliberately untested (no gateway in :test);
  # plan/3 carries all the decisions.

  alias RC.Discord.TimezoneRole

  defp role(id, name), do: %{id: id, name: name}

  test "role_name/1 and timezone_role?/1" do
    assert TimezoneRole.role_name("Europe/Paris") == "TZ: Europe/Paris"
    assert TimezoneRole.timezone_role?("TZ: Europe/Paris")
    refute TimezoneRole.timezone_role?("Cardan Legacy")
    refute TimezoneRole.timezone_role?(nil)
  end

  test "first user of a zone in the guild: create (and implicitly assign)" do
    guild_roles = [role(1, "Cardan Legacy"), role(2, "TZ: America/Chicago")]

    assert TimezoneRole.plan("TZ: Europe/Paris", [1], guild_roles) ==
             %{remove: [], add: nil, create: "TZ: Europe/Paris"}
  end

  test "existing role in guild but not on member: add without creating" do
    guild_roles = [role(2, "TZ: Europe/Paris")]

    assert TimezoneRole.plan("TZ: Europe/Paris", [], guild_roles) ==
             %{remove: [], add: 2, create: nil}
  end

  test "member already tagged correctly: no-op" do
    guild_roles = [role(2, "TZ: Europe/Paris")]

    assert TimezoneRole.plan("TZ: Europe/Paris", [2], guild_roles) ==
             %{remove: [], add: nil, create: nil}
  end

  test "timezone change swaps the old tag for the new one" do
    guild_roles = [role(2, "TZ: Europe/Paris"), role(3, "TZ: America/Chicago")]

    assert TimezoneRole.plan("TZ: America/Chicago", [2], guild_roles) ==
             %{remove: [2], add: 3, create: nil}
  end

  test "disabling the tag strips every TZ role but touches nothing else" do
    guild_roles = [role(1, "Cardan Legacy"), role(2, "TZ: Europe/Paris"), role(3, "TZ: America/Chicago")]

    assert TimezoneRole.plan(nil, [1, 2, 3], guild_roles) ==
             %{remove: [2, 3], add: nil, create: nil}
  end

  test "role-name matching is case-insensitive" do
    guild_roles = [role(2, "tz: europe/paris")]

    assert TimezoneRole.plan("TZ: Europe/Paris", [2], guild_roles) ==
             %{remove: [], add: nil, create: nil}
  end
end
