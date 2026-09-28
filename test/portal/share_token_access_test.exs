defmodule Portal.ShareTokenAccessTest do
  @moduledoc """
  Share tokens (RC.ShareToken) vs numeric ids on the API: a token opens
  drafts and private lobbies; a numeric id opens only what's public or
  what the caller could already reach, so nothing is enumerable.
  """
  use Portal.APIConnCase

  import RC.Fixtures

  alias RC.Scenarios

  @game_data %{size: 120, systems: [], sectors: [], blackholes: []}

  setup %{conn: conn} do
    author = fixture(:user)
    other = fixture(:user2)

    {:ok, %{map_with_thumbnail: draft_map}} =
      Scenarios.create_map(%{game_data: @game_data, game_metadata: %{name: "WIP"}, is_map: true}, author.id)

    {:ok, %{scenario: draft_scenario}} =
      Scenarios.create_scenario(
        %{game_data: @game_data, game_metadata: %{name: "WIP scenario"}, is_map: false},
        author.id,
        :no_thumbnail
      )

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      author: author,
      other: other,
      draft_map: draft_map,
      draft_scenario: draft_scenario
    }
  end

  describe "maps and scenarios" do
    test "a draft by numeric id opens for its author only", %{conn: conn, author: author, other: other} = ctx do
      assert conn |> login(author) |> get("/api/maps/#{ctx.draft_map.id}") |> json_response(200)
      assert conn |> login(other) |> get("/api/maps/#{ctx.draft_map.id}") |> json_response(404)
      assert conn |> login(other) |> get("/api/scenarios/#{ctx.draft_scenario.id}") |> json_response(404)
    end

    test "admins open any draft by numeric id", %{conn: conn} = ctx do
      assert conn |> login(fixture(:admin)) |> get("/api/maps/#{ctx.draft_map.id}") |> json_response(200)
    end

    test "a draft by share token opens for anyone", %{conn: conn, other: other} = ctx do
      body = conn |> login(other) |> get("/api/maps/#{ctx.draft_map.share_token}") |> json_response(200)
      assert body["id"] == ctx.draft_map.id
      assert body["share_token"] == ctx.draft_map.share_token

      assert conn |> login(other) |> get("/api/scenarios/#{ctx.draft_scenario.share_token}") |> json_response(200)
    end

    test "published rows keep opening by numeric id", %{conn: conn, other: other} = ctx do
      {:ok, _} = Scenarios.publish_map(ctx.draft_map)

      assert conn |> login(other) |> get("/api/maps/#{ctx.draft_map.id}") |> json_response(200)
    end

    test "junk and unknown refs 404", %{conn: conn, other: other} do
      assert conn |> login(other) |> get("/api/maps/AAAAAAAAAAAAAAAA") |> json_response(404)
      assert conn |> login(other) |> get("/api/maps/not-a-token") |> json_response(404)
    end

    test "someone else's draft can't seed a game by numeric id", %{conn: conn, other: other} = ctx do
      conn =
        conn
        |> login(other)
        |> post("/api/instances", %{
          instance: %{"name" => "x", "factions" => []},
          scenario_id: ctx.draft_scenario.id
        })

      assert json_response(conn, 404) == %{"message" => "scenario_not_found"}
    end
  end

  describe "lobbies" do
    setup do
      %{instance: instance} = RC.ScenarioFixtures.instance_fixture()

      open =
        RC.Instances.Instance
        |> RC.Repo.get!(instance.id)
        |> Ecto.Changeset.change(state: "open")
        |> RC.Repo.update!()

      %{instance: open}
    end

    test "a public game keeps opening by numeric id", %{conn: conn, other: other, instance: instance} do
      assert conn |> login(other) |> get("/api/instances/#{instance.id}") |> json_response(200)
    end

    test "a private game by numeric id is refused to outsiders", %{conn: conn, other: other, instance: instance} do
      private = instance |> Ecto.Changeset.change(public: false) |> RC.Repo.update!()

      assert conn |> login(other) |> get("/api/instances/#{private.id}") |> json_response(404)
      assert conn |> login(other) |> get("/api/instances/#{private.id}/registrations") |> json_response(404)
    end

    test "a private game by share token opens the read-only lobby routes", %{conn: conn, other: other} = ctx do
      private = ctx.instance |> Ecto.Changeset.change(public: false) |> RC.Repo.update!()
      token = private.share_token

      body = conn |> login(other) |> get("/api/instances/#{token}") |> json_response(200)
      assert body["id"] == private.id
      assert conn |> login(other) |> get("/api/instances/#{token}/registrations") |> json_response(200)
      assert conn |> login(other) |> get("/api/instances/#{token}/news") |> json_response(200)
    end

    test "a share token opens nothing but the lobby reads", %{conn: conn, other: other, instance: instance} do
      assert conn |> login(other) |> put("/api/instances/#{instance.share_token}/start") |> json_response(403)
    end
  end
end
