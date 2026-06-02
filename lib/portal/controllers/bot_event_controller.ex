defmodule Portal.BotEventController do
  @moduledoc """
  Lifecycle-event sink for the bot harness. Bots POST self-observations
  here (login attempt outcomes, burst boundaries, sleep windows,
  disconnect reasons) that the rc server can't see directly.

  Hard-gated on `account.is_bot == true` — a real player's JWT cannot
  write to this table. Best-effort: a failed insert never blocks the
  bot, we just log and return 204 anyway.
  """

  use Portal, :controller

  require Logger

  @max_event_name_len 64
  @max_reason_len 256

  def create(conn, params) do
    account = conn.private.guardian_default_resource

    cond do
      not match?(%RC.Accounts.Account{is_bot: true}, account) ->
        conn |> put_status(403) |> json(%{message: :not_a_bot})

      not is_binary(params["event_name"]) ->
        conn |> put_status(400) |> json(%{message: :missing_event_name})

      true ->
        attrs = %{
          account_id: account.id,
          profile_id: parse_int(params["profile_id"]),
          instance_id: parse_int(params["instance_id"]),
          event_name: String.slice(params["event_name"], 0, @max_event_name_len),
          status: normalize_status(params["status"]),
          reason: params["reason"] && String.slice(params["reason"], 0, @max_reason_len),
          channel: params["channel"] || "lifecycle"
        }

        :ok = RC.BotMonitoring.record_lifecycle(attrs)

        send_resp(conn, :no_content, "")
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp normalize_status(s) when s in ["ok", "error", "info"], do: s
  defp normalize_status(_), do: "info"
end
