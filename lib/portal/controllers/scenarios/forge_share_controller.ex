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
    meta = row.game_metadata || %{}
    path = if kind == :map, do: "map", else: "scenario"

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render("show.html",
      title: Map.get(meta, "name") || "Unnamed #{path}",
      description: describe(row, meta, kind),
      image: Portal.ThumbnailUrl.absolute_url(row),
      share_url: "#{Portal.Endpoint.url()}/forge/#{path}/#{row.id}",
      spa_url: "/portal/create/#{path}/view/#{row.id}"
    )
  end

  # One human-readable line for the unfurl card. Every part is optional —
  # old rows can miss any of these metadata keys.
  defp describe(row, meta, kind) do
    head = if kind == :map, do: "Galaxy map", else: "Scenario"

    author =
      case row.author do
        %{name: name} when is_binary(name) -> "by #{name}"
        _ -> if row.is_official, do: "official", else: nil
      end

    speed =
      case Map.get(meta, "speed") do
        speed when is_binary(speed) -> "#{speed} speed"
        _ -> nil
      end

    factions =
      case Map.get(meta, "factions") do
        factions when is_list(factions) and factions != [] -> "#{length(factions)} factions"
        _ -> nil
      end

    layout =
      case {Map.get(meta, "system_number"), Map.get(meta, "sector_number")} do
        {systems, sectors} when is_integer(systems) and is_integer(sectors) ->
          "#{systems} systems in #{sectors} sectors"

        {systems, _} when is_integer(systems) ->
          "#{systems} systems"

        _ ->
          nil
      end

    scenario_bits = if kind == :scenario, do: [speed, factions], else: []

    [Enum.join(Enum.filter([head, author], & &1), " ") | scenario_bits ++ [layout]]
    |> Enum.filter(& &1)
    |> Enum.join(" — ")
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> text("Not found")
  end
end
