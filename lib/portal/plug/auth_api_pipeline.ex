defmodule Portal.Plug.AuthApiPipeline do
  @moduledoc """
  Guardian pipeline for the JSON API surface. Verifies the `Authorization:
  Bearer ...` header only — NOT the session cookie. That makes cookie-based
  CSRF impossible against `/api/*`: a cross-site form post will not carry
  a Bearer header and `EnsureAuthenticated` rejects it.

  LiveView keeps its own session-based pipeline (`Portal.Plug.AuthAccessPipeline`)
  guarded by `:protect_from_forgery` in the `:browser` pipeline.
  """
  use Guardian.Plug.Pipeline,
    otp_app: :auth,
    error_handler: Portal.Plug.AuthErrorHandler,
    module: RC.Guardian

  plug(Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"})
  plug(Guardian.Plug.LoadResource, allow_blank: true)
end
