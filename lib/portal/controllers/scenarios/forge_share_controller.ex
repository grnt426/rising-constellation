defmodule Portal.ForgeShareController do
  @moduledoc """
  Public, no-auth share pages for Forge maps and scenarios:

      GET /forge/map/:id
      GET /forge/scenario/:id

  These exist so a link pasted outside the site (Discord, forums, chat
  apps) unfurls with the design's real name, a description line, and the
  galaxy thumbnail — the SPA's routes all serve the same index.html, so
  scrapers can never see per-map metadata there. Human visitors are
  meta-refreshed straight into the SPA's detail page; scrapers don't
  follow the refresh and read the OpenGraph tags off this page.

  Only published rows are served (the same gate the anonymous list
  endpoints use) — a draft's share URL 404s rather than leaking the
  author's work-in-progress.
  """
  use Portal, :controller

  alias RC.Scenarios

  def map(conn, %{"id" => id}) do
    case fetch(id, &Scenarios.get_map/1) do
      nil -> not_found(conn)
      map -> render_share(conn, map, :map)
    end
  end

  def scenario(conn, %{"id" => id}) do
    case fetch(id, &Scenarios.get_scenario/1) do
      nil -> not_found(conn)
      scenario -> render_share(conn, scenario, :scenario)
    end
  end

  # Parse before hitting the context — Ecto raises CastError on a
  # non-numeric id, and a garbage share URL should just 404.
  defp fetch(id, getter) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case getter.(int_id) do
          %{published_at: %DateTime{}} = row -> row
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp render_share(conn, row, kind) do
    data = Portal.ForgeOg.data(row, kind)

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render("show.html",
      title: data.title,
      description: data.description,
      image: data.image,
      share_url: data.share_url,
      spa_url: data.spa_url
    )
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> text("Not found")
  end
end
