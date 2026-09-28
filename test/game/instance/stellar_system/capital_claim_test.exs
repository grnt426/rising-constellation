defmodule Instance.StellarSystem.CapitalClaimTest do
  use ExUnit.Case, async: true

  alias Instance.Galaxy.Galaxy
  alias Instance.StellarSystem.StellarSystem

  @moduledoc """
  A player's starting system must always come with its infrastructure
  building. `Galaxy.get_initial_system/3` falls back to an autonomous
  (`:inhabited_neutral`) system once the faction's sectors run out of
  uninhabited ones, and the capital claim swaps that system's bodies for the
  fixed starter layout — which used to wipe the infrastructure the neutral had
  been generated with, leaving a capital that could not build anything.

  Systems are built with the real `StellarSystem.new/4` against real
  `Data.Game.*` content; only the `:rand` agent is a test-local stand-in.
  """

  @infra_keys [:infra_open, :infra_dome]

  # Seeded stand-in for Instance.Rand.Agent under {instance_id, :rand, :master}.
  # FleetScenario.FakeRand only accepts lists for {:random, _}, but
  # StellarSystem.new/4 draws body counts from ranges.
  defmodule SeededRand do
    use GenServer

    def init(seed) do
      :rand.seed(:exsss, {seed, seed, seed})
      {:ok, nil}
    end

    def handle_call({:uniform}, _from, s), do: {:reply, :rand.uniform(), s}
    def handle_call({:uniform, n}, _from, s), do: {:reply, :rand.uniform(n), s}
    def handle_call({:uniform, min, max}, _from, s), do: {:reply, :rand.uniform() * (max - min) + min, s}
    def handle_call({:random, enum}, _from, s), do: {:reply, Enum.random(enum), s}
    def handle_call({:take_random, list, n}, _from, s), do: {:reply, Enum.take_random(list, n), s}
  end

  setup do
    iid = System.unique_integer([:positive])
    Data.Data.insert(iid, speed: :fast, mode: :prod)

    {:ok, rand} = GenServer.start_link(SeededRand, 42, name: Game.via_tuple({iid, :rand, :master}))

    on_exit(fn ->
      Process.exit(rand, :shutdown)

      try do
        Data.Data.clear(iid)
      rescue
        _ -> :ok
      end
    end)

    {:ok, iid: iid}
  end

  defp player, do: %{id: 1, name: "p1", avatar: "a", faction: :myrmezir, faction_id: 1}

  # `forced_status` is only honoured when the rolled bodies include a planet, so
  # draw systems until one lands on the requested status.
  defp generate(iid, status) do
    Enum.find_value(1..100, fn key ->
      system =
        StellarSystem.new(
          %{"key" => key, "type" => "red_dwarf", "position" => %{"x" => 0, "y" => 0}},
          1,
          iid,
          name: "sys-#{key}",
          forced_status: status
        )

      if system.status == status, do: system
    end) || flunk("no #{status} system generated in 100 draws")
  end

  defp infrastructure(system) do
    for body <- system.bodies,
        tile <- body.tiles,
        tile.building_key in @infra_keys and tile.building_status == :built,
        do: {body.uid, tile.id, tile.building_key}
  end

  # Galaxy summaries for the fallback-order tests: sector 1 is the
  # faction's (systems 10, 11, ... with `own_statuses`); sector 2 belongs to
  # another faction and must never be used, whatever it holds.
  defp galaxy(own_statuses) do
    own =
      for {status, id} <- Enum.with_index(own_statuses, 10),
          do: %{id: id, status: status, sector_id: 1}

    foreign =
      for {status, id} <- Enum.with_index([:uninhabited, :inhabited_neutral, :uninhabitable], 90),
          do: %{id: id, status: status, sector_id: 2}

    struct(Galaxy,
      sectors: [%{id: 1, owner: :myrmezir}, %{id: 2, owner: :tetrarchy}],
      stellar_systems: own ++ foreign
    )
  end

  defp candidate_ids(state), do: state |> Galaxy.initial_system_candidates(:myrmezir) |> Enum.map(& &1.id)

  describe "claim/4 as a starting system" do
    test "an autonomous (inhabited_neutral) system still gets its infrastructure building", %{iid: iid} do
      neutral = generate(iid, :inhabited_neutral)
      # The neutral was opened at generation time; the claim must not lose that.
      assert [_] = infrastructure(neutral)

      {_, capital} = StellarSystem.claim(neutral, player(), true, false)

      assert capital.capital?
      assert capital.status == :inhabited_player
      assert [{_uid, 1, key}] = infrastructure(capital)
      assert key in @infra_keys
    end

    test "an autonomous capital starts like any other capital", %{iid: iid} do
      {_, from_neutral} = StellarSystem.claim(generate(iid, :inhabited_neutral), player(), true, false)
      {_, from_uninhabited} = StellarSystem.claim(generate(iid, :uninhabited), player(), true, false)

      assert infrastructure(from_neutral) == infrastructure(from_uninhabited)
      assert from_neutral.population.value == from_uninhabited.population.value
      assert from_neutral.population_class == from_uninhabited.population_class
    end

    test "an uninhabited system gets its infrastructure building", %{iid: iid} do
      {_, capital} = StellarSystem.claim(generate(iid, :uninhabited), player(), true, false)

      assert [{_uid, 1, _key}] = infrastructure(capital)
    end

    test "an uninhabitable system becomes a working starter capital", %{iid: iid} do
      # The last-resort pick: no planet at all before the starter transform.
      base = generate(iid, :uninhabited)

      uninhabitable = %{
        base
        | status: :uninhabitable,
          bodies: Enum.reject(base.bodies, &(&1.type in [:habitable_planet, :sterile_planet]))
      }

      {_, capital} = StellarSystem.claim(uninhabitable, player(), true, false)

      assert capital.status == :inhabited_player
      assert [{_uid, 1, _key}] = infrastructure(capital)
    end
  end

  describe "claim/4 as a conquest" do
    test "taking an autonomous system keeps its existing bodies and buildings", %{iid: iid} do
      neutral = generate(iid, :inhabited_neutral)

      {_, conquered} = StellarSystem.claim(neutral, player(), false, false)

      refute conquered.capital?
      assert conquered.bodies == neutral.bodies
      assert conquered.population.value == neutral.population.value
    end
  end

  describe "Galaxy.initial_system_candidates/2 fallback order" do
    test "uninhabited systems come first" do
      assert candidate_ids(galaxy([:inhabited_neutral, :uninhabited, :uninhabitable, :uninhabited])) == [11, 13]
    end

    test "then autonomous systems" do
      state = galaxy([:inhabited_neutral, :uninhabitable, :inhabited_player, :inhabited_neutral])
      assert candidate_ids(state) == [10, 13]
    end

    test "then uninhabitable systems" do
      assert candidate_ids(galaxy([:inhabited_dominion, :uninhabitable, :inhabited_player])) == [11]
    end

    test "never dominions, player systems, or other factions' sectors" do
      assert candidate_ids(galaxy([:inhabited_dominion, :inhabited_player])) == []
    end

    test "a faction with no sectors has no candidates" do
      state = galaxy([:uninhabited])
      assert Galaxy.initial_system_candidates(state, :synelle) == []
    end
  end

  describe "Galaxy.get_initial_system/3" do
    test "picks one of the candidates", %{iid: iid} do
      assert {:ok, %{id: 11, status: :inhabited_neutral}} =
               Galaxy.get_initial_system(galaxy([:inhabited_player, :inhabited_neutral]), :myrmezir, iid)
    end

    test "reports when there is nowhere to start", %{iid: iid} do
      assert {:error, :no_starting_system} =
               Galaxy.get_initial_system(galaxy([:inhabited_dominion, :inhabited_player]), :myrmezir, iid)
    end
  end
end
