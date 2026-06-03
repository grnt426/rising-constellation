defmodule RC.Security.AuthErrorHandlerTest do
  @moduledoc """
  Regression for the auth_error_handler returning 500 on stale credentials.

  Background: until the Stage 1-3 audit cut Guardian's access-token TTL
  from 4 weeks to 24h (commit 3c0ba4a), the `:invalid_token` / `:token_expired`
  paths in Portal.Plug.AuthErrorHandler were dormant — users almost never
  presented an expired/unverifiable JWT in a normal session. After the
  TTL cut (and the new `tv` revocation that emits `:token_revoked`), any
  returning user with a day-old cookie was getting HTTP 500 with the body
  `"invalid_token"` instead of a 401 + bad-cookie cleanup.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Portal.Plug.AuthErrorHandler

  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_test_key",
                  signing_salt: "12345678",
                  encryption_salt: "12345678"
                )

  defp build_conn(method, path, accept) do
    conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(@session_opts)
    |> fetch_session()
    |> put_req_header("accept", accept)
  end

  describe "status code mapping" do
    for {type, expected} <- [
          {:invalid_token, 401},
          {:token_expired, 401},
          {:token_revoked, 401},
          {:account_inactive, 401},
          {:no_resource_found, 401},
          {:no_claims_sub, 401},
          {:no_resource_id, 401},
          {:unauthenticated, 401},
          {:unauthorized, 401},
          {:forbidden, 403}
        ] do
      test "#{type} → #{expected} on JSON requests" do
        conn =
          build_conn(:get, "/api/account", "application/json")
          |> AuthErrorHandler.auth_error({unquote(type), :ignored}, [])

        assert conn.status == unquote(expected)
        assert conn.halted
      end
    end

    test "unknown error type defaults to 401, not 500" do
      conn =
        build_conn(:get, "/api/account", "application/json")
        |> AuthErrorHandler.auth_error({:some_future_guardian_atom, :ignored}, [])

      assert conn.status == 401
    end
  end

  describe "stale-credential HTML requests" do
    test "invalid_token: redirects to /, drops the session" do
      conn =
        build_conn(:get, "/", "text/html")
        |> put_session(:guardian_default_token, "stale.jwt.value")
        |> AuthErrorHandler.auth_error({:invalid_token, :ignored}, [])

      assert conn.status == 302
      assert Phoenix.ConnTest.redirected_to(conn) == "/"
      assert conn.halted
      assert conn.private[:plug_session_info] == :drop
    end

    test "token_expired: redirects to / from an auth-only path (no loop)" do
      conn =
        build_conn(:get, "/admin", "text/html")
        |> put_session(:guardian_default_token, "stale.jwt.value")
        |> AuthErrorHandler.auth_error({:token_expired, :ignored}, [])

      assert conn.status == 302
      assert Phoenix.ConnTest.redirected_to(conn) == "/"
      assert conn.private[:plug_session_info] == :drop
    end

    test "unauthenticated (no token presented): no redirect, no session drop" do
      conn =
        build_conn(:get, "/admin", "text/html")
        |> AuthErrorHandler.auth_error({:unauthenticated, :ignored}, [])

      assert conn.status == 401
      refute conn.private[:plug_session_info] == :drop
    end
  end

  describe "stale-credential JSON requests" do
    test "invalid_token: 401 + JSON body + session dropped" do
      conn =
        build_conn(:get, "/api/account", "application/json")
        |> put_session(:guardian_default_token, "stale.jwt.value")
        |> AuthErrorHandler.auth_error({:invalid_token, :ignored}, [])

      assert conn.status == 401
      assert conn.private[:plug_session_info] == :drop
      assert conn.resp_body =~ ~s("invalid_token")
    end
  end

  describe "missing accept header falls back to text/html" do
    test "no Accept header + invalid_token redirects (treated as browser)" do
      conn =
        conn(:get, "/")
        |> Map.put(:secret_key_base, String.duplicate("a", 64))
        |> Plug.Session.call(@session_opts)
        |> fetch_session()
        |> put_session(:guardian_default_token, "stale.jwt.value")
        |> AuthErrorHandler.auth_error({:invalid_token, :ignored}, [])

      assert conn.status == 302
    end
  end
end
