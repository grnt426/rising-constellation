defmodule Portal.BotControlController do
  @moduledoc """
  Global fleet on/off control for stress-test bots.

  Two endpoints, very different threat models:

    * `GET /api/harness/bot-control/state` — read-only, harness-secret
      gated. The orchestrator polls this on every `:wake` tick to
      decide whether to spawn the next session. No auth burden on the
      hot path beyond the constant-time secret compare.

    * `PUT /api/admin/bot-control/state` — admin-only, JWT + admin
      role. Writes the new state. Accepts `{"enabled": true|false}`.
  """

  use Portal, :controller

  def state(conn, _params) do
    json(conn, %{enabled: RC.BotControl.enabled?()})
  end

  def set_state(conn, %{"enabled" => raw}) do
    case parse_bool(raw) do
      {:ok, enabled} ->
        account_id = conn.private.guardian_default_resource.id
        :ok = RC.BotControl.set_enabled(enabled, account_id)
        json(conn, %{enabled: enabled})

      :error ->
        conn |> put_status(400) |> json(%{error: "enabled must be true/false"})
    end
  end

  def set_state(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing :enabled"})
  end

  defp parse_bool(true), do: {:ok, true}
  defp parse_bool(false), do: {:ok, false}
  defp parse_bool("true"), do: {:ok, true}
  defp parse_bool("false"), do: {:ok, false}
  defp parse_bool(_), do: :error
end
