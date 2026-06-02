defmodule RcBot.Auth do
  @moduledoc """
  Thin HTTP client for the parts of the game's REST API a bot needs to
  enter a game: identity login (returns a JWT) and instance registration
  (returns a per-instance registration token used as the channel-join
  credential).
  """

  require Logger

  @doc """
  POST /api/auth/identity/callback — returns `{:ok, jwt}` or `{:error, term}`.

  The endpoint also sets cookies for the SPA flow; bots ignore those and
  use the JWT in the response body directly.
  """
  def login(email, password) do
    url = base_http() <> "/api/auth/identity/callback"

    # The endpoint is fronted by Ueberauth.Strategy.Identity with
    # `param_nesting: "account"` — payload must be nested under "account".
    case Req.post(url, json: %{account: %{email: email, password: password}}, retry: false) do
      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 200, body: %{"jwt" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:login_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc """
  Joins the bot's profile to an instance/faction and returns the
  registration token used as the PlayerChannel-join credential.

  Two HTTP calls: the POST creates (or no-ops on) the registration but only
  acknowledges; the GET /instances/:iid/registrations is where the server
  surfaces the caller's own token. We tolerate `:conflict` on POST so a
  re-run with an already-registered bot still proceeds to the token fetch.
  """
  def register(jwt, profile_id, instance_id, faction_id) do
    with :ok <- post_registration(jwt, profile_id, instance_id, faction_id),
         {:ok, token} <- fetch_token(jwt, instance_id, profile_id) do
      {:ok, token}
    end
  end

  defp post_registration(jwt, profile_id, instance_id, faction_id) do
    url = base_http() <> "/api/registrations/profile/#{profile_id}"
    body = %{instance_id: instance_id, faction_id: faction_id}

    case Req.post(url, json: body, auth: {:bearer, jwt}, retry: false) do
      {:ok, %{status: status}} when status in 200..201 ->
        :ok

      # 409 = already_registered. Bot is idempotent — re-running should
      # still let it proceed to the token fetch.
      {:ok, %{status: 409}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:registration_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp fetch_token(jwt, instance_id, profile_id) do
    url = base_http() <> "/api/instances/#{instance_id}/registrations"

    case Req.get(url, auth: {:bearer, jwt}, retry: false) do
      {:ok, %{status: 200, body: %{"data" => entries}}} when is_list(entries) ->
        extract_token(entries, profile_id)

      {:ok, %{status: 200, body: entries}} when is_list(entries) ->
        extract_token(entries, profile_id)

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_fetch_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp extract_token(entries, profile_id) do
    # Response shape is `[%{"id" => reg_id, "profile" => %{"id" => pid, ...},
    # "token" => "..."}, ...]`. The "token" field is only present on the
    # caller's own registration entries (RegistrationView gates it on
    # account_id match).
    case Enum.find(entries, fn e -> get_in(e, ["profile", "id"]) == profile_id end) do
      %{"token" => token} when is_binary(token) ->
        {:ok, token}

      nil ->
        {:error, {:no_registration_for_profile, profile_id, entries}}

      _entry_without_token ->
        {:error, {:no_token_for_caller, profile_id}}
    end
  end

  defp base_http, do: Application.fetch_env!(:rc_bot, :target_http)
end
