defmodule Instance.Contracts.ContractTest do
  # Pure unit coverage for the Agent Contract state machine: the resolution matrix
  # (every payer×performer combination, including the silent/nil expiry defaults),
  # the fee math, and each lifecycle transition with its guards. No GenServer, no
  # Data.Querier — the module under test is deliberately pure.
  use ExUnit.Case, async: true

  alias Instance.Contracts.Contract

  @payer 100
  @performer 200
  @stranger 999

  @valid_attrs %{
    action_category: :spy,
    action_type: :assassination,
    target_system_id: 42,
    target_character_id: 7,
    note: "kill the governor of BAKA",
    bounty: 1000,
    duration: 30.0,
    max_claimant_strikes: 3
  }

  defp listed(attrs \\ %{}) do
    {:ok, c} = Contract.new(1, @payer, Map.merge(@valid_attrs, attrs), 0.0)
    c
  end

  defp active(payer_strikes \\ 0, performer_strikes \\ 0) do
    {:ok, c} = Contract.claim(listed(), @performer, payer_strikes, performer_strikes, 0.0)
    c
  end

  defp with_closures(c, payer_closure, performer_closure) do
    %{c | payer_closure: payer_closure, performer_closure: performer_closure}
  end

  describe "outcome/2 (resolution matrix)" do
    # {payer_closure, performer_closure, expected outcome}. nil == "silent at expiry".
    @matrix [
      {:pay, :claim, :paid},
      {:pay, :withdraw, :paid},
      {:pay, :dispute, :disputed},
      {:pay, nil, :paid},
      {:terminate, :claim, :refunded},
      {:terminate, :withdraw, :refunded},
      {:terminate, :dispute, :disputed},
      {:terminate, nil, :refunded},
      {:dispute, :claim, :disputed},
      {:dispute, :withdraw, :disputed},
      {:dispute, :dispute, :disputed},
      {:dispute, nil, :disputed},
      {nil, :claim, :paid},
      {nil, :withdraw, :refunded},
      {nil, :dispute, :disputed},
      {nil, nil, :refunded}
    ]

    for {payer, performer, expected} <- @matrix do
      test "payer=#{inspect(payer)} performer=#{inspect(performer)} -> #{expected}" do
        assert Contract.outcome(unquote(payer), unquote(performer)) == unquote(expected)
      end
    end
  end

  describe "compute_fees/3" do
    test "no strikes -> base 5% listing + 5% closing, 90% payout" do
      assert %{listing_fee: 50, closing_fee: 50, total: 100, payout: 900} =
               Contract.compute_fees(1000, 0, 0)
    end

    test "scales with the SUM of both parties' strikes" do
      # combined 5 -> 0.05 + 5*0.03 = 0.20 each
      assert %{listing_fee: 200, closing_fee: 200, total: 400, payout: 600} =
               Contract.compute_fees(1000, 2, 3)
    end

    test "each component caps at 40%, leaving a 20% payout floor (no hard ban)" do
      # combined 20 -> 0.65 uncapped, clamped to 0.40 each
      assert %{listing_fee: 400, closing_fee: 400, total: 800, payout: 200} =
               Contract.compute_fees(1000, 10, 10)
    end

    test "payout is always strictly positive even at extreme strike counts" do
      %{payout: payout} = Contract.compute_fees(1000, 100, 100)
      assert payout > 0
    end
  end

  describe "new/4" do
    test "builds a listed contract with deadline = created_at + duration" do
      {:ok, c} = Contract.new(1, @payer, @valid_attrs, 10.0)

      assert c.id == 1
      assert c.payer_id == @payer
      assert c.performer_id == nil
      assert c.status == :listed
      assert c.bounty == 1000
      assert c.action_category == :spy
      assert c.created_at == 10.0
      assert c.deadline == 40.0
      assert c.listing_fee == nil
    end

    test "rejects a non-positive bounty" do
      assert {:error, :invalid_bounty} = Contract.new(1, @payer, %{@valid_attrs | bounty: 0}, 0.0)
      assert {:error, :invalid_bounty} = Contract.new(1, @payer, %{@valid_attrs | bounty: -5}, 0.0)
    end

    test "rejects an unknown action category" do
      assert {:error, :invalid_category} =
               Contract.new(1, @payer, %{@valid_attrs | action_category: :wizard}, 0.0)
    end

    test "rejects a non-positive duration" do
      assert {:error, :invalid_duration} =
               Contract.new(1, @payer, %{@valid_attrs | duration: 0}, 0.0)
    end

    test "rejects a negative max_claimant_strikes" do
      assert {:error, :invalid_max_claimant_strikes} =
               Contract.new(1, @payer, %{@valid_attrs | max_claimant_strikes: -1}, 0.0)
    end
  end

  describe "claim/5" do
    test "activates, locks the fee snapshot, and resets the deadline" do
      {:ok, c} = Contract.claim(listed(), @performer, 1, 2, 100.0)

      assert c.status == :active
      assert c.performer_id == @performer
      # combined 3 -> 0.14 each
      assert c.listing_fee == 140
      assert c.closing_fee == 140
      assert c.payer_strikes_at_claim == 1
      assert c.performer_strikes_at_claim == 2
      # deadline reset to now + duration, NOT created_at + duration
      assert c.deadline == 130.0
    end

    test "cannot claim your own contract" do
      assert {:error, :cannot_claim_own_contract} =
               Contract.claim(listed(), @payer, 0, 0, 0.0)
    end

    test "rejects a claimant over the issuer's strike cap" do
      assert {:error, :too_many_strikes} =
               Contract.claim(listed(%{max_claimant_strikes: 3}), @performer, 0, 4, 0.0)
    end

    test "claimant exactly at the strike cap is allowed" do
      assert {:ok, %Contract{status: :active}} =
               Contract.claim(listed(%{max_claimant_strikes: 3}), @performer, 0, 3, 0.0)
    end

    test "cannot claim a contract that is not listed" do
      assert {:error, :not_listed} = Contract.claim(active(), @stranger, 0, 0, 0.0)
    end
  end

  describe "submit_closure/3" do
    test "payer may submit pay/terminate/dispute" do
      for intent <- [:pay, :terminate, :dispute] do
        assert {:ok, %Contract{payer_closure: ^intent}} =
                 Contract.submit_closure(active(), @payer, intent)
      end
    end

    test "performer may submit claim/withdraw/dispute" do
      for intent <- [:claim, :withdraw, :dispute] do
        assert {:ok, %Contract{performer_closure: ^intent}} =
                 Contract.submit_closure(active(), @performer, intent)
      end
    end

    test "a party submitting the other role's intent is rejected" do
      assert {:error, :invalid_closure_for_role} =
               Contract.submit_closure(active(), @payer, :claim)

      assert {:error, :invalid_closure_for_role} =
               Contract.submit_closure(active(), @performer, :pay)
    end

    test "a non-party cannot submit a closure" do
      assert {:error, :not_a_party} = Contract.submit_closure(active(), @stranger, :pay)
    end

    test "cannot submit a closure on a contract that is not active" do
      assert {:error, :not_active} = Contract.submit_closure(listed(), @payer, :pay)
    end
  end

  describe "withdraw_closure/2" do
    test "clears the payer's intent" do
      {:ok, c} = Contract.submit_closure(active(), @payer, :pay)
      assert {:ok, %Contract{payer_closure: nil}} = Contract.withdraw_closure(c, @payer)
    end

    test "clears the performer's intent" do
      {:ok, c} = Contract.submit_closure(active(), @performer, :claim)
      assert {:ok, %Contract{performer_closure: nil}} = Contract.withdraw_closure(c, @performer)
    end

    test "a non-party cannot withdraw" do
      assert {:error, :not_a_party} = Contract.withdraw_closure(active(), @stranger)
    end
  end

  describe "cancel/2" do
    test "issuer cancels a listed contract -> refund of the full bounty" do
      assert {:ok, %{outcome: :refunded, refund: 1000, payout: 0, strike: 0, contract: c}} =
               Contract.cancel(listed(), @payer)

      assert c.status == :refunded
    end

    test "non-issuer cannot cancel" do
      assert {:error, :not_a_party} = Contract.cancel(listed(), @stranger)
    end

    test "cannot cancel once active" do
      assert {:error, :not_listed} = Contract.cancel(active(), @payer)
    end
  end

  describe "resolve/1" do
    test "listed (unclaimed/expired) -> full refund, no penalty" do
      assert {:ok, %{outcome: :refunded, refund: 1000, payout: 0, strike: 0}} =
               Contract.resolve(listed())
    end

    test "paid -> payout is bounty minus the locked fees" do
      c = active(0, 0) |> with_closures(:pay, :claim)

      assert {:ok, %{outcome: :paid, payout: 900, refund: 0, strike: 0, contract: done}} =
               Contract.resolve(c)

      assert done.status == :paid
    end

    test "refunded -> full bounty back, no strike" do
      c = active() |> with_closures(:terminate, :claim)

      assert {:ok, %{outcome: :refunded, refund: 1000, payout: 0, strike: 0, contract: done}} =
               Contract.resolve(c)

      assert done.status == :refunded
    end

    test "disputed -> full refund to payer plus a strike for both parties" do
      c = active() |> with_closures(:dispute, :claim)

      assert {:ok, %{outcome: :disputed, refund: 1000, payout: 0, strike: 1, contract: done}} =
               Contract.resolve(c)

      assert done.status == :disputed
    end

    test "silent payer against a claim still pays out (Option A)" do
      c = active(0, 0) |> with_closures(nil, :claim)
      assert {:ok, %{outcome: :paid, payout: 900}} = Contract.resolve(c)
    end

    test "an already-resolved contract cannot be resolved again" do
      done = %{active() | status: :paid}
      assert {:error, :already_resolved} = Contract.resolve(done)
    end
  end

  describe "predicates" do
    test "ready_to_resolve?/1 is true only when both closures are present" do
      refute Contract.ready_to_resolve?(active())
      refute Contract.ready_to_resolve?(active() |> with_closures(:pay, nil))
      refute Contract.ready_to_resolve?(active() |> with_closures(nil, :claim))
      assert Contract.ready_to_resolve?(active() |> with_closures(:pay, :claim))
      refute Contract.ready_to_resolve?(listed())
    end

    test "expired?/2 compares against the deadline for open contracts only" do
      # active() has deadline 30.0 (claimed at now=0, duration 30)
      assert Contract.expired?(active(), 30.0)
      assert Contract.expired?(active(), 31.0)
      refute Contract.expired?(active(), 29.0)
      # terminal contracts never count as expired
      refute Contract.expired?(%{active() | status: :paid}, 9_999.0)
    end

    test "terminal?/1" do
      refute Contract.terminal?(listed())
      refute Contract.terminal?(active())
      assert Contract.terminal?(%{active() | status: :disputed})
    end

    test "party?/2" do
      c = active()
      assert Contract.party?(c, @payer)
      assert Contract.party?(c, @performer)
      refute Contract.party?(c, @stranger)
    end
  end

  describe "parse_attrs/1, validate_attrs/1, parse_closure_intent/1" do
    test "parses a string-keyed client payload into atom-keyed attrs" do
      params = %{
        "action_category" => "spy",
        "action_type" => "assassination",
        "target_system_id" => 42,
        "bounty" => 250_000,
        "duration" => 30,
        "max_claimant_strikes" => 3,
        "note" => "kill the governor"
      }

      assert {:ok, attrs} = Contract.parse_attrs(params)
      assert attrs.action_category == :spy
      assert attrs.action_type == "assassination"
      assert attrs.bounty == 250_000
      assert attrs.duration == 30.0
      assert attrs.max_claimant_strikes == 3
      # the parsed attrs build a valid contract
      assert {:ok, _c} = Contract.new(1, 100, attrs, 0.0)
    end

    test "rejects an unknown category without creating an atom" do
      params = %{"action_category" => "wizard", "bounty" => 1, "duration" => 1, "max_claimant_strikes" => 0}
      assert {:error, :invalid_category} = Contract.parse_attrs(params)
    end

    test "validate_attrs mirrors new/4 validation" do
      assert :ok = Contract.validate_attrs(@valid_attrs)
      assert {:error, :invalid_bounty} = Contract.validate_attrs(%{@valid_attrs | bounty: 0})
    end

    test "parse_closure_intent maps known strings and rejects junk" do
      assert Contract.parse_closure_intent("pay") == :pay
      assert Contract.parse_closure_intent("claim") == :claim
      assert Contract.parse_closure_intent(:dispute) == :dispute
      assert Contract.parse_closure_intent("garbage") == :invalid
    end
  end
end
