defmodule Portal.FightController do
  use Portal, :controller

  alias Instance.Character.Character
  alias Instance.Character.Player
  alias Instance.Character.Army

  def run(conn, %{"attacker" => attacker_spec, "defender" => defender_spec} = params) do
    instance_id = balance_instance(Map.get(params, "balance", "baseline"))

    attacker = build_character(1, "Joueur 1", :myrmezir, 1, attacker_spec, instance_id)
    defender = build_character(2, "Joueur 2", :tetrarchy, 2, defender_spec, instance_id)

    {{attackers, defenders}, logs, metadata, _} = Fight.Manager.fight([attacker], [defender])

    attackers = Enum.map(attackers, fn {_, _, character} -> character end)
    defenders = Enum.map(defenders, fn {_, _, character} -> character end)

    conn
    |> put_status(200)
    |> json(%{
      initial: %{attackers: [attacker], defenders: [defender]},
      final: %{attackers: attackers, defenders: defenders},
      logs: logs,
      metadata: metadata
    })
  end

  # Sim.Balance presets (`%{name => %{base_ship_key => %{field => value}}}`) so
  # the simulator can show what a balance mode changes vs. live data.
  def balances(conn, _params) do
    conn
    |> put_status(200)
    |> json(Sim.Balance.presets())
  end

  # Build an admiral + army from a side spec: `%{"tiles" => [tile, ...]}` where
  # each tile is null, a bare "ship_key" string (legacy), or
  # `%{"ship_key" => k, "level" => l}`. Combat reads `ship.level` directly, so we
  # set it on the built ship (matching Sim.Fleet) rather than feeding XP through
  # the level curve.
  defp build_character(id, name, faction, faction_id, spec, instance_id) do
    tiles = Map.get(spec, "tiles", [])

    character = Character.new(id, :admiral, :common, 1, instance_id)

    character = %{
      character
      | owner: %Player{id: id, name: name, faction: faction, faction_id: faction_id},
        status: :on_board,
        action_status: :idle,
        army: Army.new(instance_id)
    }

    {character, _index} =
      Enum.reduce(tiles, {character, 1}, fn tile, {character, index} ->
        case tile_spec(tile) do
          nil ->
            {character, index + 1}

          {ship_key, level} ->
            {:ok, character} = Character.order_ship(character, {nil, index, ship_key, nil})

            character =
              character
              |> Character.put_ship(index, 0.0)
              |> set_ship_level(index, level)

            {character, index + 1}
        end
      end)

    character
  end

  defp tile_spec(nil), do: nil

  defp tile_spec(key) when is_binary(key) do
    case safe_ship(key) do
      nil -> nil
      ship -> {ship, 0}
    end
  end

  defp tile_spec(%{"ship_key" => key} = tile) when is_binary(key) do
    case safe_ship(key) do
      nil -> nil
      ship -> {ship, normalize_level(Map.get(tile, "level", 0))}
    end
  end

  defp tile_spec(_), do: nil

  defp safe_ship(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_level(level) when is_integer(level) and level > 0, do: level
  defp normalize_level(_), do: 0

  # Pin the ship to a flat level (experience reset), mirroring Sim.Fleet — the
  # fight scales unit stats off ship.level, which is all combat reads.
  defp set_ship_level(character, _tile_id, level) when level <= 0, do: character

  defp set_ship_level(character, tile_id, level) do
    tiles =
      Enum.map(character.army.tiles, fn t ->
        if t.id == tile_id and t.ship_status == :filled and is_map(t.ship),
          do: %{t | ship: %{t.ship | level: level, experience: 0.0}},
          else: t
      end)

    %{character | army: %{character.army | tiles: tiles}}
  end

  # Simulator balance presets: run against live game data (:fast_prod) or a
  # sim-only Sim.Balance preset applied to the cached :sim dataset, so a
  # candidate rebalance can be A/B-tested in the simulator WITHOUT editing the
  # content files. Combat stats are identical across game speeds, so :fast is
  # fine here. Unknown/invalid names fall back to live data.
  defp balance_instance(name) when name in [nil, "", "baseline"], do: :fast_prod

  defp balance_instance(name) do
    case safe_preset(name) do
      nil ->
        :fast_prod

      preset ->
        Sim.Setup.install([speed: :fast, mode: :prod], Sim.Balance.changes(preset))
        :sim
    end
  end

  defp safe_preset(name) do
    preset = String.to_existing_atom(name)
    if preset in Sim.Balance.names(), do: preset, else: nil
  rescue
    ArgumentError -> nil
  end
end
