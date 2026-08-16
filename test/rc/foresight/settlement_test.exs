defmodule RC.Foresight.SettlementTest do
  use ExUnit.Case, async: true

  alias RC.Foresight.Settlement

  # An "18-day" match compressed to 18 hours — all math is proportional
  # to the elapsed fraction, so units are irrelevant.
  @t0 ~U[2026-01-01 00:00:00.000000Z]

  defp t(day), do: DateTime.add(@t0, day * 3600, :second)

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        winning_faction_id: 1,
        winning_faction_ref: "tetrarchy",
        started_at: @t0,
        decided_at: t(18),
        human_players: 4,
        registered_factions: %{}
      },
      overrides
    )
  end

  defp pred(id, account_id, faction_id, tokens, day, credited \\ 0) do
    %{
      id: id,
      account_id: account_id,
      faction_id: faction_id,
      tokens: tokens,
      credited_tokens: credited,
      inserted_at: t(day)
    }
  end

  defp entry(plan, id), do: Enum.find(plan.entries, &(&1.id == id))

  describe "the motivating example (docs/foresight.md worked example)" do
    test "early conviction beats late caution in share, points and bonus" do
      # Tetrarchy (faction 1): Alice 30 FT on day 2, Bob 20 FT on day 12.
      # Myrmezir (faction 2): Carol 200 FT. Tetrarchy wins on day 18.
      plan =
        Settlement.plan(
          [pred(:alice, 10, 1, 30, 2), pred(:bob, 11, 1, 20, 12), pred(:carol, 12, 2, 200, 1)],
          ctx()
        )

      assert plan.outcome == "settled"
      assert plan.winning_faction_ref == "tetrarchy"

      alice = entry(plan, :alice)
      # 30 back + 136 of the 200-FT pool; day 2 of 18 is inside the first
      # quartile -> both bonus shares, and she's the only qualifier:
      # B = ceil(5% x 250) = 13.
      assert alice.status == "correct"
      assert alice.tokens_recovered == 30 + 136
      assert alice.bonus_tokens == 13
      # ceil(30 x 5 x (34/18)) = 284
      assert alice.points_awarded == 284

      bob = entry(plan, :bob)
      assert bob.tokens_recovered == 20 + 64
      # day 12 of 18 is past the halfway line: no bonus share
      assert bob.bonus_tokens == 0
      # ceil(20 x 5 x (24/18)) = 134
      assert bob.points_awarded == 134

      carol = entry(plan, :carol)
      assert carol.status == "incorrect"
      assert carol.tokens_recovered == 0
      assert carol.points_awarded == 0

      assert plan.pool_tokens == 250
      assert plan.tokens_recovered == 166 + 13 + 84
      assert plan.points_minted == 284 + 134
    end
  end

  describe "crowd's lean (U)" do
    test "backing the favorite pays modestly" do
      # Cardan 200 (one mid-match prediction), Ediya 50. U = 250/200.
      plan =
        Settlement.plan(
          [pred(:fav, 1, 1, 20, 9), pred(:fav2, 2, 1, 180, 9), pred(:dog, 3, 2, 50, 9)],
          ctx()
        )

      # ceil(20 x (250/200) x 1.5) = ceil(37.5) = 38
      assert entry(plan, :fav).points_awarded == 38
    end

    test "U is capped" do
      # 1 FT against 999 FT: uncapped U would be 1000.
      plan = Settlement.plan([pred(:a, 1, 1, 10, 18), pred(:b, 2, 2, 990, 18)], ctx())
      # weight 1.0 at the decision, U capped at 5 -> exactly 50
      assert entry(plan, :a).points_awarded == 50
    end

    test "points are capped per prediction" do
      plan = Settlement.plan([pred(:a, 1, 1, 100, 0), pred(:b, 2, 2, 900, 0)], ctx())
      # uncapped: ceil(100 x 5 x 2) = 1000 -> capped at 500
      assert entry(plan, :a).points_awarded == 500
    end
  end

  describe "rounding" do
    test "every share rounds up" do
      # Pool of 10 split across three equal same-time winners: exact
      # share is 3.33 -> everyone gets 4.
      plan =
        Settlement.plan(
          [pred(:a, 1, 1, 5, 9), pred(:b, 2, 1, 5, 9), pred(:c, 3, 1, 5, 9), pred(:l, 4, 2, 10, 9)],
          ctx()
        )

      for id <- [:a, :b, :c] do
        assert entry(plan, id).tokens_recovered == 5 + 4
      end
    end

    test "bonus shares round up for every account (Brett's split)" do
      # Three correct accounts inside the first half, one of them (Brett)
      # also inside the first quartile -> 4 shares. Pool 100 -> B = 5.
      # Brett: ceil(5 x 2/4) = 3, the others ceil(5 x 1/4) = 2 each.
      plan =
        Settlement.plan(
          [
            pred(:brett, 1, 1, 10, 2),
            pred(:oona, 2, 1, 10, 8),
            pred(:pia, 3, 1, 10, 7),
            pred(:l, 4, 2, 70, 1)
          ],
          ctx()
        )

      assert entry(plan, :brett).bonus_tokens == 3
      assert entry(plan, :oona).bonus_tokens == 2
      assert entry(plan, :pia).bonus_tokens == 2
    end
  end

  describe "early-call bonus" do
    test "no qualifying winners -> no bonus minted" do
      plan = Settlement.plan([pred(:a, 1, 1, 10, 15), pred(:b, 2, 2, 10, 15)], ctx())
      assert entry(plan, :a).bonus_tokens == 0
    end

    test "one account, several predictions: one share set, credited on the earliest" do
      plan =
        Settlement.plan(
          [pred(:early, 1, 1, 5, 1), pred(:late, 1, 1, 50, 16), pred(:l, 2, 2, 45, 1)],
          ctx()
        )

      # day 1 of 18 -> quartile + half = 2 shares, sole qualifier
      # s_live = 100 -> B = 5 -> all of it on the earliest prediction
      assert entry(plan, :early).bonus_tokens == 5
      assert entry(plan, :late).bonus_tokens == 0
      # both predictions still settle independently
      assert entry(plan, :early).status == "correct"
      assert entry(plan, :late).status == "correct"
    end

    test "losers never receive bonus shares" do
      plan =
        Settlement.plan(
          [pred(:w, 1, 1, 10, 17), pred(:l_early, 2, 2, 10, 1)],
          ctx()
        )

      assert entry(plan, :l_early).status == "incorrect"
      assert entry(plan, :l_early).bonus_tokens == 0
      # and the sole (late) winner has no share either -> nothing minted
      assert entry(plan, :w).bonus_tokens == 0
    end
  end

  describe "whole-match voids" do
    test "no winner -> void_no_winner refunds the debited portion only" do
      plan =
        Settlement.plan(
          [pred(:a, 1, 1, 10, 2), pred(:courtesy, 2, 2, 5, 2, 3)],
          ctx(%{winning_faction_id: nil, winning_faction_ref: nil})
        )

      assert plan.outcome == "void_no_winner"
      assert entry(plan, :a).status == "void"
      assert entry(plan, :a).tokens_recovered == 10
      # 5 committed, 3 courtesy-minted -> only the 2 debited come back
      assert entry(plan, :courtesy).tokens_recovered == 2
      assert plan.points_minted == 0
    end

    test "fewer than three human players -> void_min_players" do
      plan = Settlement.plan([pred(:a, 1, 1, 10, 2), pred(:b, 2, 2, 10, 2)], ctx(%{human_players: 2}))
      assert plan.outcome == "void_min_players"
    end

    test "all live predictions on one faction -> void_single_faction" do
      plan = Settlement.plan([pred(:a, 1, 1, 10, 2), pred(:b, 2, 1, 30, 5)], ctx())
      assert plan.outcome == "void_single_faction"
      assert entry(plan, :a).tokens_recovered == 10
      assert entry(plan, :b).tokens_recovered == 30
    end

    test "no predictions at all is a clean no-op void" do
      plan = Settlement.plan([], ctx())
      assert plan.entries == []
      assert plan.pool_tokens == 0
    end
  end

  describe "unbacked winner (rule 9)" do
    test "nobody recovers anything" do
      plan =
        Settlement.plan(
          [pred(:a, 1, 2, 50, 2), pred(:b, 2, 3, 100, 3)],
          ctx(%{winning_faction_id: 1})
        )

      assert plan.outcome == "unbacked"
      assert plan.winning_faction_ref == "tetrarchy"
      assert entry(plan, :a).status == "incorrect"
      assert entry(plan, :a).tokens_recovered == 0
      assert entry(plan, :b).tokens_recovered == 0
      assert plan.tokens_recovered == 0
    end
  end

  describe "individual-void backstops" do
    test "registered in a different faction than predicted -> that prediction voids" do
      plan =
        Settlement.plan(
          [pred(:traitor, 1, 1, 40, 2), pred(:w, 2, 1, 10, 2), pred(:l, 3, 2, 50, 2)],
          # account 1 is registered with faction 2 but predicted faction 1
          ctx(%{registered_factions: %{1 => 2}})
        )

      assert plan.outcome == "settled"
      traitor = entry(plan, :traitor)
      assert traitor.status == "void"
      assert traitor.tokens_recovered == 40
      assert traitor.points_awarded == 0
      # the voided tokens are excluded from the pool: winner gets the
      # 50-FT pool, not 90, and U uses the live totals (60/10 -> capped 5)
      assert entry(plan, :w).tokens_recovered == 10 + 50
    end

    test "own-faction predictions from registered players settle normally" do
      plan =
        Settlement.plan(
          [pred(:loyal, 1, 1, 10, 2), pred(:l, 2, 2, 50, 2)],
          ctx(%{registered_factions: %{1 => 1, 2 => 2}})
        )

      assert entry(plan, :loyal).status == "correct"
    end

    test "an account backing two factions loses all its predictions to a void" do
      plan =
        Settlement.plan(
          [pred(:h1, 1, 1, 10, 2), pred(:h2, 1, 2, 10, 2), pred(:w, 2, 1, 10, 2), pred(:l, 3, 2, 30, 2)],
          ctx()
        )

      assert entry(plan, :h1).status == "void"
      assert entry(plan, :h2).status == "void"
      assert entry(plan, :w).status == "correct"
    end

    test "voiding can collapse the match to a single backed faction" do
      plan =
        Settlement.plan(
          [pred(:traitor, 1, 2, 40, 2), pred(:w, 2, 1, 10, 2)],
          # the only faction-2 backer is registered with faction 1
          ctx(%{registered_factions: %{1 => 1}})
        )

      assert plan.outcome == "void_single_faction"
      assert entry(plan, :w).status == "void"
    end
  end

  describe "timing edges" do
    test "a commit stamped before the start clamps to maximum earliness" do
      plan = Settlement.plan([pred(:a, 1, 1, 10, -3), pred(:l, 2, 2, 10, 9)], ctx())
      # weight 2.0, U = 2: ceil(10 x 2 x 2) = 40
      assert entry(plan, :a).points_awarded == 40
    end

    test "a degenerate zero-length window neither crashes nor mints a bonus" do
      plan =
        Settlement.plan(
          [pred(:a, 1, 1, 10, 0), pred(:l, 2, 2, 10, 0)],
          ctx(%{decided_at: @t0})
        )

      assert plan.outcome == "settled"
      # weight 1, U = 2 -> 20 points, no bonus
      assert entry(plan, :a).points_awarded == 20
      assert entry(plan, :a).bonus_tokens == 0
      assert entry(plan, :a).tokens_recovered == 10 + 10
    end
  end
end
