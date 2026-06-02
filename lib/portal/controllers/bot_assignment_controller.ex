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
            "policy":         "RcBot.Policy.Dumb",
            "bursts_total":   4,
            "inter_burst_ms_min": 2000,
            "inter_burst_ms_max": 8000
          },
          ...
        ]
      }
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

    case profile_for_account(account.id) do
      nil ->
        # Bot account without a profile is misconfigured; skip rather
        # than crash the whole response. The dashboard should surface
        # this — for now we log and drop.
        require Logger

        Logger.warning(
          "bot_assignment #{assignment.id} skipped: account #{account.id} has no profile"
        )

        nil

      profile ->
        {:ok, jwt, _claims} = RC.Guardian.encode_and_sign(account, %{})

        %{
          bot_id: bot_id_for(account),
          account_id: account.id,
          profile_id: profile.id,
          instance_id: assignment.instance_id,
          faction_id: assignment.faction_id,
          jwt: jwt,
          policy: assignment.policy,
          bursts_total: assignment.bursts_total,
          inter_burst_ms_min: assignment.inter_burst_ms_min,
          inter_burst_ms_max: assignment.inter_burst_ms_max
        }
    end
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
