defmodule RC.Security.RateLimitTest do
  @moduledoc """
  Regression test for Stage 1 #5 (HIGH): brute-force protection on the
  login endpoint via the Hammer-backed `Portal.Plug.RateLimit`.

  10 attempts per IP per 15 minutes is the configured threshold (see
  `Portal.AuthenticationController`). The 11th attempt from the same IP
  returns 429.

  Each test uses a unique synthetic `x-forwarded-for` so Hammer's ETS
  buckets don't bleed between tests in the same run.
  """
  use Portal.APIConnCase, async: false

  describe "Stage 1 #5 — login endpoint rate limit" do
    test "returns 429 after the configured threshold", %{conn: conn} do
      ip = "203.0.113." <> Integer.to_string(:erlang.unique_integer([:positive]))

      # Hit 1..10 — all should pass the limiter (and 401 because no real
      # credentials are presented; the controller proper rejects).
      for attempt <- 1..10 do
        status =
          conn
          |> Plug.Conn.put_req_header("x-forwarded-for", ip)
          |> post(Routes.authentication_path(conn, :identity_callback),
            account: %{email: "rl-#{attempt}@nope", password: "wrong"}
          )
          |> Map.get(:status)

        assert status != 429,
               "attempt #{attempt} hit the limiter early (status #{status}); expected the first 10 to pass through"
      end

      # The 11th attempt is rate-limited.
      response =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", ip)
        |> post(Routes.authentication_path(conn, :identity_callback),
          account: %{email: "rl-11@nope", password: "wrong"}
        )

      assert response.status == 429
      assert Plug.Conn.get_resp_header(response, "retry-after") != []
    end

    test "different IPs get independent buckets", %{conn: conn} do
      ip_a = "203.0.113." <> Integer.to_string(:erlang.unique_integer([:positive]))
      ip_b = "203.0.113." <> Integer.to_string(:erlang.unique_integer([:positive]))

      # Exhaust IP A.
      for _ <- 1..11 do
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", ip_a)
        |> post(Routes.authentication_path(conn, :identity_callback),
          account: %{email: "x@x", password: "x"}
        )
      end

      # IP B's first attempt should NOT be rate-limited.
      response =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", ip_b)
        |> post(Routes.authentication_path(conn, :identity_callback),
          account: %{email: "x@x", password: "x"}
        )

      refute response.status == 429,
             "IP B was rate-limited despite never sending a request before"
    end
  end
end
