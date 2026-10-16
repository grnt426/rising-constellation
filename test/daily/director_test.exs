defmodule Daily.DirectorTest do
  @moduledoc """
  Live tests of the two days whose setup the generator and the boot must get
  right for the goal to be possible at all (both shipped impossible once):

    * **Headhunter** — a real persisted daily gets an enemy player, the
      Director stands the day's roster in the human's system on the clock,
      Intelligence exposes them, a removal scores, an enemy removal attempt
      goes through the engine, and the Director stops at the deadline.
    * **Monumental** — the system holds a barren world, the player starts
      with the Monolith's patent line, and the build order is accepted.

  The Director is driven by hand (`pulse/2` with `:due`, `:intel`, `:roll`)
  rather than through its 15-second timer.
  """
  use RC.DataCase, async: false

  alias Daily.Director
  alias Daily.Headhunter
  alias Instance.Character.Character

  @moduletag timeout: 180_000

  describe "Headhunter" do
    setup do
      profile = create_profile("headhunter")
      date = first_date(:headhunter)

      {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, date)
      on_exit(fn -> Instance.Manager.destroy(iid) end)
      {:ok, :started, _} = Instance.Manager.call(iid, :start)

      {:ok, human} = Game.call(iid, :player, profile.id, :get_state)
      [home] = human.stellar_systems

      %{iid: iid, profile: profile, date: date, home: home.id, faction: human.faction_id}
    end

    test "the enemy court arrives on the clock, Intelligence exposes it, and a removal scores", ctx do
      %{iid: iid, profile: profile, date: date, home: home} = ctx
      never = fn -> 1.0 end

      assert Director.directed?(iid)
      {:ok, director} = Director.init(iid)
      assert director.human_id == profile.id
      assert director.puppet_id != profile.id

      # three intervals in: three Erased, under cover, in the home system
      {:cont, director} = Director.pulse(director, due: 3, intel: 0, roll: never)
      assert director.sent == 3
      assert map_size(director.recruits) == 3

      enemies = enemies_in(iid, home, director)
      assert length(enemies) == 3
      assert Enum.all?(enemies, &(&1.cover >= 75))
      # under cover, the player's client is sent none of them
      assert seen_by_player(iid, ctx.faction, home, director) == []

      for {id, recruit} <- director.recruits do
        {:ok, agent} = Game.call(iid, :character, id, :get_state)
        assert agent.level == recruit.level
        assert agent.protection == 10 * recruit.level
        assert agent.skills == recruit.skills
        assert agent.spy.assassination_coef.value >= 18 * Headhunter.removal_points(recruit.level)
      end

      # the same moment again sends nobody new, and no Intelligence exposes nobody
      {:cont, director} = Director.pulse(director, due: 3, intel: 0, roll: never)
      assert director.sent == 3
      assert MapSet.size(director.exposed) == 0

      # the opening recruits are level 3 at most: 400 Intelligence exposes every one
      {:cont, director} = Director.pulse(director, due: 3, intel: 400, roll: never)
      assert MapSet.size(director.exposed) == 3

      eventually(fn ->
        if Enum.all?(enemies_in(iid, home, director), &(&1.cover < 75)), do: {:ok, :exposed}, else: :retry
      end)

      # now the player's client is sent all three, level included
      seen = seen_by_player(iid, ctx.faction, home, director)
      assert length(seen) == 3
      assert Enum.all?(seen, &(&1.level in 1..3))

      # exposure holds even when the Intelligence that caused it is gone
      {:cont, director} = Director.pulse(director, due: 3, intel: 0, roll: never)
      assert MapSet.size(director.exposed) == 3

      # the player's Erased removes one of them
      erased = place_erased(iid, profile.id, home)
      [target | _] = MapSet.to_list(director.exposed)
      :ok = Game.call(iid, :player, profile.id, {:add_character_actions, erased, [removal(home, target)]})

      player =
        eventually(fn ->
          case Game.call(iid, :player, profile.id, :get_state) do
            {:ok, %{agents_assassinated: 1} = player} -> {:ok, player}
            _ -> :retry
          end
        end)

      {:cont, director} = Director.pulse(director, due: 3, intel: 0, roll: never)
      refute Map.has_key?(director.recruits, target)
      assert MapSet.size(director.exposed) == 2
      assert length(enemies_in(iid, home, director)) == 2

      # the removal is the day's score
      assert :continue = Daily.Boot.autosave(iid, player)
      assert %{score: 1.0, rank: 1} = Daily.player_rank(profile.id, date)

      # the deadline ends the Director
      Game.cast(iid, :victory, :master, :force_time_up)

      eventually(fn ->
        if Director.pulse(director, due: 3, intel: 0, roll: never) == :halt, do: {:ok, :halted}, else: :retry
      end)
    end

    test "a bold recruit makes one removal attempt on the player's Erased", ctx do
      %{iid: iid, profile: profile, date: date, home: home} = ctx

      {:ok, director} = Director.init(iid)
      bold = Enum.find(1..Headhunter.total(), &Headhunter.recruit(date, &1).bold?)
      assert bold, "the day's roster has no bold recruit"

      # with nobody to strike, the attempt is kept for later
      {:cont, director} = Director.pulse(director, due: bold, intel: 0, roll: fn -> 0.0 end)
      {bold_id, _} = Enum.find(director.recruits, fn {_id, recruit} -> recruit.n == bold end)
      refute director.recruits[bold_id].struck?

      place_erased(iid, profile.id, home)
      {:cont, director} = Director.pulse(director, due: bold, intel: 0, roll: fn -> 0.0 end)
      assert director.recruits[bold_id].struck?

      # the attempt ran in the engine: whatever the roll, it cost the attacker cover
      eventually(fn ->
        case Game.call(iid, :character, bold_id, :get_state) do
          {:ok, %{spy: %{cover: %{value: cover}}}} when cover < 75 -> {:ok, cover}
          _ -> :retry
        end
      end)

      # once only
      {:cont, director} = Director.pulse(director, due: bold, intel: 0, roll: fn -> 0.0 end)
      assert Enum.count(director.recruits, fn {_id, recruit} -> recruit.struck? end) >= 1
      assert director.recruits[bold_id].struck?
    end
  end

  describe "Monumental" do
    # 2026-10-13 is the Monumental day that shipped impossible: its seed rolls
    # no barren world. Past dates never change objective (Daily.Rotation), so
    # it stays a fixture for the case where the world has to be added.
    test "the system has a barren world and the Monolith can be ordered from the start" do
      profile = create_profile("monumental")
      date = "2026-10-13"
      assert Daily.definition_for(date).objective.key == :monumental

      {:ok, %{instance_id: iid}} = Daily.Boot.boot_persisted(profile, date)
      on_exit(fn -> Instance.Manager.destroy(iid) end)
      {:ok, :started, _} = Instance.Manager.call(iid, :start)

      refute Director.directed?(iid)

      {:ok, player} = Game.call(iid, :player, profile.id, :get_state)
      [home] = player.stellar_systems
      {:ok, system} = Game.call(iid, :stellar_system, home.id, :get_state)

      barren = Enum.find(system.bodies, &(&1.type == :sterile_planet))
      assert barren, "a Monumental system must hold a barren world"
      assert length(barren.tiles) >= 2
      # added after the rolled bodies, which had none
      assert barren == List.last(system.bodies)
      assert Enum.any?(system.bodies, &(&1.type == :habitable_planet))

      # the Monolith's patent line, oldest first
      assert List.last(player.patents) == :dome_ideo
      assert :infra_dome_1 in player.patents

      # infrastructure on the barren world, then the Monolith
      assert %Instance.Player.Player{} =
               Game.call(iid, :player, profile.id, {:order_building, home.id, "build", {barren.uid, 1, :infra_dome, 1}})

      assert {:error, :no_building_without_infra} =
               Game.call(
                 iid,
                 :player,
                 profile.id,
                 {:order_building, home.id, "build", {barren.uid, 2, :monument_dome, 1}}
               )

      # the Floating Gardens stay locked: only the Monolith's line is granted
      refute :open_ideo in player.patents

      # this grant is not markup-free: the line still raises later prices
      assert Instance.Player.Player.markup_free_patents(iid) == []
      assert Instance.Player.Player.priced_patent_count(player) == length(player.patents)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp create_profile(name) do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "director-#{name}@tetrarchyfalls.local",
        password: "director-test-password",
        name: "Director#{name}",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "Director#{name}", avatar: "todo"})
    profile
  end

  defp first_date(key) do
    Enum.find_value(0..90, fn offset ->
      date_iso = Date.utc_today() |> Date.add(offset) |> Date.to_iso8601()
      if Daily.definition_for(date_iso).objective.key == key, do: date_iso
    end) || flunk("no #{key} day within 90 days — rotation broken?")
  end

  defp enemies_in(iid, system_id, director) do
    {:ok, system} = Game.call(iid, :stellar_system, system_id, :get_state)
    Enum.filter(system.characters, &(&1.owner.id == director.puppet_id))
  end

  # The system as the player's client receives it (the faction view, which
  # drops foreign Erased that are under cover): the enemy agents in it.
  defp seen_by_player(iid, faction_id, system_id, director) do
    view = Game.call(iid, :faction, faction_id, {:get_system_state, system_id})

    view.characters
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.owner.id == director.puppet_id))
  end

  # A level-5 Erased with ten points of removal, for the human: a certain
  # success against the day's opening recruits.
  defp place_erased(iid, player_id, system_id) do
    {:ok, tmp_id} = Game.call(iid, :character_market, :master, :get_next_character_id)
    {:ok, before} = Game.call(iid, :player, player_id, :get_state)

    skills = [0, 10, 0, 0, 0, 0]

    erased = %{
      Character.new(tmp_id, :spy, :common, 1, iid, %{spec1: :assassin, spec2: :assassin, skills: skills})
      | level: 5,
        skills: skills,
        protection: 50
    }

    :ok = Game.call(iid, :player, player_id, {:convert_character, erased, system_id}, 1, 30_000)
    {:ok, now} = Game.call(iid, :player, player_id, :get_state)
    [id] = Enum.map(now.characters, & &1.id) -- Enum.map(before.characters, & &1.id)
    id
  end

  defp removal(system_id, target_id) do
    %{"type" => "assassination", "data" => %{"target" => system_id, "target_character" => target_id}}
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      :retry ->
        flunk("condition not met in time")
    end
  end
end
