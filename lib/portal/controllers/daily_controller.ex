defmodule Portal.DailyController do
  @moduledoc """
  Harness-secret-gated endpoints for the daily-challenge MVP. Lets a developer
  boot today's daily into the live server and read its economy back to confirm
  it's ticking. Not the eventual player-facing surface — see
  docs/daily-challenge.md.
  """
  use Portal, :controller

  require Logger

  # POST /api/harness/daily/start — generate + boot today's daily, return its
  # id and an initial economy snapshot.
  def start(conn, _params) do
    case Daily.Boot.boot_today() do
      {:ok, summary} ->
        conn
        |> put_status(200)
        |> json(%{
          booted: true,
          instance_id: summary.instance_id,
          player_id: summary.player_id,
          date: summary.date,
          objective: objective_view(summary.objective),
          mutators: Enum.map(summary.mutators, &mutator_view/1),
          status: Daily.Boot.status(summary.instance_id, summary.player_id)
        })

      {:error, reason} ->
        conn |> put_status(500) |> json(%{booted: false, error: inspect(reason)})
    end
  end

  # GET /api/harness/daily/:iid/status/:pid — re-read a running daily's
  # economy (poll this to watch resources tick up).
  def status(conn, %{"iid" => iid, "pid" => pid}) do
    json(conn, Daily.Boot.status(String.to_integer(iid), String.to_integer(pid)))
  end

  # POST /api/daily/play — JWT-authenticated. Boots a fresh persisted daily
  # instance for the caller's profile and returns the join payload the SPA's
  # game store consumes (same shape as GameController.join/2), so the player
  # goes straight to /game.
  def play(conn, %{"profile_id" => profile_id}) do
    account = Guardian.Plug.current_resource(conn)

    case RC.Accounts.get_profile(profile_id) do
      %RC.Accounts.Profile{account_id: aid} = profile when aid == account.id ->
        case Daily.Boot.boot_persisted(profile) do
          {:ok, info} ->
            conn
            |> put_status(200)
            |> json(%{
              instance: info.instance_id,
              faction: info.faction_id,
              profile: info.profile_id,
              registration_token: info.registration_token,
              user_token: Guardian.Plug.current_token(conn)
            })

          {:error, reason} ->
            Logger.error("daily play boot failed: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{message: :daily_boot_failed})
        end

      _ ->
        conn |> put_status(403) |> json(%{message: :profile_not_owned})
    end
  end

  # GET /api/daily/today — read-only preview of today's daily (objective,
  # mutators, system archetype) for the daily page. No boot.
  def today(conn, _params) do
    definition = Daily.definition_for(Date.utc_today())
    [system] = definition.game_data["systems"]

    json(conn, %{
      date: definition.date,
      objective: objective_view(definition.objective),
      mutators: Enum.map(definition.mutators, &mutator_view/1),
      system: %{archetype: system["type"]}
    })
  end

  # GET /api/daily/leaderboard?date=&profile_id= — ranked scores for a day
  # (default today), plus the given profile's own best/rank if provided.
  def leaderboard(conn, params) do
    date = params["date"] || Date.to_iso8601(Date.utc_today())
    definition = Daily.definition_for(date)

    you =
      case params["profile_id"] do
        pid when is_binary(pid) and pid != "" -> Daily.player_rank(pid, date)
        _ -> nil
      end

    json(conn, %{
      date: date,
      objective: objective_view(definition.objective),
      entries: Daily.leaderboard(date),
      you: you
    })
  end

  defp objective_view(nil), do: nil
  defp objective_view(o), do: %{key: o.key, name: o.name, description: o.description}

  defp mutator_view(nil), do: nil

  defp mutator_view(m),
    do: %{key: m.key, name: m.name, polarity: m.polarity, description: m.description}
end
