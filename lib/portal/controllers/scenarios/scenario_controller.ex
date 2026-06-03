defmodule Portal.ScenarioController do
  @moduledoc """
  The Scenario controller.

  Thumbnail files URI if a thumbnail is provided:
  `https://waffle-uploads.s3.fr-par.scw.cloud/storage/thumbnails/scenarios/{scenario.id}/{filename}_thumb.png`

  Thumbnail files URI if reusing the Map's thumbnail:
  `https://waffle-uploads.s3.fr-par.scw.cloud/storage/thumbnails/scenarios/{map.id}/{filename}_thumb.png`


  ### Logged in as admin:

  Create a Scenario with a new thumbnail:
      POST /scenarios, body: %{map_id: map_id, scenario: %{"game_data" => _scenario_data, "game_metadata" => _scenario_metadata, "thumbnail" => %Plug.Upload{}} }
  Create a Scenario that use the thumbnail of the map:
      POST /scenarios, body: %{map_id: map_id, scenario: %{"game_data" => _scenario_data, "game_metadata" => _scenario_metadata}
  Update a Scenario:
      PUT /scenarios/:sid
  Delete a Scenario:
      DELETE /scenarios/:sid

  ### Logged in as regular user:

  List the Scenarios:
      GET /scenarios, (optional) query_params: %{size: ..., speed: ...}
  Get a single Scenario:
      GET /scenarios/:sid
  """
  use Portal, :controller

  alias RC.Scenarios.Scenario
  alias RC.Scenarios

  require Logger

  action_fallback(Portal.FallbackController)

  def index(conn, params) do
    # See Portal.MapController.index/2 — same chip-rewriting logic.
    account_id = RC.Guardian.Plug.current_resource(conn).id

    params =
      params
      |> Map.put_new("visible_to", account_id)
      |> coerce_account_chip("mine", account_id)
      |> coerce_account_chip("favorited", account_id)
      |> coerce_account_chip("drafts", account_id)

    scenarios = Scenarios.list_scenarios(params)

    conn
    |> Scrivener.Headers.paginate(scenarios)
    |> render("index.json", scenarios: scenarios)
  end

  defp coerce_account_chip(params, key, account_id) do
    case Map.get(params, key) do
      v when v in [true, "true", "1", 1] -> Map.put(params, key, account_id)
      nil -> params
      _ -> Map.delete(params, key)
    end
  end

  @doc """
  Creates a Scenario with either:
    - a provided thumbnail
    - the Map's thumbnail or no thumbnail if the map doesn't have one
  """
  # Forge Stage 2 — author is whoever's logged in; server controls
  # author_id, is_official, published_at, and thumbnail on every
  # write path.
  defp sanitize_scenario_params(params) do
    params
    |> Map.put("is_map", false)
    |> Map.drop(["is_official", "author_id", "published_at", "thumbnail"])
  end

  def create(conn, %{"scenario" => scenario_params}) do
    author_id = RC.Guardian.Plug.current_resource(conn).id
    scenario_params = sanitize_scenario_params(scenario_params)

    case Scenarios.create_scenario(scenario_params, author_id, :no_thumbnail) do
      {:ok, %{scenario_with_thumbnail: %Scenario{} = scenario}} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", Routes.scenario_path(conn, :show, scenario))
        |> render("show.json", scenario: scenario)

      error ->
        error
    end
  end

  def publish(conn, %{"sid" => id}) do
    with scenario when not is_nil(scenario) <- Scenarios.get_scenario(id),
         {:ok, %Scenario{} = scenario} <- Scenarios.publish_scenario(scenario) do
      render(conn, "show.json", scenario: scenario)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end


  def show(conn, %{"sid" => id}) do
    case Scenarios.get_scenario(id) do
      nil ->
        {:error, :not_found}

      scenario ->
        render(conn, "show.json", scenario: scenario)
    end
  end

  def update(conn, %{"sid" => id, "scenario" => scenario_params}) do
    scenario_params = sanitize_scenario_params(scenario_params)

    with scenario when not is_nil(scenario) <- Scenarios.get_scenario(id),
         {:ok, %Scenario{} = scenario} <- Scenarios.update_scenario(scenario, scenario_params) do
      render(conn, "show.json", scenario: scenario)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def delete(conn, %{"sid" => id}) do
    with scenario when not is_nil(scenario) <- Scenarios.get_scenario(id),
         {:ok, %Scenario{}} <- Scenarios.delete_scenario(scenario) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end
end
