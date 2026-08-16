defmodule RC.ForesightTest do
  use RC.DataCase

  import Ecto.Query
  import RC.ScenarioFixtures

  alias RC.Foresight
  alias RC.Foresight.Prediction
  alias RC.Foresight.SettlementRecord
  alias RC.Foresight.Sweeper
  alias RC.Instances.Instance
  alias RC.Instances.InstanceState
  alias RC.Instances.Victory
  alias RC.Repo

  # Placement, the join-time refund hook, and end-to-end settlement over
  # real rows (the math itself is covered in settlement_test.exs).

  defp account_fixture(email) do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: email,
        password: "some password",
        name: String.replace(email, ~r/@.*/, ""),
        role: :user,
        status: :active
      })

    account
  end

  defp profile_fixture(account) do
    {:ok, profile} = RC.Accounts.create_profile(%{avatar: "todo", name: account.name, account_id: account.id})
    profile
  end

  # instance_fixture/0 builds tetrarchy + myrmezir factions but no speed
  # and state "created" — stamp it predictable and started.
  defp predictable_instance(state \\ "running") do
    %{instance: instance} = instance_fixture()

    {1, _} =
      Repo.update_all(from(i in Instance, where: i.id == ^instance.id),
        set: [game_data: %{"speed" => "slow"}, state: state]
      )

    factions = Enum.sort_by(instance.factions, & &1.id)
    %{instance | game_data: %{"speed" => "slow"}, state: state, factions: factions}
  end

  defp faction(instance, ref), do: Enum.find(instance.factions, &(&1.faction_ref == ref))

  defp register(instance, ref, account) do
    profile = profile_fixture(account)
    {:ok, %{registration: registration}} = RC.Registrations.register_profile(faction(instance, ref), profile)
    registration
  end

  defp balance(account_id) do
    Repo.one(from(a in RC.Accounts.Account, where: a.id == ^account_id, select: {a.foresight_tokens, a.foresight_points}))
  end

  defp drain(account_id, leave \\ 0) do
    {1, _} =
      Repo.update_all(from(a in RC.Accounts.Account, where: a.id == ^account_id), set: [foresight_tokens: leave])

    :ok
  end

  defp backdate_prediction(prediction, datetime) do
    {1, _} =
      Repo.update_all(from(p in Prediction, where: p.id == ^prediction.id), set: [inserted_at: datetime])

    :ok
  end

  defp start_running_at(instance, datetime) do
    {:ok, _} = RC.Instances.create_instance_state(%{instance_id: instance.id, state: "running"}, instance.account_id)

    {_, _} =
      Repo.update_all(
        from(s in InstanceState, where: s.instance_id == ^instance.id and s.state == "running"),
        set: [inserted_at: datetime]
      )

    :ok
  end

  defp decide_at(instance, winner_ref, datetime) do
    %Victory{}
    |> Victory.changeset(%{instance_id: instance.id, victory_type: "victory_track"})
    |> Repo.insert!()

    {_, _} =
      Repo.update_all(from(v in Victory, where: v.instance_id == ^instance.id), set: [inserted_at: datetime])

    for {f, index} <- Enum.with_index(instance.factions) do
      rank = if f.faction_ref == winner_ref, do: 1, else: index + 2
      Repo.update_all(from(x in RC.Instances.Faction, where: x.id == ^f.id), set: [final_rank: rank])
    end

    :ok
  end

  describe "commit/4" do
    test "happy path debits the balance and records an active prediction" do
      instance = predictable_instance()
      account = account_fixture("alice@test")
      tetrarchy = faction(instance, "tetrarchy")

      assert {:ok, prediction} = Foresight.commit(account.id, instance.id, tetrarchy.id, 30)
      assert prediction.status == "active"
      assert prediction.tokens == 30
      assert prediction.credited_tokens == 0
      assert prediction.faction_ref == "tetrarchy"
      assert balance(account.id) == {70, 0}
    end

    test "rejects a match that has not started" do
      instance = predictable_instance("open")
      account = account_fixture("alice@test")

      assert {:error, :match_not_started} =
               Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 10)
    end

    test "rejects non-predictable speeds" do
      %{instance: instance} = instance_fixture()
      {1, _} = Repo.update_all(from(i in Instance, where: i.id == ^instance.id), set: [state: "running"])
      account = account_fixture("alice@test")

      assert {:error, :not_predictable} =
               Foresight.commit(account.id, instance.id, List.first(instance.factions).id, 10)
    end

    test "closes the window once the winner is decided" do
      instance = predictable_instance()
      account = account_fixture("alice@test")
      decide_at(instance, "tetrarchy", DateTime.utc_now())

      assert {:error, :window_closed} =
               Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 10)
    end

    test "a registered player may only back their own faction" do
      instance = predictable_instance()
      account = account_fixture("player@test")
      register(instance, "tetrarchy", account)

      assert {:error, :own_faction_only} =
               Foresight.commit(account.id, instance.id, faction(instance, "myrmezir").id, 10)

      assert {:ok, _} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 10)
    end

    test "all of an account's predictions must target one faction" do
      instance = predictable_instance()
      account = account_fixture("alice@test")

      assert {:ok, _} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 10)

      assert {:error, :single_faction_per_match} =
               Foresight.commit(account.id, instance.id, faction(instance, "myrmezir").id, 10)
    end

    test "rejects a commit over the balance (beyond courtesy)" do
      instance = predictable_instance()
      account = account_fixture("alice@test")

      assert {:error, :insufficient_tokens} =
               Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 150)
    end

    test "courtesy allowance: a broke account can still commit up to the limit, once" do
      instance = predictable_instance()
      account = account_fixture("broke@test")
      drain(account.id)

      assert {:ok, prediction} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 5)
      assert prediction.credited_tokens == 5
      assert balance(account.id) == {0, 0}

      # a second outstanding courtesy prediction is refused by the index
      assert {:error, :courtesy_in_use} =
               Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 3)
    end

    test "courtesy tops up a partial balance" do
      instance = predictable_instance()
      account = account_fixture("poor@test")
      drain(account.id, 2)

      assert {:ok, prediction} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 5)
      assert prediction.credited_tokens == 3
      assert balance(account.id) == {0, 0}
    end

    test "unknown faction is rejected" do
      instance = predictable_instance()
      account = account_fixture("alice@test")

      assert {:error, :unknown_faction} = Foresight.commit(account.id, instance.id, 999_999, 10)
    end
  end

  describe "return_on_join/2" do
    test "voids active predictions and returns the debited tokens" do
      instance = predictable_instance()
      account = account_fixture("spectator@test")
      {:ok, prediction} = Foresight.commit(account.id, instance.id, faction(instance, "myrmezir").id, 20)
      assert balance(account.id) == {80, 0}

      assert :ok = Foresight.return_on_join(account.id, instance.id)

      reloaded = Repo.get(Prediction, prediction.id)
      assert reloaded.status == "void"
      assert reloaded.tokens_recovered == 20
      assert balance(account.id) == {100, 0}
    end

    test "a voided courtesy prediction returns only the debited part and frees the slot" do
      instance = predictable_instance()
      account = account_fixture("broke@test")
      drain(account.id, 2)
      {:ok, _} = Foresight.commit(account.id, instance.id, faction(instance, "myrmezir").id, 5)

      assert :ok = Foresight.return_on_join(account.id, instance.id)
      # 2 debited come back; the 3 minted dissolve
      assert balance(account.id) == {2, 0}

      # the courtesy slot is free again
      assert {:ok, _} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 5)
    end

    test "leaves decided matches to settlement" do
      instance = predictable_instance()
      account = account_fixture("spectator@test")
      {:ok, prediction} = Foresight.commit(account.id, instance.id, faction(instance, "tetrarchy").id, 20)
      decide_at(instance, "tetrarchy", DateTime.utc_now())

      assert :ok = Foresight.return_on_join(account.id, instance.id)
      assert Repo.get(Prediction, prediction.id).status == "active"
    end
  end

  describe "settle/2" do
    # Three humans registered (min-players), two spectators on the
    # winner at different times, one on the loser — the worked example's
    # shape over real rows, settled via the sweeper path (final_rank).
    test "end-to-end settlement credits balances, points, and the latch" do
      instance = predictable_instance()
      # Second-aligned: instance_states / victories timestamps are
      # second-precision, so a fractional t0 would shift every earliness
      # ratio by the truncated remainder and jitter the ceil'd shares.
      t0 = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-18 * 3600, :second)

      for {ref, email} <- [{"tetrarchy", "p1@test"}, {"tetrarchy", "p2@test"}, {"myrmezir", "p3@test"}] do
        register(instance, ref, account_fixture(email))
      end

      alice = account_fixture("alice@test")
      bob = account_fixture("bob@test")
      carol = account_fixture("carol@test")

      tetrarchy = faction(instance, "tetrarchy")
      myrmezir = faction(instance, "myrmezir")

      {:ok, p_alice} = Foresight.commit(alice.id, instance.id, tetrarchy.id, 30)
      {:ok, p_bob} = Foresight.commit(bob.id, instance.id, tetrarchy.id, 20)
      # Carol's 200 exceeds the 100-token seed; commit the max and scale
      # the row up to hit the worked-example numbers.
      {:ok, p_carol} = Foresight.commit(carol.id, instance.id, myrmezir.id, 100)
      {1, _} = Repo.update_all(from(p in Prediction, where: p.id == ^p_carol.id), set: [tokens: 200])

      backdate_prediction(p_alice, DateTime.add(t0, 2 * 3600, :second))
      backdate_prediction(p_bob, DateTime.add(t0, 12 * 3600, :second))
      backdate_prediction(p_carol, DateTime.add(t0, 1 * 3600, :second))

      start_running_at(instance, t0)
      decide_at(instance, "tetrarchy", DateTime.add(t0, 18 * 3600, :second))

      assert {:ok, plan} = Foresight.settle(instance.id)
      assert plan.outcome == "settled"
      assert plan.winning_faction_ref == "tetrarchy"

      # Alice: 100 - 30 + (30 + 136 + 13 bonus) = 249 tokens, 284 points
      assert balance(alice.id) == {249, 284}
      # Bob: 100 - 20 + (20 + 64) = 164 tokens, 134 points
      assert balance(bob.id) == {164, 134}
      # Carol: drained to 0, loses everything, no points
      assert balance(carol.id) == {0, 0}

      alice_row = Repo.get(Prediction, p_alice.id)
      assert alice_row.status == "correct"
      assert alice_row.tokens_recovered == 166
      assert alice_row.bonus_tokens == 13
      assert alice_row.points_awarded == 284

      record = Repo.get_by(SettlementRecord, instance_id: instance.id)
      assert record.outcome == "settled"
      assert record.winning_faction_ref == "tetrarchy"
      assert record.pool_tokens == 250

      # exactly-once: settling again is a no-op
      assert :already_settled = Foresight.settle(instance.id)
    end

    test "fewer than three humans voids the whole match" do
      instance = predictable_instance()
      register(instance, "tetrarchy", account_fixture("only@test"))

      alice = account_fixture("alice@test")
      bob = account_fixture("bob@test")
      {:ok, _} = Foresight.commit(alice.id, instance.id, faction(instance, "tetrarchy").id, 40)
      {:ok, _} = Foresight.commit(bob.id, instance.id, faction(instance, "myrmezir").id, 25)

      start_running_at(instance, DateTime.add(DateTime.utc_now(), -3600, :second))
      decide_at(instance, "tetrarchy", DateTime.utc_now())

      assert {:ok, plan} = Foresight.settle(instance.id)
      assert plan.outcome == "void_min_players"
      assert balance(alice.id) == {100, 0}
      assert balance(bob.id) == {100, 0}
    end

    test "settle with no active predictions is a noop" do
      instance = predictable_instance()
      decide_at(instance, "tetrarchy", DateTime.utc_now())
      assert :noop = Foresight.settle(instance.id)
    end
  end

  describe "void/2 and the sweeper" do
    test "void returns debited tokens under the given outcome" do
      instance = predictable_instance()
      alice = account_fixture("alice@test")
      {:ok, _} = Foresight.commit(alice.id, instance.id, faction(instance, "tetrarchy").id, 40)

      assert {:ok, plan} = Foresight.void(instance.id, "void_no_winner")
      assert plan.outcome == "void_no_winner"
      assert balance(alice.id) == {100, 0}
    end

    test "sweep voids ended matches without a winner and settles decided ones" do
      # ended without victory -> void
      ended = predictable_instance()
      alice = account_fixture("alice@test")
      {:ok, _} = Foresight.commit(alice.id, ended.id, faction(ended, "tetrarchy").id, 10)
      {1, _} = Repo.update_all(from(i in Instance, where: i.id == ^ended.id), set: [state: "ended"])

      # running with predictions -> untouched
      pending = predictable_instance()
      bob = account_fixture("bob@test")
      {:ok, p_pending} = Foresight.commit(bob.id, pending.id, faction(pending, "tetrarchy").id, 10)

      Sweeper.sweep()

      assert Repo.get_by(SettlementRecord, instance_id: ended.id).outcome == "void_no_winner"
      assert balance(alice.id) == {100, 0}
      assert Repo.get(Prediction, p_pending.id).status == "active"
      assert Repo.get_by(SettlementRecord, instance_id: pending.id) == nil
    end

    test "sweep voids predictions whose instance row is gone" do
      instance = predictable_instance()
      alice = account_fixture("alice@test")
      {:ok, _} = Foresight.commit(alice.id, instance.id, faction(instance, "tetrarchy").id, 15)

      Repo.delete_all(from(s in InstanceState, where: s.instance_id == ^instance.id))
      Repo.delete_all(from(f in RC.Instances.Faction, where: f.instance_id == ^instance.id))
      Repo.delete_all(from(i in Instance, where: i.id == ^instance.id))
      Sweeper.sweep()

      assert Repo.get_by(SettlementRecord, instance_id: instance.id).outcome == "void_instance_deleted"
      assert balance(alice.id) == {100, 0}
    end
  end
end
