defmodule RC.Guardian do
  use Guardian, otp_app: :rc

  alias RC.Accounts.Account

  def subject_for_token(%{id: account_id}, _claims) do
    {:ok, to_string(account_id)}
  end

  def subject_for_token(_, _) do
    {:error, :no_resource_id}
  end

  # Embed the current `token_version` as the "tv" claim on every new token.
  # `resource_from_claims/1` rejects tokens whose "tv" doesn't match the
  # account row, giving us per-account revocation on logout / password
  # change / ban via `RC.Accounts.invalidate_sessions/1`.
  def build_claims(claims, %Account{token_version: tv}, _opts) do
    {:ok, Map.put(claims, "tv", tv)}
  end

  def build_claims(claims, _resource, _opts), do: {:ok, claims}

  def resource_from_claims(%{"sub" => account_id} = claims) do
    case RC.Accounts.get_account(account_id) do
      nil ->
        {:error, :no_claims_sub}

      account ->
        with :ok <- check_status(account),
             :ok <- check_token_version(account, claims) do
          {:ok, account}
        end
    end
  end

  def resource_from_claims(_claims), do: {:error, :no_claims_sub}

  # Defensive: callers (LiveView mounts) used to pattern-match {:ok, ...}
  # directly, which crashed on expired/invalid sessions. Return nil instead
  # so callers can react gracefully (redirect to login, etc.).
  def resource_from_session(session) do
    case session["guardian_default_token"] do
      nil ->
        nil

      token ->
        case Guardian.resource_from_token(__MODULE__, token) do
          {:ok, user, _guardian} -> user
          {:error, _} -> nil
        end
    end
  end

  defp check_status(%Account{status: :active}), do: :ok
  defp check_status(%Account{}), do: {:error, :account_inactive}

  # Reject when the embedded "tv" claim doesn't match the account's current
  # token_version. Tokens issued before this field existed carry no "tv"
  # claim and are accepted iff the account is still at version 0 (the
  # default) — the first logout / password change / ban bumps the version
  # and immediately invalidates them.
  defp check_token_version(%Account{token_version: tv}, %{"tv" => claim_tv}) do
    if tv == claim_tv, do: :ok, else: {:error, :token_revoked}
  end

  defp check_token_version(%Account{token_version: 0}, _claims), do: :ok
  defp check_token_version(%Account{}, _claims), do: {:error, :token_revoked}
end
