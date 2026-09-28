defmodule Portal.HelpControllerTest do
  use Portal.HTMLConnCase

  test "GET /api/help/:lang returns the bundle for a speed, no auth", %{conn: conn} do
    body = conn |> get("/api/help/en", speed: "fast") |> json_response(200)

    assert body["lang"] == "en"
    assert body["speed"] == "fast"
    assert Enum.any?(body["pages"], &(&1["slug"] == "mobility"))
    assert Enum.any?(body["glossary"], &(&1["term"] == "mobility"))
    assert Enum.any?(body["categories"], &(&1["key"] == "systems"))
  end

  test "unknown language and speed fall back to en / slow; daily maps to slow", %{conn: conn} do
    body = conn |> get("/api/help/xx", speed: "daily") |> json_response(200)
    assert body["lang"] == "en"
    assert body["speed"] == "slow"
  end

  test "ETag revalidation answers 304", %{conn: conn} do
    conn1 = get(conn, "/api/help/en")
    [etag] = get_resp_header(conn1, "etag")
    assert json_response(conn1, 200)

    conn2 = conn |> put_req_header("if-none-match", etag) |> get("/api/help/en")
    assert conn2.status == 304
  end
end
