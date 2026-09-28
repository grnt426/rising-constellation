defmodule Portal.ForgeShareController do
  @moduledoc """
  Public, no-auth share pages for Forge maps and scenarios:

      GET /forge/map/:ref
      GET /forge/scenario/:ref

  These exist so a link pasted outside the site (Discord, forums, chat
  apps) unfurls with the design's real name, a description line, and the
  galaxy thumbnail — the SPA's routes all serve the same index.html, so
  scrapers can never see per-map metadata there. Human visitors are
  meta-refreshed straight into the SPA's detail page; scrapers don't
  follow the refresh and read the OpenGraph tags off this page.

  `ref` is a share token (what the app hands out — RC.ShareToken) or a
  legacy numeric id. A token renders any row, drafts included (titled
  "(Draft)"): whoever shared it meant others to see it. A numeric id
  renders published rows only; for a draft it redirects, untagged, to the
  numeric SPA URL, where only the author or an admin gets in — so drafts
  can't be enumerated. Unknown refs 404.
  """
  use Portal, :controller

  alias RC.Scenarios

  def map(conn, %{"id" => ref}), do: share(conn, Scenarios.fetch_map_by_ref(ref), :map)

  def scenario(conn, %{"id" => ref}),
    do: share(conn, Scenarios.fetch_scenario_by_ref(ref), :scenario)

  defp share(conn, nil, _kind), do: not_found(conn)

  defp share(conn, {row, via}, kind) do
    if Scenarios.viewable?(row, via, nil) do
      render_share(conn, row, kind)
    else
      # Never the token URL here: the visitor came by numeric id.
      path = if kind == :map, do: "map", else: "scenario"
      redirect(conn, to: "/portal/create/#{path}/view/#{row.id}")
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
