defmodule Portal.BotAssignmentController do
  @moduledoc """
  Read-only endpoint for the bot harness to fetch its current roster.

  Authenticated via shared secret (`Portal.Plug.HarnessSecret`). Returns
  the runnable assignments with a freshly-minted JWT per bot — the
  harness uses the JWT to connect directly to the socket, skipping the
  Argon2 cost of a per-session login.

  Response shape:

      {
        "data": [
          {
            "bot_id":         "stressbot-1",
            "account_id":     11,
            "profile_id":     3,
            "instance_id":    1,
            "faction_id":     1,
            "jwt":            "eyJhbGciOi...",
            "refresh_token":  "eyJhbGciOi...",
            "policy":         "RcBot.Policy.Dumb",
            "bursts_total":   4,
            "inter_burst_ms_min": 2000,
            "inter_burst_ms_max": 8000
          },
          ...
        ]
      }

  `jwt` is a short-lived access token (4h TTL); `refresh_token` is the
  long-lived (30d) credential the harness POSTs to /api/auth/refresh to
  swap for a fresh access token without re-fetching the assignment.
  """

  use Portal, :controller

  alias RC.Accounts.Profile
  alias RC.BotAssignments

  def index(conn, _params) do
    entries =
      BotAssignments.list_runnable()
      |> Enum.map(&to_harness_entry/1)
      |> Enum.reject(&is_nil/1)

    json(conn, %{data: entries})
  end

  defp to_harness_entry(assignment) do
    account = assignment.account

    with profile when not is_nil(profile) <- profile_for_account(account.id),
         registration when not is_nil(registration) <-
           registration_for(profile.id, assignment.faction_id) do
      {:ok, jwt, _claims} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")

      {:ok, refresh, _claims} =
        RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      %{
        bot_id: bot_id_for(account),
        account_id: account.id,
        profile_id: profile.id,
        instance_id: assignment.instance_id,
        faction_id: assignment.faction_id,
        jwt: jwt,
        refresh_token: refresh,
        # Pre-fetched here so the harness doesn't need to hit
        # /api/instances/:iid/registrations (which is gated by
        # group_resource_authorization and would refuse a bot
        # account on a bot-only instance).
        registration_token: registration.token,
        policy: assignment.policy,
        bursts_total: assignment.bursts_total,
        inter_burst_ms_min: assignment.inter_burst_ms_min,
        inter_burst_ms_max: assignment.inter_burst_ms_max
      }
    else
      _ ->
        require Logger

        Logger.warning(
          "bot_assignment #{assignment.id} skipped: missing profile or registration"
        )

        nil
    end
  end

  defp registration_for(profile_id, faction_id) do
    import Ecto.Query

    from(r in RC.Instances.Registration,
      where: r.profile_id == ^profile_id and r.faction_id == ^faction_id,
      limit: 1
    )
    |> RC.Repo.one()
  end

  defp profile_for_account(account_id) do
    import Ecto.Query

    from(p in Profile, where: p.account_id == ^account_id, limit: 1)
    |> RC.Repo.one()
  end

  # Stable harness-side identifier. Falls back to account_id if name is
  # missing — never returns nil.
  defp bot_id_for(account) do
    case account.name do
      nil -> "account-#{account.id}"
      "" -> "account-#{account.id}"
      name -> name <> "-#{account.id}"
    end
  end
end
