defmodule RC.Help.Data do
  @moduledoc """
  Read side of the help compiler: game content per speed, front-end locale
  strings, and the icon registry. Everything here is called at compile time
  of `RC.Help`, so the data it returns is whatever the checked-out content
  modules and `front/src/locales/*.json` say.

  Speed selection mirrors `Data.Data`: the spec whose metadata carries the
  speed (dev variants skipped), else the speed-agnostic spec, else the last
  one (the `:daily` fallback rule).
  """

  @speeds [:fast, :medium, :slow]
  @langs_root Path.expand("front/src/locales", File.cwd!())
  @icons_root Path.expand("front/src/icons", File.cwd!())
  @content_root Path.expand("lib/data/game/content", File.cwd!())

  def speeds, do: @speeds

  @shots_manifest Path.expand("priv/help/shots/manifest.json", File.cwd!())

  @doc "Speed definitions (`Data.Game.Speed`), including the daily speed."
  def speed_content, do: Data.Game.Speed.Content.data()

  @doc "Game ticks in one real hour at a speed (Legacy: 20)."
  def ticks_per_hour(speed) do
    factor = Enum.find(speed_content(), &(&1.key == speed)).factor
    3_600_000 * factor / Core.Tick.unit_time_divider()
  end

  @doc "Screenshot manifest written by `e2e/help-shots/capture.js`."
  def shots_file, do: @shots_manifest

  @doc "Screenshots by name: `%{\"name\" => %{\"file\", \"width\", \"height\", \"alt\", \"marks\"}}`."
  def shots do
    if File.exists?(@shots_manifest) do
      @shots_manifest |> File.read!() |> Jason.decode!() |> Map.get("shots", %{})
    else
      %{}
    end
  end

  @doc "Content list of a `Data.Game.*` module for a speed."
  def content(mod, speed) when speed in @speeds do
    specs = mod.specs()

    spec =
      Enum.find(specs, fn s -> s.metadata[:speed] == speed and is_nil(s.metadata[:mode]) end) ||
        Enum.find(specs, &(&1.metadata == [])) ||
        List.last(specs)

    Module.concat([spec.module]).data()
  end

  def constants(speed) do
    content(Data.Game.Constant, speed)
    |> Enum.find(&(&1.key == :main))
    |> Map.from_struct()
    |> Map.delete(:key)
  end

  def buildings(speed), do: content(Data.Game.Building, speed)
  def doctrines(speed), do: content(Data.Game.Doctrine, speed)
  def patents(speed), do: content(Data.Game.Patent, speed)
  def ships(speed), do: content(Data.Game.Ship, speed)
  def characters(speed), do: content(Data.Game.Character, speed)
  def factions, do: Data.Game.Faction.Content.data()
  def stellar_bodies, do: Data.Game.StellarBody.Content.data()
  def star_types, do: Data.Game.StellarSystem.Content.data()
  def population_classes, do: Data.Game.PopulationClass.Content.data()
  def population_statuses, do: Data.Game.PopulationStatus.Content.data()
  def pipeline_in, do: Data.Game.BonusPipelineIn.Content.data()
  def pipeline_out, do: Data.Game.BonusPipelineOut.Content.data()

  @doc "Content source files, so editing balance data recompiles the manual."
  def content_files, do: Path.wildcard(Path.join(@content_root, "*.ex"))

  @doc "Locale JSON files used by the compiler (for `@external_resource`)."
  def locale_files(langs) do
    for lang <- Enum.uniq(["en" | langs]),
        name <- ~w(data.json game.json),
        path = Path.join([@langs_root, lang, name]),
        File.exists?(path),
        do: path
  end

  @doc """
  `%{data: map, game: map}` for a language, or `nil` when the locale files
  are not present (a backend-only checkout). `data` is the inner `"data"`
  object of `data.json`.
  """
  def locale(lang) do
    data_path = Path.join([@langs_root, lang, "data.json"])
    game_path = Path.join([@langs_root, lang, "game.json"])

    if File.exists?(data_path) and File.exists?(game_path) do
      %{
        data: data_path |> File.read!() |> Jason.decode!() |> Map.get("data", %{}),
        game: game_path |> File.read!() |> Jason.decode!()
      }
    end
  end

  @doc """
  Registered icon names, e.g. `"resource/mobility"` or `"close"`, read from
  the generated vue-svgicon modules. Empty set when `front/` is absent.
  """
  def icons do
    if File.dir?(@icons_root) do
      @icons_root
      |> Path.join("**/*.js")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @icons_root))
      |> Enum.reject(&(Path.basename(&1) == "index.js"))
      |> Enum.map(&(&1 |> Path.rootname() |> String.replace("\\", "/")))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  def icons_available?, do: File.dir?(@icons_root)
end
