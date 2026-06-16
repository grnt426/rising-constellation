defmodule Instance.Contracts.ContractsTest do
  # Coverage for the registry: id allocation, the per-player strike tally, closure
  # routing to resolution, the expiry sweep, and the next-tick interval. Still pure —
  # effects (credit movements) are returned for the agent, not performed here.
  use ExUnit.Case, async: true

  alias Instance.Contracts.Contracts

  @payer 100
  @performer 200
  @attrs %{action_category: :spy, action_type: :assassination, bounty: 1000, duration: 30.0, max_claimant_strikes: 5}

  defp reg, do: Contracts.new(1)

  # A registry with one active contract (id 1), created at `now` 0 and claimed at 0.
  defp with_active do
    {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
    {:ok, s, _} = Contracts.claim(s, 1, @performer, 0.0)
    s
  end

  describe "create/4" do
    test "assigns sequential ids and stores the contracts" do
      {:ok, s, c1} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {:ok, s, c2} = Contracts.create(s, @payer, @attrs, 0.0)

      assert c1.id == 1
      assert c2.id == 2
      assert length(Contracts.all(s)) == 2
      assert Contracts.get(s, 1).payer_id == @payer
    end

    test "stamps clock and deadline from the supplied now" do
      {:ok, s, c} = Contracts.create(reg(), @payer, @attrs, 12.0)
      assert c.created_at == 12.0
      assert c.deadline == 42.0
      assert s.clock == 12.0
    end

    test "invalid attrs return an error and do not advance the id counter" do
      assert {:error, :invalid_bounty} = Contracts.create(reg(), @payer, %{@attrs | bounty: 0}, 0.0)
      # counter still at 1 -> next successful create is id 1
      {:ok, _s, c} = Contracts.create(reg(), @payer, @attrs, 0.0)
      assert c.id == 1
    end
  end

  describe "claim/4" do
    test "activates the contract and locks fees from current strikes" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {:ok, _s, c} = Contracts.claim(s, 1, @performer, 10.0)

      assert c.status == :active
      assert c.performer_id == @performer
      assert c.deadline == 40.0
      # no strikes yet -> base 5% each on a 1000 bounty
      assert c.listing_fee == 50
      assert c.closing_fee == 50
    end

    test "unknown contract id" do
      assert {:error, :contract_not_found} = Contracts.claim(reg(), 99, @performer, 0.0)
    end

    test "propagates the Contract guard for claiming your own listing" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      assert {:error, :cannot_claim_own_contract} = Contracts.claim(s, 1, @payer, 0.0)
    end
  end

  describe "submit_closure/4" do
    test "a single submission records the intent without resolving" do
      assert {:ok, _s, c} = Contracts.submit_closure(with_active(), 1, @performer, :claim)
      assert c.performer_closure == :claim
      assert c.status == :active
    end

    test "the second submission resolves and returns effects" do
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @payer, :pay)
      assert {:resolved, _s, %{outcome: :paid, payout: 900}} =
               Contracts.submit_closure(s, 1, @performer, :claim)
    end

    test "a dispute resolution adds a permanent strike to BOTH parties" do
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @payer, :dispute)
      {:resolved, s, effects} = Contracts.submit_closure(s, 1, @performer, :claim)

      assert effects.outcome == :disputed
      assert effects.refund == 1000
      assert Contracts.strikes(s, @payer) == 1
      assert Contracts.strikes(s, @performer) == 1
    end

    test "accumulated strikes raise the fees on the next contract" do
      # First contract -> dispute -> both parties at 1 strike
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @payer, :dispute)
      {:resolved, s, _} = Contracts.submit_closure(s, 1, @performer, :claim)

      # New contract between the same two: combined 2 strikes -> 0.05 + 2*0.03 = 0.11
      {:ok, s, _} = Contracts.create(s, @payer, @attrs, 0.0)
      {:ok, _s, c2} = Contracts.claim(s, 2, @performer, 0.0)
      assert c2.listing_fee == 110
      assert c2.closing_fee == 110
    end

    test "unknown contract id" do
      assert {:error, :contract_not_found} = Contracts.submit_closure(reg(), 99, @payer, :pay)
    end
  end

  describe "withdraw_closure/3" do
    test "clears a recorded intent" do
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @payer, :pay)
      assert {:ok, _s, c} = Contracts.withdraw_closure(s, 1, @payer)
      assert c.payer_closure == nil
    end
  end

  describe "cancel/3" do
    test "issuer voids an unclaimed listing for a full refund" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {:resolved, s, effects} = Contracts.cancel(s, 1, @payer)

      assert effects.outcome == :refunded
      assert effects.refund == 1000
      assert Contracts.get(s, 1).status == :refunded
    end

    test "a non-issuer cannot cancel" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      assert {:error, :not_a_party} = Contracts.cancel(s, 1, @performer)
    end
  end

  describe "next_tick/2 (expiry sweep)" do
    test "advances the clock and refunds an unclaimed expired listing" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {s, effects_list} = Contracts.next_tick(s, 35.0)

      assert [%{outcome: :refunded, refund: 1000}] = effects_list
      assert Contracts.get(s, 1).status == :refunded
      assert s.clock == 35.0
    end

    test "a claimed contract with a silent payer pays out the performer at expiry" do
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @performer, :claim)
      {_s, effects_list} = Contracts.next_tick(s, 31.0)
      assert [%{outcome: :paid, payout: 900}] = effects_list
    end

    test "leaves un-expired contracts untouched" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {s, effects_list} = Contracts.next_tick(s, 10.0)
      assert effects_list == []
      assert Contracts.get(s, 1).status == :listed
    end

    test "a disputed expiry applies strikes to both parties" do
      {:ok, s, _} = Contracts.submit_closure(with_active(), 1, @payer, :dispute)
      {s, [effects]} = Contracts.next_tick(s, 31.0)

      assert effects.outcome == :disputed
      assert Contracts.strikes(s, @payer) == 1
      assert Contracts.strikes(s, @performer) == 1
    end
  end

  describe "compute_next_tick_interval/1" do
    test "is :never with no open contracts" do
      assert Contracts.compute_next_tick_interval(reg()) == :never
    end

    test "is the soonest deadline minus the clock" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {:ok, s, _} = Contracts.create(s, @payer, %{@attrs | duration: 10.0}, 0.0)
      assert Contracts.compute_next_tick_interval(s) == 10.0
    end

    test "returns to :never once the only contract is resolved" do
      {:ok, s, _} = Contracts.create(reg(), @payer, @attrs, 0.0)
      {:resolved, s, _} = Contracts.cancel(s, 1, @payer)
      assert Contracts.compute_next_tick_interval(s) == :never
    end
  end
end
