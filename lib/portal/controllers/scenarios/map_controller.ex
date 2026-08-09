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

  # Availability guardrails (see docs/forge-redesign.md "Rate-limit
  # map/scenario creation" and docs/preview-edges-proposal.md). All
  # per-account, admins exempt inside the plug.
  #
  # - create: table-fill spam bound. 10/hour is far above any human
  #   authoring cadence.
  # - update: every save rewrites a multi-hundred-KB game_data blob;
  #   120/hour still allows a save every 30s for a whole editing session.
  # - preview_edges: synchronous O(n²) CPU work per call. The editor
  #   debounces to ~3 calls/s in short bursts while a slider drags;
  #   30/min covers that while bounding sustained abuse.
  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "map_create", limit: 10, window_ms: 3_600_000] when action == :create
  )

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "map_update", limit: 120, window_ms: 3_600_000] when action == :update
  )

  plug(
    Portal.Plug.AccountRateLimit,
    [bucket: "map_preview_edges", limit: 30, window_ms: 60_000] when action == :preview_edges
  )

  defp admin?(conn), do: RC.Guardian.Plug.current_resource(conn).role == :admin

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

    with :ok <- Portal.ForgeSize.check_params(map_params, admin?(conn)),
         {:ok, %{map_with_thumbnail: map}} <- Scenarios.create_map(map_params, author_id) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.map_path(conn, :show, map))
      |> render("show.json", map: map)
    else
      {:error, :galaxy_too_large} -> galaxy_too_large(conn)
      error -> error
    end
  end

  defp galaxy_too_large(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{message: :galaxy_too_large, limit: Portal.ForgeSize.max_systems()})
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

  def preview_edges(conn, %{"systems" => systems, "blackholes" => blackholes})
      when is_list(systems) and is_list(blackholes) do
    # Size gate BEFORE any per-element work: generate_edges is O(n²) and
    # runs synchronously in the request process, so an uncapped list is
    # a direct CPU-pinning primitive.
    if not admin?(conn) and length(systems) > Portal.ForgeSize.max_systems() do
      galaxy_too_large(conn)
    else
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

    with :ok <- Portal.ForgeSize.check_params(map_params, admin?(conn)),
         map when not is_nil(map) <- Scenarios.get_map(id),
         {:ok, %RC.Scenarios.Map{} = map} <- Scenarios.update_map(map, map_params) do
      render(conn, "show.json", map: map)
    else
      nil -> {:error, :not_found}
      {:error, :galaxy_too_large} -> galaxy_too_large(conn)
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
