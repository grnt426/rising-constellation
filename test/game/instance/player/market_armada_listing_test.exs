defmodule Instance.Player.MarketArmadaListingTest do
  @moduledoc """
  A Navarch that belongs to an armada cannot change hands on the player
  market (`board_character` offers, `Instance.Player.Market`).

  An armada is one map, `%{id, name, member_ids}`, copied onto every member
  and written only by the owning player's agent (`Instance.Player.ArmadaImpl`).
  A member sold from the field kept its copy, naming Navarchs that now belong
  to someone else, and those Navarchs kept it in theirs: two players in one
  armada, where a jump by either pulls the other's fleet along.

    * listing a member is refused with `:character_in_armada`, whether it
      stands in a system or rides its lead in transit — the Cheats tab
      transfer's rule (`Character.cheat_transferable/1`), and the mirror of
      the armada rule that keeps a listed Navarch out of armadas;
    * once the armada is broken, the Navarch lists and sells as before;
    * a listing that predates the rule cannot be taken while the Navarch is
      still in its armada — the offer stays up, and breaking the armada
      makes it takeable; cancelling it only lifts the listing.

  Real `Player.Agent` and `Character.Agent` processes, real offer rows and
  real game data; the agents are never started, so nothing ticks on its own.
  Only the stellar system the Navarchs stand in is a stand-in.
  """
  use RC.DataCase, async: false

  import RC.ScenarioFixtures

  alias Instance.Character.Armada
  alias Instance.Player.ArmadaImpl
  alias Instance.Player.Player
  alias RC.Instances.Offer
  alias RC.Repo
  alias Test.FleetScenario

  @system_id 77
  @lead_id 4_001
  @member_id 4_002

  setup do
    %{instance: instance} = instance_fixture()
    iid = instance.id
    FleetScenario.load_game_data(iid, speed: :fast, mode: :prod)
    FleetScenario.spawn_fake_stellar_system(self(), instance_id: iid, system_id: @system_id)
    # the armada's name is drawn through the rand agent
    FleetScenario.spawn_fake_rand(self(), instance_id: iid)
    # a member pulled into transit leaves the spatial index
    FleetScenario.spawn_spatial(self(), instance_id: iid)

    [faction | _] = Enum.sort_by(instance.factions, & &1.id)

    alice = player!(iid, faction, "Alice")
    bob = player!(iid, faction, "Bob")

    # Alice's two Navarchs, idle in the same system.
    navarchs = for id <- [@lead_id, @member_id], do: navarch(iid, faction, alice, id)
    alice = %{alice | characters: Enum.map(navarchs, &Instance.Player.Character.convert/1)}

    start_player!(alice)
    start_player!(bob)

    {:ok, iid: iid, faction: faction, alice: alice, bob: bob}
  end

  describe "listing a Navarch that belongs to an armada" do
    setup :form_armada

    test "is refused, as a sale or as a donation, for either member", ctx do
      for id <- [@lead_id, @member_id], mode <- ["trade", "donation"] do
        assert {:error, :character_in_armada} = list(ctx, id, mode)
      end

      assert Repo.aggregate(Offer, :count) == 0

      # nothing was flagged, on the agents or on the roster, and the armada stands
      for id <- [@lead_id, @member_id] do
        navarch = navarch!(ctx.iid, id)
        refute navarch.on_sold
        assert navarch.owner.id == ctx.alice.id
        assert %{member_ids: [@lead_id, @member_id]} = Armada.get(navarch)
      end

      refute Enum.any?(player_state!(ctx.iid, ctx.alice.id).characters, & &1.on_sold)
    end

    test "is refused while the member rides its lead in transit", ctx do
      # what the lead's Jump.start does to every other member
      assert {:ok, %{action_status: :attached}} =
               Game.call(ctx.iid, :character, @member_id, {:armada_attach, @system_id})

      assert {:error, :character_in_armada} = list(ctx, @member_id)
      assert Repo.aggregate(Offer, :count) == 0
      refute navarch!(ctx.iid, @member_id).on_sold
    end

    test "once the armada is broken, the Navarch lists and sells as before", ctx do
      assert :ok = Game.call(ctx.iid, :player, ctx.alice.id, {:break_armada, @member_id})

      assert :ok = list(ctx, @member_id)
      assert [offer] = Repo.all(Offer)
      assert :ok = Game.call(ctx.iid, :player, ctx.bob.id, {:buy_offer, offer.id})

      sold = navarch!(ctx.iid, @member_id)
      assert sold.owner.id == ctx.bob.id
      refute sold.on_sold
      assert Armada.get(sold) == nil
      assert Armada.get(navarch!(ctx.iid, @lead_id)) == nil

      assert [%{id: @lead_id}] = player_state!(ctx.iid, ctx.alice.id).characters
      assert [%{id: @member_id}] = player_state!(ctx.iid, ctx.bob.id).characters
    end
  end

  describe "a listing that predates the rule (the Navarch is listed and in an armada)" do
    setup :listed_armada_member

    test "cannot be taken: the Navarch stays its owner's, in its armada, and the offer stays up", ctx do
      assert {:error, :character_in_armada} = Game.call(ctx.iid, :player, ctx.bob.id, {:buy_offer, ctx.offer.id})

      assert_not_handed_over(ctx)
    end

    test "cannot be taken while the Navarch rides its lead in transit either", ctx do
      assert {:ok, %{action_status: :attached}} =
               Game.call(ctx.iid, :character, @member_id, {:armada_attach, @system_id})

      assert {:error, :character_in_armada} = Game.call(ctx.iid, :player, ctx.bob.id, {:buy_offer, ctx.offer.id})

      assert_not_handed_over(ctx)
      # still in transit: it was not dropped back into the system it left
      assert %{action_status: :attached, system: nil} = navarch!(ctx.iid, @member_id)
    end

    test "can be taken once its owner breaks the armada", ctx do
      assert :ok = Game.call(ctx.iid, :player, ctx.alice.id, {:break_armada, @member_id})
      assert :ok = Game.call(ctx.iid, :player, ctx.bob.id, {:buy_offer, ctx.offer.id})

      sold = navarch!(ctx.iid, @member_id)
      assert sold.owner.id == ctx.bob.id
      assert Armada.get(sold) == nil
      assert Armada.get(navarch!(ctx.iid, @lead_id)) == nil
    end

    test "cancelling it only lifts the listing: same owner, same armada", ctx do
      assert :ok = Game.call(ctx.iid, :player, ctx.alice.id, {:cancel_offer, ctx.offer.id})

      assert Repo.get!(Offer, ctx.offer.id).status == "inactive"

      navarch = navarch!(ctx.iid, @member_id)
      refute navarch.on_sold
      assert navarch.owner.id == ctx.alice.id
      assert %{member_ids: [@lead_id, @member_id]} = Armada.get(navarch)
      assert Armada.get(navarch!(ctx.iid, @lead_id)) == Armada.get(navarch)

      refute Enum.any?(player_state!(ctx.iid, ctx.alice.id).characters, & &1.on_sold)
    end
  end

  # ---------------------------------------------------------------------------

  # Alice groups her two Navarchs — what {:form_armada, _, _} runs once past
  # its Faction Government gate.
  defp form_armada(ctx) do
    assert :ok = ArmadaImpl.form(ctx.iid, player_state!(ctx.iid, ctx.alice.id), @lead_id, @member_id)
    assert %{member_ids: [@lead_id, @member_id]} = Armada.get(navarch!(ctx.iid, @member_id))
    :ok
  end

  # The state the market allowed before the rule: the Navarch is listed, then
  # given its armada map by hand, since forming or joining refuses a listed
  # Navarch.
  defp listed_armada_member(ctx) do
    assert :ok = list(ctx, @member_id)
    assert [offer] = Repo.all(Offer)

    armada = Armada.new(@lead_id, "The Iron Concord", [@lead_id, @member_id])

    for id <- [@lead_id, @member_id] do
      assert {:ok, _} = Game.call(ctx.iid, :character, id, {:update_armada, armada})
    end

    {:ok, offer: offer}
  end

  defp assert_not_handed_over(ctx) do
    assert Repo.get!(Offer, ctx.offer.id).status == "active"

    navarch = navarch!(ctx.iid, @member_id)
    assert navarch.on_sold
    assert navarch.owner.id == ctx.alice.id
    assert %{member_ids: [@lead_id, @member_id]} = Armada.get(navarch)

    assert [%{id: @lead_id}, %{id: @member_id}] = player_state!(ctx.iid, ctx.alice.id).characters

    bob = player_state!(ctx.iid, ctx.bob.id)
    assert bob.characters == []
    assert bob.credit.value == ctx.bob.credit.value
  end

  # Alice lists one of her Navarchs from the field.
  defp list(ctx, character_id, mode \\ "donation") do
    args = %{
      "mode" => mode,
      "type" => "board_character",
      "data" => %{"character_id" => character_id},
      "price" => 0,
      "allowed_players" => [],
      "allowed_factions" => []
    }

    Game.call(ctx.iid, :player, ctx.alice.id, {:create_offer, args})
  end

  defp navarch!(iid, character_id) do
    {:ok, navarch} = Game.call(iid, :character, character_id, :get_state)
    navarch
  end

  defp player_state!(iid, player_id) do
    {:ok, player} = Game.call(iid, :player, player_id, :get_state)
    player
  end

  # A real character agent, shipless (the harness cannot build ship structs).
  defp navarch(iid, faction, owner, character_id) do
    {navarch, _pid} =
      FleetScenario.spawn_real_character(self(),
        instance_id: iid,
        character_id: character_id,
        faction: owner.faction,
        faction_id: faction.id,
        system: @system_id,
        virtual_position: @system_id,
        owner_id: owner.id,
        owner_name: owner.name,
        has_ships?: false
      )

    navarch
  end

  # A real player agent, registered like the instance's own but never
  # started: it answers calls and does not tick.
  defp start_player!(player) do
    channel = "instance:player:#{player.instance_id}:#{player.id}"
    state = Core.GenState.new(:player, player.instance_id, player.id, player, channel)
    {:ok, pid} = Instance.Player.Agent.start_link(state: state)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp player!(iid, faction, name) do
    n = System.unique_integer([:positive])

    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "armada-market-#{n}@test.local",
        password: "armada-market-test-password-#{n}",
        name: "ArmadaMarket#{n}",
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
      credit: Core.DynamicValue.new(1_000_000),
      technology: Core.DynamicValue.new(0),
      ideology: Core.DynamicValue.new(0),
      patents: [],
      # the lex that opens the first Navarch slot
      doctrines: [:agent],
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

    {:ok, player, _system_bonuses, _character_bonuses} = Player.update_policies(player, [:agent])
    %{player | policies_cooldown: Core.CooldownValue.new()}
  end
end
