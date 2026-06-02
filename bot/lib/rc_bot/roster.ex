defmodule RcBot.Roster do
  @moduledoc """
  Source of truth for "which bots exist + what game they're in." Queries
  the rc server's `/api/harness/bot-assignments` endpoint, authenticated
  via shared secret. Cached briefly so the orchestrator can poll
  cheaply.

  The endpoint returns a freshly-minted JWT per bot, so the harness
  never sees plaintext credentials and never hits the Argon2 login
  path. JWTs are valid for the rc app's standard token lifetime (24h);
  bots that outlive their JWT will fail to connect and the orchestrator
  will refetch on the next cycle.
  """

  require Logger

  @cache_ttl_ms 30_000

  @doc """
  Return the current roster from the server (or cached copy if
  recent). Each entry is a map with string keys, suitable for direct
  pass-through to `RcBot.Fleet.start_bot/1` (with atom-key conversion).
  Returns `[]` if the endpoint is unreachable or unauthorised.
  """
  def all do
    case fetch() do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  @doc """
  Force-refresh the cache (e.g. after a dashboard edit).
  """
  def refresh do
    :persistent_term.erase(__MODULE__)
    all()
  end

  def size, do: length(all())

  # ── Internals ───────────────────────────────────────────────────────

  defp fetch do
    case :persistent_term.get(__MODULE__, nil) do
      {entries, expires_at_ms} when is_integer(expires_at_ms) ->
        if System.system_time(:millisecond) < expires_at_ms do
          {:ok, entries}
        else
          fetch_remote()
        end

      _ ->
        fetch_remote()
    end
  end

  defp fetch_remote do
    url = base_http() <> "/api/harness/bot-assignments"
    secret = harness_secret()

    if is_nil(secret) do
      Logger.warning("RcBot.Roster: no RC_BOT_HARNESS_SECRET set; refusing to fetch")
      {:error, :no_secret}
    else
      headers = [{"x-harness-secret", secret}]

      case Req.get(url, headers: headers, retry: false, receive_timeout: 5_000) do
        {:ok, %{status: 200, body: %{"data" => entries}}} when is_list(entries) ->
          cache(entries)
          {:ok, entries}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("RcBot.Roster fetch failed: HTTP #{status} #{inspect(body)}")
          {:error, {:bad_status, status}}

        {:error, reason} ->
          Logger.warning("RcBot.Roster fetch transport error: #{inspect(reason)}")
          {:error, {:transport, reason}}
      end
    end
  end

  defp cache(entries) do
    expires_at_ms = System.system_time(:millisecond) + @cache_ttl_ms
    :persistent_term.put(__MODULE__, {entries, expires_at_ms})
  end

  defp base_http, do: Application.fetch_env!(:rc_bot, :target_http)

  defp harness_secret do
    System.get_env("RC_BOT_HARNESS_SECRET") ||
      Application.get_env(:rc_bot, :harness_secret)
  end
end
