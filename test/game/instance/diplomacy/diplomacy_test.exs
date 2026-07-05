defmodule Instance.Diplomacy.DiplomacyTest do
  use ExUnit.Case, async: true

  alias Instance.Diplomacy.Diplomacy

  # This literal interns the faction-key atoms: the DB-row constructor
  # shape goes through to_existing_atom, and this file must not depend
  # on sibling tests having loaded content modules first.
  @faction_keys [:tetrarchy, :myrmezir, :cardan]

  @initial_meters %{exhaustion: 0, momentum: 50, frenzy: 100}

  # Both constructor shapes: runtime faction structs carry :key, DB rows
  # carry :faction_ref.
  defp new_state do
    Diplomacy.new(
      [
        %{id: 1, key: :tetrarchy},
        %{id: 2, key: :myrmezir},
        %{id: 3, faction_ref: "cardan"}
      ],
      42
    )
  end

  defp meters(state, a, b, faction_id),
    do: state.wars[Diplomacy.pair_key(a, b)][to_string(faction_id)]

  test "3+ factions default to cold war, war is unilateral and symmetric" do
    state = new_state()
    assert Diplomacy.stance(state, 1, 2) == :cold_war
    assert state.wars == %{}

    {:ok, state, events} = Diplomacy.declare_war(state, 1, 2)

    assert Diplomacy.stance(state, 1, 2) == :war
    assert Diplomacy.stance(state, 2, 1) == :war
    assert Diplomacy.stance(state, 1, 3) == :cold_war
    assert [%{type: :war_declared, from: 1, to: 2}] = events

    # both belligerents open at exhaustion 0 / momentum 50 / frenzy 100
    assert meters(state, 1, 2, 1) == @initial_meters
    assert meters(state, 1, 2, 2) == @initial_meters

    assert {:error, :already_at_war} = Diplomacy.declare_war(state, 2, 1)
    assert {:error, :cannot_target_self} = Diplomacy.declare_war(state, 1, 1)
    assert {:error, :unknown_faction} = Diplomacy.declare_war(state, 1, 99)
  end

  test "a two-faction galaxy starts at war, meters initialized" do
    state = Diplomacy.new([%{id: 7, key: :tetrarchy}, %{id: 9, key: :myrmezir}], 42)

    assert Diplomacy.stance(state, 7, 9) == :war
    assert meters(state, 7, 9, 7) == @initial_meters
    assert meters(state, 7, 9, 9) == @initial_meters
  end

  test "non-aggression needs cold war, acceptance by the target only" do
    state = new_state()

    {:ok, state, [%{type: :pact_proposed, proposal: proposal}]} =
      Diplomacy.propose(state, 1, 2, :non_aggression)

    # still cold war until accepted
    assert Diplomacy.stance(state, 1, 2) == :cold_war

    assert {:error, :already_proposed} = Diplomacy.propose(state, 1, 2, :non_aggression)
    assert {:error, :not_the_recipient} = Diplomacy.accept(state, proposal.id, 1)
    assert {:error, :not_the_recipient} = Diplomacy.accept(state, proposal.id, 3)

    {:ok, state, [%{type: :pact_accepted}]} = Diplomacy.accept(state, proposal.id, 2)

    assert Diplomacy.stance(state, 1, 2) == :non_aggression
    assert state.proposals == []

    # a pact bars a new pact proposal but not a war declaration
    assert {:error, :requires_cold_war} = Diplomacy.propose(state, 2, 1, :non_aggression)
  end

  test "war ends only by mutual peace, which retires the meters" do
    state = new_state()
    {:ok, state, _} = Diplomacy.declare_war(state, 1, 2)

    # peace requires war; NAP is barred by war
    assert {:error, :requires_cold_war} = Diplomacy.propose(state, 1, 2, :non_aggression)
    assert {:error, :requires_war} = Diplomacy.propose(state, 1, 3, :peace)

    {:ok, state, [%{proposal: proposal}]} = Diplomacy.propose(state, 1, 2, :peace)

    {:ok, state, [%{type: :pact_rejected}]} = Diplomacy.reject(state, proposal.id, 2)
    assert Diplomacy.stance(state, 1, 2) == :war

    {:ok, state, [%{proposal: proposal}]} = Diplomacy.propose(state, 2, 1, :peace)
    {:ok, state, [%{type: :pact_accepted}]} = Diplomacy.accept(state, proposal.id, 1)

    assert Diplomacy.stance(state, 1, 2) == :cold_war
    assert state.wars == %{}
  end

  test "declaring war sweeps pending proposals between the pair" do
    state = new_state()
    {:ok, state, _} = Diplomacy.propose(state, 1, 2, :non_aggression)
    {:ok, state, _} = Diplomacy.propose(state, 1, 3, :non_aggression)

    {:ok, state, _} = Diplomacy.declare_war(state, 2, 1)

    assert Enum.map(state.proposals, & &1.to) == [3]
  end

  test "breaking a pact is unilateral and reverts to cold war" do
    state = new_state()
    {:ok, state, _} = Diplomacy.propose(state, 1, 2, :non_aggression)
    [proposal] = state.proposals
    {:ok, state, _} = Diplomacy.accept(state, proposal.id, 2)

    assert {:error, :no_pact} = Diplomacy.break_pact(state, 1, 3)

    {:ok, state, [%{type: :pact_broken, from: 2, to: 1}]} = Diplomacy.break_pact(state, 2, 1)
    assert Diplomacy.stance(state, 1, 2) == :cold_war
  end

  test "stances_for exposes only non-cold-war relations, keyed by the other side" do
    state = new_state()
    {:ok, state, _} = Diplomacy.declare_war(state, 1, 2)
    {:ok, state, _} = Diplomacy.propose(state, 1, 3, :non_aggression)
    [proposal] = state.proposals
    {:ok, state, _} = Diplomacy.accept(state, proposal.id, 3)

    assert Diplomacy.stances_for(state, 1) == %{2 => :war, 3 => :non_aggression}
    assert Diplomacy.stances_for(state, 2) == %{1 => :war}
    assert Diplomacy.stances_for(state, 3) == %{1 => :non_aggression}
  end

  test "cold-war aggression builds directed tension: +10 success, half on failure" do
    state = new_state()

    # faction 1 takes a system from faction 2 → the VICTIM (2) gains
    # tension toward the aggressor (1)
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 2})
    assert state.tension == %{"2>1" => 10}

    # a failed bombardment generates half
    {state, true} =
      Diplomacy.handle_action(state, %{kind: :bombardment, aggressor: 1, victim: 2, success: false})

    assert state.tension == %{"2>1" => 15}

    # pillage is not a tension kind — cold war allows it without consequence
    {state, false} = Diplomacy.handle_action(state, %{kind: :pillage, aggressor: 1, victim: 2})
    assert state.tension == %{"2>1" => 15}

    # invalid pairs are dropped
    {^state, false} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 1})
    {^state, false} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 99})
    {^state, false} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: nil, victim: 2})
  end

  test "aggression under a non-aggression pact builds double tension" do
    state = new_state()
    {:ok, state, _} = Diplomacy.propose(state, 1, 2, :non_aggression)
    [proposal] = state.proposals
    {:ok, state, _} = Diplomacy.accept(state, proposal.id, 2)

    {state, true} = Diplomacy.handle_action(state, %{kind: :removal, aggressor: 1, victim: 2})
    assert state.tension == %{"2>1" => 20}
  end

  test "tension decays over time and evaporates near zero" do
    state = new_state()
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 2})

    # decay is 2 per game-day (480 ut)
    {state, true} = Diplomacy.advance(state, 480)
    assert state.tension == %{"2>1" => 8.0}

    # four more days wipe the remainder out entirely
    {state, true} = Diplomacy.advance(state, 4 * 480)
    assert state.tension == %{}
  end

  test "declaring war clears the pair's tension ledger" do
    state = new_state()
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 2})
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 3, victim: 2})

    {:ok, state, _} = Diplomacy.declare_war(state, 2, 1)

    # only the belligerents' ledger is wiped; third parties keep theirs
    assert state.tension == %{"2>3" => 10}
  end

  test "war actions move the sentiment meters per the effect table" do
    state = new_state()
    {:ok, state, _} = Diplomacy.declare_war(state, 1, 2)

    # sabotage feeds the saboteur's momentum (+5), failure feeds half
    {state, true} = Diplomacy.handle_action(state, %{kind: :sabotage, aggressor: 1, victim: 2})
    assert meters(state, 1, 2, 1).momentum == 55

    {state, true} =
      Diplomacy.handle_action(state, %{kind: :sabotage, aggressor: 1, victim: 2, success: false})

    assert meters(state, 1, 2, 1).momentum == 57.5

    # bombardment spends the raider's frenzy; the victim's is clamped at 100
    {state, true} = Diplomacy.handle_action(state, %{kind: :bombardment, aggressor: 1, victim: 2})
    assert meters(state, 1, 2, 1).frenzy == 95
    assert meters(state, 1, 2, 2).frenzy == 100

    # a fleet kill feeds momentum; tension is NOT built while at war
    {state, true} = Diplomacy.handle_action(state, %{kind: :fleet_destroyed, aggressor: 2, victim: 1})
    assert meters(state, 1, 2, 2).momentum == 55
    assert state.tension == %{}
  end

  test "exhaustion drips per game-day of war and conquest relieves it" do
    state = new_state()
    {:ok, state, _} = Diplomacy.declare_war(state, 1, 2)

    # five game-days of war: both sides at exhaustion 5
    {state, true} = Diplomacy.advance(state, 5 * 480)
    assert meters(state, 1, 2, 1).exhaustion == 5.0
    assert meters(state, 1, 2, 2).exhaustion == 5.0

    # taking a system knocks the taker's exhaustion down (floor 0)
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 1, victim: 2})
    assert meters(state, 1, 2, 1).exhaustion == 0
    assert meters(state, 1, 2, 2).exhaustion == 5.0
  end

  test "backfill adds tension/wars and retrofits meters onto pre-existing wars" do
    # a pre-meters snapshot: the struct decoded as a plain map without
    # the new fields, holding a war declared before meters existed
    old = %{
      factions: [%{id: 1, key: :tetrarchy}, %{id: 2, key: :myrmezir}],
      relations: %{"1:2" => :war},
      proposals: [],
      counter: 1,
      instance_id: 42
    }

    state = Diplomacy.backfill(old)

    assert state.tension == %{}
    assert state.wars["1:2"]["1"] == @initial_meters
    assert state.wars["1:2"]["2"] == @initial_meters
  end

  test "stances modify resolved system visibility (war fogs, pact opens)" do
    faction = %Instance.Faction.Faction{
      id: 1,
      key: :tetrarchy,
      players: [],
      chat: [],
      contacts: %{},
      all_radars: %{},
      radars: %{},
      detected_objects: [],
      market_taxes: Instance.Faction.Market.new(),
      icons: [],
      icon_rate_buckets: %{},
      galactic_survey_cache: nil,
      government: nil,
      diplomacy: %{2 => :war, 3 => :non_aggression},
      instance_id: 42
    }

    # informer-level contact (2) on three foreign systems
    contact = Core.VisibilityValue.new(:informer, Core.ValuePart.new("someone", 2))
    faction = %{faction | contacts: %{10 => contact, 11 => contact, 12 => contact}}

    system = fn id, owner_fid ->
      %{id: id, characters: [], owner: %{faction: :other, faction_id: owner_fid}}
    end

    at_war = Instance.Faction.Faction.resolve_system_visibility(faction, system.(10, 2))
    pact = Instance.Faction.Faction.resolve_system_visibility(faction, system.(11, 3))
    cold_war = Instance.Faction.Faction.resolve_system_visibility(faction, system.(12, 4))

    assert cold_war.value == 2
    assert at_war.value == 1
    assert pact.value == 3
  end

  test "public serialization carries relations, tension, wars and factions" do
    state = new_state()
    {:ok, state, _} = Diplomacy.declare_war(state, 1, 2)
    {:ok, state, _} = Diplomacy.propose(state, 1, 3, :non_aggression)
    {state, true} = Diplomacy.handle_action(state, %{kind: :conquest, aggressor: 3, victim: 2})

    json = Jason.decode!(Jason.encode!(state))

    assert json["relations"] == %{"1:2" => "war"}
    assert json["tension"] == %{"2>3" => 10}
    assert json["wars"]["1:2"]["1"]["momentum"] == 50
    assert [%{"kind" => "non_aggression", "from" => 1, "to" => 3}] = json["proposals"]
    assert Enum.map(json["factions"], & &1["key"]) == Enum.map(@faction_keys, &to_string/1)
    refute Map.has_key?(json, "instance_id")
  end
end
