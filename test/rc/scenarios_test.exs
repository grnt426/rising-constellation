defmodule RC.ScenarioTest do
  use RC.DataCase

  alias RC.Scenarios
  alias RC.Scenarios.Folder

  import RC.Fixtures

  @filename "test.png"
  @file_path Path.join([File.cwd!(), "/test/support/", @filename])

  @stored_file_path Path.join([
                      File.cwd!(),
                      Application.compile_env(:waffle, :storage_dir),
                      Application.compile_env(:rc, RC.Uploader.ThumbnailFile) |> Keyword.get(:path)
                    ])

  @image_plug_upload %Plug.Upload{
    content_type: "image/png",
    filename: @filename,
    path: @file_path
  }

  @map_create_attrs %{
    game_data: %{},
    game_metadata: %{},
    is_map: true,
    is_official: true,
    thumbnail: @image_plug_upload
  }

  @map_create_attrs_with_false %{
    game_data: %{},
    game_metadata: %{},
    is_map: false,
    is_official: true,
    thumbnail: @image_plug_upload
  }

  @map_update_attrs %{
    game_data: %{update: "update content"},
    game_metadata: %{},
    is_map: true,
    is_official: false,
    thumbnail: @image_plug_upload
  }
  @map_invalid_attrs %{
    game_data: nil,
    game_metadata: nil,
    is_map: nil,
    is_official: nil,
    thumbnail: nil
  }

  @scenario_create_attrs %{
    scenario_data: %{game_data: %{"data" => "some data"}, game_metadata: %{"speed" => "some speed"}}
  }

  # Align counts + new associative / counter fields that Stage 2 (author) and
  # Stage 4 (plays/games_count) added after this test file was written, so
  # `==` against the get_map / get_scenario result stays meaningful: the
  # DB-read struct preloads `:author` (NotLoaded -> nil) and the games_count
  # field defaults to 0, while the in-memory fixture struct has them as
  # NotLoaded / nil.
  def put_counts(scenario, likes \\ 0, dislikes \\ 0, favorites \\ 0) do
    scenario
    |> Map.put(:likes, likes)
    |> Map.put(:dislikes, dislikes)
    |> Map.put(:favorites, favorites)
    |> Map.put(:author, nil)
    |> Map.put(:plays, 0)
  end

  def map_fixture() do
    {:ok, %{map_with_thumbnail: map}} =
      %{}
      |> Enum.into(@map_create_attrs)
      |> Scenarios.create_map()

    # Stage 2 — list endpoints default to published-only. Publish here so
    # the existing list_maps tests keep finding this row.
    # Re-fetch: Stage 1 thumbnail regen runs synchronously in test (see
    # config/test.exs) and writes the thumbnail file_name onto the row;
    # the original in-memory struct doesn't reflect that, so we re-read.
    {:ok, _} = Scenarios.publish_map(map)
    Scenarios.get_map(map.id)
  end

  def map_fixture(:no_thumbnail) do
    {:ok, map} =
      %{}
      |> Enum.into(@map_create_attrs)
      |> Scenarios.create_map(:no_thumbnail)

    map
  end

  def scenario_fixture(attrs \\ %{}) do
    {:ok, %{map_with_thumbnail: map}} =
      attrs
      |> Enum.into(@map_create_attrs)
      |> Scenarios.create_map()

    {:ok, %{scenario: scenario}} =
      Scenarios.create_scenario(
        %{
          game_data: Map.merge(map.game_data, @scenario_create_attrs.scenario_data.game_data),
          game_metadata: Map.merge(map.game_metadata, @scenario_create_attrs.scenario_data.game_metadata),
          is_official: map.is_official,
          is_map: false,
          thumbnail: map.thumbnail
        },
        :reuse_thumbnail
      )

    # Stage 2 — publish so list_scenarios returns this row, then re-fetch
    # so author preload / Stage-1 thumbnail file_name are reflected.
    {:ok, _} = Scenarios.publish_scenario(scenario)
    Scenarios.get_scenario(scenario.id)
  end

  defp get_path(map, filename, maps_or_scenarios \\ "scenarios") do
    Path.join([@stored_file_path, maps_or_scenarios, "#{map.id}", filename])
  end

  describe "maps" do
    alias RC.Scenarios.Map
    alias RC.Scenarios

    setup do
      on_exit(fn -> File.rm_rf(@stored_file_path) end)
    end

    test "list_maps/0 returns all maps" do
      map = map_fixture()
      assert (%Scrivener.Page{} = paginated_entries) = Scenarios.list_maps()
      assert paginated_entries.entries == [map |> put_counts()]
      assert paginated_entries.total_entries == 1
    end

    test "get_map/1 returns the map with given id" do
      map = map_fixture()
      assert Scenarios.get_map(map.id) == map |> put_counts()
    end

    test "create_map/1 with valid data creates a map" do
      assert {:ok, %{map_with_thumbnail: %Map{} = map}} = Scenarios.create_map(@map_create_attrs)
      assert map.game_data == %{}
      # Stage 2 — `is_official` is no longer settable from create attrs;
      # admins flip it via a separate endpoint.
      assert map.is_official == false
      # Stage 2 — `thumbnail` is no longer in @castable_attrs; user-supplied
      # uploads are silently ignored, and the auto-gen flow runs only when
      # `game_data` is non-empty (this test uses `%{}`), so no file lands.
      assert File.exists?(get_path(map, "test_thumb.png")) == false
    end

    test "create_map/2 with valid data and no thumbnail creates a map" do
      assert {:ok, %Map{} = map} = Scenarios.create_map(@map_create_attrs, :no_thumbnail)
      assert map.game_data == %{}
      # Stage 2 — see above. is_official is admin-only.
      assert map.is_official == false
      assert File.exists?(get_path(map, "test_thumb.png")) == false
      assert map.thumbnail == nil
    end

    test "create_map/1 with is_map false returns error" do
      # Stage 1 — create_map was simplified out of Ecto.Multi for the error
      # path, so failures are a 2-tuple `{:error, changeset}` rather than the
      # historical 4-tuple `{:error, op, changeset, changes}`.
      assert {:error, %Ecto.Changeset{}} = Scenarios.create_map(@map_create_attrs_with_false)
    end

    test "create_map/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Scenarios.create_map(@map_invalid_attrs)
    end

    test "update_map/2 with valid data updates the map" do
      map = map_fixture()
      assert {:ok, %Map{} = map} = Scenarios.update_map(map, @map_update_attrs)
      assert map.game_data == %{update: "update content"}
      assert map.is_official == false
    end

    test "update_map/2 with invalid data returns error changeset" do
      map = map_fixture()
      assert {:error, %Ecto.Changeset{}} = Scenarios.update_map(map, @map_invalid_attrs)
      assert map |> put_counts() == Scenarios.get_map(map.id)
    end

    test "delete_map/1 deletes the map" do
      map = map_fixture()
      map = Scenarios.get_map_as_scenario(map.id)
      assert {:ok, _} = Scenarios.delete_scenario(map)
      assert Scenarios.get_map(map.id) == nil
    end
  end

  describe "scenarios" do
    alias RC.Scenarios.Scenario
    alias RC.Scenarios

    setup do
      on_exit(fn -> File.rm_rf(@stored_file_path) end)
    end

    # test fait quand je faisais des tests de query, au final j'ai gardé vu qu'il était là
    test "list_scenario/0 returns right number of likes, dislikes and favorites" do
      scenario = scenario_fixture()
      account = fixture(:user)
      account3 = fixture(:user2)
      account2 = fixture(:admin)

      likes_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_likes_name)
      dislikes_name = Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_dislikes_name)

      folder_attrs = %Folder{
        name: likes_name,
        description: "likes",
        account_id: account.id
      }

      folder_attrs2 = %Folder{
        name: likes_name,
        description: "likes",
        account_id: account2.id
      }

      folder_attrs3 = %Folder{
        name: "not a special folder",
        description: "not a special folder",
        account_id: account.id
      }

      folder_attrs4 = %Folder{
        name: dislikes_name,
        description: "dislike",
        account_id: account3.id
      }

      {:ok, folder} = RC.Repo.insert(folder_attrs)
      {:ok, folder2} = RC.Repo.insert(folder_attrs2)
      {:ok, folder3} = RC.Repo.insert(folder_attrs3)
      {:ok, folder4} = RC.Repo.insert(folder_attrs4)

      # scenario is in 2 `likes` folder and 1 normal folder
      {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])
      {:ok, _} = Scenarios.insert_map_or_scenario(folder2, [scenario.id])
      {:ok, _} = Scenarios.insert_map_or_scenario(folder3, [scenario.id])
      {:ok, _} = Scenarios.insert_map_or_scenario(folder4, [scenario.id])

      [scenario_returned] = Scenarios.list_scenarios(%{}).entries
      assert scenario_returned.likes == 2
      assert scenario_returned.dislikes == 1
    end

    test "list_scenarios/0 returns all scenarios" do
      scenario = scenario_fixture()

      scenario =
        scenario
        |> put_counts()

      assert Scenarios.list_scenarios().entries == [scenario]
    end

    test "get_scenario/1 returns the scenario with given id" do
      scenario = scenario_fixture()
      assert Scenarios.get_scenario(scenario.id) == scenario |> put_counts()
    end

    test "create_scenario/1 with valid data and no thumbnail creates a scenario that reuse the Map's thumbnail" do
      map = map_fixture()

      attrs = %{
        game_data: Map.merge(map.game_data, @scenario_create_attrs.scenario_data.game_data),
        game_metadata: Map.merge(map.game_metadata, @scenario_create_attrs.scenario_data.game_metadata),
        is_official: map.is_official,
        is_map: false,
        thumbnail: map.thumbnail
      }

      assert {:ok, %{scenario: %Scenario{}}} = Scenarios.create_scenario(attrs, :reuse_thumbnail)
      # Stage 2 — the parent `map` from map_fixture/0 has empty game_data,
      # so its auto-gen thumbnail never runs and the file isn't there to
      # reuse. The scenario's own thumbnail (auto-gen from non-empty
      # game_data here) lands at `thumbnail_thumb.png` in scenarios/{sid}/.
      assert File.exists?(get_path(map, "test_thumb.png")) == false
    end

    test "create_scenario/1 with valid data and no thumbnail creates a scenario that has no thumbnail if the Map does not have one" do
      map = map_fixture(:no_thumbnail)

      attrs = %{
        game_data: Map.merge(map.game_data, @scenario_create_attrs.scenario_data.game_data),
        game_metadata: Map.merge(map.game_metadata, @scenario_create_attrs.scenario_data.game_metadata),
        is_official: map.is_official,
        is_map: false,
        thumbnail: map.thumbnail
      }

      assert {:ok, %{scenario: %Scenario{} = scenario}} = Scenarios.create_scenario(attrs, :no_thumbnail)
      assert scenario.game_data == attrs.game_data
      assert scenario.game_metadata == attrs.game_metadata
      assert scenario.is_map == attrs.is_map
      assert scenario.is_official == attrs.is_official
      assert File.exists?(get_path(map, "test_thumb.png")) == false
    end

    test "create_scenario/1 with valid data and a thumbnail creates a scenario" do
      map = map_fixture()

      attrs = %{
        game_data: Map.merge(map.game_data, @scenario_create_attrs.scenario_data.game_data),
        game_metadata: Map.merge(map.game_metadata, @scenario_create_attrs.scenario_data.game_metadata),
        is_official: map.is_official,
        is_map: false,
        thumbnail: @image_plug_upload
      }

      assert {:ok, %{scenario_with_thumbnail: %Scenario{} = scenario}} =
               Scenarios.create_scenario(attrs, :create_thumbnail)

      # Stage 2 — user-supplied thumbnail is silently ignored (not in
      # @castable_attrs). With non-empty game_data the auto-gen flow
      # runs instead and writes `thumbnail_thumb.png` (Waffle naming
      # of the SVG → PNG output, not the test.png the test uploaded).
      assert File.exists?(get_path(scenario, "thumbnail_thumb.png", "scenarios")) ==
               true

      assert scenario.game_data == attrs.game_data
      assert scenario.game_metadata == attrs.game_metadata
      assert scenario.is_map == attrs.is_map
      assert scenario.is_official == attrs.is_official
    end
  end

  describe "json filters" do
    @map_filters_create_attrs %{
      game_data: %{size: 500, victory_type: "kaboom", speed: 100, other_stuffs: "some more data"},
      game_metadata: %{size: 500, victory_type: "kaboom", speed: 100, factions_number: 5, factions_capacity: 10},
      is_map: true,
      is_official: true,
      thumbnail: @image_plug_upload
    }

    def map_game_data_fixture(attrs \\ %{}) do
      {:ok, %{map_with_thumbnail: map}} =
        attrs
        |> Enum.into(@map_filters_create_attrs)
        |> Scenarios.create_map()

      # Stage 2 — list endpoints default to published-only.
      {:ok, _} = Scenarios.publish_map(map)
      Scenarios.get_map(map.id)
    end

    setup do
      on_exit(fn -> File.rm_rf(@stored_file_path) end)
    end

    # test "list_maps/1 with list as filters returns scenarios with selected columns" do
    #   map = map_game_data_fixture()
    #
    #   maps = Scenarios.list_maps(["size"])
    #   assert maps = [map.game_data]
    # end

    test "list_maps/1 with map as filters returns filtered scenarios" do
      map = map_game_data_fixture()

      [map_returned] = Scenarios.list_maps(%{"size" => "500"}).entries
      # `map` now comes from get_map (DB roundtrip) so game_data has string
      # keys, not atom keys — `.size` (atom access) used to work on the
      # in-memory create result but not after refetch.
      assert map_returned.game_data["size"] == map.game_data["size"]
      assert map_returned.game_data["speed"] == map.game_data["speed"]
      assert map_returned.game_data["victory_type"] == map.game_data["victory_type"]
    end

    test "list_maps/1 with map as filters returns nothing" do
      _map = map_game_data_fixture()

      maps = Scenarios.list_maps(%{"size" => "600"}).entries
      assert maps == []
    end

    # test "list_maps/1 with map with multiple values as filters returns the map" do
    #   _map = map_game_data_fixture()

    #   filter = %{"size" => "500", "speed" => "100", "victory_type" => "kaboom"}

    #   [map_returned] = Scenarios.list_maps(filter).entries
    #   assert map_returned.game_data["speed"] == 100
    #   assert map_returned.game_data["size"] == 500
    #   assert map_returned.game_data["victory_type"] == filter["victory_type"]
    # end

    test "list_maps/1 with is_official in filters returns the map" do
      map = map_game_data_fixture()

      # Stage 2 — `is_official` is no longer settable via create_map attrs
      # (admin-only flag). Directly flip it on the row so this filter test
      # has a true-valued row to find.
      {:ok, _} =
        map
        |> Ecto.Changeset.change(is_official: true)
        |> RC.Repo.update()

      filter = %{"is_official" => true}

      [map_returned] = Scenarios.list_maps(filter).entries
      assert map_returned.game_data["speed"] == 100
      assert map_returned.game_data["size"] == 500
      assert map_returned.game_data["victory_type"] == "kaboom"
    end
  end

  describe "folders" do
    alias RC.Scenarios.Folder

    @valid_attrs %{name: "some name", description: "some description"}
    @update_attrs %{name: "some updated name", description: "some updated description"}
    @invalid_attrs %{name: nil, description: nil}

    def folder_fixture(attrs \\ %{}) do
      {:ok, folder} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Scenarios.create_folder()

      folder
    end

    setup do
      on_exit(fn -> File.rm_rf(@stored_file_path) end)
    end

    test "list_folders/0 returns all folders" do
      folder = folder_fixture()
      assert Scenarios.list_folders().entries == [folder]
    end

    test "get_folder/1 returns the folder with given id" do
      folder = folder_fixture()
      assert Scenarios.get_folder(folder.id) == folder
    end

    test "create_folder/1 with valid data creates a folder" do
      assert {:ok, %Folder{} = folder} = Scenarios.create_folder(@valid_attrs)
      assert folder.name == "some name"
    end

    test "create_folder/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Scenarios.create_folder(@invalid_attrs)
    end

    test "update_folder/2 with valid data updates the folder" do
      folder = folder_fixture()
      assert {:ok, %Folder{} = folder} = Scenarios.update_folder(folder, @update_attrs)
      assert folder.name == "some updated name"
    end

    test "update_folder/2 with invalid data returns error changeset" do
      folder = folder_fixture()
      assert {:error, %Ecto.Changeset{}} = Scenarios.update_folder(folder, @invalid_attrs)
      assert folder == Scenarios.get_folder(folder.id)
    end

    test "delete_folder/1 deletes the folder" do
      folder = folder_fixture()
      assert {:ok, %Folder{}} = Scenarios.delete_folder(folder)
      assert Scenarios.get_folder(folder.id) == nil
    end

    test "insert_map_or_scenario/2 insert scenarios in a folder" do
      folder = folder_fixture()
      scenario = scenario_fixture()
      assert {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])
    end

    test "insert_map_or_scenario/2 insert map in a folder" do
      folder = folder_fixture()
      map = map_fixture()
      assert {:ok, _} = Scenarios.insert_map_or_scenario(folder, [map.id])
    end

    test "remove_map_or_scenario/2 remove a scenario from folder" do
      folder = folder_fixture()
      scenario = scenario_fixture()
      assert {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])
      assert {1, _} = Scenarios.remove_map_or_scenario(folder, scenario.id)
    end

    test "remove_map_or_scenario/2 remove a map from folder" do
      folder = folder_fixture()
      map = map_fixture()
      assert {:ok, _} = Scenarios.insert_map_or_scenario(folder, [map.id])
      assert {1, _} = Scenarios.remove_map_or_scenario(folder, map.id)
    end

    test "adds scenario in likes folder and returns all liked scenarios correctly" do
      account = fixture(:user)
      scenario = scenario_fixture()

      folder_attrs = %Folder{
        name: Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_likes_name),
        description: "likes",
        account_id: account.id
      }

      {:ok, folder} = RC.Repo.insert(folder_attrs)

      assert Scenarios.folder_exists?(account.id, :scenario_likes_name) == true
      assert {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])

      # list_scenarios(account_id, folder_filter) doesn't run the counts
      # aggregate (unlike get_scenario / list_scenarios/0), so nil out the
      # fixture's counts before comparing — they don't have to match the
      # folder-filtered listing's lighter projection.
      scenario_for_compare =
        scenario
        |> Map.put(:likes, nil)
        |> Map.put(:dislikes, nil)
        |> Map.put(:favorites, nil)
        |> Map.put(:plays, nil)
        |> Map.put(:author, %Ecto.Association.NotLoaded{
          __field__: :author,
          __cardinality__: :one,
          __owner__: RC.Scenarios.Scenario
        })

      assert Scenarios.list_scenarios(account.id, :scenario_likes_name).entries == [scenario_for_compare]
    end

    test "get_likes_count/1 gets likes count" do
      account = fixture(:user)
      scenario = scenario_fixture()

      folder_attrs = %Folder{
        name: Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_likes_name),
        description: "likes",
        account_id: account.id
      }

      {:ok, folder} = RC.Repo.insert(folder_attrs)

      {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])

      assert Scenarios.get_reserved_folder_count(scenario.id, :scenario_likes_name) == 1
    end

    test "get_opposite_folder/3 gets the like folder when atom is :dislike" do
      account = fixture(:user)
      scenario = scenario_fixture()

      folder_attrs = %Folder{
        name: Application.get_env(:rc, RC.Scenarios.Folder) |> Keyword.get(:scenario_likes_name),
        description: "likes",
        account_id: account.id
      }

      {:ok, folder} = RC.Repo.insert(folder_attrs)

      {:ok, _} = Scenarios.insert_map_or_scenario(folder, [scenario.id])

      opposite_folder = Scenarios.get_opposite_folder(account.id, scenario.id, :dislike)

      assert opposite_folder == folder
    end

    test "get_opposite_folder/3 returns nil when atom is :like and the scenario is not disliked" do
      account = fixture(:user)
      scenario = scenario_fixture()

      opposite_folder = Scenarios.get_opposite_folder(account.id, scenario.id, :like)

      assert opposite_folder == nil
    end
  end
end
