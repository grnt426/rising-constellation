defmodule RC.Security.GameActionsTest do
  @moduledoc """
  Regression tests for the Stage 4 critical/high fixes:

    * #C1 — Faction.Agent crash protection: `Faction.push_message` /
      `Faction.ChatMessage.new` no longer raise on non-binary input (which
      used to crash the per-faction GenServer and DoS every member).
    * #C3 — `place_offer` for technology / ideology requires positive
      integer amount; negative values used to mint resources.
    * #C4 — `RC.Offers.transition_status/3` is the atomic offer state
      transition primitive; two concurrent callers cannot both succeed.
    * #H7 — `ReplayRecorder.record_action` skips persistence on
      `{:error, _}` results (closes the DB-pool-saturation amplifier on
      bad-payload spam).
    * #H8 — `Faction.ChatMessage.new` slices `from` to 64 chars (defense
      in depth on top of server-side derivation in the channel handler).
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures

  alias Instance.Faction.ChatMessage
  alias Instance.Faction.Faction
  alias Instance.Player.Market, as: PlayerMarket
  alias Portal.ReplayRecorder
  alias RC.Instances.Offer
  alias RC.Offers
  alias RC.Repo

  defp empty_faction do
    %Faction{
      id: 1,
      key: :synelle,
      players: [],
      chat: [],
      contacts: %{},
      all_radars: %{},
      radars: %{},
      detected_objects: [],
      market_taxes: Instance.Faction.Market.new(),
      icons: [],
      icon_rate_buckets: %{},
      galactic_survey_cache: nil,
      government: nil,
      diplomacy: %{},
      instance_id: 1
    }
  end

  # The `Instance.Player.Player` struct has a lot of nested DynamicValue
  # state; build only the slice place_offer needs (`technology` /
  # `ideology` resource counters).
  defp player_with_balance(technology: technology, ideology: ideology) do
    %{
      technology: %Core.DynamicValue{value: technology, details: [], change: 0.0},
      ideology: %Core.DynamicValue{value: ideology, details: [], change: 0.0}
    }
  end

  describe "Stage 4 #C1 — Faction.push_message does NOT crash on malformed input" do
    test "nil message returns state unchanged" do
      state = empty_faction()
      # Before the fix this would raise `String.length(nil)` inside the
      # Faction.Agent's on_cast, crashing the per-faction GenServer.
      assert ^state = Faction.push_message(state, "sender", 1, nil)
      assert state.chat == []
    end

    test "integer message returns state unchanged" do
      state = empty_faction()
      assert ^state = Faction.push_message(state, "sender", 1, 42)
    end

    test "non-binary `from` returns state unchanged" do
      state = empty_faction()
      assert ^state = Faction.push_message(state, nil, 1, "hello")
      assert ^state = Faction.push_message(state, 123, 1, "hello")
    end

    test "non-integer `from_id` returns state unchanged" do
      # `from_id` carries the sender's profile_id for per-account mute
      # lookups; the guard rejects non-integer values so a bad payload
      # from a future caller can't slip a nil/string into the chat ring.
      state = empty_faction()
      assert ^state = Faction.push_message(state, "sender", nil, "hello")
      assert ^state = Faction.push_message(state, "sender", "1", "hello")
    end

    test "well-formed strings still produce a chat entry" do
      state = empty_faction()
      new_state = Faction.push_message(state, "Alice", 1, "hello")
      assert [%ChatMessage{from: "Alice", from_id: 1, message: "hello"}] = new_state.chat
    end
  end

  describe "Stage 4 #M1 / #H8 defense-in-depth — ChatMessage.new caps `from` length" do
    test "long `from` string is sliced to 64 chars" do
      from = String.duplicate("A", 5_000)
      msg = ChatMessage.new(from, 1, "ok")
      assert byte_size(msg.from) <= 65
    end

    test "nil `from` is coerced to empty string (does not crash)" do
      msg = ChatMessage.new(nil, 1, "ok")
      assert msg.from == ""
    end

    test "well-formed short `from` passes through unchanged" do
      msg = ChatMessage.new("Alice", 1, "hi")
      assert msg.from == "Alice"
    end
  end

  describe "Stage 4 #C3 — place_offer rejects negative / zero / non-integer amounts" do
    test "negative technology amount is rejected (used to mint)" do
      state = player_with_balance(technology: 1_000, ideology: 1_000)

      assert {:error, :not_enough_technology} =
               PlayerMarket.create_offer(state, %{
                 "type" => "technology",
                 "data" => %{"amount" => -1_000_000},
                 "price" => 0,
                 "allowed_players" => [],
                 "allowed_factions" => []
               })
    end

    test "zero technology amount is rejected (free offer slot)" do
      state = player_with_balance(technology: 1_000, ideology: 1_000)

      assert {:error, :not_enough_technology} =
               PlayerMarket.create_offer(state, %{
                 "type" => "technology",
                 "data" => %{"amount" => 0},
                 "price" => 0,
                 "allowed_players" => [],
                 "allowed_factions" => []
               })
    end

    test "float technology amount is rejected (must be integer)" do
      state = player_with_balance(technology: 1_000, ideology: 1_000)

      assert {:error, :not_enough_technology} =
               PlayerMarket.create_offer(state, %{
                 "type" => "technology",
                 "data" => %{"amount" => 1.5},
                 "price" => 0,
                 "allowed_players" => [],
                 "allowed_factions" => []
               })
    end

    test "negative ideology amount is rejected (used to mint)" do
      state = player_with_balance(technology: 1_000, ideology: 1_000)

      assert {:error, :not_enough_ideology} =
               PlayerMarket.create_offer(state, %{
                 "type" => "ideology",
                 "data" => %{"amount" => -1_000_000},
                 "price" => 0,
                 "allowed_players" => [],
                 "allowed_factions" => []
               })
    end
  end

  describe "Stage 4 #C4 — RC.Offers.transition_status is atomic" do
    setup [:create_post]

    defp seed_offer(profile_id, instance_id, status) do
      {:ok, offer} =
        %Offer{}
        |> Ecto.Changeset.cast(
          %{
            type: "technology",
            status: status,
            data: ~s({"amount": 100}),
            value: 1000,
            price: 50,
            is_public: true,
            profile_id: profile_id,
            instance_id: instance_id
          },
          [:type, :status, :data, :value, :price, :is_public, :profile_id, :instance_id]
        )
        |> Ecto.Changeset.validate_required([:type, :status, :data, :value, :price, :is_public])
        |> Repo.insert()

      offer
    end

    defp instance_for_offer do
      # We just need a real instance row so the offer FK is satisfied.
      import RC.ScenarioFixtures
      %{instance: instance} = instance_fixture()
      instance
    end

    test "first transition succeeds; second on the same expected status fails", %{admin: admin} do
      instance = instance_for_offer()
      profile = create_profile_for(admin)
      offer = seed_offer(profile.id, instance.id, "active")

      assert {:ok, sold} = Offers.transition_status(offer, "active", "sold")
      assert sold.status == "sold"

      # In the DB it's now "sold". A second attempt to transition from
      # "active" must fail — that's the race-window guard.
      assert {:error, :stale_status} = Offers.transition_status(offer, "active", "sold")

      # The row really is "sold" (we didn't accidentally flip it back).
      assert Repo.get!(Offer, offer.id).status == "sold"
    end

    test "transition from wrong expected status fails (no-op)", %{admin: admin} do
      instance = instance_for_offer()
      profile = create_profile_for(admin)
      offer = seed_offer(profile.id, instance.id, "active")

      assert {:error, :stale_status} = Offers.transition_status(offer, "inactive", "sold")
      assert Repo.get!(Offer, offer.id).status == "active"
    end

    test "concurrent transitions on the same offer — only one wins", %{admin: admin} do
      instance = instance_for_offer()
      profile = create_profile_for(admin)
      offer = seed_offer(profile.id, instance.id, "active")

      # Fire two transitions in parallel against the same row. Exactly
      # one must succeed; the other must report :stale_status. This is
      # the property a concurrent buy-buy race needs.
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            # Each Task needs its own DB ownership.
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Offers.transition_status(offer, "active", "sold")
          end)
        end

      results = Task.await_many(tasks, 5_000)

      successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      failures = Enum.count(results, fn r -> match?({:error, :stale_status}, r) end)

      assert successes == 1, "expected exactly one transition to win"
      assert failures == 1, "the loser must report :stale_status"
    end

    defp create_profile_for(account) do
      {:ok, profile} =
        Repo.insert(
          RC.Accounts.Profile.changeset(%RC.Accounts.Profile{}, %{
            avatar: "x",
            name: "p-#{:erlang.unique_integer([:positive])}",
            account_id: account.id
          })
        )

      profile
    end
  end

  describe "Stage 4 #H7 — replay recorder skips persistence on {:error, _}" do
    test "{:error, _} results are not persisted" do
      # ReplayRecorder.record_action returns nil whether it spawns or
      # skips, so we can't observe the call directly. But the gating
      # predicate is testable: it's a tiny module-private function and
      # we exercise it via record_action's external behavior — calling
      # it with a non-recordable socket (`has_replay: false`) returns
      # nil, just like the error-result path.
      #
      # Better: test the public effect — there must be NO new Replay row
      # after calling record_action with an error result on a recording-
      # enabled socket.
      socket = recording_socket()
      before_count = Repo.aggregate(RC.Instances.Replay, :count, :id)

      ReplayRecorder.record_action("test_msg", %{"a" => 1}, socket, {:error, :anything}, 100)
      # spawn is async; give it a tiny window
      Process.sleep(50)

      after_count = Repo.aggregate(RC.Instances.Replay, :count, :id)
      assert after_count == before_count, "expected NO replay row to be written for error result"
    end

    test ":ok results ARE persisted" do
      socket = recording_socket()
      before_count = Repo.aggregate(RC.Instances.Replay, :count, :id)

      ReplayRecorder.record_action("test_msg", %{"a" => 1}, socket, :ok, 100)
      Process.sleep(100)

      after_count = Repo.aggregate(RC.Instances.Replay, :count, :id)
      assert after_count == before_count + 1, "expected one replay row for an :ok result"
    end

    defp recording_socket do
      # Build the assigns shape that record_action's first clause expects.
      # We need real instance_id + profile_id rows to satisfy the FKs.
      import RC.ScenarioFixtures
      %{instance: instance} = instance_fixture()
      account = fixture(:user)

      {:ok, profile} =
        Repo.insert(
          RC.Accounts.Profile.changeset(%RC.Accounts.Profile{}, %{
            avatar: "x",
            name: "p-recording-#{:erlang.unique_integer([:positive])}",
            account_id: account.id
          })
        )

      %{
        assigns: %{
          player_id: profile.id,
          instance_id: instance.id,
          channel_name: "player",
          has_replay: true
        }
      }
    end
  end
end
