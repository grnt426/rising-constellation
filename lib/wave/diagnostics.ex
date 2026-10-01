defmodule Wave.Diagnostics do
  @moduledoc """
  The admin health readout of a live Rebel Defense instance: is the Warlord
  running and keeping up, what it has asked the engine for and how often the
  engine said no, how its attempts turned out, which agents have been sitting
  on an order for too long, and its recent behaviour log.

  Served by `GET /api/instances/:iid/wave/diagnostics` (admins only) and
  rendered by the portal's Rebellion diagnostics page. Every live read degrades
  to nil, so the page still loads while the instance is down or mid-boot.
  """

  import Ecto.Query

  alias RC.Instances.InstanceEvent
  alias Wave.Warlord

  # An agent that has been on one order this long (game time, measured from
  # dispatch, or from entering its stage when it was never dispatched) is
  # flagged. At
  # Legacy speed 120 ut is six real hours: a lane crossing plus an action.
  @stale_ut 120.0
  @event_limit 60

  def read(instance_id, game_data \\ %{}) when is_integer(instance_id) do
    warlord = call(instance_id, :wave, :master, :get_state)
    time = call(instance_id, :time, :master, :get_state)
    bot = warlord && warlord.player_id && call(instance_id, :player, warlord.player_id, :get_state)
    galaxy = call(instance_id, :galaxy, :master, :get_state)

    summary = warlord && Warlord.summary(warlord)
    names = galaxy && Map.new(galaxy.stellar_systems, &{&1.id, &1.name})

    %{
      instance_id: instance_id,
      live: warlord != nil,
      stale_after_ut: @stale_ut,
      clock: clock_view(time, warlord, start_ut(instance_id, game_data)),
      warlord: summary && warlord_view(summary),
      rebellion: bot && player_view(bot),
      orders: summary && orders_view(summary.orders),
      outcomes: summary && outcomes_view(summary.stats),
      refusals: summary && refusals_view(summary.stats),
      agents: warlord && agents_view(warlord, bot, names || %{}),
      sectors: galaxy && sectors_view(galaxy, warlord && warlord.bot_faction),
      events: recent_events(instance_id)
    }
  end

  # --- clock -------------------------------------------------------------------

  # The Warlord charges every tick's elapsed game time to `elapsed`, so a gap
  # between it and the match clock means passes were skipped or the Warlord
  # was restarted from an older snapshot.
  defp clock_view(time, warlord, start_ut) do
    now = time && time.now.value - start_ut

    %{
      running: match?(%{is_running: true}, time),
      speed: time && time.speed,
      game_ut: round1(now),
      warlord_ut: warlord && round1(warlord.elapsed),
      lag_ut: now && warlord && round1(now - warlord.elapsed)
    }
  end

  defp warlord_view(summary) do
    Map.take(summary, [
      :bot_faction,
      :player_id,
      :match_day,
      :next_hire_in_ut,
      :scale_players,
      :ceilings,
      :training_dummy,
      :intel_known,
      :gauges,
      :perf,
      :telemetry
    ])
  end

  defp player_view(player) do
    %{
      id: player.id,
      name: player.name,
      is_active: player.is_active,
      is_bankrupt: player.is_bankrupt,
      credit: round0(player.credit.value),
      technology: round0(player.technology.value),
      ideology: round0(player.ideology.value),
      systems: length(player.stellar_systems),
      dominions: length(player.dominions),
      agents: length(player.characters),
      deck: length(player.character_deck)
    }
  end

  # --- orders and outcomes -------------------------------------------------------

  defp orders_view(orders) do
    orders
    |> Enum.map(fn {kind, entry} ->
      total = entry.ok + entry.failed

      %{
        kind: kind,
        ok: entry.ok,
        failed: entry.failed,
        success_rate: rate(entry.ok, total),
        last_ok_ut: round1(entry.last_ok_ut),
        last_failed_ut: round1(entry.last_failed_ut),
        last_reason: entry.last_reason,
        reasons: entry.reasons |> Enum.sort_by(fn {_, n} -> -n end) |> Enum.map(fn {r, n} -> %{reason: r, count: n} end)
      }
    end)
    |> Enum.sort_by(& &1.kind)
  end

  # What became of the orders the engine accepted.
  defp outcomes_view(stats) do
    get = &Map.get(stats, &1, 0)

    [
      outcome("Colonisation", get.(:dispatched), [{"colonised", get.(:colonised)}]),
      outcome("Dominion capture", get.(:captures_attempted), [
        {"captured", get.(:captured)},
        {"failed", get.(:capture_failed)},
        {"aborted", get.(:capture_aborted)}
      ]),
      outcome(
        "Erased strikes",
        get.(:removals_attempted) + get.(:sabotages_attempted) + get.(:infiltrations_attempted),
        [{"resolved", get.(:erased_resolved)}, {"aborted", get.(:erased_aborted)}]
      ),
      outcome("Erased removals", get.(:removals_attempted), [{"succeeded", get.(:removals_succeeded)}]),
      outcome("Erased practice", get.(:erased_practice), [
        {"resolved", get.(:practice_resolved)},
        {"aborted", get.(:practice_aborted)}
      ]),
      outcome("Destabilization", get.(:destabs_attempted), [
        {"resolved", get.(:destab_resolved)},
        {"aborted", get.(:destab_aborted)},
        {"happiness taken", get.(:destab_penalty)}
      ]),
      outcome("Destabilization practice", get.(:destab_practice), [
        {"resolved", get.(:destab_practice_resolved)},
        {"aborted", get.(:destab_practice_aborted)}
      ]),
      outcome("Seduction", get.(:seductions_attempted), [
        {"converted", get.(:seductions_succeeded)},
        {"failed", get.(:seductions_failed)},
        {"aborted", get.(:seductions_aborted)}
      ]),
      outcome("Converts", nil, [
        {"adopted", get.(:converts_adopted)},
        {"Navarchs employed", get.(:converts_employed)}
      ]),
      outcome("Siderian movement", nil, [
        {"evasion hops", get.(:evasions)},
        {"scouting trips", get.(:siderian_scouts)}
      ]),
      outcome("Agents lost", nil, [
        {"Siderians", get.(:siderians_lost)},
        {"Erased", get.(:erased_lost)}
      ])
    ]
  end

  defp outcome(label, attempted, results) do
    %{
      label: label,
      attempted: attempted,
      results:
        Enum.map(results, fn {name, n} ->
          %{name: name, count: n, share: if(attempted, do: rate(n, attempted))}
        end)
    }
  end

  defp refusals_view(stats) do
    stats
    |> Map.get(:refused, %{})
    |> Enum.map(fn {reason, n} -> %{reason: reason, count: n} end)
    |> Enum.sort_by(&(-&1.count))
  end

  # --- agents --------------------------------------------------------------------

  # Every agent the Warlord tracks, joined to the engine's own view of it, oldest
  # stage first. Engine-side agents the Warlord does not track are listed too:
  # they are either mid-hire or leaked, and a leaked agent is never re-ordered.
  defp agents_view(warlord, bot, names) do
    engine = if bot, do: Map.new(bot.characters, &{&1.id, &1}), else: %{}
    now = warlord.elapsed

    reserve =
      Map.new(Map.get(warlord, :convert_navarchs, %{}), fn {id, since} -> {id, %{stage: :reserve, since: since}} end)

    tracked =
      [
        {"Navarch", warlord.colonisers},
        {"Reserve Navarch", reserve},
        {"Siderian", Map.get(warlord, :siderians, %{})},
        {"Erased", Map.get(warlord, :erased, %{})}
      ]
      |> Enum.flat_map(fn {role, roster} ->
        Enum.map(roster, fn {id, entry} -> agent_row(label(role, entry), id, entry, Map.get(engine, id), now, names) end)
      end)

    tracked_ids = MapSet.new(tracked, & &1.id)
    dummy_id = Map.get(warlord, :training_dummy)

    untracked =
      engine
      |> Map.values()
      |> Enum.reject(&MapSet.member?(tracked_ids, &1.id))
      |> Enum.map(fn character ->
        %{
          id: character.id,
          role: if(character.id == dummy_id, do: "Training Navarch", else: "Untracked #{character.type}"),
          name: character.name,
          stage: nil,
          duty: nil,
          theatre: nil,
          action: nil,
          missing: false,
          target: nil,
          target_name: nil,
          age_ut: nil,
          stale: false,
          engine: engine_view(character, names)
        }
      end)

    Enum.sort_by(tracked, &(-(&1.age_ut || 0))) ++ untracked
  end

  # A Siderian's trade and a convert's origin, next to its kind.
  defp label("Siderian", entry), do: "Siderian · #{Warlord.siderian_role(entry)}" <> convert_suffix(entry)
  defp label(role, entry), do: role <> convert_suffix(entry)

  defp convert_suffix(entry), do: if(Map.get(entry, :converted, false), do: " (convert)", else: "")

  defp agent_row(role, id, entry, character, now, names) do
    since = Map.get(entry, :dispatched_at) || Map.get(entry, :since) || now
    stage = Map.get(entry, :stage)
    age = now - since
    target = Map.get(entry, :target)

    %{
      id: id,
      role: role,
      name: character && character.name,
      stage: stage,
      duty: Map.get(entry, :duty),
      theatre: Map.get(entry, :theatre),
      action: Map.get(entry, :action),
      target: target,
      target_name: target && Map.get(names, target),
      age_ut: round1(age),
      # Idle agents waiting on a hire or a target are not stuck orders.
      stale: stage not in [nil, :idle] and age > @stale_ut,
      engine: character && engine_view(character, names),
      missing: character == nil
    }
  end

  defp engine_view(character, names) do
    queue =
      case character.actions do
        nil -> 0
        %{queue: queue} -> queue |> Queue.to_list() |> length()
        _ -> 0
      end

    %{
      status: character.status,
      action_status: character.action_status,
      system: character.system,
      system_name: Map.get(names, character.system),
      queued_actions: queue
    }
  rescue
    _ -> %{status: Map.get(character, :status), action_status: Map.get(character, :action_status)}
  end

  # --- sectors -----------------------------------------------------------------------

  defp sectors_view(galaxy, bot_faction) do
    owners = Enum.frequencies_by(galaxy.sectors, & &1.owner)

    %{
      total: length(galaxy.sectors),
      rebel: Map.get(owners, bot_faction, 0),
      by_owner: Enum.map(owners, fn {owner, n} -> %{owner: owner, count: n} end)
    }
  end

  # --- behaviour log -----------------------------------------------------------------

  defp recent_events(instance_id) do
    from(e in InstanceEvent,
      where: e.instance_id == ^instance_id and like(e.kind, "wave_%"),
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: @event_limit
    )
    |> RC.Repo.all()
    |> Enum.map(fn event ->
      %{
        id: event.id,
        kind: event.kind,
        character_id: event.character_id,
        system_id: event.system_id,
        inserted_at: event.inserted_at,
        payload:
          case Jason.decode(event.payload || "") do
            {:ok, payload} -> payload
            _ -> event.payload
          end
      }
    end)
  rescue
    _ -> []
  end

  # Time.now starts at the scenario's year on the game calendar (see
  # Instance.Manager); the match clock is the distance from there.
  defp start_ut(instance_id, game_data) do
    calendar = Data.Querier.one(Data.Game.Calendar, instance_id, :tetrarch)
    (game_data["date"] || 0) * calendar.days_in_month * calendar.months_in_year
  rescue
    _ -> 0
  end

  # --- helpers -------------------------------------------------------------------------

  defp call(instance_id, type, id, message) do
    case Game.call_no_log(instance_id, type, id, message, 1, 3_000) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp rate(_n, 0), do: nil
  defp rate(n, total), do: Float.round(n / total, 3)

  defp round1(value) when is_number(value), do: Float.round(value / 1, 1)
  defp round1(_), do: nil

  defp round0(value) when is_number(value), do: round(value)
  defp round0(_), do: nil
end
