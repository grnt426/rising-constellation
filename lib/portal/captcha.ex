defmodule Portal.Captcha do
  @moduledoc """
  Proof-of-work captcha for the open signup form (ALTCHA protocol, V1).

  Replaces the deferred Cloudflare Turnstile plan: everything runs
  in-house — the server mints an HMAC-signed SHA-256 challenge
  (`GET /api/captcha`), the browser brute-forces the matching number with
  SubtleCrypto (see `solveCaptcha` in assets/js/app.js) behind a
  "Validating…" spinner, and `verify/1` checks the returned payload before
  `POST /api/accounts` runs. No third-party service, no cookies, no
  fingerprinting — a spammer just has to burn ~1-2s of CPU per attempt.

  Disabled whenever `:hmac_key` is nil (dev/test default). Prod sets
  CAPTCHA_HMAC_KEY (config/runtime.exs); AccountController fails closed on
  missing/bad payloads only while enabled.

  Solved challenges are strictly one-time: the first `verify/1` claims the
  challenge in `Portal.Captcha.UsedChallenges`; replays fail until the
  challenge would have expired anyway (`:expires_s`).
  """

  alias Portal.Captcha.UsedChallenges

  # A well-formed payload is a base64 JSON object of ~6 short fields;
  # anything bigger is garbage and not worth decoding.
  @max_payload_bytes 2_048

  # Every key the client may send. Enforced BEFORE the payload reaches
  # the altcha lib, whose Payload.from_json calls String.to_atom on
  # arbitrary keys — without this whitelist an attacker could grow the
  # BEAM atom table one garbage key at a time.
  @payload_keys ~w(algorithm challenge number salt signature took)

  def enabled?, do: config(:hmac_key) != nil

  @doc "Mint a fresh ALTCHA V1 challenge (as a string-keyed, JSON-ready map)."
  def create_challenge do
    expires = DateTime.to_unix(DateTime.utc_now()) + config(:expires_s)

    %Altcha.V1.ChallengeOptions{
      hmac_key: config(:hmac_key),
      max_number: config(:max_number),
      expires: expires
    }
    |> Altcha.V1.create_challenge()
    # Round-trip through the struct's own JSON encoder so :algorithm lands
    # as the canonical "SHA-256" string of the ALTCHA wire protocol (the
    # struct holds it as the atom :sha256).
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc """
  Verify a solved payload (base64 JSON, as produced by the signup hook).
  `:ok` exactly once per challenge; `{:error, :captcha_failed}` for
  missing, malformed, wrongly-solved, expired or replayed payloads.

  Expiry is checked here rather than via the lib's `check_expires` — the
  lib's V1 expiry branch discards its own result (an `if` with unused
  value), so expired-but-correct solutions would verify. The expires
  param is tamper-proof regardless: it lives inside the salt, which the
  HMAC-signed challenge hash covers.
  """
  def verify(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok, map} <- decode(payload),
         true <- well_formed?(map),
         true <- unexpired?(map),
         true <- Altcha.V1.verify_solution(payload, config(:hmac_key), false),
         true <- UsedChallenges.claim("altcha:" <> map["challenge"], config(:expires_s) * 2) do
      :ok
    else
      _ -> {:error, :captcha_failed}
    end
  end

  def verify(_), do: {:error, :captcha_failed}

  defp decode(payload) do
    with {:ok, json} <- Base.decode64(payload),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp well_formed?(map) do
    is_binary(map["challenge"]) and is_binary(map["salt"]) and
      Enum.all?(Map.keys(map), &(&1 in @payload_keys))
  end

  # We always mint with an expires param, so its absence means a stripped
  # or foreign salt — rejected either way (the signature check would fail
  # on tampering too; this is belt and braces plus the actual time check).
  defp unexpired?(%{"salt" => salt}) do
    with [_salt, query] <- String.split(salt, "?", parts: 2),
         %{"expires" => expires} <- URI.decode_query(query),
         {unix, _rest} <- Integer.parse(expires) do
      DateTime.to_unix(DateTime.utc_now()) <= unix
    else
      _ -> false
    end
  end

  defp config(key), do: Application.get_env(:rc, __MODULE__, []) |> Keyword.get(key)
end
