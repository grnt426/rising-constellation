defmodule Portal.EdictControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  setup %{conn: conn} do
    account = fixture(:user)
    {:ok, conn: login(conn, account), account: account}
  end

  test "the API needs a signed-in account" do
    conn = build_conn()
    assert conn |> get("/api/edict/catalog") |> response(401)
    assert conn |> post("/api/edict/analyze", %{source: "score 1"}) |> response(401)
  end

  test "GET /api/edict/catalog lists the palette", %{conn: conn} do
    body = json_response(get(conn, "/api/edict/catalog"), 200)
    assert Enum.any?(body["actions"], &(&1["name"] == "give"))
    assert Enum.any?(body["builtins"], &(&1["name"] == "sum"))
    assert body["world"]["player"]["record"]["income"]["record"]["credit"] == "number"
    assert body["simulator"]["economy"]["credit"] == [30.0, 800.0]
    assert body["simulator"]["stock"]["credit"] == 300_000.0
  end

  test "GET /api/edict/examples returns sources", %{conn: conn} do
    body = json_response(get(conn, "/api/edict/examples"), 200)
    keys = Enum.map(body["examples"], & &1["key"])
    assert "first_steps" in keys and "the_bequest" in keys
  end

  test "text in: tree and diagnostics out", %{conn: conn} do
    body = json_response(post(conn, "/api/edict/analyze", %{source: "score player.credt"}), 200)
    assert body["program"]["decls"] |> hd() |> Map.get("k") == "score"
    assert [%{"severity" => "error", "message" => message}] = body["diagnostics"]
    assert message =~ "did you mean credit"
  end

  test "tree in: canonical text, node positions and code snippets out", %{conn: conn} do
    %{"program" => program} =
      json_response(post(conn, "/api/edict/analyze", %{source: "score sum(player.systems, s => s.population)"}), 200)

    lambda = program["decls"] |> hd() |> get_in(["expr", "args"]) |> List.last()

    body = json_response(post(conn, "/api/edict/analyze", %{program: program, code_ids: [lambda["id"]]}), 200)
    assert body["source"] == "score sum(player.systems, s => s.population)\n"
    assert body["positions"][hd(program["decls"])["id"]] == [1, 1]
    assert body["snippets"][lambda["id"]] == "s => s.population"
  end

  test "a forged tree is refused", %{conn: conn} do
    body = json_response(post(conn, "/api/edict/analyze", %{program: %{decls: [%{k: "Elixir.File"}]}}), 422)
    assert body["message"] =~ "unknown"
  end

  test "fragments parse on their own", %{conn: conn} do
    body = json_response(post(conn, "/api/edict/fragment", %{source: "min(a, 2) * 3", kind: "expr"}), 200)
    assert body["node"]["k"] == "bin"

    body = json_response(post(conn, "/api/edict/fragment", %{source: "min(a, ", kind: "expr"}), 200)
    assert body["error"]["message"]
  end

  test "simulate runs a whole scenario", %{conn: conn} do
    source = Edict.example("first_steps").source
    body = json_response(post(conn, "/api/edict/simulate", %{source: source, pace: "strong"}), 200)
    assert body["ok"] == true
    assert body["report"]["result"]["reason"] == "deadline"
    assert length(body["report"]["timeline"]) == 8
  end

  test "simulate reports a broken setup instead of failing", %{conn: conn} do
    body = json_response(post(conn, "/api/edict/simulate", %{source: "setup {\n  time_limit = 3h\n}"}), 200)
    assert body["ok"] == false
    assert [%{"message" => message}] = body["errors"]
    assert message =~ "time_limit"
  end

  test "playtest only boots the caller's own profile, and never a script with errors", %{conn: conn, account: account} do
    {:ok, other} =
      RC.Accounts.create_account(%{
        email: "edict-other@tetrarchyfalls.local",
        password: "edict-other-password",
        name: "Other",
        role: :user,
        status: :active
      })

    {:ok, theirs} = RC.Accounts.create_profile(%{account_id: other.id, name: "NotMine", avatar: "todo"})
    {:ok, mine} = RC.Accounts.create_profile(%{account_id: account.id, name: "Mine", avatar: "todo"})

    assert json_response(post(conn, "/api/edict/playtest", %{source: "score 1", profile_id: theirs.id}), 403)

    body = json_response(post(conn, "/api/edict/playtest", %{source: "score player.credt", profile_id: mine.id}), 200)
    assert body["ok"] == false
    assert RC.Repo.aggregate(RC.Instances.Instance, :count) == 0
  end
end
