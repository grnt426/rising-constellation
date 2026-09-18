defmodule RC.FlashSchedulesTest do
  use RC.DataCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Discord.{FlashAnnouncer, FlashEvent}
  alias RC.FlashSchedules
  alias RC.FlashSchedules.{Schedule, ScheduledMatch}
  alias RC.Instances
  alias RC.Instances.Victory
  alias RC.Registrations

  # Tuesday 2030-01-08 20:00 US Eastern (EST, UTC-5).
  @start ~U[2030-01-09 01:00:00.000000Z]

  defp schedule(attrs \\ %{}) do
    admin = fixture(:admin)
    scenario = valid_scenario_fixture()

    {:ok, schedule} =
      %{
        "name" => "Tuesday Flash",
        "weekday" => 2,
        "start_time" => "20:00:00",
        "scenario_ids" => [scenario.id],
        "game_mode_type" => "ranked",
        "min_players" => 2
      }
      |> Map.merge(attrs)
      |> FlashSchedules.create_schedule(admin.id)

    schedule
  end

  defp player(n) do
    account =
      create_and_get_account(%{
        email: "flash#{n}@user",
        hashed_password: "x",
        password: "some password",
        name: "flash player #{n}",
        role: :user,
        status: :active
      })

    {:ok, profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "a", name: "Pilot #{n}", account_id: account.id}))

    %{account: account, profile: profile}
  end

  defp rules,
    do: "Players not ready at start are removed. If not started within 48hrs of start time, this match auto-closes."

  defp join_lobby(instance, faction_ref, player) do
    faction = Enum.find(instance.factions, &(&1.faction_ref == faction_ref))
    {:ok, _} = Registrations.register_profile(faction, player.profile)
    player
  end

  # Plans the match's Discord event and records the push, the way the
  # scheduler does with a live bot.
  defp push(match, now) do
    data = FlashSchedules.event_data(match, now)

    case FlashEvent.plan(match, data) do
      {:create, params, record} ->
        {:ok, match} = FlashSchedules.record_event(match, Map.put(record, :discord_event_id, "424242"))
        {:create, params, match}

      {:modify, params, record} ->
        {:ok, match} = FlashSchedules.record_event(match, record)
        {:modify, params, match}

      :none ->
        {:none, nil, match}
    end
  end

  defp synced(now), do: now |> FlashSchedules.matches_needing_event_sync() |> Enum.map(& &1.id)

  describe "occurrences" do
    test "weekly US Eastern slots follow daylight saving" do
      s = %Schedule{weekday: 2, start_time: ~T[20:00:00], scenario_ids: [1], anchor_date: ~D[2026-09-15]}

      starts =
        s
        |> FlashSchedules.occurrences(~U[2026-10-20 00:00:00Z], ~U[2026-11-12 00:00:00Z])
        |> Enum.map(& &1.starts_at)

      # EDT (UTC-4) until Nov 1 2026, then EST (UTC-5).
      assert starts == [
               ~U[2026-10-21 00:00:00Z],
               ~U[2026-10-28 00:00:00Z],
               ~U[2026-11-04 01:00:00Z],
               ~U[2026-11-11 01:00:00Z]
             ]
    end

    test "the map pool rotates in order, one map per week from the anchor" do
      s = %Schedule{weekday: 2, start_time: ~T[20:00:00], scenario_ids: [11, 22, 33], anchor_date: ~D[2026-09-16]}

      assert FlashSchedules.scenario_for(s, ~D[2026-09-22]) == 11
      assert FlashSchedules.scenario_for(s, ~D[2026-09-29]) == 22
      assert FlashSchedules.scenario_for(s, ~D[2026-10-06]) == 33
      assert FlashSchedules.scenario_for(s, ~D[2026-10-13]) == 11
      assert FlashSchedules.scenario_for(s, ~D[2026-09-15]) == 33
    end
  end

  test "required_ready is ceil(80%) of joined players, at least 2 and the minimum" do
    assert FlashSchedules.required_ready(1, 2) == 2
    assert FlashSchedules.required_ready(2, 2) == 2
    assert FlashSchedules.required_ready(3, 2) == 3
    assert FlashSchedules.required_ready(5, 2) == 4
    assert FlashSchedules.required_ready(10, 2) == 8
    assert FlashSchedules.required_ready(15, 2) == 12
    assert FlashSchedules.required_ready(4, 6) == 6
  end

  describe "create_due_matches/1" do
    test "opens the lobby 48h before the start, once" do
      schedule = schedule(%{"mutator_keys" => ["empire_of_wealth"]})

      assert FlashSchedules.create_due_matches(DateTime.add(@start, -49 * 3600)) == []

      assert [%ScheduledMatch{} = match] = FlashSchedules.create_due_matches(DateTime.add(@start, -48 * 3600))
      assert match.schedule_id == schedule.id
      assert match.scheduled_start_at == @start
      assert match.status == "open"

      instance = Instances.get_instance(match.instance_id)
      assert instance.state == "open"
      assert instance.registration_status == :open
      assert instance.public

      assert instance.description =~ ~r/^Scheduled Flash match\./
      assert String.ends_with?(instance.description, "\n\n" <> rules())

      assert instance.game_data["game_mode_type"] == "ranked"
      assert instance.game_data["mutators"] == [%{"key" => "empire_of_wealth"}]
      assert instance.game_metadata["mutators"] == [%{"key" => "empire_of_wealth"}]
      # 270 systems / 6 / 2 factions.
      assert Enum.map(instance.factions, & &1.capacity) == [23, 23]

      assert FlashSchedules.create_due_matches(DateTime.add(@start, -3600)) == []
    end

    test "a custom description keeps the rules appended" do
      schedule(%{"description" => "Bring snacks."})
      [match] = FlashSchedules.create_due_matches(DateTime.add(@start, -3600))

      assert Instances.get_instance(match.instance_id).description == "Bring snacks.\n\n" <> rules()
    end

    test "disabled schedules create nothing" do
      schedule(%{"enabled" => false})
      assert FlashSchedules.create_due_matches(DateTime.add(@start, -3600)) == []
    end

    test "schedule validation rejects non-Flash maps and unknown mutators" do
      admin = fixture(:admin)

      assert {:error, changeset} =
               FlashSchedules.create_schedule(
                 %{
                   "name" => "Bad",
                   "weekday" => 9,
                   "start_time" => "20:00:00",
                   "scenario_ids" => [-1],
                   "mutator_keys" => ["not_a_mutator"],
                   "min_players" => 1
                 },
                 admin.id
               )

      errors = errors_on(changeset)
      assert errors[:weekday]
      assert errors[:scenario_ids]
      assert errors[:mutator_keys]
      assert errors[:min_players]
    end
  end

  describe "lobby" do
    setup do
      schedule()
      [match] = FlashSchedules.create_due_matches(DateTime.add(@start, -3600))
      %{match: match, instance: Instances.get_instance(match.instance_id)}
    end

    test "ready-up gates the start; unready players are removed when it starts", %{match: match, instance: instance} do
      [a, b, c, d, e] =
        [
          join_lobby(instance, "tetrarchy", player(1)),
          join_lobby(instance, "tetrarchy", player(2)),
          join_lobby(instance, "myrmezir", player(3)),
          join_lobby(instance, "myrmezir", player(4)),
          join_lobby(instance, "myrmezir", player(5))
        ]

      before_start = DateTime.add(@start, -60)
      lobby = FlashSchedules.lobby(instance.id, before_start)
      assert %{joined_count: 5, ready_count: 0, required_ready: 4, can_start: false} = lobby
      assert :before_start_time in lobby.blockers

      for p <- [a, b, c], do: {:ok, _} = FlashSchedules.set_ready(instance.id, p.account.id, true)

      assert {:error, :not_enough_ready} =
               FlashSchedules.start_match(instance.id, a.account.id, now: @start, async: false)

      {:ok, _} = FlashSchedules.set_ready(instance.id, d.account.id, true)

      assert {:error, :before_start_time} =
               FlashSchedules.start_match(instance.id, d.account.id, now: before_start, async: false)

      assert {:error, :not_ready} = FlashSchedules.start_match(instance.id, e.account.id, now: @start, async: false)

      assert {:error, :not_registered} =
               FlashSchedules.start_match(instance.id, player(8).account.id, now: @start, async: false)

      # Any ready player may start; e never readied up and is left out.
      assert {:ok, :started} = FlashSchedules.start_match(instance.id, d.account.id, now: @start, async: false)

      assert Instances.get_instance(instance.id).state == "running"
      assert Repo.get!(ScheduledMatch, match.id).status == "started"

      players = Registrations.list(instance.id)
      assert length(players) == 4
      assert Enum.all?(players, &(&1.state == "playing"))
      refute Enum.any?(players, &(&1.profile_id == e.profile.id))

      {:ok, :killed} = Instance.Manager.destroy(instance.id)

      # The #lfg result is pending once a victory is recorded, and names the
      # winning faction's players.
      assert FlashSchedules.unposted_results() == []

      ranking =
        instance.factions
        |> Enum.sort_by(&(&1.faction_ref != "myrmezir"))
        |> Enum.zip([12, 5])
        |> Enum.map(fn {f, vp} -> %{id: f.id, key: String.to_atom(f.faction_ref), victory_points: vp} end)

      {:ok, _} = Instances.record_victory(ranking, "victory_track")

      assert [pending] = FlashSchedules.unposted_results()

      assert %{winner: "myrmezir", winner_players: ["Pilot 3", "Pilot 4"], factions: [%{victory_points: 12}, _]} =
               FlashSchedules.result_data(pending)

      {:ok, _} = FlashSchedules.mark(pending, :result_posted_at)
      assert FlashSchedules.unposted_results() == []
    end

    test "one faction alone can't start", %{instance: instance} do
      a = join_lobby(instance, "tetrarchy", player(1))
      b = join_lobby(instance, "tetrarchy", player(2))
      for p <- [a, b], do: {:ok, _} = FlashSchedules.set_ready(instance.id, p.account.id, true)

      assert {:error, :single_faction} =
               FlashSchedules.start_match(instance.id, a.account.id, now: @start, async: false)
    end

    test "ready is only for players in the lobby", %{instance: instance} do
      outsider = player(9)
      assert {:error, :not_registered} = FlashSchedules.set_ready(instance.id, outsider.account.id, true)
      assert {:error, :not_scheduled} = FlashSchedules.set_ready(-1, outsider.account.id, true)
    end

    test "lobbies still unstarted 48h after the start close", %{match: match, instance: instance} do
      assert FlashSchedules.expire_stale_matches(DateTime.add(@start, 47 * 3600)) == []
      assert [%{status: "expired"}] = FlashSchedules.expire_stale_matches(DateTime.add(@start, 48 * 3600))

      assert Instances.get_instance(instance.id).state == "ended"
      assert Repo.get!(ScheduledMatch, match.id).status == "expired"
    end
  end

  describe "Discord scheduled events" do
    setup do
      schedule()
      [match] = FlashSchedules.create_due_matches(DateTime.add(@start, -48 * 3600))
      %{match: match, instance: Instances.get_instance(match.instance_id)}
    end

    test "the event is created with the lobby, pointing at it", %{match: match, instance: instance} do
      now = DateTime.add(@start, -48 * 3600)
      {:create, params, _match} = push(match, now)

      assert params.name == instance.name
      assert params.scheduled_start_time == @start
      # Flash scenario: 120 minutes of wall clock.
      assert params.scheduled_end_time == DateTime.add(@start, 120 * 60)
      # EXTERNAL event, GUILD_ONLY, located at the lobby.
      assert params.entity_type == 3
      assert params.privacy_level == 2
      assert params.channel_id == nil
      assert params.entity_metadata.location =~ "/portal/instance/#{instance.id}"

      assert params.description =~ "Ranked Flash match"
      assert params.description =~ "0 players registered · 0 ready · 2 more ready needed to start"
      assert params.description =~ "/portal/instance/#{instance.id}"
    end

    test "a lobby created after its start time gets no event", %{match: match} do
      # The scheduler was down and caught up inside the grace window;
      # Discord refuses an event that starts in the past.
      assert FlashEvent.plan(match, FlashSchedules.event_data(match, DateTime.add(@start, 60))) == :none
    end

    test "the event is only re-pushed when its player counts move", %{match: match, instance: instance} do
      now = DateTime.add(@start, -47 * 3600)
      {:create, _params, match} = push(match, now)

      # Nothing changed: no PATCH.
      assert {:none, _, match} = push(match, now)

      a = join_lobby(instance, "tetrarchy", player(1))
      join_lobby(instance, "myrmezir", player(2))

      {:modify, params, match} = push(match, now)
      assert params.status == 1
      assert params.description =~ "2 players registered · 0 ready · 2 more ready needed to start"

      {:ok, _} = FlashSchedules.set_ready(instance.id, a.account.id, true)
      {:modify, params, match} = push(match, now)
      assert params.description =~ "2 players registered · 1 ready · 1 more ready needed to start"

      assert {:none, _, _} = push(match, now)
    end

    test "the event goes ACTIVE at start and COMPLETED on a victory", %{match: match, instance: instance} do
      {:create, _params, match} = push(match, DateTime.add(@start, -48 * 3600))

      {:ok, match} =
        match |> ScheduledMatch.changeset(%{status: "started", started_at: @start}) |> Repo.update()

      {:modify, params, match} = push(match, @start)
      assert params.status == 2
      assert params.description =~ "The match is under way"

      {:ok, _} = Repo.insert(Victory.changeset(%Victory{}, %{instance_id: instance.id, victory_type: "win_on_time"}))

      # Discord only allows SCHEDULED → ACTIVE → COMPLETED, so a victory
      # while the event is still ACTIVE completes it in one step.
      {:modify, params, match} = push(match, DateTime.add(@start, 3600))
      assert params.status == 3
      assert params.description =~ "has ended"

      # Once finished, the event is never touched again.
      assert {:none, _, _} = push(match, DateTime.add(@start, 7200))
    end

    test "a victory before the event ever went ACTIVE advances one step at a time", %{
      match: match,
      instance: instance
    } do
      {:create, _params, match} = push(match, DateTime.add(@start, -48 * 3600))
      {:ok, match} = match |> ScheduledMatch.changeset(%{status: "started", started_at: @start}) |> Repo.update()
      {:ok, _} = Repo.insert(Victory.changeset(%Victory{}, %{instance_id: instance.id, victory_type: "win_on_time"}))

      {:modify, %{status: 2}, match} = push(match, DateTime.add(@start, 60))
      {:modify, %{status: 3}, _match} = push(match, DateTime.add(@start, 120))
    end

    test "an expired lobby cancels its event", %{match: match} do
      {:create, _params, match} = push(match, DateTime.add(@start, -48 * 3600))

      [_expired] = FlashSchedules.expire_stale_matches(DateTime.add(@start, 48 * 3600))
      match = Repo.get!(ScheduledMatch, match.id)

      {:modify, params, _match} = push(match, DateTime.add(@start, 48 * 3600))
      assert params.status == 4
      assert params.description =~ "Cancelled"
    end

    test "only lobbies that can still get an event are synced", %{match: match} do
      before_start = DateTime.add(@start, -47 * 3600)
      assert synced(before_start) == [match.id]

      # Past its start and still without an event: nothing left to do.
      assert synced(DateTime.add(@start, 60)) == []

      {:ok, match} = FlashSchedules.record_event(match, %{discord_event_id: "1", discord_event_status: "scheduled"})
      assert synced(DateTime.add(@start, 60)) == [match.id]

      {:ok, _} = FlashSchedules.record_event(match, %{discord_event_status: "completed"})
      assert synced(before_start) == []
    end

    test "event_url needs a configured guild" do
      assert FlashEvent.event_url(nil, 123) == nil
      assert FlashEvent.event_url("55", 123) == "https://discord.com/events/123/55"
      # No community guild configured in test.
      assert FlashEvent.event_url("55") == nil
    end
  end

  describe "#lfg posts" do
    test "announcement embed carries the start time, mode, factions and lobby link" do
      schedule(%{"mutator_keys" => ["empire_of_wealth"]})
      [match] = FlashSchedules.create_due_matches(DateTime.add(@start, -3600))

      embed = match |> FlashSchedules.announcement_data() |> FlashAnnouncer.announcement_embed()

      assert embed.title =~ "Tuesday Flash"
      assert embed.description =~ "<t:#{DateTime.to_unix(@start)}:F>"
      assert embed.url =~ "/portal/instance/#{match.instance_id}"
      fields = Map.new(embed.fields, &{&1.name, &1.value})
      assert fields["Mode"] == "Ranked"
      assert fields["Mutators"] == "Empire of Wealth"
      assert fields["Factions"] =~ "23 seats"
      # No guild configured in test, so no RSVP link on the embed.
      refute Map.has_key?(fields, "Discord event")

      embed =
        %{FlashSchedules.announcement_data(match) | event_url: "https://discord.com/events/1/2"}
        |> FlashAnnouncer.announcement_embed()

      assert Map.new(embed.fields, &{&1.name, &1.value})["Discord event"] =~ "https://discord.com/events/1/2"

      # Posting without a running bot is a no-op the scheduler retries later.
      assert FlashAnnouncer.post(embed) == :skipped
    end

    test "result embed names the winner, its players and the standings" do
      embed =
        FlashAnnouncer.result_embed(%{
          instance_id: 7,
          name: "Tuesday Flash · Tue Jan 8",
          map_name: "Citadel",
          ranked: true,
          victory_type: "victory_track",
          winner: "synelle",
          winner_players: ["Alrua", "Tremes"],
          factions: [
            %{key: "synelle", rank: 1, victory_points: 14},
            %{key: "ark", rank: 2, victory_points: 6}
          ]
        })

      assert embed.title =~ "wins Tuesday Flash"
      fields = Map.new(embed.fields, &{&1.name, &1.value})
      assert fields["Winning players"] == "Alrua, Tremes"
      assert fields["Final standings"] =~ "14 VP"
      assert fields["Final standings"] =~ "6 VP"
    end
  end
end
