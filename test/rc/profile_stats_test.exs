defmodule RC.ProfileStatsTest do
  use RC.DataCase

  # Aggregate profile stats for the public profile endpoint and the
  # Discord /player card: official-legacy wins/participations, daily
  # podium totals, and per-faction match counts.

  alias RC.Instances.Faction
  alias RC.Instances.Instance
  alias RC.Instances.Registration
  alias RC.Instances.Victory

  defp account!(n) do
    {:ok, account} =
      RC.Accounts.create_account(%{
        email: "profile-stats-#{n}@test.local",
        password: "profile-stats-#{n}",
        name: "PStats#{n}",
        role: :user,
        status: :active
      })

    account
  end

  defp profile!(account, n) do
    {:ok, profile} = RC.Accounts.create_profile(%{account_id: account.id, name: "PStatsP#{n}", avatar: "todo"})
    profile
  end

  defp instance!(owner, attrs) do
    Repo.insert!(%Instance{
      account_id: owner.id,
      name: Map.get(attrs, :name, "stats instance"),
      state: Map.fetch!(attrs, :state),
      discord_ready: Map.get(attrs, :discord_ready, false),
      game_data: Map.get(attrs, :game_data, %{})
    })
  end

  defp join!(instance, profile, faction_ref, final_rank \\ nil) do
    faction =
      Repo.insert!(%Faction{
        instance_id: instance.id,
        faction_ref: faction_ref,
        capacity: 10,
        final_rank: final_rank
      })

    Repo.insert!(%Registration{faction_id: faction.id, profile_id: profile.id, state: "playing"})
    faction
  end

  defp victory!(instance), do: Repo.insert!(%Victory{instance_id: instance.id, victory_type: "victory_track"})

  test "official legacy wins and participations count only discord-ready, ended, slow instances" do
    owner = account!(1)
    profile = profile!(owner, 1)

    # won official legacy
    won = instance!(owner, %{state: "ended", discord_ready: true, game_data: %{"speed" => "slow"}})
    join!(won, profile, "cardan", 1)
    victory!(won)

    # lost official legacy (rank 2)
    lost = instance!(owner, %{state: "ended", discord_ready: true, game_data: %{"speed" => "slow"}})
    join!(lost, profile, "ark", 2)
    victory!(lost)

    # official legacy still running — not yet a participation
    running = instance!(owner, %{state: "running", discord_ready: true, game_data: %{"speed" => "slow"}})
    join!(running, profile, "cardan")

    # unofficial legacy (not discord_ready)
    casual = instance!(owner, %{state: "ended", discord_ready: false, game_data: %{"speed" => "slow"}})
    join!(casual, profile, "cardan", 1)
    victory!(casual)

    # official but Flash speed
    flash = instance!(owner, %{state: "ended", discord_ready: true, game_data: %{"speed" => "fast"}})
    join!(flash, profile, "cardan", 1)
    victory!(flash)

    assert %{legacy: %{wins: 1, participations: 2}} = RC.ProfileStats.for_profile(profile.id)
  end

  test "daily block counts podium finishes on settled days and completion by score" do
    owner = account!(2)
    profile = profile!(owner, 2)
    rival_a = profile!(account!(3), 3)
    rival_b = profile!(account!(4), 4)

    # Dates must be in the past — "settled" means strictly before the
    # active daily date.
    # Day 1 (settled): profile wins gold.
    {:ok, _} = Daily.record_score(profile.id, "2001-01-01", :golden_flow, 100.0, 0.0, 1)
    {:ok, _} = Daily.record_score(rival_a.id, "2001-01-01", :golden_flow, 50.0, 0.0, 1)

    # Day 2 (settled): profile takes bronze behind both rivals.
    {:ok, _} = Daily.record_score(rival_a.id, "2001-01-02", :golden_flow, 90.0, 0.0, 2)
    {:ok, _} = Daily.record_score(rival_b.id, "2001-01-02", :golden_flow, 80.0, 0.0, 2)
    {:ok, _} = Daily.record_score(profile.id, "2001-01-02", :golden_flow, 70.0, 0.0, 2)

    # Day 3 (settled): a race DNF — played but not completed, silver by tiebreak.
    {:ok, _} = Daily.record_score(rival_a.id, "2001-01-03", :the_grand_prix, 0.0, 3.0, 3)
    {:ok, _} = Daily.record_score(profile.id, "2001-01-03", :the_grand_prix, 0.0, 2.0, 3)

    # Today (not settled): a would-be gold that must not count as a medal yet.
    today = Date.to_iso8601(Daily.today())
    {:ok, _} = Daily.record_score(profile.id, today, :golden_flow, 999.0, 0.0, 4)

    assert %{daily: daily} = RC.ProfileStats.for_profile(profile.id)
    assert daily == %{gold: 1, silver: 1, bronze: 1, completed: 3, played: 4}
  end

  test "faction counts cover started non-daily matches of every speed" do
    owner = account!(5)
    profile = profile!(owner, 5)

    ended_legacy = instance!(owner, %{state: "ended", game_data: %{"speed" => "slow"}})
    join!(ended_legacy, profile, "cardan", 2)

    running_flash = instance!(owner, %{state: "running", game_data: %{"speed" => "fast", "game_mode_type" => "ranked"}})
    join!(running_flash, profile, "cardan")

    paused_tactic = instance!(owner, %{state: "paused", game_data: %{"speed" => "medium"}})
    join!(paused_tactic, profile, "tetrarchy")

    # never started — not played
    lobby = instance!(owner, %{state: "open", game_data: %{"speed" => "slow"}})
    join!(lobby, profile, "ark")

    # daily — excluded
    daily = instance!(owner, %{state: "ended", game_data: %{"speed" => "daily", "game_mode_type" => "daily"}})
    join!(daily, profile, "tetrarchy", 1)

    assert %{factions: factions} = RC.ProfileStats.for_profile(profile.id)
    assert factions == %{"cardan" => 2, "tetrarchy" => 1}
  end

  test "a profile with no history gets all-zero stats" do
    profile = profile!(account!(6), 6)

    assert RC.ProfileStats.for_profile(profile.id) == %{
             legacy: %{wins: 0, participations: 0},
             daily: %{gold: 0, silver: 0, bronze: 0, completed: 0, played: 0},
             factions: %{}
           }
  end
end
