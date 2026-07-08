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
  * No scheduled renewal — a throne holds until WEALTH unseats it: the
    BID-TO-CHALLENGE, Option B sealed match (docs/faction-government.md
    §3). A non-sitting member stakes ≥0.5% of the faction's total
    credit. The sitting oligarchs then have 24h
    (`government_approval_duration`) to collectively match it 1:1 from
    personal funds — the treasury may contribute, once per
    `government_lockout_duration`. Matched: the government stands, the
    challenger forfeits 10% of the stake to the treasury and sits out a
    72h lockout. Unmatched at the deadline: the government FALLS — every
    seat vacates, matchers forfeit 20% of what they put up, all three
    auctions re-open, and the challenger's stake seeds the Executive
    auction at 1.5× vote strength (refunds/pools settle on the REAL
    stake, so nothing is minted).

  Escrow: the agent debits credit at bid/stake time (atomic
  `{:try_debit_send, …}` on the payer's Player.Agent) *before* the
  engine records it; refunds are emitted as `:refund` events the agent
  settles with async `{:add_resources, …}` casts.
  """

  @behaviour Instance.Faction.Government.Rules

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Ballot
  alias Instance.Faction.Government.Rules

  @lockouts_key :ark_challenge_lockouts
  @gov_funds_key :ark_gov_funds_cooldown
  @challenge_min_pct 0.5
  @defended_penalty 0.10
  @overthrown_penalty 0.20
  @seed_multiplier 1.5

  @impl true
  def initial_ballots(ctx), do: Enum.map(Rules.seats(), &seat_ballot(&1, ctx))

  @impl true
  def by_election_ballots(seat, ctx), do: [seat_ballot(seat, ctx)]

  @impl true
  def after_close(government, ballot, result, ctx) do
    case result do
      {:winner, winner, _totals} ->
        {refunds, winner_pool} = settle_escrow(ballot, winner.player_id)

        {government, events} =
          Government.fill_seat(government, ballot.seat, winner,
            keep_other_seats: Government.relaxed?(ctx)
          )

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

  # ----------------------------------------------------------------
  # Bid-to-challenge (Option B sealed match)
  # ----------------------------------------------------------------

  # The stake is already escrowed by the agent; every guard failure here
  # bounces it straight back (agent refund contract).
  @impl true
  def challenge(government, actor_id, stake, ctx) do
    lockouts = Government.get_meta(government, @lockouts_key, %{})
    minimum = ctx.faction_credit_total.() * @challenge_min_pct / 100

    cond do
      Map.get(government, :challenge) != nil ->
        {:error, :challenge_already_open}

      Government.seat_holder?(government, actor_id) ->
        {:error, :already_seated}

      Enum.all?(Rules.seats(), &(Map.get(government.seats, &1) == nil)) ->
        {:error, :seat_vacant}

      Map.get(lockouts, actor_id, 0) > 0 ->
        {:error, :challenge_lockout}

      not is_number(stake) or stake < minimum ->
        {:error, :stake_below_minimum}

      true ->
        challenger = Rules.roster_candidate(ctx.players, actor_id)

        challenge = %{
          challenger_id: actor_id,
          challenger_name: challenger && challenger.name,
          stake: stake,
          matched: [],
          treasury_matched: 0,
          remaining: ctx.constants.government_approval_duration
        }

        government = %{government | challenge: challenge}

        {:ok, government,
         [
           %{
             type: :challenge_started,
             challenger_id: actor_id,
             name: challenge.challenger_name,
             stake: stake
           }
         ]}
    end
  end

  # A sitting oligarch answers. Personal contributions arrive escrowed;
  # a treasury contribution is drawn here (no escrow) and is allowed
  # once per government_lockout_duration.
  @impl true
  def challenge_match(government, actor_id, amount, use_treasury, ctx) do
    challenge = Map.get(government, :challenge)

    cond do
      challenge == nil ->
        {:error, :no_challenge}

      not Government.seat_holder?(government, actor_id) ->
        {:error, :not_seated}

      not is_number(amount) or amount <= 0 ->
        {:error, :invalid_payload}

      use_treasury and Government.get_meta(government, @gov_funds_key, 0) > 0 ->
        {:error, :treasury_funds_on_cooldown}

      use_treasury and Map.get(government.treasury, :credit, 0) < amount ->
        {:error, :treasury_insufficient}

      true ->
        {government, challenge} =
          if use_treasury do
            government = %{
              government
              | treasury: Map.update!(government.treasury, :credit, &(&1 - amount))
            }

            government =
              Government.put_meta(
                government,
                @gov_funds_key,
                ctx.constants.government_lockout_duration
              )

            {government, %{challenge | treasury_matched: challenge.treasury_matched + amount}}
          else
            {government, %{challenge | matched: add_contribution(challenge.matched, actor_id, amount)}}
          end

        matched_total =
          challenge.treasury_matched + Enum.reduce(challenge.matched, 0, &(&1.amount + &2))

        matched_event = %{
          type: :challenge_matched,
          by: actor_id,
          amount: amount,
          treasury: use_treasury,
          total: matched_total,
          stake: challenge.stake
        }

        if matched_total >= challenge.stake do
          {government, events} = resolve_defended(government, challenge, ctx)
          {:ok, government, [matched_event | events]}
        else
          government = %{government | challenge: challenge}
          {:ok, government, [matched_event]}
        end
    end
  end

  defp add_contribution(matched, player_id, amount) do
    case Enum.split_with(matched, &(&1.player_id == player_id)) do
      {[], rest} -> rest ++ [%{player_id: player_id, amount: amount}]
      {[entry], rest} -> rest ++ [%{entry | amount: entry.amount + amount}]
    end
  end

  # Countdown + lockout bookkeeping. An unanswered challenge at the
  # deadline topples the government.
  @impl true
  def tick(government, elapsed_time, ctx) do
    government = tick_meta_cooldowns(government, elapsed_time)

    case Map.get(government, :challenge) do
      nil ->
        {government, []}

      challenge ->
        remaining = challenge.remaining - elapsed_time

        if remaining > 0 do
          {%{government | challenge: %{challenge | remaining: remaining}}, []}
        else
          resolve_overthrown(government, challenge, ctx)
        end
    end
  end

  defp tick_meta_cooldowns(government, elapsed_time) do
    lockouts =
      government
      |> Government.get_meta(@lockouts_key, %{})
      |> Enum.map(fn {player_id, remaining} -> {player_id, remaining - elapsed_time} end)
      |> Enum.filter(fn {_player_id, remaining} -> remaining > 0 end)
      |> Map.new()

    gov_funds = max(Government.get_meta(government, @gov_funds_key, 0) - elapsed_time, 0)

    government
    |> Government.put_meta(@lockouts_key, lockouts)
    |> Government.put_meta(@gov_funds_key, gov_funds)
  end

  # Matched 1:1 within the window: the government stands. Matchers get
  # their money back in full (treasury share returns to the treasury);
  # the challenger forfeits 10% to the treasury and sits out a lockout.
  defp resolve_defended(government, challenge, ctx) do
    penalty = trunc(challenge.stake * @defended_penalty)

    refunds =
      [%{type: :refund, player_id: challenge.challenger_id, credit: challenge.stake - penalty}] ++
        Enum.map(challenge.matched, fn %{player_id: player_id, amount: amount} ->
          %{type: :refund, player_id: player_id, credit: amount}
        end)

    government =
      %{government | challenge: nil}
      |> Government.deposit_treasury(:credit, penalty + challenge.treasury_matched)
      |> Government.put_meta(
        @lockouts_key,
        government
        |> Government.get_meta(@lockouts_key, %{})
        |> Map.put(challenge.challenger_id, ctx.constants.government_lockout_duration)
      )

    {government,
     [
       %{
         type: :challenge_defended,
         challenger_id: challenge.challenger_id,
         name: challenge.challenger_name,
         stake: challenge.stake,
         penalty: penalty
       }
     ] ++ refunds}
  end

  # Unmatched: the government falls. Every seat vacates, matchers eat
  # 20% of what they risked, fresh auctions open — with the challenger's
  # stake pre-cast on themselves for the Executive chair at 1.5× vote
  # strength (settlement uses the REAL stake; no credit is minted).
  defp resolve_overthrown(government, challenge, ctx) do
    {government, vacate_events} =
      Enum.reduce(Rules.seats(), {government, []}, fn seat, {government, events} ->
        {government, seat_events} = Government.vacate_seat(government, seat)
        {government, events ++ seat_events}
      end)

    refunds =
      Enum.map(challenge.matched, fn %{player_id: player_id, amount: amount} ->
        %{type: :refund, player_id: player_id, credit: amount - trunc(amount * @overthrown_penalty)}
      end)

    matcher_penalties =
      challenge.matched
      |> Enum.map(fn %{amount: amount} -> trunc(amount * @overthrown_penalty) end)
      |> Enum.sum()

    government =
      %{government | challenge: nil}
      |> Government.deposit_treasury(:credit, matcher_penalties + challenge.treasury_matched)

    {government, open_events} = Government.open_ballots(government, initial_ballots(ctx))
    government = seed_leader_bid(government, challenge, ctx)

    overthrown = %{
      type: :government_overthrown,
      challenger_id: challenge.challenger_id,
      name: challenge.challenger_name,
      stake: challenge.stake
    }

    {government,
     [overthrown] ++
       vacate_events ++
       [%{type: :elections_opened, seats: Rules.seats(), renewal: true}] ++
       open_events ++ refunds}
  end

  # "The challenger seeds the new election with 1.5× their bid as vote
  # strength" — pre-cast on the freshly opened Executive auction. The
  # vote carries :real_stake so escrow settlement pays out (or banks)
  # what was actually staked.
  defp seed_leader_bid(government, challenge, ctx) do
    with %Ballot{} = ballot <-
           Enum.find(government.ballots, &(&1.seat == :leader and Ballot.expired?(&1) == false)),
         %{} = candidate <- Rules.roster_candidate(ctx.players, challenge.challenger_id) do
      seeded = %{
        choice: challenge.challenger_id,
        stake: challenge.stake * @seed_multiplier,
        real_stake: challenge.stake
      }

      with {:ok, ballot} <- Ballot.add_candidate(ballot, candidate),
           {:ok, ballot} <- Ballot.cast_vote(ballot, challenge.challenger_id, seeded) do
        put_ballot(government, ballot)
      else
        _ -> government
      end
    else
      _ -> government
    end
  end

  defp put_ballot(government, ballot) do
    ballots =
      Enum.map(government.ballots, fn existing ->
        if existing.id == ballot.id, do: ballot, else: existing
      end)

    %{government | ballots: ballots}
  end

  # Bids on the winner fund the treasury; every other bid is refunded.
  # `real_stake` (challenge seeding) overrides the displayed stake for
  # settlement in both directions.
  defp settle_escrow(ballot, winner_id) do
    Enum.reduce(ballot.votes, {[], 0}, fn {voter_id, vote}, {refunds, pool} ->
      stake = Map.get(vote, :real_stake) || Map.get(vote, :stake, 0)

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
