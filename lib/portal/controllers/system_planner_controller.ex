defmodule Portal.SystemPlannerController do
  @moduledoc """
  The system planner page's backend (see `RC.SystemPlanner`). Every action
  is a pure computation over static game data: no instance, no persistence.
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

  # GET /api/system-planner/preset/:name
  # A ready-made plan (the help manual's example systems), in the format the
  # page imports.
  def preset(conn, %{"name" => name}) do
    case RC.SystemPlanner.Presets.fetch(name) do
      {:ok, plan} ->
        json(conn, plan)

      :error ->
        conn
        |> put_status(404)
        |> json(%{message: :unknown_preset})
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
