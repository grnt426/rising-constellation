defmodule RC.Security.AuthzPlugTest do
  @moduledoc """
  Regression tests for Stage 2 #1 (CRITICAL): the authorization plug used
  to dispatch on `conn.params` (path + body + query merged) and matched
  function clauses in the order `aid -> bcid -> pid -> iid`. An attacker
  could append `?pid=<their_own_pid>` (or `?aid=<their_own_aid>`) to any
  route gated on `:iid` or `:bcid` and the plug would happily compare the
  injected key against their OWN resource, returning true and waving the
  request through.

  Fix: the plug now reads from `conn.path_params` only — the keys are
  exactly what the route declared, not whatever the attacker added.

  We exercise the original exploit shape against several routes and
  assert the server returns 403.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.Repo

  defp attacker_and_victim(_) do
    attacker = fixture(:user) |> activate!()
    victim = fixture(:user2) |> activate!()

    {:ok, attacker_profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: "atk profile", account_id: attacker.id}))

    {:ok, victim_profile} =
      Repo.insert(Profile.changeset(%Profile{}, %{avatar: "x", name: "vic profile", account_id: victim.id}))

    %{instance: victim_instance} = instance_fixture()

    {:ok, victim_instance} =
      Ecto.Changeset.change(victim_instance, account_id: victim.id) |> Repo.update()

    {:ok,
     attacker: attacker,
     victim: victim,
     attacker_profile: attacker_profile,
     victim_profile: victim_profile,
     victim_instance: victim_instance}
  end

  describe "Stage 2 #1 — ?pid=<attacker_pid> cannot flip the gate on :iid routes" do
    setup [:attacker_and_victim]

    test "PUT /api/instances/:iid with ?pid=<own> is forbidden",
         %{conn: conn, attacker: attacker, attacker_profile: ap, victim_instance: vi} do
      response =
        conn
        |> login(attacker)
        |> put(
          Routes.instance_path(conn, :update, vi.id, pid: ap.id),
          %{"instance" => %{"name" => "pwned"}}
        )

      assert response.status == 403,
             "expected 403; was #{response.status} — plug dispatched on injected pid"
    end

    test "DELETE /api/instances/:iid with ?pid=<own> is forbidden",
         %{conn: conn, attacker: attacker, attacker_profile: ap, victim_instance: vi} do
      response =
        conn
        |> login(attacker)
        |> delete(Routes.instance_path(conn, :delete, vi.id, pid: ap.id))

      assert response.status == 403
    end

    test "PUT /api/instances/:iid/start with ?pid=<own> is forbidden",
         %{conn: conn, attacker: attacker, attacker_profile: ap, victim_instance: vi} do
      response =
        conn
        |> login(attacker)
        |> put(Routes.instance_path(conn, :start, vi.id, pid: ap.id))

      assert response.status == 403
    end
  end

  describe "Stage 2 #1 — ?aid=<attacker_aid> cannot flip the gate on :pid routes" do
    setup [:attacker_and_victim]

    test "PUT /api/profiles/:pid with ?aid=<own> is forbidden",
         %{conn: conn, attacker: attacker, victim_profile: vp} do
      response =
        conn
        |> login(attacker)
        |> put(
          Routes.profile_path(conn, :update, vp.id, aid: attacker.id),
          %{"profile" => %{"name" => "pwned by injection"}}
        )

      assert response.status == 403
    end

    test "POST /api/registrations/profile/:pid with ?aid=<own> is forbidden",
         %{conn: conn, attacker: attacker, victim_profile: vp} do
      response =
        conn
        |> login(attacker)
        |> post(
          Routes.registration_path(conn, :join, vp.id, aid: attacker.id),
          %{"faction_id" => 1, "instance_id" => 1}
        )

      assert response.status == 403
    end
  end

  describe "Stage 2 #1 — body params can't flip the gate either" do
    setup [:attacker_and_victim]

    test "PUT /api/instances/:iid with body {pid: own_pid} is forbidden",
         %{conn: conn, attacker: attacker, attacker_profile: ap, victim_instance: vi} do
      response =
        conn
        |> login(attacker)
        |> put(
          Routes.instance_path(conn, :update, vi.id),
          %{"pid" => ap.id, "instance" => %{"name" => "pwned via body"}}
        )

      assert response.status == 403
    end
  end

  defp activate!(account) do
    {:ok, a} = Ecto.Changeset.change(account, status: :active) |> Repo.update()
    a
  end
end
