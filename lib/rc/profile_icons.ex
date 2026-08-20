defmodule RC.ProfileIcons do
  @moduledoc """
  Registry of the in-game icons a player may pick as their profile's
  "favorite icon", plus the five faction keys for `favorite_faction`.

  Backed by `priv/data/profile_icons.json`, generated from the SPA's
  vue-svgicon modules by `bin/gen_profile_icons.exs` (see that script
  for the regeneration workflow). Loaded once into `:persistent_term`
  on first use — the map is read-mostly and shared by validation
  (`known?/1`) and the Discord card renderer (`svg/1`).
  """

  @registry_key {__MODULE__, :registry}

  @faction_keys Enum.map(Data.Game.Faction.Content.data(), &Atom.to_string(&1.key))

  @doc "The five faction keys as strings, in canonical declaration order."
  def faction_keys, do: @faction_keys

  @doc "Whether `name` is a selectable in-game icon (nil is not)."
  def known?(nil), do: false
  def known?(name) when is_binary(name), do: Map.has_key?(registry(), name)

  @doc "All icon names, sorted."
  def list, do: registry() |> Map.keys() |> Enum.sort()

  @doc """
  The inline-SVG data for an icon: `%{viewbox: "0 0 32 32", body: "<path .../>"}`,
  or nil for unknown names. Bodies are pid-stripped and safe to inline in
  the Discord card SVGs (attributes only, no CSS classes).
  """
  def svg(name) when is_binary(name) do
    case Map.get(registry(), name) do
      %{"viewbox" => viewbox, "body" => body} -> %{viewbox: viewbox, body: body}
      nil -> nil
    end
  end

  def svg(_), do: nil

  defp registry do
    case :persistent_term.get(@registry_key, nil) do
      nil ->
        registry = load_registry()
        :persistent_term.put(@registry_key, registry)
        registry

      registry ->
        registry
    end
  end

  defp load_registry do
    path = Path.join(to_string(:code.priv_dir(:rc)), "data/profile_icons.json")

    case File.read(path) do
      {:ok, json} ->
        Jason.decode!(json)

      {:error, reason} ->
        # A missing registry should degrade to "no icon is valid", not
        # crash profile updates. It ships in priv/, so this only fires
        # if the generated file was dropped from a build.
        require Logger
        Logger.error("profile_icons.json unreadable (#{inspect(reason)}) at #{path}")
        %{}
    end
  end
end
