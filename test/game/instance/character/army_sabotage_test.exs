defmodule Instance.Character.ArmySabotageTest do
  use ExUnit.Case, async: true

  alias Instance.Character.{Army, Ship}

  # :fast_prod resolves game data without a running instance, and the
  # inline :rand clause in Game.call covers the tile draw.
  @iid :fast_prod

  defp put_ship(army, tile_id, key) do
    data = Data.Querier.one(Data.Game.Ship, @iid, key)

    army
    |> Army.plan_ship(tile_id, data, nil)
    |> Army.put_ship(tile_id, 0, nil)
  end

  defp tile(army, id), do: Enum.find(army.tiles, &(&1.id == id))

  defp refute_zombies(army) do
    for t <- army.tiles, t.ship_status == :filled do
      refute Ship.is_destroyed(t.ship),
             "tile #{t.id} holds a fully-floored ship (#{t.ship.key}) instead of being emptied"
    end
  end

  describe "direct hit" do
    test "removes the ship outright when pv exceeds its total hull" do
      # 8 interceptors: 8 x 25 = 200 total
      army = put_ship(Army.new(@iid), 1, :fighter_4v3)

      {after_army, logs} = Army.sabotage(army, @iid, 864)

      assert tile(after_army, 1).ship_status == :empty
      assert :lost_ship in logs
    end

    test "removes the ship when per-unit damage floors every unit" do
      # 4 multi-turret corvettes: 4 x 335 = 1340 total, so 864 takes the
      # survive branch — but 864 > 335 floors all four units at once
      army = put_ship(Army.new(@iid), 1, :corvette_3v2)

      {after_army, logs} = Army.sabotage(army, @iid, 864)

      assert tile(after_army, 1).ship_status == :empty
      assert :lost_ship in logs
    end

    test "applies pv to every unit equally when they survive" do
      # 2 assault frigates: 2 x 200
      army = put_ship(Army.new(@iid), 1, :frigate_1)

      {after_army, logs} = Army.sabotage(army, @iid, 108)

      t = tile(after_army, 1)
      assert t.ship_status == :filled
      assert Enum.all?(t.ship.units, &(&1.hull == 92))
      assert :damaged_ship in logs
    end
  end

  describe "splash" do
    test "a splash-floored neighbor is removed, not left as a wreck" do
      # whichever tile the draw picks, its neighbor's fate is deterministic:
      # drawing t1 (1340 < 5000, removed) blasts 134 onto t2's interceptors
      # (400 total, 25/unit -> all floored); drawing t2 (400 < 5000, removed)
      # blasts 40 onto t1's corvettes (335 -> 295 each)
      army =
        Army.new(@iid)
        |> put_ship(1, :corvette_3v2)
        |> put_ship(2, :fighter_4v4)

      {after_army, _logs} = Army.sabotage(army, @iid, 5000)

      refute_zombies(after_army)

      case {tile(after_army, 1).ship_status, tile(after_army, 2).ship_status} do
        {:empty, :empty} ->
          :ok

        {:filled, :empty} ->
          assert Enum.all?(tile(after_army, 1).ship.units, &(&1.hull == 295))

        other ->
          flunk("unexpected tile states: #{inspect(other)}")
      end
    end

    test "splash stays at 10% of calculated pv when the primary is floored (Phura case)" do
      # prod instance 87 regression: coef-144 success (pv 864) on 4x MT
      # corvette next to 2x assault frigate. The corvettes floor (now:
      # removed); the frigates must still take exactly 86.4 per unit.
      army =
        Army.new(@iid)
        |> put_ship(1, :corvette_3v2)
        |> put_ship(2, :frigate_1)

      {after_army, _logs} = Army.sabotage(army, @iid, 864)

      refute_zombies(after_army)

      case {tile(after_army, 1).ship_status, tile(after_army, 2).ship_status} do
        {:empty, :filled} ->
          assert Enum.all?(tile(after_army, 2).ship.units, &(&1.hull == 200 - 86.4))

        {:filled, :empty} ->
          # draw hit the frigates instead (400 < 864, removed; blast 40)
          assert Enum.all?(tile(after_army, 1).ship.units, &(&1.hull == 295))

        other ->
          flunk("unexpected tile states: #{inspect(other)}")
      end
    end
  end

  test "repeated sabotage never leaves a floored ship on a filled tile" do
    fleet =
      Army.new(@iid)
      |> put_ship(1, :corvette_3v2)
      |> put_ship(2, :frigate_1)
      |> put_ship(3, :corvette_3v2)
      |> put_ship(4, :fighter_4v4)
      |> put_ship(5, :corvette_3v2)

    for _ <- 1..50 do
      {after_army, _logs} = Army.sabotage(fleet, @iid, 864)
      refute_zombies(after_army)
    end
  end
end
