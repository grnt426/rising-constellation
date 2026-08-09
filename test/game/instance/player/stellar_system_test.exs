defmodule Instance.Player.StellarSystemTest do
  @moduledoc """
  Locks the information boundary on the owner-channel copy of a system's
  characters (`Instance.Player.StellarSystem.visible_characters/1`).

  The player channel pushes this list to the system owner's client, so it
  must not reveal more than the sanctioned own-system faction view
  (visibility 5): foreign Erased still under cover must be absent, and no
  entry may carry a cover value (gated at visibility 6 — never client-
  visible). Before this filter the raw system copies leaked hidden spies
  and their exact cover values to anyone reading the socket.
  """

  use ExUnit.Case, async: true

  alias Instance.Player.StellarSystem, as: PlayerSystem
  alias Instance.StellarSystem.StellarSystem
  alias Test.FleetScenario

  # cover_threshold is 75 in every speed's constants; >= 75 is undercover
  @undercover_cover 80
  @discovered_cover 10

  setup do
    instance_id = FleetScenario.unique_instance_id()
    Data.Data.insert(instance_id, speed: :fast, mode: :prod)

    owner = %Instance.StellarSystem.Player{
      id: 7,
      avatar: "",
      name: "owner",
      faction: :ark,
      faction_id: 1
    }

    {:ok, instance_id: instance_id, owner: owner}
  end

  defp system_with(instance_id, owner, characters) do
    struct(StellarSystem, %{
      id: 101,
      instance_id: instance_id,
      owner: owner,
      characters: characters
    })
  end

  defp system_character(character_id, opts) do
    cover = Keyword.get(opts, :cover)

    FleetScenario.build_system_character(Keyword.merge([character_id: character_id], Keyword.delete(opts, :cover)))
    |> Map.put(:cover, cover)
  end

  test "foreign undercover Erased are removed entirely", %{instance_id: iid, owner: owner} do
    hidden = system_character(1, faction: :myrmezir, faction_id: 2, type: :spy, cover: @undercover_cover)
    system = system_with(iid, owner, [hidden])

    assert PlayerSystem.visible_characters(system) == []
  end

  test "foreign discovered Erased stay, but without their cover value",
       %{instance_id: iid, owner: owner} do
    exposed = system_character(1, faction: :myrmezir, faction_id: 2, type: :spy, cover: @discovered_cover)
    system = system_with(iid, owner, [exposed])

    assert [%{id: 1, type: :spy, cover: nil, owner: %{faction: :myrmezir}}] =
             PlayerSystem.visible_characters(system)
  end

  test "own-faction Erased stay visible even under cover, and keep their cover value",
       %{instance_id: iid, owner: owner} do
    # cover is faction-private: the owning faction may see it, nobody else
    own_spy = system_character(1, faction: :ark, faction_id: 1, type: :spy, cover: @undercover_cover)
    system = system_with(iid, owner, [own_spy])

    assert [%{id: 1, type: :spy, cover: @undercover_cover}] = PlayerSystem.visible_characters(system)
  end

  test "non-spies pass through with the vis-5 field set and no cover",
       %{instance_id: iid, owner: owner} do
    navarch = system_character(1, faction: :myrmezir, faction_id: 2, type: :admiral)
    system = system_with(iid, owner, [navarch])

    assert [visible] = PlayerSystem.visible_characters(system)
    assert %{id: 1, type: :admiral, name: "char-1", level: 1, protection: 10, determination: 10} = visible
    assert visible.cover == nil
    assert visible.owner.faction == :myrmezir
  end

  test "convert/1 routes characters through the filter", %{instance_id: iid, owner: owner} do
    # a mixed roster: one hidden foreign spy (must vanish), one foreign
    # navarch (must stay) — asserted through the full convert/1 output
    hidden = system_character(1, faction: :myrmezir, faction_id: 2, type: :spy, cover: @undercover_cover)
    navarch = system_character(2, faction: :myrmezir, faction_id: 2, type: :admiral)

    system =
      struct(StellarSystem, %{
        id: 101,
        instance_id: iid,
        name: "sys-101",
        type: :red_dwarf,
        status: :inhabited_player,
        position: %Spatial.Position{x: 0.0, y: 0.0},
        sector_id: 1,
        governor: nil,
        owner: owner,
        characters: [hidden, navarch],
        queue: Instance.StellarSystem.ProductionQueue.new(),
        workforce: 0,
        habitation: Core.Value.new(),
        production: Core.Value.new(),
        technology: Core.Value.new(),
        ideology: Core.Value.new(),
        credit: Core.Value.new(),
        happiness: Core.Value.new(),
        defense: Core.Value.new(),
        radar: Core.Value.new(),
        siege: nil
      })

    converted = PlayerSystem.convert(system)
    assert [%{id: 2, type: :admiral, cover: nil}] = converted.characters
  end
end
