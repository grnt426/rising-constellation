defmodule SystemAI.UniqueBuildingFilterTest do
  @moduledoc """
  The system AI must never draw a unique building that is already present —
  `:unique_body` on the target body, `:unique_system` anywhere in the system.
  Before the fix the filter compared `limitation == :unique` (a value no
  building uses), so duplicates stayed drawable and were only rejected
  downstream by `order_building_production`, silently burning the system's
  AI action (proven 2026-08-22 by a steered-RNG run of the real behavior
  tree: {:error, :already_one_on_body} / {:error, :already_one_on_system}).

  The end-to-end test drives the REAL `SystemAI.do_action` (parsed production
  behavior tree, real content, deterministic fake RNG) and asserts the action
  now succeeds by building something else.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias SystemAI.{BuildingsHelper, Helper}
  alias Test.FleetScenario

  @profiles [:production, :credit, :technologic, :ideologic, :defense]
  @categories [:production, :credit, :technologic, :ideologic, :defense]
  # r >= 0.5 keeps succeed_upgrade?(0.5, _) failing so the behavior tree falls
  # through to build_random instead of the upgrade branch
  @r_grid Enum.map(505..995//10, &(&1 / 1000))
  @system_values [5, 10, 20]

  defmodule BTGalaxy do
    @moduledoc false
    use GenServer

    def init(bt), do: {:ok, bt}
    def handle_call(:get_behavior_tree, _from, bt), do: {:reply, {:ok, bt}, bt}
  end

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :medium, mode: :prod)
    {:ok, iid: iid}
  end

  # Filter unit behavior

  test "an already-built :unique_body building is removed from the target body's pool", %{iid: iid} do
    for sv <- @system_values, target <- unique_candidates(iid, sv, :unique_body) do
      state = build_state(iid, target, :unique_body)
      body = target_body(state)
      bodies = Helper.get_bodies(state)

      for cat <- @categories do
        pool = drawable_pool(iid, sv, cat, body, bodies)

        refute Enum.any?(pool, &(&1.key == target.key)),
               "#{target.key} (built on body, :unique_body) still drawable in #{cat} pool at sv #{sv}"
      end
    end
  end

  test "a :unique_system building built on another body is removed from every pool", %{iid: iid} do
    for sv <- @system_values, target <- unique_candidates(iid, sv, :unique_system) do
      state = build_state(iid, target, :unique_system)
      body = target_body(state)
      bodies = Helper.get_bodies(state)

      for cat <- @categories do
        pool = drawable_pool(iid, sv, cat, body, bodies)

        refute Enum.any?(pool, &(&1.key == target.key)),
               "#{target.key} (built elsewhere, :unique_system) still drawable in #{cat} pool at sv #{sv}"
      end
    end
  end

  test "a planned (queued, not yet built) unique building counts as present", %{iid: iid} do
    [target | _] = unique_candidates(iid, 10, :unique_body)

    planned_tile = %{Tile.new(3, :primary) | construction_status: :new, building_key: target.key}

    body = %{
      uid: "1",
      type: :sterile_planet,
      tiles: [Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2), planned_tile, Tile.new(4, :primary)]
    }

    filtered = Helper.filter_already_built_unique_buildings([target], body, [body])
    assert filtered == []
  end

  test "non-unique duplicates stay drawable", %{iid: iid} do
    non_unique =
      BuildingsHelper.get_biome_buildings(:dome, iid)
      |> Enum.find(&(&1.limitation == :none and &1.type == :normal))

    assert non_unique != nil

    body = %{
      uid: "1",
      type: :sterile_planet,
      tiles: [
        Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2),
        Tile.new(2, :primary) |> Tile.force_building(non_unique.key, 1),
        Tile.new(3, :primary)
      ]
    }

    assert Helper.filter_already_built_unique_buildings([non_unique], body, [body]) == [non_unique]
  end

  # get_categories_proportion_built must drop a category whose pool the unique
  # filter empties — otherwise choose_category can draw a category with
  # nothing drawable and the behavior tree restarts forever (see the comment
  # on that function).
  test "category ratios and drawable pools stay consistent", %{iid: iid} do
    for sv <- @system_values, target <- unique_candidates(iid, sv, :unique_body) do
      state = build_state(iid, target, :unique_body)
      body = target_body(state)
      bodies = Helper.get_bodies(state)

      k = Helper.get_categories_proportion_built(body, bodies, :dome, sv, iid)

      for {cat, ratio} <- k, ratio != 1 do
        assert drawable_pool(iid, sv, cat, body, bodies) != [],
               "category #{cat} is drawable (ratio #{ratio}) but its pool is empty at sv #{sv}"
      end
    end
  end

  # End-to-end: the same state that used to waste its action on
  # {:error, :already_one_on_body} now builds a different building.

  test "do_action builds a valid building instead of wasting the action on a duplicate", %{iid: iid} do
    path = Path.join(:code.priv_dir(:rc), "data/system_ai/behavior_tree.json")
    bt = Instance.SystemAI.Parser.parse!(path, "Dominion")

    {:ok, galaxy_pid} = GenServer.start_link(BTGalaxy, bt, name: Game.via_tuple({iid, :galaxy, :master}))
    on_exit(fn -> Process.exit(galaxy_pid, :shutdown) end)

    {state, target, sv, r, expected} =
      Enum.find_value(@system_values, fn sv ->
        Enum.find_value(unique_candidates(iid, sv, :unique_body), fn target ->
          state = build_state(iid, target, :unique_body)
          body = target_body(state)
          bodies = Helper.get_bodies(state)

          k = Helper.get_categories_proportion_built(body, bodies, :dome, sv, iid)

          Enum.find_value(@profiles, fn profile ->
            p_base = Helper.get_profile_probabilities(profile)
            cumulated = Helper.get_cumulated_probabilities(p_base, k)

            Enum.find_value(@r_grid, fn r ->
              cat = Helper.get_random_category(cumulated, r)
              pool = if cat, do: drawable_pool(iid, sv, cat, body, bodies), else: []

              # random_index 0 draws the pool head; require the pool to have
              # once contained the built unique so this state is exactly the
              # old wasted-action scenario
              with [head | _] <- pool,
                   true <- target_category?(target, cat) do
                {%{state | ai_profile: profile}, target, sv, r, head.key}
              else
                _ -> nil
              end
            end)
          end)
        end)
      end)

    FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: r, random_index: 0)

    assert {:ok, new_state} = SystemAI.do_action(state, sv)

    assert [item] = Queue.to_list(new_state.queue.queue)
    assert item.type == :building
    assert item.prod_key == expected
    refute item.prod_key == target.key
  end

  # At system value >= 18 the orbital pools are all-unique or empty, so a moon
  # that has built them all has NO drawable category left. choose_category must
  # end the action ({:done}) — a :fail there would cascade into a root-level
  # behavior-tree failure, which restarts the tree and never terminates.
  test "a saturated body ends the action instead of looping the behavior tree", %{iid: iid} do
    path = Path.join(:code.priv_dir(:rc), "data/system_ai/behavior_tree.json")
    bt = Instance.SystemAI.Parser.parse!(path, "Dominion")

    {:ok, galaxy_pid} = GenServer.start_link(BTGalaxy, bt, name: Game.via_tuple({iid, :galaxy, :master}))
    on_exit(fn -> Process.exit(galaxy_pid, :shutdown) end)

    sv = 20

    orbital_uniques =
      BuildingsHelper.get_biome_buildings(:orbital, iid)
      |> Helper.filter_buildings_by_system_value(sv)
      |> Enum.filter(&(&1.limitation in [:unique_body, :unique_system]))

    non_uniques =
      BuildingsHelper.get_biome_buildings(:orbital, iid)
      |> Helper.filter_buildings_by_system_value(sv)
      |> Enum.reject(&(&1.limitation in [:unique_body, :unique_system]))

    assert non_uniques == [],
           "census drift: orbital sv>=18 gained non-unique buildings (#{inspect(Enum.map(non_uniques, & &1.key))}) — pick another saturated setup"

    tiles =
      orbital_uniques
      |> Enum.with_index(1)
      |> Enum.map(fn {b, i} -> Tile.new(i, :secondary) |> Tile.force_building(b.key, 1) end)
      |> Kernel.++([Tile.new(length(orbital_uniques) + 1, :secondary)])

    moon =
      struct(StellarBody, %{
        id: 1,
        uid: "1",
        type: :moon,
        name: "Saturated",
        industrial_factor: 3,
        technological_factor: 3,
        activity_factor: 3,
        population: 10,
        bodies: [],
        tiles: tiles
      })

    state = %{build_state(iid, hd(orbital_uniques), :unique_body) | bodies: [moon]}

    FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

    assert {:ok, new_state} = SystemAI.do_action(state, sv)
    assert Queue.to_list(new_state.queue.queue) == []
  end

  # Helpers

  defp unique_candidates(iid, sv, limitation) do
    BuildingsHelper.get_biome_buildings(:dome, iid)
    |> Helper.filter_buildings_by_system_value(sv)
    |> Enum.filter(&(&1.limitation == limitation and &1.type == :normal))
    |> Enum.reject(&(&1.key in [:infra_dome, :hab_dome]))
  end

  defp drawable_pool(iid, sv, cat, body, bodies) do
    BuildingsHelper.get_biome_buildings(:dome, iid)
    |> Helper.filter_buildings_by_system_value(sv)
    |> Helper.filter_building_by_profile(cat)
    |> Helper.filter_already_built_unique_buildings(body, bodies)
  end

  defp target_category?(target, cat) do
    Helper.filter_building_by_profile([target], cat) == [target]
  end

  # Scenario :unique_body — one dome body carrying infra_dome + hab_dome + the
  # target unique, plus a free tile the duplicate order would target.
  # Scenario :unique_system — the unique sits on a FULL first body; the AI can
  # only target the second body, which never built it.
  defp build_state(iid, target, limitation) do
    target_body_tiles = [
      Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2),
      Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
      Tile.new(3, :primary),
      Tile.new(4, :primary)
    ]

    bodies =
      case limitation do
        :unique_body ->
          tiles = List.update_at(target_body_tiles, 2, &Tile.force_building(&1, target.key, 1))
          [dome_body(1, tiles)]

        :unique_system ->
          carrier_tiles = [
            Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 2),
            Tile.new(2, :primary) |> Tile.force_building(target.key, 1)
          ]

          [dome_body(1, carrier_tiles), dome_body(2, target_body_tiles)]
      end

    struct(StellarSystem, %{
      id: 999,
      name: "filter-test",
      status: :inhabited_neutral,
      instance_id: iid,
      bodies: bodies,
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      # > 3 available workforce fails workforce_needed?(3); >= any building
      # cost passes enough_workforce?
      workforce: 20,
      used_workforce: 0,
      habitation: %Core.Value{value: 0, details: %{}},
      happiness: %Core.Value{value: 50, details: %{}},
      population: Core.DynamicValue.new(0.0),
      ai_profile: :production
    })
  end

  defp dome_body(id, tiles) do
    struct(StellarBody, %{
      id: id,
      uid: "#{id}",
      type: :sterile_planet,
      name: "Filter #{id}",
      industrial_factor: 3,
      technological_factor: 3,
      activity_factor: 3,
      population: 10,
      bodies: [],
      tiles: tiles
    })
  end

  # the body the AI would target: the last one (the only one with free tiles)
  defp target_body(state) do
    state.bodies |> List.last() |> then(&%{uid: &1.uid, type: &1.type, tiles: &1.tiles})
  end
end
