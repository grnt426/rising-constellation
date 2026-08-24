defmodule Portal.ForgeOg do
  @moduledoc """
  OpenGraph metadata for Forge maps and scenarios, shared by the two
  surfaces that emit it:

    * `Portal.ForgeShareController` — the dedicated /forge/:kind/:id
      share pages (meta-refresh into the SPA);
    * `Portal.SpaShareController` — the real SPA URLs
      (/portal/create/map/view/:id etc.), served as index.html with
      these tags injected so links unfurl without players needing to
      know the /forge form.
  """

  @doc """
  Title / description / image / URLs for a map or scenario row.
  `kind` is `:map` or `:scenario`.
  """
  def data(row, kind) do
    meta = row.game_metadata || %{}
    path = if kind == :map, do: "map", else: "scenario"

    %{
      title: Map.get(meta, "name") || "Unnamed #{path}",
      description: describe(row, meta, kind),
      image: Portal.ThumbnailUrl.absolute_url(row),
      share_url: "#{Portal.Endpoint.url()}/forge/#{path}/#{row.id}",
      spa_url: "/portal/create/#{path}/view/#{row.id}"
    }
  end

  @doc """
  The meta-tag block for injection into an HTML head, as a safe string.
  `page_url` is the canonical URL the tags describe. Excludes any
  meta-refresh — the /forge pages add their own.
  """
  def meta_tags(data, page_url) do
    title = escape(data.title)
    description = escape(data.description)

    image_tags =
      case data.image do
        nil ->
          ~s(<meta name="twitter:card" content="summary"/>)

        image ->
          image = escape(image)

          ~s(<meta property="og:image" content="#{image}"/>) <>
            ~s(<meta property="og:image:width" content="400"/>) <>
            ~s(<meta property="og:image:height" content="400"/>) <>
            ~s(<meta name="twitter:card" content="summary_large_image"/>) <>
            ~s(<meta name="twitter:image" content="#{image}"/>)
      end

    ~s(<meta property="og:type" content="website"/>) <>
      ~s(<meta property="og:site_name" content="Tetrarchy Falls"/>) <>
      ~s(<meta property="og:title" content="#{title}"/>) <>
      ~s(<meta property="og:description" content="#{description}"/>) <>
      ~s(<meta property="og:url" content="#{escape(page_url)}"/>) <>
      image_tags <>
      ~s(<meta name="twitter:title" content="#{title}"/>) <>
      ~s(<meta name="twitter:description" content="#{description}"/>)
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

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
