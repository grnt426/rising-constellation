defmodule Instance.Faction.GovernmentCardsTest do
  @moduledoc """
  The player-facing timeline card consolidation
  (`Instance.Faction.Agent.consolidate_failed_round/1`): a grouped
  election that fails re-opens every seat on the same tick, which would
  otherwise emit one "vote concluded" + one "re-vote" card PER SEAT.
  These assert the six-cards-into-one collapse while the per-seat audit
  events survive for the audit log and Discord relay.
  """
  use ExUnit.Case, async: true

  alias Instance.Faction.Agent

  defp closed(seat, outcome, winner \\ nil),
    do: %{type: :ballot_closed, ballot_id: 1, seat: seat, question: :elect, outcome: outcome, winner: winner}

  defp revote(seat, round), do: %{type: :revote_opened, seat: seat, round: round}
  defp failed(seat, reason), do: %{type: :election_failed, seat: seat, reason: reason}

  describe "consolidate_failed_round/1" do
    test "a failed multi-seat round collapses to one re-vote card" do
      events = [
        closed(:leader, :quorum_not_met),
        revote(:leader, 2),
        closed(:economy, :quorum_not_met),
        revote(:economy, 2),
        closed(:military, :quorum_not_met),
        revote(:military, 2)
      ]

      {out, cards} = Agent.consolidate_failed_round(events)

      # every ballot_closed and revote survives (audit rows + Discord),
      # but each is flagged so its individual player card is suppressed
      assert length(out) == 6
      assert Enum.all?(out, &Map.get(&1, :_suppress_card, false))

      assert [{"election_revote", data}] = cards
      assert data.round == 2
      assert Enum.sort(data.seats) == [:economy, :leader, :military]
    end

    test "re-vote round number is the highest seen in the batch" do
      events = [
        closed(:leader, :quorum_not_met),
        revote(:leader, 5)
      ]

      {_out, [{"election_revote", data}]} = Agent.consolidate_failed_round(events)
      assert data.round == 5
    end

    test "an exhausted election collapses to one abandoned card" do
      events = [
        closed(:leader, :quorum_not_met),
        failed(:leader, :quorum_rounds_exhausted),
        closed(:economy, :quorum_not_met),
        failed(:economy, :quorum_rounds_exhausted),
        closed(:military, :quorum_not_met),
        failed(:military, :quorum_rounds_exhausted)
      ]

      {out, cards} = Agent.consolidate_failed_round(events)

      assert Enum.all?(Enum.filter(out, &(&1.type == :ballot_closed)), &Map.get(&1, :_suppress_card, false))
      assert [{"election_abandoned", data}] = cards
      assert Enum.sort(data.seats) == [:economy, :leader, :military]
    end

    test "a seated winner is never collapsed" do
      winner = %{player_id: 7, name: "Aria"}
      events = [closed(:leader, :seated, winner)]

      assert {^events, []} = Agent.consolidate_failed_round(events)
    end

    test "a lone failure with no re-vote or exhaustion passes through untouched" do
      # e.g. a Synelle rejection or an ARK auction with no bids: it keeps
      # its own single card, nothing to consolidate.
      events = [closed(:leader, :quorum_not_met)]
      assert {^events, []} = Agent.consolidate_failed_round(events)
    end
  end
end
