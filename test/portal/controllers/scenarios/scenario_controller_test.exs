defmodule Portal.ScenarioControllerTest do
  use Portal.APIConnCase

  alias RC.Scenarios

  import RC.Fixtures

  @filename "test.png"
  @file_path Path.join([File.cwd!(), "/test/support/", @filename])

  @stored_file_path Path.join([
                      File.cwd!(),
                      Application.compile_env(:waffle, :storage_dir),
                      Application.compile_env(:rc, RC.Uploader.ThumbnailFile) |> Keyword.get(:path),
                      "scenarios"
                    ])

  @image_plug_upload %Plug.Upload{
    content_type: "image/png",
    filename: @filename,
    path: @file_path
  }

  @invalid_attrs %{game_data: nil, is_official: nil}

  @scenario_create_attrs_thumbnail %{
    game_data: %{"data" => "some data"},
    game_metadata: %{},
    thumbnail: @image_plug_upload,
    is_official: true
  }

  @scenario_create_attrs_filters %{
    game_data: %{speed: "fast", victory_type: "kaboom"},
    game_metadata: %{speed: "fast", victory_type: "kaboom", size: 500},
    thumbnail: @image_plug_upload
  }

  @scenario_update_attrs_thumbnail %{
    game_data: %{"data" => "some updated data"},
    is_official: false
  }

  @scenario_create_attrs %{
    game_data: %{"data" => "some data"},
    game_metadata: %{},
    is_official: true
  }

  @scenario_invalid_attrs %{
    game_data: nil,
    game_metadata: %{},
    thumbnail: nil
  }

  setup %{conn: conn} do
    on_exit(fn -> File.rm_rf(@stored_file_path) end)
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp get_path(id, filename) do
    Path.join([@stored_file_path, "#{id}", filename])
  end

  describe "index" do
    setup [:create_account_user]

    test "lists all scenarios", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> get(Routes.scenario_path(conn, :index))

      assert json_response(conn, 200) == []
      assert conn.assigns.scenarios.total_entries == 0
    end
  end

  describe "index with filters" do
    setup [:create_account_admin]

    test "lists filtered scenarios", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_filters)

      assert %{"id" => sid} = json_response(conn, 201)

      # Stage 2 — list endpoints default to published-only. New rows land as
      # drafts; publish here so the listing returns the row this test created.
      {:ok, _} = Scenarios.get_scenario(sid) |> Scenarios.publish_scenario()

      {:ok, account: account_user} = create_account_user(%{})

      conn =
        build_conn()
        |> login(account_user)
        |> get(Routes.scenario_path(conn, :index, %{size: 500}))

      assert [map] = json_response(conn, 200)
      assert map["game_metadata"]["size"] == 500
      assert map["game_metadata"]["speed"] == "fast"
    end

    test "lists filtered scenarios returns empty list if wrong filter", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_filters)

      assert response(conn, 201)

      {:ok, account: account_user} = create_account_user(%{})

      conn =
        build_conn()
        |> login(account_user)
        |> get(Routes.scenario_path(conn, :index, %{size: 600}))

      assert [] = json_response(conn, 200)
    end
  end

  describe "create scenario" do
    setup [:create_account_admin]

    test "renders scenario when data with thumbnail is valid", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_thumbnail)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> get(Routes.scenario_path(conn, :show, id))

      # Stage 2 — `is_official` is not settable from create attrs; admins
      # flip it via a separate endpoint, so newly created rows are false.
      assert %{
               "id" => ^id,
               "game_data" => %{"data" => "some data"},
               "is_official" => false,
               "likes" => 0,
               "dislikes" => 0,
               "favorites" => 0
             } = json_response(conn, 200)

      # Stage 2 — auto-gen thumbnail (from non-empty game_data) lands at
      # `thumbnail_thumb.png`, not `test_thumb.png`. The user-uploaded
      # thumbnail field is silently ignored (not in @castable_attrs).
      assert File.exists?(get_path(id, "thumbnail_thumb.png")) == true
    end

    test "renders scenario when data without thumbnail is valid and map has thumbnail", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> get(Routes.scenario_path(conn, :show, id))

      # Stage 2 — see "with thumbnail" test above; is_official defaults to false.
      assert %{
               "id" => ^id,
               "game_data" => %{"data" => "some data"},
               "is_official" => false,
               "likes" => 0,
               "dislikes" => 0,
               "favorites" => 0
             } = json_response(conn, 200)
    end

    test "renders scenario when data without thumbnail is valid and map has no thumbnail", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> get(Routes.scenario_path(conn, :show, id))

      # Stage 2 — see other create tests; is_official defaults to false.
      # Stage 2 — auto-gen thumbnail runs from non-empty game_data, so
      # `thumbnail` is a URL string (the test's old `nil` expectation was
      # for the pre-Stage 1 world where no thumbnail was auto-generated).
      response = json_response(conn, 200)

      assert %{
               "id" => ^id,
               "game_data" => %{"data" => "some data"},
               "is_official" => false,
               "likes" => 0,
               "dislikes" => 0,
               "favorites" => 0
             } = response

      assert is_binary(response["thumbnail"])
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      account: account
    } do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_invalid_attrs)

      assert json_response(conn, 400) == %{
               "message" => %{"game_data" => ["can't be blank"]}
             }
    end
  end

  describe "update scenario" do
    setup [:create_account_admin]

    test "renders scenario when data is valid", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_thumbnail)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> put(Routes.scenario_path(conn, :update, id), scenario: @scenario_update_attrs_thumbnail)

      assert %{"id" => ^id} = json_response(conn, 200)

      conn = get(conn, Routes.scenario_path(conn, :show, id))

      assert %{
               "id" => ^id,
               "game_data" => %{"data" => "some updated data"},
               "is_official" => false,
               "likes" => 0,
               "dislikes" => 0,
               "favorites" => 0
             } = json_response(conn, 200)
    end

    test "renders errors when data is invalid", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_thumbnail)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> put(Routes.scenario_path(conn, :update, id), scenario: @invalid_attrs)

      # Stage 2 — `is_official` no longer in required fields.
      assert json_response(conn, 400) == %{
               "message" => %{"game_data" => ["can't be blank"]}
             }
    end
  end

  describe "delete scenario" do
    setup [:create_account_admin]

    test "deletes chosen scenario", %{conn: conn, account: account} do
      conn =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: @scenario_create_attrs_thumbnail)

      assert %{"id" => id} = json_response(conn, 201)

      conn =
        build_conn()
        |> login(account)
        |> delete(Routes.scenario_path(conn, :delete, id))

      assert response(conn, 204)

      conn =
        build_conn()
        |> login(account)
        |> get(Routes.scenario_path(conn, :show, id))

      assert json_response(conn, 404)["message"] == "not_found"
    end
  end
end
