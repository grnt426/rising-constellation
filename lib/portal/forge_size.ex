defmodule Portal.ForgeSize do
  @moduledoc """
  Central cap on the galaxy size accepted from non-admin users.

  Instance init, the spatial-graph generator, and the map editor all do
  work that grows super-linearly with system count, so an oversized
  galaxy is a CPU denial-of-service vector. One constant, enforced at
  every user-facing entry point:

    * `POST /instances` — starting a game from an oversized scenario
      (`Portal.InstanceController`)
    * `POST/PUT /maps` and `/scenarios` — storing an oversized galaxy
      (`Portal.MapController`, `Portal.ScenarioController`)
    * `POST /maps/preview-edges` — running the O(n²) edge generator on
      an oversized system list (`Portal.MapController`)

  Admins bypass the cap everywhere (official "Big One"-scale games).
  The scenario-select filter in front/src/portal/pages/play/Scenarios.vue
  mirrors this constant client-side.
  """

  @max_systems 2000

  def max_systems, do: @max_systems

  @doc """
  Counts systems in a game_data-shaped map. Tolerates string or atom
  keys (DB rows load with string keys; in-code fixtures may use atoms).
  """
  def system_count(%{} = game_data) do
    case Map.get(game_data, "systems") || Map.get(game_data, :systems) do
      systems when is_list(systems) -> length(systems)
      _ -> 0
    end
  end

  def system_count(_), do: 0

  @doc """
  Checks a `%{"game_data" => ...}` params map (map/scenario create and
  update bodies) against the cap. `:ok` when under the cap, when the
  actor is an admin, or when the body carries no game_data (partial
  updates such as publish/favorite metadata writes).
  """
  def check_params(_params, true = _admin?), do: :ok

  def check_params(params, false = _admin?) when is_map(params) do
    game_data = Map.get(params, "game_data") || Map.get(params, :game_data)

    if system_count(game_data) > @max_systems,
      do: {:error, :galaxy_too_large},
      else: :ok
  end

  def check_params(_params, false), do: :ok
end
