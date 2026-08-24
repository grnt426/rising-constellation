defmodule Portal.SpaShareController do
  @moduledoc """
  Serves the SPA's index.html for the shareable Forge URLs —

      /portal/create/map/view/:id       /portal/create/map/:id
      /portal/create/scenario/view/:id  /portal/create/scenario/edit/:id
      /portal/create/scenario/new/:id   (unfurls as the source map)

  — with the row's OpenGraph tags injected into `<head>`, so a link a
  player copies straight from the address bar unfurls on Discord just
  like the dedicated /forge share URL. The page itself is byte-for-byte
  the SPA (the app boots and routes normally); scrapers read the
  injected tags, browsers ignore them.

  In prod these requests arrive via an nginx `location` that forwards
  exactly these paths to Phoenix instead of serving the static bundle
  (see deploy/nginx/rc.conf.example); nginx also intercepts any 404
  from here and falls back to the static index.html, so a release
  without these routes — or a missing index file — degrades to today's
  behavior instead of breaking deep links.

  Draft or unknown rows get the untouched index.html: these are real
  app URLs and must always load the SPA, they just don't earn tags.
  Routes exist in prod and test only — dev serves /portal through the
  Vue dev-server proxy, which must keep receiving these paths.
  """
  use Portal, :controller

  alias RC.Scenarios

  def map_view(conn, %{"id" => id}), do: serve(conn, id, :map)
  def map_edit(conn, %{"id" => id}), do: serve(conn, id, :map)
  def scenario_view(conn, %{"id" => id}), do: serve(conn, id, :scenario)
  def scenario_edit(conn, %{"id" => id}), do: serve(conn, id, :scenario)
  # "Create a scenario from map :id" — the interesting entity is the map.
  def scenario_new(conn, %{"id" => id}), do: serve(conn, id, :map)

  defp serve(conn, id, kind) do
    case index_html() do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        # Bounded staleness for the CloudFront/browser caches in front:
        # a renamed or freshly-thumbnailed row updates its unfurl within
        # the hour without waiting for a deploy invalidation.
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, maybe_inject(html, fetch(id, kind), conn))

      _ ->
        # No index.html to serve (nginx misroute, half-finished deploy).
        # nginx intercepts this 404 and serves the static bundle.
        send_resp(conn, 404, "not found")
    end
  end

  # Published rows only — same anonymous-visibility gate as the /forge
  # pages and the list endpoints. Everything else serves the plain SPA.
  defp fetch(id, kind) do
    getter = if kind == :map, do: &Scenarios.get_map/1, else: &Scenarios.get_scenario/1

    case Integer.parse(id) do
      {int_id, ""} ->
        case getter.(int_id) do
          %{published_at: %DateTime{}} = row -> {row, kind}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_inject(html, nil, _conn), do: html

  defp maybe_inject(html, {row, kind}, conn) do
    data = Portal.ForgeOg.data(row, kind)
    page_url = Portal.Endpoint.url() <> conn.request_path
    tags = Portal.ForgeOg.meta_tags(data, page_url)

    html
    |> String.replace("<head>", "<head>" <> tags, global: false)
    |> replace_title(data.title)
  end

  # The built index ships a static <title>Tetrarchy Falls</title>; swap
  # it when present so the browser tab and any scraper that prefers
  # <title> over og:title show the design's name. A rebuilt bundle with
  # a different title tag just keeps its own — og:title still carries
  # the name for unfurls.
  defp replace_title(html, title) do
    escaped = title |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    String.replace(
      html,
      "<title>Tetrarchy Falls</title>",
      "<title>#{escaped} — Tetrarchy Falls</title>",
      global: false
    )
  end

  # The Vue bundle's index.html. Prod extracts vue.tar.gz under
  # /home/rc/www-root (nginx's docroot — see deploy/bin/deploy.sh), so
  # that path comes first; priv/static/portal covers setups that serve
  # the SPA straight from Phoenix. Tests point :index_path at a fixture.
  defp index_html do
    configured = Application.get_env(:rc, __MODULE__, [])[:index_path]

    [
      configured,
      "/home/rc/www-root/asylamba/front/index.html",
      Application.app_dir(:rc, "priv/static/portal/index.html")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value({:error, :not_found}, fn path ->
      case File.read(path) do
        {:ok, html} -> {:ok, html}
        _ -> nil
      end
    end)
  end
end
