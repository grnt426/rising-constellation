defmodule Portal.ArchiveExportControllerTest do
  use Portal.APIConnCase, async: false

  import RC.Fixtures

  alias RC.Repo

  defp archive_match(account, published) do
    now = NaiveDateTime.utc_now()

    {1, [%{id: instance_id}]} =
      Repo.insert_all("instances", [%{name: "Citadel", account_id: account.id, inserted_at: now, updated_at: now}],
        returning: [:id]
      )

    Repo.insert!(%RC.Archive.Match{
      instance_id: instance_id,
      name: "Citadel",
      speed: "slow",
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now(),
      published: published,
      factions: [%{"key" => "tetrarchy", "rank" => 1}],
      summary: %{"days" => 1}
    })
  end

  defp export(conn, account, match) do
    conn
    |> login(account)
    |> get(Routes.archive_path(conn, :export, match.id))
  end

  describe "GET /api/archive/matches/:id/export" do
    setup [:create_account_user]

    test "downloads an xlsx, then limits the account to one per minute", %{conn: conn, account: account} do
      match = archive_match(account, true)

      response = export(conn, account, match)
      assert response.status == 200
      assert get_resp_header(response, "content-type") == [RC.Archive.Export.content_type()]
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition =~ ~s(filename="legacy-archive-)
      assert <<"PK", _::binary>> = response.resp_body

      response = export(conn, account, match)
      assert response.status == 429
      assert [retry] = get_resp_header(response, "retry-after")
      assert String.to_integer(retry) in 1..60
      assert json_response(response, 429)["message"] == "rate_limited"

      # Another account has its own allowance.
      other = fixture(:user2)
      assert export(conn, other, match).status == 200
    end

    test "unpublished or missing matches 404 without using the allowance", %{conn: conn, account: account} do
      draft = archive_match(account, false)
      published = archive_match(account, true)

      assert export(conn, account, draft).status == 404
      assert conn |> login(account) |> get(Routes.archive_path(conn, :export, 0)) |> Map.get(:status) == 404
      assert export(conn, account, published).status == 200
    end

    test "admins are exempt and can export drafts", %{conn: conn, account: account} do
      admin = fixture(:admin)
      draft = archive_match(account, false)

      assert export(conn, admin, draft).status == 200
      assert export(conn, admin, draft).status == 200
    end
  end
end
