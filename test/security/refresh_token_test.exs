defmodule RC.Security.RefreshTokenTest do
  @moduledoc """
  Regression tests for the access/refresh token split.

  Background: the Stage 1-3 audit cut access-token TTL from 4 weeks to 24h.
  That bounded leaked-token damage correctly but produced a poor UX for
  multi-day game sessions — any reconnect or HTTP call after the 24h
  boundary failed with `:token_expired`. The fix is the classic short
  access + long refresh model: 4h access, 30d refresh. The refresh token
  is accepted only at POST /api/auth/refresh and is bound by the same
  `tv` revocation knob that already kills access tokens.
  """
  use Portal.APIConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.Fixtures

  describe "POST /api/auth/refresh — Steam / bot path (refresh in body)" do
    test "valid refresh token returns a new access token", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      response =
        conn
        |> post(Routes.authentication_path(conn, :refresh), %{refresh_token: refresh})

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_binary(body["access_token"])

      # The minted token actually verifies as an access token.
      assert {:ok, claims} =
               Guardian.decode_and_verify(RC.Guardian, body["access_token"], %{
                 "typ" => "access"
               })

      assert claims["sub"] == to_string(account.id)
    end

    test "access token presented as refresh is rejected (typ mismatch)", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, access, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")

      response =
        conn
        |> post(Routes.authentication_path(conn, :refresh), %{refresh_token: access})

      assert response.status == 401
    end

    test "refresh fails after invalidate_sessions (tv bump)", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      # User logs out from another device — token_version bumps.
      {:ok, _} = RC.Accounts.invalidate_sessions(account)

      response =
        conn
        |> post(Routes.authentication_path(conn, :refresh), %{refresh_token: refresh})

      assert response.status == 401
    end

    test "refresh fails when no credential is presented", %{conn: conn} do
      response = post(conn, Routes.authentication_path(conn, :refresh), %{})

      assert response.status == 401
      assert %{"message" => "no_refresh_token"} = Jason.decode!(response.resp_body)
    end

    test "garbage refresh token is rejected", %{conn: conn} do
      response =
        conn
        |> post(Routes.authentication_path(conn, :refresh), %{
          refresh_token: "not.a.real.jwt"
        })

      assert response.status == 401
    end
  end

  describe "POST /api/auth/refresh — web path (refresh in session)" do
    test "session-stored refresh token is accepted with no body credential", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      response =
        conn
        |> init_test_session(%{refresh_token: refresh})
        |> post(Routes.authentication_path(conn, :refresh), %{})

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_binary(body["access_token"])
    end

    test "body refresh token takes precedence... actually session takes precedence",
         %{conn: conn} do
      # Lock down the precedence we documented in the controller: session
      # first, then body. If both are present, session wins.
      account = fixture(:user) |> activate!()

      {:ok, session_refresh, _} =
        RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      # A blatantly-bogus body refresh — would 401 if it were used.
      response =
        conn
        |> init_test_session(%{refresh_token: session_refresh})
        |> post(Routes.authentication_path(conn, :refresh), %{
          refresh_token: "not.a.real.jwt"
        })

      assert response.status == 200
    end
  end

  describe "Guardian config — TTLs and typ enforcement" do
    test "access token TTL is 4 hours" do
      account = fixture(:user) |> activate!()
      {:ok, _, claims} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")

      ttl_seconds = claims["exp"] - claims["iat"]
      assert ttl_seconds == 4 * 60 * 60
    end

    test "refresh token TTL is 30 days" do
      account = fixture(:user) |> activate!()
      {:ok, _, claims} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      ttl_seconds = claims["exp"] - claims["iat"]
      assert ttl_seconds == 30 * 24 * 60 * 60
    end

    test "access token cannot pass the {\"typ\" => \"refresh\"} constraint" do
      account = fixture(:user) |> activate!()
      {:ok, access, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")

      assert {:error, _} =
               Guardian.decode_and_verify(RC.Guardian, access, %{"typ" => "refresh"})
    end

    test "refresh token cannot pass the {\"typ\" => \"access\"} constraint" do
      account = fixture(:user) |> activate!()
      {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      assert {:error, _} =
               Guardian.decode_and_verify(RC.Guardian, refresh, %{"typ" => "access"})
    end
  end

  describe "refresh token rotation" do
    alias RC.Accounts.RefreshToken

    test "web/session path rotates: successor in body + session, predecessor marked spent",
         %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)
      {:ok, %{"jti" => jti, "fam" => family}} = decode_refresh(refresh)

      response =
        conn
        |> init_test_session(%{refresh_token: refresh})
        |> post(Routes.authentication_path(conn, :refresh), %{})

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      # A successor was minted, returned, and stored in the session.
      assert is_binary(body["refresh_token"])
      assert body["refresh_token"] != refresh
      assert get_session(response, :refresh_token) == body["refresh_token"]

      # Predecessor is stamped spent; successor is active in the SAME family.
      assert %RefreshToken{rotated_at: %DateTime{}} = RC.Repo.get(RefreshToken, jti)
      {:ok, %{"jti" => new_jti, "fam" => new_family}} = decode_refresh(body["refresh_token"])
      assert new_family == family
      assert %RefreshToken{rotated_at: nil} = RC.Repo.get(RefreshToken, new_jti)
    end

    test "legacy body path (no rotate flag) does not rotate and can be re-presented",
         %{conn: conn} do
      # Deployed Steam builds and the bot harness re-present their
      # login-time refresh token for its whole life — they must keep
      # working without tripping replay detection.
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)
      {:ok, %{"jti" => jti}} = decode_refresh(refresh)

      for _ <- 1..2 do
        response =
          post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
            refresh_token: refresh
          })

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_binary(body["access_token"])
        # No successor minted or leaked.
        refute Map.has_key?(body, "refresh_token")
      end

      assert %RefreshToken{rotated_at: nil} = RC.Repo.get(RefreshToken, jti)
    end

    test "body path with rotate: true rotates and returns the successor", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)
      {:ok, %{"jti" => jti}} = decode_refresh(refresh)

      response =
        post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
          refresh_token: refresh,
          rotate: true
        })

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_binary(body["refresh_token"])
      assert body["refresh_token"] != refresh
      assert %RefreshToken{rotated_at: %DateTime{}} = RC.Repo.get(RefreshToken, jti)
    end

    test "spent token re-presented within the grace window still succeeds (multi-tab race)",
         %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)

      # First redeem rotates...
      assert post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
               refresh_token: refresh,
               rotate: true
             }).status == 200

      # ...an immediate replay (second tab waking from sleep) is benign.
      response =
        post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
          refresh_token: refresh,
          rotate: true
        })

      assert response.status == 200
      assert is_binary(Jason.decode!(response.resp_body)["refresh_token"])
      # No revocation happened.
      assert RC.Accounts.get_account!(account.id).token_version == account.token_version
    end

    test "spent token re-presented after the grace window revokes every session",
         %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)
      {:ok, %{"jti" => jti}} = decode_refresh(refresh)

      # Rotate, then backdate the rotation stamp past the grace window to
      # simulate a replay long after the legitimate client moved on.
      response =
        post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
          refresh_token: refresh,
          rotate: true
        })

      assert response.status == 200
      successor = Jason.decode!(response.resp_body)["refresh_token"]

      backdated = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      RC.Repo.update_all(
        from(rt in RefreshToken, where: rt.jti == ^jti),
        set: [rotated_at: backdated]
      )

      replay =
        post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
          refresh_token: refresh
        })

      assert replay.status == 401
      assert %{"message" => "token_revoked"} = Jason.decode!(replay.resp_body)

      # The tv bump killed the thief's AND the victim's credentials —
      # including the legitimately-rotated successor.
      assert RC.Accounts.get_account!(account.id).token_version == account.token_version + 1

      after_revoke =
        post(build_conn_json(), Routes.authentication_path(conn, :refresh), %{
          refresh_token: successor
        })

      assert after_revoke.status == 401
    end

    test "untracked (pre-rotation) token is adopted into a tracked family on rotation",
         %{conn: conn} do
      account = fixture(:user) |> activate!()
      # Minted directly — no tracking row, like every token issued before
      # the rotation table shipped.
      {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

      response =
        conn
        |> init_test_session(%{refresh_token: refresh})
        |> post(Routes.authentication_path(conn, :refresh), %{})

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert is_binary(body["refresh_token"])

      {:ok, %{"jti" => new_jti}} = decode_refresh(body["refresh_token"])
      assert %RefreshToken{rotated_at: nil} = RC.Repo.get(RefreshToken, new_jti)
    end

    test "login opens a tracked rotation family" do
      account = fixture(:user) |> activate!()
      {:ok, refresh} = RC.Accounts.issue_refresh_token(account)
      {:ok, %{"jti" => jti, "fam" => family}} = decode_refresh(refresh)

      assert is_binary(family)
      assert %RefreshToken{rotated_at: nil, account_id: aid} = RC.Repo.get(RefreshToken, jti)
      assert aid == account.id
    end

    defp decode_refresh(token),
      do: Guardian.decode_and_verify(RC.Guardian, token, %{"typ" => "refresh"})

    defp build_conn_json do
      Phoenix.ConnTest.build_conn() |> put_req_header("accept", "application/json")
    end
  end

  describe "login response includes both tokens" do
    test "identity_callback returns access_token + refresh_token", %{conn: conn} do
      account = fixture(:user) |> activate!()

      # Have to set a known password since Argon2 hash in the fixture is fake.
      {:ok, account} =
        Ecto.Changeset.change(account, %{
          hashed_password: Argon2.hash_pwd_salt("realpassword!")
        })
        |> RC.Repo.update()

      ip = "203.0.113." <> Integer.to_string(:erlang.unique_integer([:positive]))

      response =
        conn
        |> put_req_header("x-forwarded-for", ip)
        |> post(Routes.authentication_path(conn, :identity_callback),
          account: %{email: account.email, password: "realpassword!"}
        )

      assert response.status == 200
      body = Jason.decode!(response.resp_body)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      # Backwards-compat `token` still present.
      assert body["token"] == body["access_token"]

      # The access and refresh tokens verify under their respective typs.
      assert {:ok, _} =
               Guardian.decode_and_verify(RC.Guardian, body["access_token"], %{
                 "typ" => "access"
               })

      assert {:ok, _} =
               Guardian.decode_and_verify(RC.Guardian, body["refresh_token"], %{
                 "typ" => "refresh"
               })
    end
  end

  defp activate!(account) do
    {:ok, account} = Ecto.Changeset.change(account, status: :active) |> RC.Repo.update()
    account
  end
end
