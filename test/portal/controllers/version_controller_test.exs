defmodule Portal.VersionControllerTest do
  @moduledoc """
  GET /api/version — which game server is live (RC.Build): its revision,
  when it came online, and whether a deploy is in progress. Public and
  never cached; stable for the life of the node.
  """
  use Portal.APIConnCase, async: false

  # the deploy flag lives in the process-global Portal.Config cache
  setup do
    on_exit(fn -> Portal.Config.update_key(:deploy_flag, false) end)
    :ok
  end

  test "reports version, live_since and deploying, uncached", %{conn: conn} do
    conn = get(conn, "/api/version")

    assert %{"version" => version, "live_since" => live_since, "deploying" => false} = json_response(conn, 200)
    assert is_binary(version) and version != ""
    assert {:ok, _, 0} = DateTime.from_iso8601(live_since)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "the same server always gives the same version and live_since", %{conn: conn} do
    first = conn |> get("/api/version") |> json_response(200)
    second = Phoenix.ConnTest.build_conn() |> get("/api/version") |> json_response(200)

    assert Map.take(first, ["version", "live_since"]) == Map.take(second, ["version", "live_since"])
  end

  test "deploying follows the deploy notice flag", %{conn: conn} do
    {:ok, _} = RC.Deploy.set_flag(true, "test")
    assert %{"deploying" => true} = conn |> get("/api/version") |> json_response(200)

    {:ok, _} = RC.Deploy.set_flag(false, "test")
    assert %{"deploying" => false} = Phoenix.ConnTest.build_conn() |> get("/api/version") |> json_response(200)
  end
end
