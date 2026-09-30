defmodule Portal.MaintenanceController do
  use Portal, :controller

  def healthcheck(conn, _params) do
    conn
    |> put_status(200)
    |> json("ok")
  end

  def maintenance(conn, _params) do
    if RC.Maintenance.get_flag() do
      conn
      |> put_status(500)
      |> json(true)
    else
      conn
      |> put_status(200)
      |> json(0)
    end
  end

  # Which server is live (RC.Build): `%{version, live_since, deploying}`.
  # Public, and never cached anywhere — a stale answer defeats the point.
  def backend_version(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(200)
    |> json(RC.Build.info())
  end
end
