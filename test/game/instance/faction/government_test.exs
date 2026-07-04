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
        government_law_cooldown: @law_cooldown
      },
      faction_ideology_income: Keyword.get(opts, :income, fn -> 100 end),
      active_player_count: Keyword.get(opts, :active, fn -> length(players) end)
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

    test "three failed nominations dissolve the government and reopen the leader election" do
      {government, ctx} = synelle_with_leader(4)

      government =
        Enum.reduce(1..2, government, fn _round, government ->
          {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
          {government, _} = close_open_ballots(government, ctx)
          assert government.seats.leader != nil
          government
        end)

      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      {government, events} = close_open_ballots(government, ctx)

      assert Enum.any?(events, &(&1.type == :government_dissolved))
      assert government.seats.leader == nil
      assert [%Ballot{seat: :leader, question: :elect}] = government.ballots

      # a fresh mandate starts with a clean strike counter
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 0
    end

    test "a successful approval resets the strike counter" do
      {government, ctx} = synelle_with_leader(4)

      # one failure
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      {government, _} = close_open_ballots(government, ctx)
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 1

      # then a success
      {:ok, government, _} = Government.appoint(government, 1, :economy, 3, ctx)
      [%{id: approval_id}] = government.ballots
      {:ok, government, _} = Government.cast_vote(government, 2, approval_id, %{choice: :approve}, ctx)
      {:ok, government, _} = Government.cast_vote(government, 4, approval_id, %{choice: :approve}, ctx)
      {government, _} = close_open_ballots(government, ctx)

      assert government.seats.economy.player_id == 3
      assert Government.get_meta(government, :synelle_failed_nominations, 0) == 0
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

      assert {:error, :not_head_of_economy} = Government.set_tax_rates(government, 1, rates, ctx)

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
               Government.purchase_patent(government, 1, :research_compact, ctx)

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

  describe "tick integration" do
    test "faction state without a government passes through unchanged" do
      state = %{government: nil}
      {change, new_state} = Government.tick({MapSet.new(), state}, 5)

      assert change == MapSet.new()
      assert new_state == state
    end
  end
end
