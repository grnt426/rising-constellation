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
  * TITHE SETTLEMENT: when a seat is won, every pledger of that ballot
    pays what they offered — their pledged ideology income is deducted
    for 72h (`government_lockout_duration`) and the total is
    redistributed evenly to all members for the same period. The tithe
    IS the tax; pledge stakes are snapshotted at cast time from the
    pledger's ideology income rate.
  * LOSS OF FAITH: any member may open a pledge against a sitting seat;
    it needs no deadline vote — the moment the standing pledges reach
    10% of the faction's ideology income, the holder falls (instant
    trigger). An unfilled pledge quietly expires after 72h and arms the
    deposition cooldown.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Core.CooldownValue
  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @loss_of_faith_pct 10

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
  def after_close(government, %{question: :depose} = ballot, result, ctx),
    do: Rules.settle_deposition(government, ballot, result, ctx)

  def after_close(government, ballot, {:winner, winner, _totals}, ctx) do
    {government, seat_events} =
      Government.fill_seat(government, ballot.seat, winner,
        keep_other_seats: Government.relaxed?(ctx)
      )

    {government, tithe_events} = settle_tithe(government, ballot, ctx)
    {government, seat_events ++ tithe_events}
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

  # "The offering was made": every pledger of the winning ballot pays
  # their snapshot pledge for 72h; the pot redistributes evenly to the
  # ACTIVE members (pledgers included — mildly progressive by design,
  # see the doc's self-dealing note). Recipients are snapshotted at
  # settlement, same as the debits: a member who wakes up mid-window
  # wasn't in the divisor and doesn't collect (user rule 2026-07-07 —
  # inactive players never soak faction money).
  defp settle_tithe(government, ballot, ctx) do
    debits =
      for {voter_id, vote} <- ballot.votes,
          (Map.get(vote, :stake) || 0) > 0,
          into: %{},
          do: {voter_id, vote.stake}

    total = debits |> Map.values() |> Enum.sum()
    recipients = ctx.active_player_ids.()

    if total <= 0 or recipients == [] do
      {government, []}
    else
      tithe = %{
        debits: debits,
        recipients: recipients,
        credit_per_member: total / length(recipients),
        cooldown: CooldownValue.new(ctx.constants.government_lockout_duration)
      }

      government = Government.add_tithe(government, tithe)

      {government,
       [%{type: :tithe_settled, seat: ballot.seat, total: total, pledgers: map_size(debits)}, %{type: :sync_effects}]}
    end
  end

  # Loss of faith: a standing pledge against the incumbent with an
  # INSTANT trigger at 10% of faction ideology income. The candidate
  # list is the incumbent alone — pledging "against" is pledging on
  # them — and the 72h window bounds a pledge that never fills.
  @impl true
  def deposition_ballot(government, seat, ctx) do
    target = Map.get(government.seats, seat)

    %{
      kind: :stake_pledge,
      seat: seat,
      # Own quorum group: a simultaneous pledge against another seat
      # must not pool its offering with this one.
      group: "depose-#{seat}",
      question: :depose,
      candidates: [target],
      open_candidacy: nil,
      duration: ctx.constants.government_lockout_duration,
      quorum: %{kind: :ideology_income_pct, pct: @loss_of_faith_pct},
      meta: %{target: target, instant: true}
    }
  end

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
