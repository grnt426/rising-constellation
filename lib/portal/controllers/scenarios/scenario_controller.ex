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

  # Availability guardrails — same rationale and numbers as
  # Portal.MapController (see the comment there). Per-account,
  # admins exempt inside the plug.
  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "scenario_create", limit: 10, window_ms: 3_600_000] when action == :create
  )

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "scenario_update", limit: 120, window_ms: 3_600_000] when action == :update
  )

  defp admin?(conn), do: RC.Guardian.Plug.current_resource(conn).role == :admin

  defp galaxy_too_large(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{message: :galaxy_too_large, limit: Portal.ForgeSize.max_systems()})
  end

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
    |> mirror_mutators_into_metadata()
  end

  # Stage 5 — mutators are the source of truth under game_data. We
  # mirror just the list (no other game_data spilled) into
  # game_metadata so the lightweight list-row partial can render
  # "Empire of Wealth" chips without shipping the whole 100KB
  # game_data blob to every Forge list request.
  defp mirror_mutators_into_metadata(%{"game_data" => gd, "game_metadata" => gm} = params)
       when is_map(gd) and is_map(gm) do
    mutators = Map.get(gd, "mutators", [])
    %{params | "game_metadata" => Map.put(gm, "mutators", mutators)}
  end

  defp mirror_mutators_into_metadata(params), do: params

  # Attached scripts (Edict) are rebuilt on the server from the ids the
  # editor sent: each frozen from its author's saved version, or kept as the
  # scenario had it when it is no longer available (RC.Scripts.attach/3).
  # Lists render game_metadata only, so the flag and the names are mirrored
  # there for the "scripted" badge.
  defp attach_scripts(%{"game_data" => gd} = params, account_id, previous_game_data) when is_map(gd) do
    frozen = RC.Scripts.attach(gd["scripts"], account_id, previous_game_data)
    gd = if frozen == [], do: Map.delete(gd, "scripts"), else: Map.put(gd, "scripts", frozen)

    params = %{params | "game_data" => gd}

    # an update may leave game_metadata out: then it stays as it is
    case params["game_metadata"] do
      %{} = gm when frozen == [] ->
        %{params | "game_metadata" => Map.drop(gm, ["scripted", "scripts"])}

      %{} = gm ->
        scripts = Enum.map(frozen, &Map.take(&1, ["id", "name"]))
        %{params | "game_metadata" => Map.merge(gm, %{"scripted" => true, "scripts" => scripts})}

      _ ->
        params
    end
  end

  defp attach_scripts(params, _account_id, _previous), do: params

  defp script_checks(%Scenario{game_data: game_data}), do: Edict.Attachment.check(game_data)

  def create(conn, %{"scenario" => scenario_params}) do
    author_id = RC.Guardian.Plug.current_resource(conn).id
    scenario_params = scenario_params |> sanitize_scenario_params() |> attach_scripts(author_id, nil)

    with :ok <- Portal.ForgeSize.check_params(scenario_params, admin?(conn)),
         {:ok, %{scenario_with_thumbnail: %Scenario{} = scenario}} <-
           Scenarios.create_scenario(scenario_params, author_id, :no_thumbnail) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.scenario_path(conn, :show, scenario))
      |> render("show.json", scenario: scenario, script_checks: script_checks(scenario))
    else
      {:error, :galaxy_too_large} -> galaxy_too_large(conn)
      error -> error
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

  # `sid` is a numeric id or a share token (RC.ShareToken). Drafts behind
  # a numeric id are author/admin-only; see Scenarios.viewable?/3.
  def show(conn, %{"sid" => ref}) do
    with {scenario, via} <- Scenarios.fetch_scenario_by_ref(ref),
         true <- Scenarios.viewable?(scenario, via, RC.Guardian.Plug.current_resource(conn)) do
      render(conn, "show.json", scenario: scenario)
    else
      _ -> {:error, :not_found}
    end
  end

  def update(conn, %{"sid" => id, "scenario" => scenario_params}) do
    account_id = RC.Guardian.Plug.current_resource(conn).id
    scenario_params = sanitize_scenario_params(scenario_params)

    with :ok <- Portal.ForgeSize.check_params(scenario_params, admin?(conn)),
         scenario when not is_nil(scenario) <- Scenarios.get_scenario(id),
         scenario_params = attach_scripts(scenario_params, account_id, scenario.game_data),
         {:ok, %Scenario{} = scenario} <- Scenarios.update_scenario(scenario, scenario_params) do
      render(conn, "show.json", scenario: scenario, script_checks: script_checks(scenario))
    else
      nil -> {:error, :not_found}
      {:error, :galaxy_too_large} -> galaxy_too_large(conn)
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
