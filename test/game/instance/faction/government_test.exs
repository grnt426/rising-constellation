defmodule Instance.Faction.GovernmentTest do
  use ExUnit.Case, async: true

  alias Instance.Faction.Government
  alias Instance.Faction.Government.Ballot

  @moduledoc """
  Engine-level tests: the Government module and the five faction rule
  modules, driven directly through `Government.advance/3` with a stubbed
  ctx (no instance boot, no DB — the Tetrarchy scoreboard read is
  rescue-guarded and degrades to roster order here, which the weighted
  test exploits by injecting weights through cast payloads instead).
  """

  @founding 10
  @election 10
  @min_election 5
  @law_cooldown 10
  @lockout 30
  @test_instance_id 999_999_999

  # The treasury ops resolve FactionPatent / FactionLex nodes through
  # Data.Querier, so the fake instance needs real content inserted once.
  setup_all do
    Data.Data.insert(@test_instance_id, speed: :fast, mode: :prod)
    on_exit(fn -> Data.Data.clear(@test_instance_id) end)
    :ok
  end

  defp players(0), do: []

  defp players(count) do
    Enum.map(1..count, fn i ->
      %Instance.Faction.Player{id: i, name: "Player #{i}"}
    end)
  end

  defp ctx(faction_key, players, opts \\ []) do
    %{
      instance_id: @test_instance_id,
      faction_id: 1,
      faction_key: faction_key,
      players: players,
      constants: %{
        government_founding_duration: @founding,
        government_election_duration: @election,
        government_election_min_duration: @min_election,
        government_approval_duration: @election,
        government_term_myrmezir: 100,
        government_term_synelle: 160,
        government_cardan_quorum_pct: 5,
        government_cardan_max_rounds: 3,
        government_tax_cap: 10,
        government_max_laws: 2,
        government_law_cooldown: @law_cooldown,
        government_lockout_duration: @lockout,
        market_taxe: 0.1
      },
      faction_ideology_income: Keyword.get(opts, :income, fn -> 100 end),
      faction_credit_total: Keyword.get(opts, :credit_total, fn -> 100_000 end),
      active_player_ids: Keyword.get(opts, :active_ids, fn -> Enum.map(players, & &1.id) end),
      active_player_count: Keyword.get(opts, :active, fn -> length(players) end),
      seat_holder_status: Keyword.get(opts, :holder_status, fn _player_id -> :ok end)
    }
  end

  defp founded(faction_key, players, opts \\ []) do
    ctx = ctx(faction_key, players, opts)
    government = Government.new(ctx)
    {government, events} = Government.advance(government, @founding, ctx)
    {government, events, ctx}
  end

  defp close_open_ballots(government, ctx),
    do: Government.advance(government, @election, ctx)

  describe "founding" do
    test "opens the faction's initial ballots when the countdown ends" do
      {government, events, _ctx} = founded(:myrmezir, players(6))

      assert government.phase == :running
      assert length(government.ballots) == 3
      assert Enum.map(government.ballots, & &1.seat) == [:leader, :economy, :military]
      assert Enum.all?(government.ballots, &(&1.open_candidacy == :self_only))
      assert Enum.any?(events, &(&1.type == :elections_opened))
    end

    test "does nothing before the countdown ends" do
      ctx = ctx(:myrmezir, players(4))
      government = Government.new(ctx)
      {government, events} = Government.advance(government, @founding - 1, ctx)

      assert government.phase == :founding
      assert government.ballots == []
      assert events == []
    end

    test "tetrarchy opens one weighted leader ballot capped at 5 candidates" do
      {government, _events, _ctx} = founded(:tetrarchy, players(8))

      assert [%Ballot{seat: :leader, kind: :plurality} = ballot] = government.ballots
      assert length(ballot.candidates) == 5
      # 8 players → thirds of size ceil(8/3)=3: weights 3,3,3 / 2,2,2 / 1,1
      assert ballot.weights |> Map.values() |> Enum.sort() == [1, 1, 2, 2, 2, 3, 3, 3]
    end

    test "cardan opens a grouped, quorum-carrying pledge election" do
      {government, _events, _ctx} = founded(:cardan, players(5))

      assert length(government.ballots) == 3
      assert Enum.all?(government.ballots, &(&1.kind == :stake_pledge))
      assert Enum.all?(government.ballots, &(&1.group == "round-1"))
      assert Enum.all?(government.ballots, &(&1.quorum.pct == 5))
    end

    test "ark auctions every seat — no chair is gifted" do
      {government, _events, _ctx} = founded(:ark, players(5))

      assert length(government.ballots) == 3
      assert Enum.map(government.ballots, & &1.seat) == [:leader, :economy, :military]
      assert Enum.all?(government.ballots, &(&1.kind == :stake_bid))
      assert Enum.all?(government.ballots, &(&1.open_candidacy == :by_stake))
    end
  end

  describe "plurality elections" do
    test "most votes wins the seat; results are aggregate-only" do
      {government, _events, ctx} = founded(:synelle, players(4))
      [%{id: ballot_id}] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)
      {:ok, government, _} = Government.nominate(government, 3, ballot_id, 3, ctx)

      {:ok, government, _} = Government.cast_vote(government, 1, ballot_id, %{candidate_id: 2}, ctx)
      {:ok, government, _} = Government.cast_vote(government, 3, ballot_id, %{candidate_id: 2}, ctx)
      {:ok, government, _} = Government.cast_vote(government, 4, ballot_id, %{candidate_id: 3}, ctx)

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 2
      assert Enum.any?(events, &(&1.type == :seat_changed and &1.player_id == 2))

      [entry] = government.history
      assert entry.outcome == :seated
      assert Enum.find(entry.totals, &(&1.player_id == 2)).amount == 2
      refute Map.has_key?(entry, :votes)
    end

    test "zero votes leaves the seat vacant" do
      {government, _events, ctx} = founded(:synelle, players(3))
      [%{id: ballot_id}] = government.ballots
      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader == nil
      assert Enum.any?(events, &(&1.type == :election_failed and &1.reason == :no_votes))
    end

    test "weighted votes count with their snapshot weight" do
      {government, _events, ctx} = founded(:tetrarchy, players(6))
      [%{id: ballot_id, weights: weights} = ballot] = government.ballots

      # Roster order = scoreboard order here (no stats): player 1 has
      # weight 3, players 5..6 weight 1.
      assert weights[1] == 3
      [c1, c2 | _] = ballot.candidates

      {:ok, government, _} =
        Government.cast_vote(government, 1, ballot_id, %{candidate_id: c1.player_id}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 5, ballot_id, %{candidate_id: c2.player_id}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 6, ballot_id, %{candidate_id: c2.player_id}, ctx)

      {government, _events} = close_open_ballots(government, ctx)

      # 3 (one first-third voter) beats 1+1 (two last-third voters).
      assert government.seats.leader.player_id == c1.player_id
    end
  end

  describe "myrmezir candidacy" do
    test "self-nomination only, and only for one seat of the cycle" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      [leader_ballot, economy_ballot | _] = government.ballots

      assert {:error, :self_nomination_only} =
               Government.nominate(government, 1, leader_ballot.id, 2, ctx)

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot.id, 1, ctx)

      assert {:error, :already_running} =
               Government.nominate(government, 1, economy_ballot.id, 1, ctx)
    end

    test "term expiry reopens all three seats with sitting acting heads" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      [%{id: leader_ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot_id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot_id, %{candidate_id: 1}, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1
      assert government.ballots == []

      # Advance to term expiry (term = 100, already elapsed 10 closing).
      {government, events} = Government.advance(government, 90, ctx)

      assert length(government.ballots) == 3
      assert Enum.any?(events, &(&1.type == :elections_opened and &1.renewal))
      # acting head keeps the seat while the renewal runs
      assert government.seats.leader.player_id == 1
    end
  end

  describe "synelle appointments" do
    defp synelle_with_leader(player_count) do
      {government, _events, ctx} = founded(:synelle, players(player_count))
      [%{id: ballot_id}] = government.ballots
      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 1, ctx)
      {:ok, government, _} = Government.cast_vote(government, 2, ballot_id, %{candidate_id: 1}, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1
      {government, ctx}
    end

    test "leader nominates; half the active membership approving seats the appointee" do
      {government, ctx} = synelle_with_leader(4)

      assert {:error, :not_leader} = Government.appoint(government, 2, :economy, 3, ctx)

      {:ok, government, _events} = Government.appoint(government, 1, :economy, 3, ctx)
      [%{id: approval_id, kind: :approval, question: :approve}] = government.ballots

      # 4 active members → 2 approvals required
      {:ok, government, _} =
        Government.cast_vote(government, 2, approval_id, %{choice: :approve}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 4, approval_id, %{choice: :approve}, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.economy.player_id == 3
    end

    test "a vote-cast majority below half the membership still rejects (silence counts)" do
      {government, ctx} = synelle_with_leader(4)

      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      [%{id: approval_id}] = government.ballots

      # one approve, nobody else votes: majority of votes cast, but only
      # 1/4 of the membership — rejected
      {:ok, government, _} = Government.cast_vote(government, 2, approval_id, %{choice: :approve}, ctx)

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.economy == nil
      assert Enum.any?(events, &(&1.type == :appointment_rejected and &1.failed_rounds == 1))
    end

    # Nominating BOTH cabinet seats keeps the nomination window disarmed,
    # so these two tests exercise the pure rejection-strike path.
    defp nominate_both(government, ctx) do
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      {:ok, government, _} = Government.appoint(government, 1, :military, 4, ctx)
      government
    end

    test "three rejection strikes dissolve the government and reopen the leader election" do
      {government, ctx} = synelle_with_leader(4)

      # Round 1: both nominations ignored → two strikes, leadership holds.
      government = nominate_both(government, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader != nil
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 2

      # Round 2: the third rejection is insolvency — the leader abdicates
      # mid-batch and a fresh election opens.
      government = nominate_both(government, ctx)
      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :government_dissolved))
      assert government.seats.leader == nil
      assert [%Ballot{seat: :leader, question: :elect}] = government.ballots
    end

    test "a successful approval resets the strike counter" do
      {government, ctx} = synelle_with_leader(4)

      # two failures (both nominations ignored)
      government = nominate_both(government, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 2

      # then successes: approvals seat the cabinet and clear the slate
      government = nominate_both(government, ctx)

      government =
        Enum.reduce(government.ballots, government, fn %{id: ballot_id}, government ->
          {:ok, government, _} = Government.cast_vote(government, 1, ballot_id, %{choice: :approve}, ctx)
          {:ok, government, _} = Government.cast_vote(government, 2, ballot_id, %{choice: :approve}, ctx)
          government
        end)

      {government, _} = close_open_ballots(government, ctx)

      assert government.seats.economy.player_id == 3
      assert government.seats.military.player_id == 4
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 0
    end

    test "an ignored nomination window strikes twice and fails the leadership in two windows" do
      {government, ctx} = synelle_with_leader(4)

      # Window 1 expires with both cabinet seats un-nominated: two strikes.
      {government, events} = Government.advance(government, @election, ctx)
      assert Enum.any?(events, &(&1.type == :nomination_window_expired))
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 2
      assert government.seats.leader != nil

      # Window 2 crosses the three-strike bar: dissolved within "48h".
      {government, events} = Government.advance(government, @election, ctx)
      assert Enum.any?(events, &(&1.type == :government_dissolved))
      assert government.seats.leader == nil
      assert [%Ballot{seat: :leader, question: :elect}] = government.ballots
    end

    test "leader term expiry vacates the seat and reopens the election" do
      {government, ctx} = synelle_with_leader(4)

      {government, events} = Government.advance(government, 150, ctx)

      assert government.seats.leader == nil
      assert [%Ballot{seat: :leader, kind: :plurality}] = government.ballots
      assert Enum.any?(events, &(&1.type == :elections_opened and &1.renewal))
    end
  end

  describe "cardan pledges and quorum" do
    test "cannot nominate yourself" do
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      assert {:error, :cannot_nominate_self} =
               Government.nominate(government, 1, ballot_id, 1, ctx)
    end

    test "quorum failure fails every seat and reopens at half duration" do
      # Faction income 100/ut, quorum 5% → 5.0 needed across the group.
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)

      {:ok, government, _} =
        Government.cast_vote(
          government,
          1,
          ballot_id,
          %{candidate_id: 2, pct: 10, stake: 2.0},
          ctx
        )

      # 2.0 pledged of 5.0 required → stage 1 (a faint glow)
      ballot = Enum.find(government.ballots, &(&1.id == ballot_id))
      assert ballot.public.quorum_stage == 1

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader == nil
      assert Enum.count(events, &(&1.type == :revote_opened)) == 3
      assert length(government.ballots) == 3
      assert Enum.all?(government.ballots, &(&1.group == "round-2"))
      assert Enum.all?(government.ballots, &(&1.cooldown.initial == @election / 2))
    end

    test "revote duration floors at the minimum" do
      {government, _events, ctx} = founded(:cardan, players(4))

      # rounds 1 and 2 fail with no pledges → round 3 would be 2.5 but
      # floors at 5
      {government, _} = close_open_ballots(government, ctx)
      {government, _} = Government.advance(government, @election / 2, ctx)

      assert Enum.all?(government.ballots, &(&1.group == "round-3"))
      assert Enum.all?(government.ballots, &(&1.cooldown.initial == @min_election))
    end

    test "after max rounds the seats stay vacant for by-election" do
      {government, _events, ctx} = founded(:cardan, players(4))

      {government, _} = close_open_ballots(government, ctx)
      {government, _} = Government.advance(government, @election / 2, ctx)
      {government, events} = Government.advance(government, @min_election, ctx)

      assert government.ballots == []
      assert Enum.count(events, &(Map.get(&1, :reason) == :quorum_rounds_exhausted)) == 3

      # and a member can restart one seat
      {:ok, government, _} = Government.call_by_election(government, 1, :leader, ctx)
      assert [%Ballot{seat: :leader, group: "by-leader"}] = government.ballots
    end

    test "met quorum elects the largest pledge; totals stay hidden while open" do
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)
      {:ok, government, _} = Government.nominate(government, 2, ballot_id, 3, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 1, ballot_id, %{candidate_id: 2, pct: 40, stake: 4.0}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 4, ballot_id, %{candidate_id: 3, pct: 30, stake: 3.0}, ctx)

      ballot = Enum.find(government.ballots, &(&1.id == ballot_id))
      assert ballot.public.quorum_stage == 3
      assert ballot.public.totals == nil

      {government, _events} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 2
    end
  end

  describe "ark auction" do
    defp ark_ballot(government, seat),
      do: Enum.find(government.ballots, &(&1.seat == seat))

    test "bidding nominates, largest sum wins, treasury funded, losers refunded" do
      {government, _events, ctx} = founded(:ark, players(4))
      %{id: leader_id} = ark_ballot(government, :leader)

      {:ok, government, _} =
        Government.cast_vote(government, 1, leader_id, %{candidate_id: 1, stake: 500}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_id, %{candidate_id: 3, stake: 300}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 4, leader_id, %{candidate_id: 3, stake: 100}, ctx)

      # public auction: running totals visible while open
      ballot = Enum.find(government.ballots, &(&1.id == leader_id))
      totals = Map.new(ballot.public.totals, &{&1.player_id, &1.amount})
      assert totals == %{1 => 500, 3 => 400}

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 1
      assert government.treasury.credit == 500

      refunds = Enum.filter(events, &(&1.type == :refund))

      assert Enum.sort_by(refunds, & &1.player_id) |> Enum.map(&{&1.player_id, &1.credit}) ==
               [{2, 300}, {4, 100}]
    end

    test "every seat is bought separately; each winning pool funds the treasury" do
      {government, _events, ctx} = founded(:ark, players(4))

      {:ok, government, _} =
        Government.cast_vote(government, 1, ark_ballot(government, :leader).id, %{candidate_id: 1, stake: 500}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, ark_ballot(government, :economy).id, %{candidate_id: 2, stake: 200}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 3, ark_ballot(government, :military).id, %{candidate_id: 4, stake: 100}, ctx)

      {government, _events} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 1
      assert government.seats.economy.player_id == 2
      assert government.seats.military.player_id == 4
      assert government.treasury.credit == 800
    end

    test "appointments do not exist in an oligarchy" do
      {government, _events, ctx} = founded(:ark, players(4))

      {:ok, government, _} =
        Government.cast_vote(government, 2, ark_ballot(government, :leader).id, %{candidate_id: 1, stake: 50}, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1

      assert {:error, :elected_seats} = Government.appoint(government, 1, :military, 3, ctx)
    end

    test "winning two auctions at once keeps only the last seat (single-seat invariant)" do
      {government, _events, ctx} = founded(:ark, players(4))

      {:ok, government, _} =
        Government.cast_vote(government, 2, ark_ballot(government, :leader).id, %{candidate_id: 1, stake: 50}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 3, ark_ballot(government, :economy).id, %{candidate_id: 1, stake: 40}, ctx)

      {government, _} = close_open_ballots(government, ctx)

      # both pools were still banked; player 1 ends up in the later-
      # closing seat only
      assert government.treasury.credit == 90
      assert government.seats.leader == nil
      assert government.seats.economy.player_id == 1
    end
  end

  describe "seats and by-elections" do
    test "a player never holds two seats" do
      {government, ctx} = synelle_with_leader(4)

      # seat player 3 as economy via approval
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      [%{id: approval_id}] = government.ballots
      {:ok, government, _} = Government.cast_vote(government, 2, approval_id, %{choice: :approve}, ctx)
      {:ok, government, _} = Government.cast_vote(government, 4, approval_id, %{choice: :approve}, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.economy.player_id == 3

      # player 3 then wins the leader seat in a by-election: their old
      # seat is vacated
      {government, _} = Government.vacate_seat(government, :leader)
      {:ok, government, _} = Government.call_by_election(government, 2, :leader, ctx)
      [%{id: leader_ballot_id}] = government.ballots
      {:ok, government, _} = Government.nominate(government, 2, leader_ballot_id, 3, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot_id, %{candidate_id: 3}, ctx)

      {government, _} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 3
      assert government.seats.economy == nil
    end

    test "by-election guards: occupied seat, open ballot, appointed seats" do
      {government, _events, ctx} = founded(:tetrarchy, players(4))

      # leader ballot still open
      assert {:error, :ballot_already_open} =
               Government.call_by_election(government, 1, :leader, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader == nil

      # council seats are appointed in a monarchy — no by-election
      assert {:error, :not_available} =
               Government.call_by_election(government, 1, :economy, ctx)

      {:ok, government, _} = Government.call_by_election(government, 1, :leader, ctx)
      assert [%Ballot{seat: :leader}] = government.ballots
    end

    test "appointing an already-seated player is rejected" do
      {government, ctx} = synelle_with_leader(4)

      assert {:error, :already_seated} = Government.appoint(government, 1, :economy, 1, ctx)
    end
  end

  describe "empty faction (zero registered members)" do
    # A faction nobody joined still founds a government and runs its
    # elections; they fail cleanly and leave the seats vacant instead of
    # crashing the agent or wedging the engine.
    test "ark auctions open for all seats, close with no candidates, seats stay vacant" do
      {government, _events, ctx} = founded(:ark, players(0))

      assert length(government.ballots) == 3
      assert Enum.all?(government.ballots, &(&1.kind == :stake_bid))

      {government, events} = close_open_ballots(government, ctx)

      assert government.ballots == []
      assert government.seats == %{leader: nil, economy: nil, military: nil}
      assert Enum.count(events, &(&1.type == :election_failed and &1.reason == :no_candidates)) == 3
      assert government.treasury.credit == 0
    end

    test "tetrarchy weighted vote degrades to an empty candidate list" do
      {government, _events, ctx} = founded(:tetrarchy, players(0))

      assert [%Ballot{seat: :leader, candidates: []}] = government.ballots

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader == nil
      assert Enum.any?(events, &(&1.type == :election_failed and &1.reason == :no_candidates))
    end

    test "cardan quorum against zero faction income fails, revotes, and caps out" do
      {government, _events, ctx} = founded(:cardan, players(0), income: fn -> 0 end)

      # zero income means the >= threshold is trivially met with zero
      # pledges, so the failure mode is :no_candidates, not quorum spin
      {government, events} = close_open_ballots(government, ctx)

      assert government.ballots == []
      assert Enum.count(events, &(Map.get(&1, :reason) == :no_candidates)) == 3
    end
  end

  describe "treasury economy (taxes, research, laws)" do
    # A seated Tetrarchy: player 1 leads, player 2 heads the economy.
    defp seated_government(opts \\ []) do
      {government, _events, ctx} = founded(:tetrarchy, players(3), opts)
      {government, _} = close_open_ballots(government, ctx)
      {government, _} = Government.fill_seat(government, :leader, %{player_id: 1, name: "Player 1"})
      {government, _} = Government.fill_seat(government, :economy, %{player_id: 2, name: "Player 2"})
      {government, ctx}
    end

    test "tax rates: economy-seat only, engine-capped, audited" do
      {government, ctx} = seated_government()
      rates = %{credit: 8, technology: 5, ideology: 0}

      # player 3 holds no seat (the LEADER is no longer denied — royal
      # prerogative, see the overreach describe)
      assert {:error, :not_head_of_economy} = Government.set_tax_rates(government, 3, rates, ctx)

      assert {:error, :tax_above_cap} =
               Government.set_tax_rates(government, 2, %{rates | credit: 11}, ctx)

      assert {:error, :tax_above_cap} =
               Government.set_tax_rates(government, 2, %{rates | credit: -1}, ctx)

      {:ok, government, events} = Government.set_tax_rates(government, 2, rates, ctx)

      assert government.tax_rates == rates
      assert Enum.any?(events, &(&1.type == :taxes_changed and &1.by == 2))
    end

    test "patent purchases: seat, treasury, and ancestor rules" do
      {government, ctx} = seated_government()
      government = Government.deposit(government, %{technology: 2_000})

      assert {:error, :not_head_of_economy} =
               Government.purchase_patent(government, 3, :research_compact, ctx)

      assert {:error, :unknown_key} = Government.purchase_patent(government, 2, :warp_cannon, ctx)

      assert {:error, :ancestor_not_owned} =
               Government.purchase_patent(government, 2, :deep_space_relay, ctx)

      {:ok, government, events} = Government.purchase_patent(government, 2, :research_compact, ctx)

      assert government.faction_patents == [:research_compact]
      assert government.treasury.technology == 1_200
      assert Enum.any?(events, &(&1.type == :patent_purchased and &1.key == :research_compact))

      assert {:error, :already_owned} =
               Government.purchase_patent(government, 2, :research_compact, ctx)

      # 1_600 > 1_200 remaining
      assert {:error, :treasury_insufficient} =
               Government.purchase_patent(government, 2, :deep_space_relay, ctx)
    end

    test "lexes are bought by the leader and enacted into limited law slots" do
      {government, ctx} = seated_government()
      government = Government.deposit(government, %{ideology: 5_000})

      assert {:error, :not_leader} = Government.purchase_lex(government, 2, :assembly_charter, ctx)

      {:ok, government, _} = Government.purchase_lex(government, 1, :assembly_charter, ctx)
      {:ok, government, _} = Government.purchase_lex(government, 1, :civic_pride, ctx)
      {:ok, government, _} = Government.purchase_lex(government, 1, :mobilization_act, ctx)

      # purchased but NOT enacted: no effect yet
      assert Government.effects(government, ctx).bonuses == []

      assert {:error, :not_leader} = Government.update_laws(government, 2, [:civic_pride], ctx)

      assert {:error, :too_many_laws} =
               Government.update_laws(
                 government,
                 1,
                 [:assembly_charter, :civic_pride, :mobilization_act],
                 ctx
               )

      assert {:error, :lex_not_owned} = Government.update_laws(government, 1, [:war_footing], ctx)

      {:ok, government, events} =
        Government.update_laws(government, 1, [:civic_pride, :mobilization_act], ctx)

      assert government.active_laws == [:civic_pride, :mobilization_act]
      assert Enum.any?(events, &(&1.type == :laws_changed))

      # the change cooldown arms
      assert {:error, :laws_on_cooldown} =
               Government.update_laws(government, 1, [:assembly_charter], ctx)

      {government, _} = Government.advance(government, @law_cooldown, ctx)
      {:ok, government, _} = Government.update_laws(government, 1, [:assembly_charter], ctx)
      assert government.active_laws == [:assembly_charter]
    end

    test "effects payload carries patents + enacted laws + tax rates" do
      {government, ctx} = seated_government()

      government =
        Government.deposit(government, %{technology: 1_000, ideology: 2_000})

      {:ok, government, _} = Government.purchase_patent(government, 2, :research_compact, ctx)
      {:ok, government, _} = Government.purchase_lex(government, 1, :assembly_charter, ctx)
      {:ok, government, _} = Government.update_laws(government, 1, [:assembly_charter], ctx)
      {:ok, government, _} = Government.set_tax_rates(government, 2, %{credit: 6, technology: 0, ideology: 0}, ctx)

      effects = Government.effects(government, ctx)

      assert Enum.map(effects.bonuses, & &1.key) == [:research_compact, :assembly_charter]
      assert %Core.Bonus{to: :player_technology, value: 2} = hd(effects.bonuses).bonus
      assert effects.tax_rates.credit == 6
    end

    test "treasury distribution: economy-seat only, even floored shares, remainder stays" do
      {government, ctx} = seated_government()
      government = Government.deposit(government, %{credit: 1_000, technology: 100})

      assert {:error, :not_head_of_economy} =
               Government.distribute_treasury(government, 3, 50, ctx)

      assert {:error, :invalid_percent} = Government.distribute_treasury(government, 2, 0, ctx)
      assert {:error, :invalid_percent} = Government.distribute_treasury(government, 2, 101, ctx)

      # 50% of 1000 credit over 3 members → 166 each, 502 remains;
      # 50% of 100 tech → 16 each, 52 remains
      {:ok, government, events} = Government.distribute_treasury(government, 2, 50, ctx)

      assert government.treasury.credit == 1_000 - 166 * 3
      assert government.treasury.technology == 100 - 16 * 3

      grants = Enum.filter(events, &(&1.type == :grant))
      assert length(grants) == 3
      assert Enum.all?(grants, &(&1.credit == 166 and &1.technology == 16 and &1.ideology == 0))
      assert Enum.any?(events, &(&1.type == :treasury_distributed and &1.by == 2))
    end

    test "distributing an empty treasury is rejected" do
      {government, ctx} = seated_government()

      assert {:error, :nothing_to_distribute} =
               Government.distribute_treasury(government, 2, 50, ctx)
    end

    test "deposit ignores non-positive and non-numeric amounts" do
      {government, ctx} = seated_government()
      _ = ctx

      government =
        Government.deposit(government, %{credit: 100, technology: -5, ideology: "junk"})

      assert government.treasury == %{credit: 100, technology: 0, ideology: 0}
    end
  end

  describe "secrecy (serialization)" do
    test "broadcast JSON never contains votes, weights, or pledge totals" do
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 1, ballot_id, %{candidate_id: 2, pct: 50, stake: 4.9}, ctx)

      json = Jason.encode!(government)

      refute json =~ "\"votes\""
      refute json =~ "\"weights\""
      refute json =~ "\"stake\":"
      refute json =~ "4.9"
      # but the staged indicator and participation count are there
      # (4.9 of 5.0 required → stage 2, guttering — numbers stay hidden)
      assert json =~ "\"quorum_stage\":2"
      assert json =~ "\"vote_count\":1"
    end

    test "own_votes exposes exactly the viewer's entries" do
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 1, ballot_id, %{candidate_id: 2, pct: 50, stake: 4.9}, ctx)

      assert %{^ballot_id => %{choice: 2, pct: 50, stake: 4.9}} =
               Government.own_votes(government, 1)

      assert Government.own_votes(government, 3) == %{}
    end
  end

  describe "cheat fast-forward" do
    # Engine-level counterpart of the Faction.Agent cheat ops
    # (:cheat_gov_skip_founding / :cheat_gov_conclude_elections). Skip =
    # advance by the remaining founding time (opens elections, resolves
    # nothing). Conclude = Government.conclude_successful/2: seat only the
    # elections that would already succeed; failing ones keep running.

    test "skip founding: advancing by the remaining time opens elections without resolving them" do
      ctx = ctx(:myrmezir, players(4))
      government = Government.new(ctx)

      # part-way through founding, as the cheat would find it
      {government, _} = Government.advance(government, 3, ctx)
      assert government.phase == :founding

      {government, events} = Government.advance(government, government.founding.value + 1, ctx)

      assert government.phase == :running
      assert Enum.any?(events, &(&1.type == :elections_opened))
      # founding overflow is discarded: fresh ballots keep their full duration
      assert Enum.all?(government.ballots, &(&1.cooldown.value == @election))
    end

    test "advance(0) alone does not close open ballots" do
      {government, _events, ctx} = founded(:myrmezir, players(4))

      {government, events} = Government.advance(government, 0, ctx)

      assert length(government.ballots) == 3
      assert Enum.all?(government.ballots, &(&1.cooldown.value == @election))
      assert events == []
    end

    test "conclude seats a voted-in winner immediately, through the real close path" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      [%{id: leader_ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot_id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot_id, %{candidate_id: 1}, ctx)

      {government, events, concluded} = Government.conclude_successful(government, ctx)

      assert concluded == 1
      assert government.seats.leader.player_id == 1
      assert Enum.any?(events, &(&1.type == :ballot_closed and &1.outcome == :seated))
      # nothing else time-warped: the scheduled term renewal did not move
      assert government.term.value == 100
    end

    test "conclude leaves unvoted elections running — never force-fails them" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      before = government.ballots

      {government, events, concluded} = Government.conclude_successful(government, ctx)

      assert concluded == 0
      assert events == []
      assert government.ballots == before
      assert Enum.all?(government.ballots, &(&1.cooldown.value == @election))
      assert government.seats.leader == nil
    end

    test "conclude is per-seat: the voted leader seats while unvoted council races keep running" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      [%{id: leader_ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot_id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot_id, %{candidate_id: 1}, ctx)

      {government, _events, concluded} = Government.conclude_successful(government, ctx)

      assert concluded == 1
      assert government.seats.leader.player_id == 1
      assert Enum.map(government.ballots, & &1.seat) == [:economy, :military]
      assert Enum.all?(government.ballots, &(&1.cooldown.value == @election))
    end

    test "reopen restores a tetrarchy leader race after a no-vote failure left the seat vacant" do
      # Tetrarchy has no term cycle: a failed initial election is never
      # rescheduled by the engine — the flagship case for the cheat.
      {government, _events, ctx} = founded(:tetrarchy, players(4))

      {government, _} = Government.advance(government, @election, ctx)
      assert government.ballots == []
      assert government.seats.leader == nil

      {government, events, opened} = Government.reopen_elections(government, ctx)

      assert opened == 1
      assert [%Ballot{seat: :leader, kind: :plurality} = ballot] = government.ballots
      assert ballot.cooldown.value == @election
      assert Enum.any?(events, &(&1.type == :elections_opened and &1.renewal))
    end

    test "reopen mid-mandate is a snap re-election: incumbents stay seated while the race runs" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      [%{id: leader_ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot_id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot_id, %{candidate_id: 1}, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1
      assert government.ballots == []

      {government, _events, opened} = Government.reopen_elections(government, ctx)

      assert opened == 3
      assert Enum.map(government.ballots, & &1.seat) == [:leader, :economy, :military]
      # the sitting leader keeps the seat as acting head until replaced
      assert government.seats.leader.player_id == 1
    end

    test "reopen never duplicates a race that is already open" do
      {government, _events, ctx} = founded(:myrmezir, players(4))
      assert length(government.ballots) == 3

      {government, events, opened} = Government.reopen_elections(government, ctx)

      assert opened == 0
      assert events == []
      assert length(government.ballots) == 3
    end

    test "conclude respects cardan quorum groups: unmet quorum concludes nothing" do
      # income 100/ut, quorum 5% → 5.0 pledge needed across the group;
      # a single 4.9 pledge leaves the group short.
      {government, _events, ctx} = founded(:cardan, players(4))
      [%{id: ballot_id} | _] = government.ballots

      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 2, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 1, ballot_id, %{candidate_id: 2, pct: 50, stake: 4.9}, ctx)

      {government, events, concluded} = Government.conclude_successful(government, ctx)

      assert concluded == 0
      assert events == []
      assert length(government.ballots) == 3
    end
  end

  describe "tick integration" do
    test "faction state without a government passes through unchanged" do
      state = %{government: nil}
      {change, new_state} = Government.tick({MapSet.new(), state}, 5)

      assert change == MapSet.new()
      assert new_state == state
    end
  end

  # ------------------------------------------------------------------
  # Mid-term accountability (user decisions 2026-07-07)
  # ------------------------------------------------------------------

  defp tetrarchy_with_leader(count, opts \\ []) do
    {government, _events, ctx} = founded(:tetrarchy, players(count), opts)
    [%{id: ballot_id}] = government.ballots
    {:ok, government, _} = Government.cast_vote(government, 2, ballot_id, %{candidate_id: 1}, ctx)
    {government, _} = close_open_ballots(government, ctx)
    assert government.seats.leader.player_id == 1
    {government, ctx}
  end

  describe "seat incapacitation" do
    test "an AFK leader is vacated and the election reopens immediately" do
      {government, _ctx} = tetrarchy_with_leader(4)

      afk_ctx =
        ctx(:tetrarchy, players(4), holder_status: fn 1 -> :afk end)

      {government, events} = Government.advance(government, 15, afk_ctx)

      assert government.seats.leader == nil
      assert Enum.any?(events, &(&1.type == :seat_incapacitated and &1.reason == :afk))
      assert Enum.any?(events, &(&1.type == :elections_opened and &1.renewal))
      assert Enum.any?(government.ballots, &(&1.seat == :leader and &1.question == :elect))
    end

    test "an eliminated appointed head vacates without an election (leader re-appoints)" do
      {government, ctx} = tetrarchy_with_leader(4)
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      assert government.seats.economy.player_id == 3

      status_ctx =
        ctx(:tetrarchy, players(4),
          holder_status: fn
            3 -> :eliminated
            _other -> :ok
          end
        )

      {government, events} = Government.advance(government, 15, status_ctx)

      assert government.seats.economy == nil
      assert government.seats.leader != nil
      assert Enum.any?(events, &(&1.type == :seat_incapacitated and &1.reason == :eliminated))
      # appointed seat: no ballot — the throne simply re-appoints
      refute Enum.any?(government.ballots, &(&1.seat == :economy))
    end
  end

  describe "small-faction relaxation" do
    test "below four actives one member may run for and win several seats" do
      {government, _events, ctx} = founded(:myrmezir, players(3))

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      economy_ballot = Enum.find(government.ballots, &(&1.seat == :economy))

      # :self_only would normally reject the second candidacy across the
      # group; with 3 actives every restriction lifts.
      {:ok, government, _} = Government.nominate(government, 1, leader_ballot.id, 1, ctx)
      {:ok, government, _} = Government.nominate(government, 1, economy_ballot.id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot.id, %{candidate_id: 1}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, economy_ballot.id, %{candidate_id: 1}, ctx)

      {government, _} = close_open_ballots(government, ctx)

      # multi-chair: winning the second seat kept the first
      assert government.seats.leader.player_id == 1
      assert government.seats.economy.player_id == 1
    end

    test "at four actives the one-seat rule still applies" do
      {government, _events, ctx} = founded(:myrmezir, players(4))

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      economy_ballot = Enum.find(government.ballots, &(&1.seat == :economy))

      {:ok, government, _} = Government.nominate(government, 1, leader_ballot.id, 1, ctx)

      assert {:error, :already_running} =
               Government.nominate(government, 1, economy_ballot.id, 1, ctx)
    end
  end

  describe "deposition" do
    test "tetrarchy: the weighted electorate can unseat the Tetrarch" do
      {government, ctx} = tetrarchy_with_leader(4)

      {:ok, government, events} = Government.depose(government, 2, :leader, ctx)
      assert Enum.any?(events, &(&1.type == :deposition_started))

      [depose_ballot] = Enum.filter(government.ballots, &(&1.question == :depose))

      # roster-order weights over 4 players: 3/3/2/2 → total 10, bar 5.
      {:ok, government, _} =
        Government.cast_vote(government, 2, depose_ballot.id, %{choice: :approve}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 3, depose_ballot.id, %{choice: :approve}, ctx)

      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :deposed))
      assert government.seats.leader == nil
      assert Enum.any?(government.ballots, &(&1.seat == :leader and &1.question == :elect))
    end

    test "a rebuffed deposition arms the faction-wide cooldown" do
      {government, ctx} = tetrarchy_with_leader(4)

      {:ok, government, _} = Government.depose(government, 2, :leader, ctx)
      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :deposition_failed))
      assert government.seats.leader != nil
      assert {:error, :deposition_on_cooldown} = Government.depose(government, 2, :leader, ctx)
    end

    test "cardan: the loss-of-faith pledge triggers the instant it fills" do
      {government, _events, ctx} = founded(:cardan, players(4), income: fn -> 100 end)

      # seat a leader through a normal pledge election first
      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      {:ok, government, _} = Government.nominate(government, 2, leader_ballot.id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot.id, %{candidate_id: 1, pct: 20, stake: 20}, ctx)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1

      # the pledge against the throne: 10% of 100 income = 10 to trigger
      {:ok, government, _} = Government.depose(government, 3, :leader, ctx)
      [pledge] = Enum.filter(government.ballots, &(&1.question == :depose))

      {:ok, government, events} =
        Government.cast_vote(government, 3, pledge.id, %{candidate_id: 1, pct: 15, stake: 15}, ctx)

      # no clock ran — the quorum filled, the throne fell on the spot
      assert Enum.any?(events, &(&1.type == :deposed))
      assert government.seats.leader == nil
      assert Enum.any?(government.ballots, &(&1.seat == :leader and &1.question == :elect))
    end
  end

  describe "synelle snaps" do
    defp synelle_full_cabinet do
      {government, _events, ctx} = founded(:synelle, players(5))
      [%{id: ballot_id}] = government.ballots
      {:ok, government, _} = Government.nominate(government, 1, ballot_id, 1, ctx)
      {:ok, government, _} = Government.cast_vote(government, 2, ballot_id, %{candidate_id: 1}, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1

      government =
        Enum.reduce([{:economy, 3}, {:military, 4}], government, fn {seat, appointee}, government ->
          {:ok, government, _} = Government.appoint(government, 1, seat, appointee, ctx)
          [%{id: approval_id}] = Enum.filter(government.ballots, &(&1.seat == seat))

          government =
            Enum.reduce([1, 2, 5], government, fn voter, government ->
              {:ok, government, _} =
                Government.cast_vote(government, voter, approval_id, %{choice: :approve}, ctx)

              government
            end)

          {government, _} = close_open_ballots(government, ctx)
          government
        end)

      assert government.seats.economy.player_id == 3
      assert government.seats.military.player_id == 4
      {government, ctx}
    end

    test "the leader can dissolve the cabinet outright" do
      {government, ctx} = synelle_full_cabinet()

      assert {:error, :not_leader} = Government.snap(government, 3, :cabinet, ctx)
      {:ok, government, events} = Government.snap(government, 1, :cabinet, ctx)

      assert Enum.any?(events, &(&1.type == :cabinet_dissolved))
      assert government.seats.economy == nil
      assert government.seats.military == nil
      assert government.seats.leader != nil
    end

    test "both cabinet members jointly dissolve the leader" do
      {government, ctx} = synelle_full_cabinet()

      assert {:error, :not_cabinet} = Government.snap(government, 2, :leader, ctx)

      {:ok, government, events} = Government.snap(government, 3, :leader, ctx)
      assert Enum.any?(events, &(&1.type == :snap_consent))
      assert government.seats.leader != nil

      {:ok, government, events} = Government.snap(government, 4, :leader, ctx)
      assert Enum.any?(events, &(&1.type == :government_dissolved and &1.reason == :cabinet_revolt))
      assert government.seats.leader == nil
      assert Enum.any?(government.ballots, &(&1.seat == :leader and &1.question == :elect))
    end

    test "the three-quarter crisis vote fells the leadership" do
      {government, ctx} = synelle_full_cabinet()

      {:ok, government, events} = Government.snap(government, 5, :crisis, ctx)
      assert Enum.any?(events, &(&1.type == :crisis_vote_started))

      [crisis] = Enum.filter(government.ballots, &(&1.question == :dissolve))

      # 5 actives at 75% → 4 approvals required; 3 is not enough
      government =
        Enum.reduce([2, 3, 4], government, fn voter, government ->
          {:ok, government, _} = Government.cast_vote(government, voter, crisis.id, %{choice: :approve}, ctx)
          government
        end)

      {:ok, government, _} = Government.cast_vote(government, 5, crisis.id, %{choice: :approve}, ctx)
      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :government_dissolved and &1.reason == :crisis_vote))
      assert government.seats.leader == nil
    end
  end

  describe "ark challenge (option B sealed match)" do
    defp ark_with_government(opts \\ []) do
      {government, _events, ctx} = founded(:ark, players(5), opts)

      government =
        Enum.reduce(Enum.zip(government.ballots, [1, 2, 3]), government, fn {%{id: ballot_id}, winner}, government ->
          {:ok, government, _} =
            Government.cast_vote(government, winner, ballot_id, %{candidate_id: winner, stake: 100}, ctx)

          government
        end)

      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1
      {government, ctx}
    end

    test "a matched challenge stands, taxes the challenger, and locks them out" do
      {government, ctx} = ark_with_government(credit_total: fn -> 100_000 end)

      # floor is 0.5% of 100k = 500
      assert {:error, :stake_below_minimum} = Government.challenge(government, 4, 400, ctx)
      assert {:error, :already_seated} = Government.challenge(government, 1, 600, ctx)

      {:ok, government, events} = Government.challenge(government, 4, 600, ctx)
      assert Enum.any?(events, &(&1.type == :challenge_started))
      assert {:error, :challenge_already_open} = Government.challenge(government, 5, 600, ctx)

      {:ok, government, events} = Government.challenge_match(government, 1, 600, false, ctx)

      assert Enum.any?(events, &(&1.type == :challenge_defended))
      # challenger refunded 90%, matcher refunded in full
      assert Enum.any?(events, &(&1.type == :refund and &1.player_id == 4 and &1.credit == 540))
      assert Enum.any?(events, &(&1.type == :refund and &1.player_id == 1 and &1.credit == 600))
      # 10% penalty banked (on top of the 300 auction pools)
      assert government.treasury.credit == 300 + 60
      # seats stand; the challenger sits out the lockout
      assert government.seats.leader.player_id == 1
      assert {:error, :challenge_lockout} = Government.challenge(government, 4, 600, ctx)
    end

    test "an unmatched challenge topples the government and seeds the new auction" do
      {government, ctx} = ark_with_government(credit_total: fn -> 100_000 end)

      {:ok, government, _} = Government.challenge(government, 4, 600, ctx)
      # half-hearted defense: 100 of 600 matched when the window closes
      {:ok, government, _} = Government.challenge_match(government, 2, 100, false, ctx)

      {government, events} = Government.advance(government, @election, ctx)

      assert Enum.any?(events, &(&1.type == :government_overthrown))
      assert government.seats.leader == nil
      assert government.seats.economy == nil

      # matcher eats 20% of what they risked
      assert Enum.any?(events, &(&1.type == :refund and &1.player_id == 2 and &1.credit == 80))

      # fresh auctions, with the challenger pre-cast on the Executive at
      # 1.5× vote strength
      leader_auction = Enum.find(government.ballots, &(&1.seat == :leader))
      assert leader_auction != nil
      assert Enum.any?(leader_auction.candidates, &(&1.player_id == 4))

      # settlement uses the REAL stake: winning banks 600, not 900
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 4
      assert government.treasury.credit == 300 + 20 + 600
    end
  end

  describe "myrmezir law referendum" do
    test "the president proposes, the assembly disposes" do
      {government, _events, ctx} = founded(:myrmezir, players(4))

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      {:ok, government, _} = Government.nominate(government, 1, leader_ballot.id, 1, ctx)
      {:ok, government, _} = Government.cast_vote(government, 2, leader_ballot.id, %{candidate_id: 1}, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 1

      government = Map.put(government, :faction_lexes, [:test_lex])

      {:ok, government, events} = Government.update_laws(government, 1, [:test_lex], ctx)
      assert Enum.any?(events, &(&1.type == :laws_proposed))
      # nothing applies until the vote lands
      assert government.active_laws == []

      [referendum] = Enum.filter(government.ballots, &(&1.question == :laws))
      assert {:error, :ballot_already_open} = Government.update_laws(government, 1, [:test_lex], ctx)

      # 4 actives → 2 approvals
      {:ok, government, _} = Government.cast_vote(government, 2, referendum.id, %{choice: :approve}, ctx)
      {:ok, government, _} = Government.cast_vote(government, 3, referendum.id, %{choice: :approve}, ctx)
      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :laws_changed))
      assert government.active_laws == [:test_lex]
    end
  end

  describe "cardan tithe settlement" do
    test "winning pledges collect for the lockout window and redistribute evenly" do
      {government, _events, ctx} = founded(:cardan, players(4), income: fn -> 100 end)

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      {:ok, government, _} = Government.nominate(government, 2, leader_ballot.id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot.id, %{candidate_id: 1, pct: 8, stake: 8}, ctx)

      {government, events} = close_open_ballots(government, ctx)

      assert government.seats.leader.player_id == 1
      assert Enum.any?(events, &(&1.type == :tithe_settled and &1.total == 8))

      # the settlement rides the effects payload: pledger debited, all
      # four members credited an even share
      [tithe] = government.tithes
      assert tithe.debits == %{2 => 8}
      assert tithe.credit_per_member == 2.0
      assert Enum.sort(tithe.recipients) == [1, 2, 3, 4]

      effects = Government.effects(government, ctx)
      assert effects.tithes.debits == %{2 => 8}
      assert effects.tithes.credit_per_member == 2.0

      # and it expires with the lockout window
      {government, _} = Government.advance(government, @lockout, ctx)
      assert government.tithes == []
      assert Government.effects(government, ctx).tithes.credit_per_member == 0
    end

    test "inactive members neither receive a share nor shrink the divisor" do
      {government, _events, ctx} =
        founded(:cardan, players(4), income: fn -> 100 end, active_ids: fn -> [1, 2] end)

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))
      {:ok, government, _} = Government.nominate(government, 2, leader_ballot.id, 1, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 2, leader_ballot.id, %{candidate_id: 1, pct: 8, stake: 8}, ctx)

      {government, _events} = close_open_ballots(government, ctx)

      # only the two ACTIVE members split the pot
      [tithe] = government.tithes
      assert Enum.sort(tithe.recipients) == [1, 2]
      assert tithe.credit_per_member == 4.0
      assert Government.effects(government, ctx).tithes.recipients |> Enum.sort() == [1, 2]
    end
  end

  # ------------------------------------------------------------------
  # Faction economy modifiers + treasury flows (user design 2026-07-09)
  # ------------------------------------------------------------------

  defp seated(faction_key, count) do
    {government, _events, ctx} = founded(faction_key, players(count))
    {government, _} = close_open_ballots(government, ctx)
    {government, _} = Government.fill_seat(government, :leader, %{player_id: 1, name: "Player 1"})
    {government, _} = Government.fill_seat(government, :economy, %{player_id: 2, name: "Player 2"})
    {government, ctx}
  end

  defp node_cost(module, key),
    do: Data.Querier.one(module, @test_instance_id, key).cost

  describe "faction economy modifiers" do
    test "synelle buys research 10% cheaper" do
      {government, ctx} = seated(:synelle, 4)
      government = Government.deposit(government, %{technology: 10_000})
      base = node_cost(Data.Game.FactionPatent, :research_compact)
      expected = round(base * 0.9)

      {:ok, government, events} = Government.purchase_patent(government, 2, :research_compact, ctx)

      assert government.treasury.technology == 10_000 - expected
      assert Enum.any?(events, &(&1.type == :patent_purchased and &1.cost == expected))
    end

    test "cardan pays 10% more for research and 5% less for lexes" do
      {government, ctx} = seated(:cardan, 4)
      government = Government.deposit(government, %{technology: 10_000, ideology: 10_000})
      patent_base = node_cost(Data.Game.FactionPatent, :research_compact)
      lex_base = node_cost(Data.Game.FactionLex, :assembly_charter)

      {:ok, government, _} = Government.purchase_patent(government, 2, :research_compact, ctx)
      assert government.treasury.technology == 10_000 - round(patent_base * 1.1)

      {:ok, government, _} = Government.purchase_lex(government, 1, :assembly_charter, ctx)
      assert government.treasury.ideology == 10_000 - round(lex_base * 0.95)

      # ...and swaps doctrine 5% faster
      {government, _} = Government.apply_laws(government, [:assembly_charter], ctx)
      assert government.law_cooldown.value == round(@law_cooldown * 0.95)
    end

    test "myrmezir writes cheap laws slowly" do
      {government, ctx} = seated(:myrmezir, 4)
      government = Government.deposit(government, %{ideology: 10_000})
      lex_base = node_cost(Data.Game.FactionLex, :assembly_charter)

      {:ok, government, _} = Government.purchase_lex(government, 1, :assembly_charter, ctx)
      assert government.treasury.ideology == 10_000 - round(lex_base * 0.9)

      {government, _} = Government.apply_laws(government, [:assembly_charter], ctx)
      assert government.law_cooldown.value == round(@law_cooldown * 1.1)
    end

    test "ark unlocks are 10% off but also bill the treasury credit at 10x base" do
      {government, ctx} = seated(:ark, 4)
      base = node_cost(Data.Game.FactionPatent, :research_compact)

      # enough technology, but no credit: the surcharge blocks it
      government = Government.deposit(government, %{technology: 10_000})

      assert {:error, :treasury_insufficient} =
               Government.purchase_patent(government, 2, :research_compact, ctx)

      government = Government.deposit(government, %{credit: base * 10})
      {:ok, government, events} = Government.purchase_patent(government, 2, :research_compact, ctx)

      assert government.treasury.technology == 10_000 - round(base * 0.9)
      assert government.treasury.credit == 0
      assert Enum.any?(events, &(&1.type == :patent_purchased and &1.credit_cost == base * 10))
    end
  end

  describe "treasury flows" do
    test "the withdrawal cap is economy-seat business" do
      {government, ctx} = seated(:tetrarchy, 4)

      assert {:error, :not_head_of_economy} = Government.set_withdraw_cap(government, 3, 10, ctx)
      assert {:error, :invalid_percent} = Government.set_withdraw_cap(government, 2, 101, ctx)

      {:ok, government, events} = Government.set_withdraw_cap(government, 2, 10, ctx)
      assert government.withdraw_cap_pct == 10
      assert Enum.any?(events, &(&1.type == :withdraw_cap_changed and &1.pct == 10))
    end

    test "member withdrawals: capped per 24h window, taxed at market rate" do
      {government, ctx} = seated(:tetrarchy, 4)
      government = Government.deposit(government, %{credit: 1_000})

      assert {:error, :withdrawals_disabled} =
               Government.withdraw(government, 3, %{credit: 50}, ctx)

      {:ok, government, _} = Government.set_withdraw_cap(government, 2, 10, ctx)

      # 100 of 1000 = exactly the 10% cap; payout taxed at 10%
      {:ok, government, events} = Government.withdraw(government, 3, %{credit: 100}, ctx)
      assert government.treasury.credit == 900
      assert Enum.any?(events, &(&1.type == :grant and &1.player_id == 3 and &1.credit == 90))

      # the window is spent — any further ask breaks the cap
      assert {:error, :withdraw_cap_exceeded} =
               Government.withdraw(government, 3, %{credit: 50}, ctx)

      # another member has their own allowance
      {:ok, government, _} = Government.withdraw(government, 4, %{credit: 90}, ctx)

      # and the window rolls: after 24h the ledger clears
      {government, _} = Government.advance(government, @election + 5, ctx)
      {:ok, _government, _} = Government.withdraw(government, 3, %{credit: 50}, ctx)
    end

    test "the head of economy grants freely past the cap, untaxed" do
      {government, ctx} = seated(:tetrarchy, 4)
      government = Government.deposit(government, %{credit: 1_000})

      assert {:error, :not_head_of_economy} =
               Government.grant(government, 3, 4, %{credit: 500}, ctx)

      # far beyond any cap, no tax taken
      {:ok, government, events} = Government.grant(government, 2, 3, %{credit: 800}, ctx)
      assert government.treasury.credit == 200
      assert Enum.any?(events, &(&1.type == :grant and &1.player_id == 3 and &1.credit == 800))
      assert Enum.any?(events, &(&1.type == :treasury_granted and &1.by == 2))

      assert {:error, :treasury_insufficient} =
               Government.grant(government, 2, 3, %{credit: 500}, ctx)
    end
  end

  # ------------------------------------------------------------------
  # Royal prerogative: the Tetrarch acts as any council seat, the whole
  # faction eats a 10% income malus for 24h per act (source design:
  # "Tetrarch acts as a council seat → −10 faction stability for 24h")
  # ------------------------------------------------------------------

  describe "royal prerogative (tetrarch overreach)" do
    test "the tetrarch performs economy actions in the quaestor's stead, billed publicly" do
      {government, ctx} = seated(:tetrarchy, 4)

      {:ok, government, events} = Government.set_withdraw_cap(government, 1, 10, ctx)

      assert government.withdraw_cap_pct == 10
      assert [%{malus: 10, action: :set_withdraw_cap}] = government.overreach

      assert Enum.any?(
               events,
               &(&1.type == :leader_overreach and &1.by == 1 and &1.malus == 10 and
                   &1.seat == :economy)
             )

      # the malus reaches every member through the effects payload
      assert Enum.any?(events, &(&1.type == :sync_effects))
      assert Government.effects(government, ctx).overreach_malus == 10
    end

    test "acts stack, and each entry ages out after the 24h window" do
      {government, ctx} = seated(:tetrarchy, 4)
      government = Government.deposit(government, %{credit: 1_000})

      {:ok, government, _} = Government.set_withdraw_cap(government, 1, 10, ctx)
      {:ok, government, _} = Government.grant(government, 1, 3, %{credit: 100}, ctx)

      assert length(government.overreach) == 2
      assert Government.effects(government, ctx).overreach_malus == 20

      # past the approval window both entries expire and effects re-push
      {government, events} = Government.advance(government, @election + 1, ctx)

      assert Map.get(government, :overreach) == []
      assert Government.effects(government, ctx).overreach_malus == 0
      assert Enum.any?(events, &(&1.type == :sync_effects))
    end

    test "the quaestor acts natively — no tyranny billed" do
      {government, ctx} = seated(:tetrarchy, 4)

      {:ok, government, events} = Government.set_withdraw_cap(government, 2, 10, ctx)

      assert Map.get(government, :overreach) == []
      refute Enum.any?(events, &(&1.type == :leader_overreach))
    end

    test "patent purchases fall under the prerogative too" do
      {government, ctx} = seated(:tetrarchy, 4)
      government = Government.deposit(government, %{technology: 10_000})

      {:ok, government, events} = Government.purchase_patent(government, 1, :research_compact, ctx)

      assert :research_compact in government.faction_patents
      assert Enum.any?(events, &(&1.type == :leader_overreach and &1.action == :patent_purchased))
    end

    test "other factions' leaders stay bound to their own office" do
      {government, ctx} = seated(:myrmezir, 4)

      assert {:error, :not_head_of_economy} = Government.set_withdraw_cap(government, 1, 10, ctx)
      assert Map.get(government, :overreach) == []
    end
  end

  # ------------------------------------------------------------------
  # Inactive players never distort government math (user rule 2026-07-07)
  # ------------------------------------------------------------------

  describe "inactive-player guards" do
    test "treasury distribution pays active members only, split by active count" do
      {government, ctx} = tetrarchy_with_leader(4)
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      government = Government.deposit(government, %{credit: 1000})

      active_ctx = ctx(:tetrarchy, players(4), active_ids: fn -> [1, 3] end)

      {:ok, _government, events} =
        Government.distribute_treasury(government, 3, 100, active_ctx)

      grants = Enum.filter(events, &(&1.type == :grant))
      assert Enum.map(grants, & &1.player_id) |> Enum.sort() == [1, 3]
      # 1000 over TWO actives, not four
      assert Enum.all?(grants, &(&1.credit == 500))
    end

    test "inactive members cannot be nominated, appointed, or bid onto a seat" do
      # nomination (myrmezir: member 3 is inactive)
      {government, _events, ctx} =
        founded(:myrmezir, players(5), active_ids: fn -> [1, 2, 4, 5] end)

      leader_ballot = Enum.find(government.ballots, &(&1.seat == :leader))

      assert {:error, :candidate_inactive} =
               Government.nominate(government, 3, leader_ballot.id, 3, ctx)

      # appointment (tetrarchy)
      {government, _ctx} = tetrarchy_with_leader(5)
      inactive_ctx = ctx(:tetrarchy, players(5), active_ids: fn -> [1, 2, 4, 5] end)

      assert {:error, :candidate_inactive} =
               Government.appoint(government, 1, :economy, 3, inactive_ctx)

      # auction bid (ark): bidding on the inactive member is refused
      {government, _events, ark_ctx} =
        founded(:ark, players(5), active_ids: fn -> [1, 2, 4, 5] end)

      [%{id: ballot_id} | _] = government.ballots

      assert {:error, :candidate_inactive} =
               Government.cast_vote(government, 1, ballot_id, %{candidate_id: 3, stake: 100}, ark_ctx)
    end

    test "tetrarchy elections and depositions weigh active members only" do
      # player 1 (scoreboard top by roster fallback) is inactive: they are
      # neither a candidate nor part of the weight base
      {government, _events, ctx} =
        founded(:tetrarchy, players(4), active_ids: fn -> [2, 3, 4] end)

      [ballot] = government.ballots
      refute Enum.any?(ballot.candidates, &(&1.player_id == 1))
      refute Map.has_key?(ballot.weights, 1)

      # 3 actives → thirds of 1: weights 3/2/1, total 6, majority bar 3
      assert ballot.weights == %{2 => 3, 3 => 2, 4 => 1}

      {:ok, government, _} = Government.cast_vote(government, 3, ballot.id, %{candidate_id: 2}, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert government.seats.leader.player_id == 2

      # deposition bar over the same active-only base: weights 2 + 1
      # meet ceil(6/2) = 3 — with an inflated 4-member base (total 8,
      # bar 4) this same coalition would have failed
      {:ok, government, _} = Government.depose(government, 3, :leader, ctx)
      [depose_ballot] = Enum.filter(government.ballots, &(&1.question == :depose))
      assert depose_ballot.weights == %{2 => 3, 3 => 2, 4 => 1}

      {:ok, government, _} =
        Government.cast_vote(government, 3, depose_ballot.id, %{choice: :approve}, ctx)

      {:ok, government, _} =
        Government.cast_vote(government, 4, depose_ballot.id, %{choice: :approve}, ctx)

      {government, events} = close_open_ballots(government, ctx)
      assert Enum.any?(events, &(&1.type == :deposed))
      assert government.seats.leader == nil
    end
  end
end
