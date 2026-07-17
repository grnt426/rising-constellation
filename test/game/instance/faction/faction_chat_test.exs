defmodule Instance.Faction.FactionChatTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.Faction

  @moduledoc """
  Genesis chat seeding + system chat messages for cheat-enabled games.
  Uses the metadata cache directly (like GovernmentTest) — no instance
  boot, no DB.
  """

  @cheat_iid 999_999_888
  @plain_iid 999_999_887

  setup_all do
    Data.Data.insert(@cheat_iid, speed: :fast, mode: :prod, cheats_enabled: true)
    Data.Data.insert(@plain_iid, speed: :fast, mode: :prod)

    on_exit(fn ->
      Data.Data.clear(@cheat_iid)
      Data.Data.clear(@plain_iid)
    end)

    :ok
  end

  defp db_faction, do: %{id: 1, faction_ref: "myrmezir"}

  test "genesis chat carries the cheats announcement on a cheats-enabled instance" do
    faction = Faction.new(db_faction(), @cheat_iid)

    assert [%{from: "SYSTEM", from_id: nil, message: message}] = faction.chat
    assert message == Instance.Cheats.chat_announcement()
  end

  test "genesis chat is empty on a normal instance" do
    assert Faction.new(db_faction(), @plain_iid).chat == []
  end

  test "push_system_message appends a nil-from_id SYSTEM line" do
    faction =
      db_faction()
      |> Faction.new(@plain_iid)
      |> Faction.push_system_message("hello")

    assert [%{from: "SYSTEM", from_id: nil, message: "hello"}] = faction.chat
  end

  test "cheat helpers default to disabled / 1x outside a live instance" do
    refute Instance.Cheats.enabled?(123_456_789)
    assert Instance.Cheats.speedup(123_456_789) == 1
  end

  test "speedup reads the persisted multiplier from the metadata cache" do
    Data.Data.update_metadata(@cheat_iid, :cheat_speedup, 20)
    assert Instance.Cheats.speedup(@cheat_iid) == 20
    assert Instance.Cheats.enabled?(@cheat_iid)
  after
    Data.Data.update_metadata(@cheat_iid, :cheat_speedup, 1)
  end
end
