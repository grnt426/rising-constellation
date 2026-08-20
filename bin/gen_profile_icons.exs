# Regenerates priv/data/profile_icons.json from the SPA's vue-svgicon
# modules (front/src/icons/**). The JSON is the backend's icon registry:
# RC.ProfileIcons validates profiles.favorite_icon against it, and the
# Discord /player card renderer inlines the SVG bodies from it.
#
# Run inside the dev container (host Elixir is not supported):
#
#   docker compose exec rc mix run bin/gen_profile_icons.exs
#
# Commit the regenerated JSON. Re-run whenever icons are added to
# front/src/icons in one of the included groups.
#
# Only game-flavored groups are included — UI chrome (root-level carets,
# spinners, ...) and the logo are not meaningful "favorite icon" choices.

included_groups = ~w(
  action agent building doctrine faction marker patent reaction resource
  ship stellar_body stellar_system
)

icons_root = Path.join(File.cwd!(), "front/src/icons")
out_path = Path.join(File.cwd!(), "priv/data/profile_icons.json")

unless File.dir?(icons_root), do: raise("icons dir not found: #{icons_root}")

# vue-svgicon modules are single-icon registrations of the shape:
#   icon.register({
#     'group/name': {
#       width: 32, height: 32,
#       viewBox: '0 0 32 32',
#       data: '<path pid="0" d="..."/>'
#     }
#   })
# The `pid` attributes are vue-svgicon bookkeeping and invalid SVG —
# strip them (same rule as lib/rc/discord/render/assets.ex).
#
# vue-svgicon also rewrites fill/stroke to _fill/_stroke so it can tint at
# runtime. The backend consumers tint too (favorite icon in faction color),
# so normalize for a `<g fill="TINT" color="TINT">` wrapper:
#   _fill="none"  -> fill="none"          (structural holes stay holes)
#   _fill="..."   -> dropped              (inherits the wrapper tint)
#   _stroke="..." -> stroke="currentColor" (outline icons take the tint too)
parse_icon = fn source, file ->
  name =
    case Regex.run(~r/'([\w\/-]+)':\s*\{/, source) do
      [_, name] -> name
      _ -> raise("no icon name found in #{file}")
    end

  viewbox =
    case Regex.run(~r/viewBox:\s*'([^']+)'/, source) do
      [_, vb] -> vb
      _ -> raise("no viewBox found in #{file}")
    end

  body =
    case Regex.run(~r/data:\s*'(.*)'/s, source) do
      [_, data] ->
        data
        |> String.replace(~r/\s+pid="\d+"/, "")
        |> String.replace(~s(_fill="none"), ~s(fill="none"))
        |> String.replace(~r/\s+_fill="[^"]*"/, "")
        |> String.replace(~r/_stroke="[^"]*"/, ~s(stroke="currentColor"))

      _ ->
        raise("no data found in #{file}")
    end

  {name, %{"viewbox" => viewbox, "body" => body}}
end

icons =
  for group <- included_groups,
      file <- Path.wildcard(Path.join([icons_root, group, "*.js"])),
      Path.basename(file) != "index.js",
      # frame_* entries are container/border art, not pickable flavor
      not String.starts_with?(Path.basename(file), "frame_"),
      into: %{} do
    parse_icon.(File.read!(file), file)
  end

File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, Jason.encode!(icons, pretty: true) <> "\n")

groups = icons |> Map.keys() |> Enum.map(&(&1 |> String.split("/") |> hd())) |> Enum.frequencies()
IO.puts("wrote #{map_size(icons)} icons to #{out_path}")
IO.inspect(groups, label: "per group")
