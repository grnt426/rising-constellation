defmodule Instance.Player.MarketMutualAidTest do
  @moduledoc """
  The player market's Mutual Aid modes and audience rules
  (`Instance.Player.Market`):

    * whoever completes an offer (buyer, claimer, fulfiller) pays the tax:
      the greater of 1 credit per technology/ideology point and 10% of the
      price, 10% of the credits exchanged on top, 10% of an agent's
      valuation;
    * the poster only escrows the goods (refunded on cancel);
    * donations carry no price — the claimer receives them whole;
    * requests escrow nothing — the fulfiller pays the amount plus the tax,
      the requester receives exactly the amount asked for;
    * Mutual Aid only ever reaches the poster's own faction, and so do trades
      in matches with two factions or fewer; named players must be faction
      members;
    * taking an offer re-checks its audience (an offer id alone is not
      enough).

  Real offer rows (sandboxed DB) and real `%Player{}` structs; the market fee
  comes from the instance's Data constants (market_taxe 0.1).
  """
  use RC.DataCase, async: false

  import RC.ScenarioFixtures

  alias Instance.Player.Market
  alias Instance.Player.Player
  alias RC.Instances.Offer
  alias RC.Repo

  setup do
    %{instance: instance} = instance_fixture()
    iid = instance.id
    Data.Data.insert(iid, speed: :fast, mode: :prod)

    on_exit(fn ->
      try do
        Data.Data.clear(iid)
      rescue
        _ -> :ok
      end
    end)

    [f1, f2] = Enum.sort_by(instance.factions, & &1.id)

    alice = player!(iid, f1, "Alice")
    bob = player!(iid, f1, "Bob")
    carol = player!(iid, f2, "Carol")

    {:ok, iid: iid, f1: f1, f2: f2, alice: alice, bob: bob, carol: carol}
  end

  describe "donations" do
    test "credits: the donor escrows the amount; the claimer receives it whole, 10% tax on top",
         %{alice: alice, bob: bob} do
      assert {:ok, alice} = Market.create_offer(alice, offer("donation", "credit", 1_000))
      assert alice.credit.value == 10_000 - 1_000

      offer = only_offer!()
      assert offer.price == 0
      assert Market.offer_mode(offer) == "donation"

      assert {:ok, bob, poster_id, payout, "donation"} = Market.buy_offer(bob, offer.id)
      assert poster_id == alice.id
      assert payout == {0, 0, 0}
      assert bob.credit.value == 10_000 + 1_000 - 100
    end

    test "credits: claiming needs no prior balance (the tax comes out of the claim)",
         %{alice: alice, bob: bob} do
      {:ok, _} = Market.create_offer(alice, offer("donation", "credit", 1_000))
      assert {:ok, bob, _, _, "donation"} = Market.buy_offer(%{bob | credit: resource(0)}, only_offer!().id)
      assert bob.credit.value == 900
    end

    test "technology: no price; the claimer pays 1 credit of tax per point", %{alice: alice, bob: bob} do
      args = offer("donation", "technology", 500) |> Map.put("price", 123_456)
      assert {:ok, alice} = Market.create_offer(alice, args)
      assert alice.technology.value == 9_500
      assert alice.credit.value == 10_000

      offer = only_offer!()
      assert offer.price == 0

      assert {:ok, bob, _poster, {0, 0, 0}, "donation"} = Market.buy_offer(bob, offer.id)
      assert bob.technology.value == 10_500
      assert bob.credit.value == 10_000 - 500
    end

    test "a claimer who can't cover the tax is refused and the donation stays up",
         %{alice: alice, bob: bob} do
      {:ok, _} = Market.create_offer(alice, offer("donation", "ideology", 2_000))
      offer = only_offer!()
      assert {:error, :not_enough_credit} = Market.buy_offer(%{bob | credit: resource(1_999)}, offer.id)
      assert Repo.get!(Offer, offer.id).status == "active"
    end

    test "cancelling a credit donation refunds it", %{alice: alice} do
      {:ok, alice} = Market.create_offer(alice, offer("donation", "credit", 2_500))
      assert {:ok, alice} = Market.cancel_offer(alice, only_offer!().id)
      assert alice.credit.value == 10_000
    end

    test "a donation cannot be posted to a player of another faction", %{alice: alice, carol: carol} do
      args = offer("donation", "credit", 1_000) |> Map.put("allowed_players", [carol.id])
      assert {:error, :market_player_not_in_faction} = Market.create_offer(alice, args)
      assert Repo.aggregate(Offer, :count) == 0
    end

    test "a donation's audience is the poster's faction, whatever the client sends",
         %{alice: alice, carol: carol, f2: f2} do
      args = offer("donation", "technology", 100) |> Map.put("allowed_factions", [f2.id])
      {:ok, _} = Market.create_offer(alice, args)
      offer = only_offer!()

      refute offer.is_public
      assert [] == RC.Offers.get_offers(alice.instance_id, carol.id, f2.id)
      assert {:error, :offer_not_found} = Market.buy_offer(carol, offer.id)
      assert Repo.get!(Offer, offer.id).status == "active"
    end

    test "a named teammate can claim it", %{alice: alice, bob: bob} do
      args = offer("donation", "ideology", 100) |> Map.put("allowed_players", [bob.id])
      {:ok, _} = Market.create_offer(alice, args)
      assert {:ok, _bob, _, _, "donation"} = Market.buy_offer(bob, only_offer!().id)
    end
  end

  describe "requests" do
    test "technology: nothing escrowed; the fulfiller pays amount + fee, the requester receives it",
         %{alice: alice, bob: bob} do
      assert {:ok, alice_after} = Market.create_offer(alice, offer("request", "technology", 800))
      assert alice_after.technology.value == 10_000
      assert alice_after.credit.value == 10_000

      offer = only_offer!()
      assert Market.offer_mode(offer) == "request"

      assert {:ok, bob, poster_id, payout, "request"} = Market.buy_offer(bob, offer.id)
      assert poster_id == alice.id
      assert payout == {0, 800, 0}
      assert bob.technology.value == 9_200
      # tax: 1 credit per tech point
      assert bob.credit.value == 9_200
    end

    test "credits: the fulfiller pays the amount plus the fee in credits", %{alice: alice, bob: bob} do
      {:ok, _} = Market.create_offer(alice, offer("request", "credit", 3_000))
      assert {:ok, bob, _poster, {3_000, 0, 0}, "request"} = Market.buy_offer(bob, only_offer!().id)
      assert bob.credit.value == 10_000 - 3_000 - 300
    end

    test "a fulfiller short on the resource is refused and the request stays up",
         %{alice: alice, bob: bob} do
      {:ok, _} = Market.create_offer(alice, offer("request", "ideology", 500))
      offer = only_offer!()

      assert {:error, :not_enough_ideology} = Market.buy_offer(%{bob | ideology: resource(100)}, offer.id)
      assert Repo.get!(Offer, offer.id).status == "active"

      # the fee is checked too
      assert {:error, :not_enough_credit} = Market.buy_offer(%{bob | credit: resource(400)}, offer.id)
      assert Repo.get!(Offer, offer.id).status == "active"
    end

    test "cancelling a request gives nothing back (nothing was taken)", %{alice: alice} do
      {:ok, _} = Market.create_offer(alice, offer("request", "credit", 5_000))
      assert {:ok, alice} = Market.cancel_offer(alice, only_offer!().id)
      assert alice.credit.value == 10_000
    end

    test "agents cannot be requested, and amounts must be positive integers", %{alice: alice} do
      assert {:error, :bad_argument} =
               Market.create_offer(alice, %{
                 "mode" => "request",
                 "type" => "character_deck",
                 "data" => %{"character_id" => 1}
               })

      assert {:error, :bad_argument} = Market.create_offer(alice, offer("request", "credit", 0))
      assert {:error, :bad_argument} = Market.create_offer(alice, offer("request", "credit", -10))
      assert Repo.aggregate(Offer, :count) == 0
    end

    test "players cannot fulfil their own request", %{alice: alice} do
      {:ok, _} = Market.create_offer(alice, offer("request", "credit", 100))
      assert {:error, :cannot_buy_own_offer} = Market.buy_offer(alice, only_offer!().id)
    end
  end

  describe "trades" do
    test "the buyer pays price + 1 credit per point (cheap listings); the seller gets the price",
         %{alice: alice, bob: bob} do
      args = offer("trade", "technology", 100) |> Map.put("price", 700)
      assert {:ok, posted} = Market.create_offer(alice, args)
      assert posted.credit.value == 10_000
      assert posted.technology.value == 10_000 - 100

      offer = only_offer!()
      assert {:ok, bob, _poster, {700, 0, 0}, "trade"} = Market.buy_offer(bob, offer.id)
      assert bob.credit.value == 10_000 - 700 - 100
      assert bob.technology.value == 10_100

      {:ok, posted_again} = Market.create_offer(posted, offer("trade", "ideology", 2_000) |> Map.put("price", 0))
      [ideo] = Repo.all(from(o in Offer, where: o.type == "ideology"))
      assert {:ok, bob, _poster, {0, 0, 0}, "trade"} = Market.buy_offer(bob, ideo.id)
      assert bob.credit.value == 10_000 - 800 - 2_000

      assert posted_again.ideology.value == 8_000
    end

    test "a steep price is taxed at 10% of the price when that beats 1 credit per point",
         %{alice: alice, bob: bob} do
      # 100 tech at 5 000: 10% of the price (500) > 100 points
      {:ok, _} = Market.create_offer(alice, offer("trade", "technology", 100) |> Map.put("price", 5_000))
      assert {:ok, bob, _poster, {5_000, 0, 0}, "trade"} = Market.buy_offer(bob, only_offer!().id)
      assert bob.credit.value == 10_000 - 5_000 - 500
    end

    test "tax/2 takes the greater of 1 per point and 10% of the price" do
      tech = fn amount, price ->
        %Offer{type: "technology", price: price, data: Jason.encode!(%{"amount" => amount})}
      end

      assert Market.tax(tech.(1_000, 0), 0.1) == 1_000
      assert Market.tax(tech.(1_000, 10_000), 0.1) == 1_000
      assert Market.tax(tech.(1_000, 100_000), 0.1) == 10_000.0
      assert Market.tax(%Offer{type: "credit", price: 0, data: ~s({"amount": 3000})}, 0.1) == 300.0
    end

    test "cancelling a trade returns the goods", %{alice: alice} do
      {:ok, posted} = Market.create_offer(alice, offer("trade", "technology", 300) |> Map.put("price", 5))
      assert {:ok, back} = Market.cancel_offer(posted, only_offer!().id)
      assert back.technology.value == 10_000
      assert back.credit.value == 10_000
    end

    test "credits cannot be sold (only donated)", %{alice: alice} do
      assert {:error, :bad_argument} = Market.create_offer(alice, offer("trade", "credit", 100))
    end

    test "in a two-faction match a trade is locked to the poster's faction",
         %{alice: alice, carol: carol, f2: f2} do
      args = offer("trade", "technology", 100) |> Map.merge(%{"price" => 700, "allowed_factions" => [f2.id]})
      {:ok, _} = Market.create_offer(alice, args)
      offer = only_offer!()

      assert offer.price == 700
      assert [] == RC.Offers.get_offers(alice.instance_id, carol.id, f2.id)
      assert {:error, :offer_not_found} = Market.buy_offer(carol, offer.id)
    end

    test "in a two-faction match named buyers must be teammates", %{alice: alice, carol: carol} do
      args = offer("trade", "technology", 100) |> Map.put("allowed_players", [carol.id])
      assert {:error, :market_player_not_in_faction} = Market.create_offer(alice, args)
    end

    test "with three factions the poster chooses the audience freely", %{iid: iid, alice: alice, carol: carol, f2: f2} do
      Repo.insert!(%RC.Instances.Faction{instance_id: iid, faction_ref: "cardan", capacity: 10})

      {:ok, _} = Market.create_offer(alice, offer("trade", "technology", 100) |> Map.put("price", 250))
      offer = only_offer!()
      assert offer.is_public

      assert {:ok, carol, _poster, {250, 0, 0}, "trade"} = Market.buy_offer(carol, offer.id)
      assert carol.technology.value == 10_100
      assert carol.credit.value == 10_000 - 250 - 100

      args = offer("trade", "ideology", 10) |> Map.put("allowed_players", [carol.id])
      assert {:ok, _} = Market.create_offer(alice, args)
      assert Repo.get_by!(Offer, type: "ideology").is_public == false
      assert [_] = RC.Offers.get_offers(iid, carol.id, f2.id) |> Enum.filter(&(&1.type == "ideology"))
    end

    test "legacy rows without a mode still trade, with the same tax",
         %{alice: alice, bob: bob, f1: f1} do
      {:ok, offer} =
        RC.Offers.create_for_allowed_factions(
          %{
            type: "technology",
            data: ~s({"amount": 40}),
            internal: nil,
            price: 90,
            profile_id: alice.id,
            instance_id: alice.instance_id,
            value: 400
          },
          [f1.id]
        )

      assert Market.offer_mode(offer) == "trade"
      assert {:ok, bob, _poster, {90, 0, 0}, "trade"} = Market.buy_offer(bob, offer.id)
      assert bob.credit.value == 10_000 - 90 - 40
    end
  end

  describe "agents listed from the field" do
    test "offer lists say where the agent is now and whether it can still be bought",
         %{iid: iid, alice: alice, f1: f1} do
      {_character, pid} =
        Test.FleetScenario.spawn_fake_character(self(),
          instance_id: iid,
          character_id: 4_001,
          faction: :tetrarchy,
          system: 77,
          owner_id: alice.id
        )

      field = agent_offer!(alice, f1, 4_001)
      deck = agent_offer!(alice, f1, 4_002, "character_deck")

      [live_field, plain_deck] = Market.with_live_agents([field, deck], iid)

      assert %{available: true, system_id: 77, character: %{id: 4_001}} = live_field.live
      refute Map.has_key?(plain_deck, :live)

      # sold on elsewhere / captured: no longer the poster's
      GenServer.call(pid, {:update, &%{&1 | owner: %{&1.owner | id: alice.id + 1}}})
      assert [%{live: %{available: false, system_id: nil}}] = Market.with_live_agents([field], iid)

      # dead or gone: no agent process at all
      GenServer.stop(pid)
      assert [%{live: %{available: false}}] = Market.with_live_agents([field], iid)
    end
  end

  # ---------------------------------------------------------------------------

  defp agent_offer!(poster, faction, character_id, type \\ "board_character") do
    {:ok, offer} =
      RC.Offers.create_for_allowed_factions(
        %{
          type: type,
          data: Jason.encode!(%{"character_id" => character_id, "mode" => "trade"}),
          internal: nil,
          price: 1,
          profile_id: poster.id,
          instance_id: poster.instance_id,
          value: 50_000
        },
        [faction.id]
      )

    offer
  end

  defp offer(mode, type, amount) do
    %{
      "mode" => mode,
      "type" => type,
      "data" => %{"amount" => amount},
      "price" => 0,
      "allowed_players" => [],
      "allowed_factions" => []
    }
  end

  defp only_offer! do
    [offer] = Repo.all(Offer)
    offer
  end

  defp player!(iid, faction, name) do
    n = System.unique_integer([:positive])

    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "market-#{n}@test.local",
        password: "market-test-password-#{n}",
        name: "Market#{n}",
        role: :user,
        status: :active
      })

    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "#{name}#{n}", avatar: "todo"})
    {:ok, _} = RC.Registrations.register_profile(faction, profile)

    struct(Player, %{
      id: profile.id,
      instance_id: iid,
      faction_id: faction.id,
      faction: String.to_atom(faction.faction_ref),
      name: name,
      credit: resource(10_000),
      technology: resource(10_000),
      ideology: resource(10_000),
      character_deck: [],
      characters: []
    })
  end

  defp resource(value), do: %Core.DynamicValue{value: value, details: %{}, change: 0}
end
