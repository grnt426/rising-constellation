defmodule Portal.HelpController do
  @moduledoc """
  `GET /api/help/:lang?speed=slow` — the compiled help manual as JSON for
  the SPA (help modal and the Help drawer's Manual tab). Public: the same
  pages are served to everyone at `/help`. The bundle is a compile-time
  constant, so an ETag lets the client revalidate for free.
  """

  use Portal, :controller

  alias RC.Help

  @speeds %{"fast" => :fast, "medium" => :medium, "slow" => :slow, "daily" => :slow}

  def bundle(conn, %{"lang" => lang} = params) do
    lang = if lang in Help.languages(), do: lang, else: "en"
    speed = Map.get(@speeds, params["speed"], :slow)
    etag = ~s("help-#{Help.version()}-#{lang}-#{speed}")

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "public, max-age=300")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      json(conn, Help.bundle(lang, speed))
    end
  end
end
