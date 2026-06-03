defmodule Portal.MapController do
  @moduledoc """

  The Map controller.

  Thumbnail files URI: `https://waffle-uploads.s3.fr-par.scw.cloud/storage/thumbnails/scenarios/id/filename_thumb.png`

  ### Logged in as admin:

  Create a Map:
      POST /maps
  Update a Map:
      PUT /maps/:mid
  Delete a Map
      DELETE /maps/:mid

  ### Logged in as regular user:

  List the Maps:
      GET /maps, (optional) body: %{filters: %{size: ..., speed: ...}}
  Get a single Map:
      GET /maps/:mid
  """
  use Portal, :controller

  alias RC.Scenarios

  require Logger

  action_fallback(Portal.FallbackController)

  def index(conn, params) do
    account_id = RC.Guardian.Plug.current_resource(conn).id

    # `visible_to` is the published-OR-own-drafts gate from Stage 2.
    # `mine` and `favorited` are chip filters — the frontend just sends
    # "true" to switch them on, and the controller substitutes the
    # current account_id so the context query has something to filter
    # by. Untouched when the chip is off so the value falls through to
    # `put_map_filters/2`'s unknown-key clause and is ignored.
    params =
      params
      |> Map.put_new("visible_to", account_id)
      |> coerce_account_chip("mine", account_id)
      |> coerce_account_chip("favorited", account_id)
      |> coerce_account_chip("drafts", account_id)

    maps = Scenarios.list_maps(params)

    conn
    |> Scrivener.Headers.paginate(maps)
    |> render("index.json", maps: maps)
  end

  # If the chip is on (any truthy value), replace it with the caller's
  # account_id; otherwise drop the key entirely so it doesn't trip the
  # filter clause with a non-integer value.
  defp coerce_account_chip(params, key, account_id) do
    case Map.get(params, key) do
      v when v in [true, "true", "1", 1] -> Map.put(params, key, account_id)
      nil -> params
      _ -> Map.delete(params, key)
    end
  end

  def create(conn, %{"map" => map_params}) do
    # Forge Stage 2 — author is whoever's logged in. Strip any client-set
    # `is_official` / `thumbnail`; the server fully controls authorship
    # and thumbnails, the latter rendered from game_data after insert.
    author_id = RC.Guardian.Plug.current_resource(conn).id
    map_params = Map.drop(map_params, ["is_official", "author_id", "published_at", "thumbnail"])

    case Scenarios.create_map(map_params, author_id) do
      {:ok, %{map_with_thumbnail: map}} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", Routes.map_path(conn, :show, map))
        |> render("show.json", map: map)

      error ->
        error
    end
  end

  def publish(conn, %{"mid" => id}) do
    with map when not is_nil(map) <- Scenarios.get_map(id),
         {:ok, %RC.Scenarios.Map{} = map} <- Scenarios.publish_map(map) do
      render(conn, "show.json", map: map)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end


  def preview_edges(conn, %{"systems" => systems, "blackholes" => blackholes}) do
    systems =
      Enum.map(systems, fn %{"key" => key, "position" => %{"x" => x, "y" => y}} ->
        %{id: key, position: %Spatial.Position{x: x, y: y}}
      end)

    blackholes =
      Enum.map(blackholes, fn %{"radius" => radius, "position" => %{"x" => x, "y" => y}} ->
        %{radius: radius, position: %Spatial.Position{x: x, y: y}}
      end)

    edges = Instance.Galaxy.SpatialGraph.generate_edges(systems, blackholes)

    conn
    |> put_status(200)
    |> render("edges.json", edges: edges)
  end

  def show(conn, %{"mid" => id}) do
    case Scenarios.get_map(id) do
      nil ->
        {:error, :not_found}

      map ->
        render(conn, "show.json", map: map)
    end
  end

  def update(conn, %{"mid" => id, "map" => map_params}) do
    # Same guardrails as create — author/is_official/published_at are
    # server-controlled, never user-supplied.
    map_params = Map.drop(map_params, ["is_official", "author_id", "published_at"])

    with map when not is_nil(map) <- Scenarios.get_map(id),
         {:ok, %RC.Scenarios.Map{} = map} <- Scenarios.update_map(map, map_params) do
      render(conn, "show.json", map: map)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def delete(conn, %{"mid" => id}) do
    with map when not is_nil(map) <- Scenarios.get_map_as_scenario(id),
         {:ok, _} <- Scenarios.delete_scenario(map) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end
end
