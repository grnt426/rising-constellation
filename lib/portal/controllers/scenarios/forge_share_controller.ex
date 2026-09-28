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

  Only published rows get tags (the same gate the anonymous list
  endpoints use). A draft's share URL redirects to its SPA detail page
  untagged: the author (the only one the SPA shows a draft to) still
  lands on it, and nothing about the work-in-progress leaks into an
  unfurl. Unknown ids 404.
  """
  use Portal, :controller

  alias RC.Scenarios

  def map(conn, %{"id" => id}), do: share(conn, fetch(id, &Scenarios.get_map/1), :map)

  def scenario(conn, %{"id" => id}),
    do: share(conn, fetch(id, &Scenarios.get_scenario/1), :scenario)

  defp share(conn, nil, _kind), do: not_found(conn)
  defp share(conn, {:draft, row}, kind), do: redirect(conn, to: Portal.ForgeOg.data(row, kind).spa_url)
  defp share(conn, row, kind), do: render_share(conn, row, kind)

  # Parse before hitting the context — Ecto raises CastError on a
  # non-numeric id, and a garbage share URL should just 404.
  defp fetch(id, getter) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case getter.(int_id) do
          %{published_at: %DateTime{}} = row -> row
          %{} = draft -> {:draft, draft}
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
