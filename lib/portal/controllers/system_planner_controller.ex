defmodule Portal.SystemPlannerController do
  @moduledoc """
  The system planner page's backend (see `RC.SystemPlanner`). Both actions
  are pure computations over static game data: no instance, no persistence.
  """
  use Portal, :controller

  # POST /api/system-planner/compute
  def compute(conn, params) do
    case RC.SystemPlanner.compute(params) do
      {:ok, result} ->
        json(conn, result)

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{message: reason})
    end
  end

  # GET /api/system-planner/template?speed=slow
  def template(conn, params) do
    case RC.SystemPlanner.parse_speed(Map.get(params, "speed", "slow")) do
      {:ok, speed} ->
        json(conn, RC.SystemPlanner.template(speed))

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{message: reason})
    end
  end
end
