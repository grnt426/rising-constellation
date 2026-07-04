defmodule Instance.Faction.Government.Rules.Ark do
  @moduledoc """
  ARK — Oligarchy.

  * EVERY seat is auctioned — Executive, Board of Commerce, Industrial
    Arms Overseer alike. Members escrow credit bids on their preferred
    candidate per seat (bidding on someone *is* nominating them, self
    included). Highest per-candidate sum wins; running totals are
    public — it's an auction, not a ballot box. No appointments: in an
    oligarchy every chair is bought, not gifted.
  * Each seat's winning pool goes to the Faction Treasury; every bid on
    a losing candidate is refunded in full.
  * No scheduled renewal. (The bid-to-challenge protocol is a later
    phase; a throne holds until wealth unseats it.)

  Escrow: the agent debits credit at bid time (atomic
  `{:try_debit_send, …}` on the bidder's Player.Agent) *before* the
  engine records the stake; refunds are emitted as `:refund` events the
  agent settles with async `{:add_resources, …}` casts.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Rules

  @impl true
  def initial_ballots(ctx), do: Enum.map(Rules.seats(), &seat_ballot(&1, ctx))

  @impl true
  def by_election_ballots(seat, ctx), do: [seat_ballot(seat, ctx)]

  @impl true
  def after_close(government, ballot, result, _ctx) do
    case result do
      {:winner, winner, _totals} ->
        {refunds, winner_pool} = settle_escrow(ballot, winner.player_id)

        {government, events} = Government.fill_seat(government, ballot.seat, winner)
        government = Government.deposit_treasury(government, :credit, winner_pool)

        {government, events ++ refunds}

      {:failed, reason, _totals} ->
        # Nobody bid (or no candidates): whatever trickled in is returned.
        {refunds, _} = settle_escrow(ballot, nil)
        {government, [%{type: :election_failed, seat: ballot.seat, reason: reason} | refunds]}

      _other ->
        {government, []}
    end
  end

  @impl true
  def appoint(_government, _actor_id, _seat, _appointee, _ctx), do: {:error, :elected_seats}

  @impl true
  def term_spec(_ctx), do: nil

  @impl true
  def on_term_expired(government, _ctx), do: {government, []}

  # Bids on the winner fund the treasury; every other bid is refunded.
  defp settle_escrow(ballot, winner_id) do
    Enum.reduce(ballot.votes, {[], 0}, fn {voter_id, vote}, {refunds, pool} ->
      stake = Map.get(vote, :stake, 0)

      cond do
        stake <= 0 -> {refunds, pool}
        vote.choice == winner_id -> {refunds, pool + stake}
        true -> {[%{type: :refund, player_id: voter_id, credit: stake} | refunds], pool}
      end
    end)
  end

  defp seat_ballot(seat, ctx) do
    %{
      kind: :stake_bid,
      seat: seat,
      candidates: [],
      open_candidacy: :by_stake,
      duration: ctx.constants.government_election_duration
    }
  end
end
