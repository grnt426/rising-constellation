defmodule Daily.EntryTest do
  use RC.DataCase

  # Keep-best semantics of Daily.record_score/6 with tiebreaks, and the
  # tiebreak-aware ranking — the leaderboard contract for scoring shapes
  # (docs/daily-challenge-ideas.md).

  @date "2099-01-01"

  defp profile! do
    n = System.unique_integer([:positive])

    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "daily-entry-#{n}@test.local",
        password: "daily-entry-test-#{n}",
        name: "DailyEntry#{n}",
        role: :user,
        status: :active
      })

    {:ok, profile} =
      RC.Accounts.create_profile(%{account_id: account.id, name: "DailyP#{n}", avatar: "todo"})

    profile
  end

  test "keep-best is lexicographic on (score, tiebreak)" do
    p = profile!()

    assert {:ok, %Daily.Entry{}} = Daily.record_score(p.id, @date, :the_triumvirate, 10.0, 5.0, 1)

    # a lower score never replaces, no matter the tiebreak
    assert {:ok, :kept_best} = Daily.record_score(p.id, @date, :the_triumvirate, 9.0, 99.0, 2)

    # same score, higher tiebreak replaces
    assert {:ok, %Daily.Entry{tiebreak: 7.0}} =
             Daily.record_score(p.id, @date, :the_triumvirate, 10.0, 7.0, 3)

    # same score, lower tiebreak keeps
    assert {:ok, :kept_best} = Daily.record_score(p.id, @date, :the_triumvirate, 10.0, 6.0, 4)

    # higher score replaces regardless of tiebreak
    assert {:ok, %Daily.Entry{score: 11.0, tiebreak: 0.0}} =
             Daily.record_score(p.id, @date, :the_triumvirate, 11.0, 0.0, 5)
  end

  test "the 5-arity form still works (tiebreak defaults to 0.0)" do
    p = profile!()
    assert {:ok, %Daily.Entry{tiebreak: 0.0}} = Daily.record_score(p.id, @date, :golden_flow, 3.0, 6)
  end

  test "leaderboard and player_rank break ties on tiebreak" do
    [a, b, c] = [profile!(), profile!(), profile!()]

    {:ok, _} = Daily.record_score(a.id, @date, :golden_flow, 10.0, 1.0, 1)
    {:ok, _} = Daily.record_score(b.id, @date, :golden_flow, 10.0, 3.0, 2)
    {:ok, _} = Daily.record_score(c.id, @date, :golden_flow, 12.0, 0.0, 3)

    board = Daily.leaderboard(@date)
    assert Enum.map(board, & &1.name) == [c.name, b.name, a.name]
    assert Enum.map(board, & &1.rank) == [1, 2, 3]

    assert %{rank: 1} = Daily.player_rank(c.id, @date)
    assert %{rank: 2} = Daily.player_rank(b.id, @date)
    assert %{rank: 3} = Daily.player_rank(a.id, @date)
  end
end
