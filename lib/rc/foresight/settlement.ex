defmodule RC.Foresight.Settlement do
  @moduledoc """
  Pure settlement math for Foresight match predictions (docs/foresight.md).

  No database access — `plan/2` takes a snapshot of a match's predictions
  plus the match facts and returns the full settlement plan that
  `RC.Foresight.settle/2` applies in one transaction.

  All reward arithmetic is integer-exact: earliness weights are carried as
  numerator/denominator pairs over millisecond durations, so results never
  depend on float representation. Every fractional reward rounds UP —
  player-favoring by design; the economy is deliberately a little
  inflationary and seasonal resets are the pressure valve.
  """

  # -- Tunables (documented in the constants table of docs/foresight.md) --

  @starting_tokens 100
  @courtesy_limit 5
  @min_players 3
  # Earliness boost in percent of the base weight: a commit at match start
  # weighs (100 + boost)/100 = 2.0, a commit at the decision weighs 1.0.
  @time_boost_pct 100
  # Crowd's-lean multiplier cap (U).
  @contrarian_cap 5
  # Minted early-call bonus, percent of the live match pool.
  @bonus_rate_pct 5
  @max_points_per_prediction 500

  def starting_tokens, do: @starting_tokens
  def courtesy_limit, do: @courtesy_limit
  def min_players, do: @min_players

  @doc """
  Computes the settlement plan for one match.

  `predictions` is a list of maps with `:id`, `:account_id`, `:faction_id`,
  `:tokens`, `:credited_tokens` and `:inserted_at` (`DateTime`).

  `ctx` is a map with:

    * `:winning_faction_id` / `:winning_faction_ref` — nil when the match
      produced no winner (admin finish, deletion, …)
    * `:started_at` / `:decided_at` — `DateTime`s bounding the earliness
      window (first "running" transition, victories row insert)
    * `:human_players` — non-bot registration count at settlement
    * `:registered_factions` — `%{account_id => faction_id}` for accounts
      registered in the match (own-faction backstop)

  Returns `%{outcome, winning_faction_ref, entries, pool_tokens,
  tokens_recovered, points_minted}` where `entries` is one map per
  prediction: `%{id, account_id, status, tokens_recovered, bonus_tokens,
  points_awarded}`. `tokens_recovered` is the exact balance credit for that
  prediction (its own tokens are already included where due);
  `bonus_tokens` is credited on top, on the account's earliest qualifying
  prediction.
  """
  def plan(predictions, ctx) do
    result =
      cond do
        is_nil(ctx.winning_faction_id) ->
          void_all(predictions, "void_no_winner")

        ctx.human_players < @min_players ->
          void_all(predictions, "void_min_players")

        true ->
          {voided, live} = split_voided(predictions, ctx.registered_factions)
          backed = live |> Enum.map(& &1.faction_id) |> Enum.uniq()

          if length(backed) < 2 do
            void_all(predictions, "void_single_faction")
          else
            {winners, losers} = Enum.split_with(live, &(&1.faction_id == ctx.winning_faction_id))
            settle(winners, losers, voided, ctx)
          end
      end

    recovered = Enum.sum(for e <- result.entries, do: e.tokens_recovered + e.bonus_tokens)

    Map.merge(result, %{
      pool_tokens: Enum.sum(Enum.map(predictions, & &1.tokens)),
      tokens_recovered: recovered,
      points_minted: Enum.sum(Enum.map(result.entries, & &1.points_awarded))
    })
  end

  # Whole-match voids: every prediction returns its debited portion.
  defp void_all(predictions, outcome) do
    %{outcome: outcome, winning_faction_ref: nil, entries: Enum.map(predictions, &void_entry/1)}
  end

  # Individual-void backstops (the join-time refund hook is the primary
  # defense): predictions by accounts registered in a different faction
  # than they predicted, and — should a placement race ever slip past
  # rule 6 — accounts backing more than one faction lose all their
  # predictions in the match to a void (refund), keeping settlement
  # deterministic.
  defp split_voided(predictions, registered_factions) do
    hedgers =
      predictions
      |> Enum.group_by(& &1.account_id, & &1.faction_id)
      |> Enum.filter(fn {_aid, fids} -> length(Enum.uniq(fids)) > 1 end)
      |> MapSet.new(fn {aid, _fids} -> aid end)

    Enum.split_with(predictions, fn p ->
      MapSet.member?(hedgers, p.account_id) or
        (case Map.fetch(registered_factions, p.account_id) do
           {:ok, faction_id} -> faction_id != p.faction_id
           :error -> false
         end)
    end)
  end

  # Rule 9: the winning faction was unbacked — the crowd was wrong and
  # nobody recovers anything. Losers forfeit; individually-voided
  # predictions still refund.
  defp settle([], losers, voided, ctx) do
    %{
      outcome: "unbacked",
      winning_faction_ref: ctx.winning_faction_ref,
      entries: Enum.map(voided, &void_entry/1) ++ Enum.map(losers, &lost_entry/1)
    }
  end

  defp settle(winners, losers, voided, ctx) do
    tot = duration_ms(ctx)

    # Weight of prediction i is wn_i/wd with a shared denominator:
    #   wd   = tot * 100
    #   wn_i = wd + boost_pct * (tot - elapsed_i)
    # For pool shares wd cancels; for points it does not.
    {wd, weighted} =
      if tot > 0 do
        wd = tot * 100

        {wd,
         Enum.map(winners, fn p ->
           el = elapsed_ms(p, ctx.started_at, tot)
           %{p: p, el: el, wn: wd + @time_boost_pct * (tot - el)}
         end)}
      else
        # Degenerate window (should not happen in practice): everything
        # weighs 1 and nothing qualifies for the early-call bonus.
        {1, Enum.map(winners, fn p -> %{p: p, el: 1, wn: 1} end)}
      end

    s_win = Enum.sum(Enum.map(winners, & &1.tokens))
    pool = Enum.sum(Enum.map(losers, & &1.tokens))
    s_live = s_win + pool

    # Crowd's lean U = clamp(s_live / s_win, 1, cap) as a rational.
    {u_num, u_den} =
      if s_live >= @contrarian_cap * s_win, do: {@contrarian_cap, 1}, else: {s_live, s_win}

    total_weight = Enum.sum(Enum.map(weighted, fn %{p: p, wn: wn} -> p.tokens * wn end))

    winner_entries =
      weighted
      |> Enum.map(fn %{p: p, el: el, wn: wn} ->
        share = if pool > 0, do: ceil_div(pool * p.tokens * wn, total_weight), else: 0

        %{
          id: p.id,
          account_id: p.account_id,
          status: "correct",
          tokens_recovered: p.tokens + share,
          bonus_tokens: 0,
          points_awarded: min(@max_points_per_prediction, ceil_div(p.tokens * u_num * wn, u_den * wd)),
          el: el
        }
      end)
      |> apply_bonus(s_live, tot)
      |> Enum.map(&Map.delete(&1, :el))

    %{
      outcome: "settled",
      winning_faction_ref: ctx.winning_faction_ref,
      entries: winner_entries ++ Enum.map(losers, &lost_entry/1) ++ Enum.map(voided, &void_entry/1)
    }
  end

  # Early-call bonus: B = ceil(bonus_rate × live pool) minted tokens,
  # split in flat per-account shares — 1 for any correct prediction in
  # the first half of the match, +1 for any in the first quartile — and
  # credited on each account's earliest winning prediction. Correct
  # predictions only: paying early losers would make a 1-token early
  # commit on every match a farming strategy.
  defp apply_bonus(entries, _s_live, tot) when tot <= 0, do: entries

  defp apply_bonus(entries, s_live, tot) do
    by_account = Enum.group_by(entries, & &1.account_id)

    shares =
      by_account
      |> Enum.map(fn {aid, es} ->
        half = if Enum.any?(es, &(2 * &1.el <= tot)), do: 1, else: 0
        quartile = if Enum.any?(es, &(4 * &1.el <= tot)), do: 1, else: 0
        {aid, half + quartile}
      end)
      |> Enum.reject(fn {_aid, n} -> n == 0 end)
      |> Map.new()

    total_shares = shares |> Map.values() |> Enum.sum()

    if total_shares == 0 do
      entries
    else
      bonus_pool = ceil_div(s_live * @bonus_rate_pct, 100)
      earliest = Map.new(by_account, fn {aid, es} -> {aid, Enum.min_by(es, & &1.el).id} end)

      Enum.map(entries, fn e ->
        with {:ok, n} <- Map.fetch(shares, e.account_id),
             true <- earliest[e.account_id] == e.id do
          %{e | bonus_tokens: ceil_div(bonus_pool * n, total_shares)}
        else
          _ -> e
        end
      end)
    end
  end

  defp lost_entry(p) do
    %{id: p.id, account_id: p.account_id, status: "incorrect", tokens_recovered: 0, bonus_tokens: 0, points_awarded: 0}
  end

  defp void_entry(p) do
    # Only the debited portion returns; a courtesy-minted portion
    # dissolves (rule 8 — otherwise the courtesy allowance could be
    # farmed through matches likely to void).
    %{
      id: p.id,
      account_id: p.account_id,
      status: "void",
      tokens_recovered: p.tokens - p.credited_tokens,
      bonus_tokens: 0,
      points_awarded: 0
    }
  end

  defp duration_ms(%{started_at: %DateTime{} = t0, decided_at: %DateTime{} = t1}),
    do: max(DateTime.diff(t1, t0, :millisecond), 0)

  defp duration_ms(_ctx), do: 0

  defp elapsed_ms(p, t0, tot) do
    p.inserted_at
    |> DateTime.diff(t0, :millisecond)
    |> min(tot)
    |> max(0)
  end

  defp ceil_div(a, b) when b > 0, do: div(a + b - 1, b)
end
