defmodule Portal.DiscordController do
  @moduledoc """
  Discord linking endpoints exposed to the game web.

  Currently a single action: mint a short-lived one-time code that
  the authenticated user can take to Discord and exchange via the
  `/link` slash command. The actual write to `accounts.discord_id`
  happens in the bot path (`RC.Accounts.Discord.consume_code/2`),
  not here — see docs/discord-bot.md.

  Unlinking is exposed only through the bot (`/unlink` with button
  confirmation) and not here, deliberately: it keeps the unlink
  audit trail in one place and avoids dual-channel state changes.
  """

  use Portal, :controller

  require Logger

  alias RC.Accounts.Discord

  action_fallback(Portal.FallbackController)

  # Rate-limit on the link-code mint. The plug keys off client IP
  # (see Portal.Plug.RateLimit). 30 per hour is generous for any
  # legitimate use — even with retries a user generates one or two
  # codes — and bounds abuse from a single source. Sits in the
  # same shape as the password-reset throttle on AccountController.
  plug Portal.Plug.RateLimit,
       [bucket: "discord_link_code", limit: 30, window_ms: 3_600_000]
       when action in [:create_link_code]

  @doc """
  POST /api/discord/link-code

  Mints a code for `conn.private.guardian_default_resource` (the
  authenticated account). Best-effort expires any prior unconsumed
  codes for the account so there's only one live code at a time.

  Returns 201 with:
      %{"code" => "K7QF-93MR", "expires_in_seconds" => 300}
  """
  def create_link_code(conn, _params) do
    account_id = conn.private.guardian_default_resource.id

    case Discord.generate_code(account_id) do
      {:ok, code} ->
        conn
        |> put_status(:created)
        |> json(%{code: code, expires_in_seconds: 300})

      {:error, changeset} ->
        Logger.error(
          "[Portal.DiscordController] failed to generate link code for account #{account_id}: " <>
            inspect(changeset)
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{message: :code_generation_failed})
    end
  end
end
