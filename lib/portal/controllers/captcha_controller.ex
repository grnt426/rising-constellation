defmodule Portal.CaptchaController do
  @moduledoc """
  Mints ALTCHA proof-of-work challenges for the signup form.

      GET /api/captcha

  Returns `{"enabled": false}` when the captcha is off (dev/test, or prod
  without CAPTCHA_HMAC_KEY) so the signup hook can skip the solve step —
  otherwise the challenge fields the hook brute-forces. See Portal.Captcha.
  """
  use Portal, :controller

  # Challenge minting is just an HMAC, but there is no reason to hand a
  # scraper unlimited challenges either. Generous next to signup's 10/hour
  # (failed form attempts re-fetch a fresh challenge each try).
  plug(Portal.Plug.RateLimit, bucket: "captcha", limit: 30, window_ms: 3_600_000)

  def challenge(conn, _params) do
    if Portal.Captcha.enabled?() do
      json(conn, Portal.Captcha.create_challenge() |> Map.put("enabled", true))
    else
      json(conn, %{enabled: false})
    end
  end
end
