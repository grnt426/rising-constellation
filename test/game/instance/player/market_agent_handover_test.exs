defmodule Instance.Player.MarketAgentHandoverTest do
  @moduledoc """
  An agent on assignment changing hands through the player market
  (`board_character` offers, `Instance.Player.Market`) — the late-game move
  where a player who can no longer pay for a fleet hands it to a teammate.

  From the moment it is claimed the agent answers to its new owner:

    * it strikes (or not) on the new owner's solvency, not the old one's;
    * it carries the new owner's lex bonuses, not the old owner's;
    * its wages and fleet upkeep leave the old owner's income and enter the
      new owner's at once, so a donor ruined by that fleet recovers on their
      next tick.

  The Cheats tab agent transfer ends in the same state: both go through
  `Player.release_character/2` and `Player.adopt_character/2`.

  Real `Player.Agent` and `Character.Agent` processes, real offer rows and
  real game data; the agents are never started, so nothing ticks on its own.
  Only the stellar system the Navarch stands in is a stand-in.
  """
  use RC.DataCase, async: false

  import RC.ScenarioFixtures

  alias Instance.Character.Army
  alias Instance.Character.Character
  alias Instance.Character.Ship
  alias Instance.Player.Player
  alias RC.Instances.Offer
  alias RC.Repo
  alias Test.FleetScenario

  @navarch_id 4_001
  @system_id 77
  @character_bonuses [:character, :army, :spy, :speaker]

  # Lexes (fast content): `:agent` opens the first Navarch slot,
  # `:upgrade_repair` raises fleet repair, `:reduce_maintenance_2` cuts fleet
  # upkeep. Neither army lex touches the player's own income.
  @donor_lexes [:agent, :upgrade_repair]
  @claimer_lexes [:agent, :reduce_maintenance_2]

  setup do
    %{instance: instance} = instance_fixture()
    iid = instance.id
    FleetScenario.load_game_data(iid, speed: :fast, mode: :prod)
    FleetScenario.spawn_fake_stellar_system(self(), instance_id: iid, system_id: @system_id)

    [faction | _] = Enum.sort_by(instance.factions, & &1.id)

    alice = player!(iid, faction, "Alice", 0, @donor_lexes)
    bob = player!(iid, faction, "Bob", 1_000_000, @claimer_lexes)

    # Alice's Navarch, deployed under her lexes, with a ship to pay for.
    navarch = navarch(iid, faction, alice)
    start_agent!(Instance.Character.Agent, :character, navarch, alice.id)
    alice = Player.update_character(%{alice | characters: [Instance.Player.Character.convert(navarch)]}, navarch)

    # No credits left and an income the fleet drags below zero: the next tick
    # declares Alice bankrupt, which puts the Navarch on strike.
    {_change, alice} = Player.next_tick(alice, 0)

    start_agent!(Instance.Player.Agent, :player, alice, alice.id)
    start_agent!(Instance.Player.Agent, :player, bob, bob.id)

    {:ok, iid: iid, alice: alice, bob: bob, deployed: navarch}
  end

  test "the fixture: a bankrupt donor whose Navarch is on strike under her lexes", ctx do
    navarch = navarch!(ctx.iid)

    assert ctx.alice.is_bankrupt
    assert ctx.alice.credit.change < 0

    assert navarch.on_strike
    assert navarch.army.reaction == :flee
    assert lexes(navarch.army.repair_coef) == [:upgrade_repair]
    assert lexes(navarch.army.maintenance) == []
    assert navarch.army.maintenance.value > 0
  end

  describe "a donated Navarch, once claimed" do
    test "no longer strikes: the claimer is solvent", ctx do
      navarch = hand_over!(ctx)

      assert navarch.owner.id == ctx.bob.id
      refute navarch.on_sold
      refute navarch.on_strike

      # and takes orders again — bankruptcy left it on the Deserter stance
      assert {:ok, %{army: %{reaction: :defend}}} =
               Game.call(ctx.iid, :character, @navarch_id, {:update_reaction, :defend})
    end

    test "carries the claimer's lex bonuses, not the donor's", ctx do
      navarch = hand_over!(ctx)

      assert lexes(navarch.army.maintenance) == [:reduce_maintenance_2]
      assert lexes(navarch.army.repair_coef) == []
      assert navarch.army.maintenance.value < ctx.deployed.army.maintenance.value

      # exactly what the claimer's own deployment would have given it
      own = Character.update_bonuses(ctx.deployed, :player, Player.extract_bonus(ctx.bob, @character_bonuses))
      assert navarch.army.maintenance == own.army.maintenance
      assert navarch.army.repair_coef == own.army.repair_coef
    end

    test "moves its wages and fleet upkeep to the claimer's income at once", ctx do
      navarch = hand_over!(ctx)
      alice = player_state!(ctx.iid, ctx.alice.id)
      bob = player_state!(ctx.iid, ctx.bob.id)

      wages = wages(ctx.iid, navarch)
      upkeep = navarch.army.maintenance.value

      assert alice.characters == []
      assert charges(alice) == %{}
      assert_in_delta alice.credit.change, 0, 1.0e-9

      assert [%{id: @navarch_id, on_sold: false, army_maintenance: ^upkeep}] = bob.characters
      assert charges(bob) == %{character_wages: [-wages], fleet_maintenance: [-upkeep]}
      assert_in_delta bob.credit.change, ctx.bob.credit.change - wages - upkeep, 1.0e-9
    end

    test "lifts the donor's bankruptcy on their next tick", ctx do
      hand_over!(ctx)

      {_change, alice} = Player.next_tick(player_state!(ctx.iid, ctx.alice.id), 0)
      refute alice.is_bankrupt
    end
  end

  test "a sold Navarch is refreshed for its buyer like a donated one", ctx do
    navarch = hand_over!(ctx, "trade", 2_500)
    bob = player_state!(ctx.iid, ctx.bob.id)

    refute navarch.on_strike
    assert lexes(navarch.army.maintenance) == [:reduce_maintenance_2]

    assert charges(bob) == %{
             character_wages: [-wages(ctx.iid, navarch)],
             fleet_maintenance: [-navarch.army.maintenance.value]
           }

    assert charges(player_state!(ctx.iid, ctx.alice.id)) == %{}
  end

  test "the Cheats tab transfer leaves the agent and both players in the same state", ctx do
    Data.Data.update_metadata(ctx.iid, :cheats_enabled, true)

    # Instance.Manager {:cheat_transfer_character, ...}, minus its guards
    assert :ok = Game.call(ctx.iid, :player, ctx.alice.id, {:cheat_release_character, @navarch_id})
    assert {:ok, _} = Game.call(ctx.iid, :character, @navarch_id, {:update_owner, ctx.bob})
    assert :ok = Game.call(ctx.iid, :player, ctx.bob.id, {:cheat_adopt_character, @navarch_id})

    navarch = navarch!(ctx.iid)
    alice = player_state!(ctx.iid, ctx.alice.id)
    bob = player_state!(ctx.iid, ctx.bob.id)

    refute navarch.on_strike
    assert lexes(navarch.army.maintenance) == [:reduce_maintenance_2]
    assert lexes(navarch.army.repair_coef) == []

    assert alice.characters == []
    assert charges(alice) == %{}
    assert [%{id: @navarch_id}] = bob.characters

    assert charges(bob) == %{
             character_wages: [-wages(ctx.iid, navarch)],
             fleet_maintenance: [-navarch.army.maintenance.value]
           }
  end

  # ---------------------------------------------------------------------------

  # Alice lists the Navarch, Bob takes it; returns the Navarch as it is then.
  defp hand_over!(ctx, mode \\ "donation", price \\ 0) do
    args = %{
      "mode" => mode,
      "type" => "board_character",
      "data" => %{"character_id" => @navarch_id},
      "price" => price,
      "allowed_players" => [],
      "allowed_factions" => []
    }

    assert :ok = Game.call(ctx.iid, :player, ctx.alice.id, {:create_offer, args})
    assert [offer] = Repo.all(Offer)
    assert :ok = Game.call(ctx.iid, :player, ctx.bob.id, {:buy_offer, offer.id})

    navarch!(ctx.iid)
  end

  defp navarch!(iid) do
    {:ok, navarch} = Game.call(iid, :character, @navarch_id, :get_state)
    navarch
  end

  defp player_state!(iid, player_id) do
    {:ok, player} = Game.call(iid, :player, player_id, :get_state)
    player
  end

  # The lexes behind an army value.
  defp lexes(value), do: value.details |> Map.get(:doctrine, []) |> Enum.map(& &1.reason)

  # What a player's agents cost them: the wage and fleet upkeep entries of
  # their credit income.
  defp charges(player) do
    player.credit.details
    |> Map.take([:character_wages, :fleet_maintenance])
    |> Map.new(fn {kind, parts} -> {kind, Enum.map(parts, & &1.value)} end)
  end

  defp wages(iid, navarch) do
    Data.Querier.one(Data.Game.Constant, iid, :main).character_level_wages * navarch.level
  end

  defp navarch(iid, faction, owner) do
    ship =
      Data.Game.Ship
      |> Data.Querier.all(iid)
      |> Enum.find(fn ship -> ship.class != :capital and ship.maintenance_cost > 0 end)

    character =
      FleetScenario.build_character(
        instance_id: iid,
        character_id: @navarch_id,
        faction: owner.faction,
        faction_id: faction.id,
        system: @system_id,
        owner_id: owner.id,
        owner_name: owner.name
      )

    %{character | army: Army.set_ship(Army.new(iid), 1, Ship.new(ship))}
    |> Character.set_virtual_position(@system_id)
    |> Character.update_bonuses(:player, Player.extract_bonus(owner, @character_bonuses))
  end

  # A real agent process, registered like the instance's own but never
  # started: it answers calls and does not tick.
  defp start_agent!(module, type, data, player_id) do
    channel = "instance:player:#{data.instance_id}:#{player_id}"
    {:ok, pid} = module.start_link(state: Core.GenState.new(type, data.instance_id, data.id, data, channel))
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp player!(iid, faction, name, credit, lexes) do
    n = System.unique_integer([:positive])

    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "handover-#{n}@test.local",
        password: "handover-test-password-#{n}",
        name: "Handover#{n}",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "#{name}#{n}", avatar: "todo"})
    {:ok, _} = RC.Registrations.register_profile(faction, profile)

    player = %Player{
      id: profile.id,
      account_id: account.id,
      faction_id: faction.id,
      faction: String.to_atom(faction.faction_ref),
      is_dead: false,
      is_bankrupt: false,
      is_active: true,
      avatar: "todo",
      name: name,
      stellar_systems: [],
      dominions: [],
      characters: [],
      credit: Core.DynamicValue.new(credit),
      technology: Core.DynamicValue.new(0),
      ideology: Core.DynamicValue.new(0),
      patents: [],
      doctrines: Enum.uniq(@donor_lexes ++ @claimer_lexes),
      policies: [],
      character_deck: [],
      max_policies: 2,
      update_policies_count: 1,
      policies_cooldown: Core.CooldownValue.new(),
      max_systems: Core.Value.new(),
      max_dominions: Core.Value.new(),
      max_admirals: Core.Value.new(),
      max_spies: Core.Value.new(),
      max_speakers: Core.Value.new(),
      dominion_rate: Core.Value.new(),
      transformed_system_count: 0,
      dominions_under_attack: [],
      instance_id: iid,
      registration_id: 1,
      connected_clients: 0,
      pending_notifications: [],
      next_stats: 0,
      last_connection: Core.DynamicValue.new(0)
    }

    {:ok, player, _system_bonuses, _character_bonuses} = Player.update_policies(player, lexes)
    %{player | policies_cooldown: Core.CooldownValue.new()}
  end
end
