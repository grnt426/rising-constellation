defmodule Instance.Faction.Government.Rules.Cardan do
  @moduledoc """
  Cardan — Theocracy.

  * Members nominate *someone else* to each position, then secretly
    pledge a share of their own ideology income as vote strength.
  * The whole election (all three seats together) fails unless the sum
    of every pledge reaches `government_cardan_quorum_pct` percent of
    the faction's total ideology income. Members only ever see a
    boolean "the offering suffices / is wanting" — never the numbers.
  * A failed vote immediately re-runs at half duration (floored at
    `government_election_min_duration`), up to
    `government_cardan_max_rounds` rounds; after that the seats stay
    vacant until a member calls a by-election.

  Deferred to the economy phase: the 72h tithe settlement (pledged
  income deducted from pledgers and redistributed evenly) and the
  loss-of-faith vote. Pledge stakes are snapshotted at cast time from
  the pledger's ideology income rate.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @impl true
  def initial_ballots(ctx) do
    seat_ballots(Rules.seats(), "round-1", 1, ctx.constants.government_election_duration, ctx)
  end

  # A by-election gets its own quorum group so it never accidentally
  # pools with an unrelated seat's vote that happens to close the same
  # tick.
  @impl true
  def by_election_ballots(seat, ctx) do
    seat_ballots([seat], "by-#{seat}", 1, ctx.constants.government_election_duration, ctx)
  end

  @impl true
  def after_close(government, ballot, {:winner, winner, _totals}, _ctx) do
    # TODO(phase-2 economy): tithe settlement — deduct each pledger's
    # offered income for 72h and redistribute the total evenly across
    # the faction. Requires the player income-modifier hook.
    Government.fill_seat(government, ballot.seat, winner)
  end

  def after_close(government, ballot, {:failed, :quorum_not_met, _totals}, ctx) do
    round = Map.get(ballot.meta, :round, 1)

    if round >= ctx.constants.government_cardan_max_rounds do
      {government,
       [%{type: :election_failed, seat: ballot.seat, reason: :quorum_rounds_exhausted}]}
    else
      duration =
        max(
          Map.get(ballot.meta, :duration, ctx.constants.government_election_duration) / 2,
          ctx.constants.government_election_min_duration
        )

      # Each failed seat re-opens into the same deterministic group id
      # ("round-N"), so the three seats keep closing together and the
      # quorum stays election-wide. Nominations reset — the faithful
      # must put names forward again.
      {government, events} =
        Government.open_ballots(
          government,
          seat_ballots([ballot.seat], "round-#{round + 1}", round + 1, duration, ctx)
        )

      {government, [%{type: :revote_opened, seat: ballot.seat, round: round + 1} | events]}
    end
  end

  def after_close(government, ballot, {:failed, reason, _totals}, _ctx),
    do: {government, [%{type: :election_failed, seat: ballot.seat, reason: reason}]}

  def after_close(government, _ballot, _result, _ctx), do: {government, []}

  @impl true
  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :elected_seats}

  @impl true
  def term_spec(_ctx), do: nil

  @impl true
  def on_term_expired(government, _ctx), do: {government, []}

  defp seat_ballots(seats, group, round, duration, ctx) do
    Enum.map(seats, fn seat ->
      %{
        kind: :stake_pledge,
        seat: seat,
        group: group,
        candidates: [],
        open_candidacy: :others_only,
        duration: duration,
        quorum: %{
          kind: :ideology_income_pct,
          pct: ctx.constants.government_cardan_quorum_pct
        },
        meta: %{round: round, duration: duration}
      }
    end)
  end
end
