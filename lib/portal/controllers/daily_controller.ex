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

  defp objective_view(nil), do: nil
  defp objective_view(o), do: %{key: o.key, name: o.name, description: o.description}

  defp mutator_view(nil), do: nil
  defp mutator_view(m), do: %{key: m.key, name: m.name, polarity: m.polarity}
end
