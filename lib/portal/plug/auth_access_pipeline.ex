defmodule Portal.Plug.AuthAccessPipeline do
  use Guardian.Plug.Pipeline,
    otp_app: :auth,
    error_handler: Portal.Plug.AuthErrorHandler,
    module: RC.Guardian

  # If the session's access token is expired but its refresh token is still
  # good, transparently re-sign the session before verification — otherwise
  # every HTML/LiveView visit >4h after the last refresh bounces to /login
  # (and, before this plug, destroyed the refresh token with it).
  plug(Portal.Plug.SessionRefresh)
  # If there is a session token, restrict it to an access token and validate it
  plug(Guardian.Plug.VerifySession, claims: %{"typ" => "access"})
  # If there is an authorization header, restrict it to an access token and validate it
  plug(Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"})
  # Load the user if either of the verifications worked
  plug(Guardian.Plug.LoadResource, allow_blank: true)
end
