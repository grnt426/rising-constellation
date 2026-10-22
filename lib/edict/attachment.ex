defmodule Edict.Attachment do
  @moduledoc """
  Scripts attached to a Forge scenario: keeping them, and checking them
  against the scenario's map.

  **Frozen copies.** A scenario keeps a copy of each attached script (its
  text, digest, name and author) in `game_data["scripts"]`, taken from the
  author's saved version when the scenario is saved. A match runs exactly
  that copy, so a script edited, unpublished or deleted later never changes
  or breaks a scenario that uses it; saving the scenario again picks up the
  latest version (`RC.ScenarioScripts`).

  **Checks.** The goal is not to prove a script does what its author meant,
  only that it starts correctly on this map. Two kinds of check, both
  warnings (the scenario still saves):

    * the setup against the map: `factions = 5` on a two-faction map, a
      `faction` the map doesn't have, a `time_limit` that isn't the match's,
      a rival court (a match has none), daily-only fields, patents the
      speed's tree doesn't have;
    * a dry boot: the script starts once for a model player of every
      faction on the map (the starting stocks of the map's speed, one home
      system), runs its first two seconds and counts its score. Any error
      there (`factions[4]` on a two-faction map) is reported.

  `instance_setup/1` merges the attached scripts' grants, discounts and
  mutators into what a new match boots with.
  """

  alias Edict.{Catalog, Checker, Parser, Runtime, Sandbox, Scenario, World}

  @max_scripts 3
  @modes %{"slow" => "legacy", "medium" => "tactic", "fast" => "flash", "daily" => "daily"}
  @speed_names %{"slow" => "Legacy", "medium" => "Tactic", "fast" => "Flash", "daily" => "daily"}

  @doc "How many scripts one scenario may attach."
  def max_scripts, do: @max_scripts

  @doc "`scenario.mode` for a game speed: slow → legacy, medium → tactic, fast → flash."
  def mode(speed) when is_atom(speed) and not is_nil(speed), do: mode(Atom.to_string(speed))
  def mode(speed), do: Map.get(@modes, speed, "legacy")

  # --- frozen copies -------------------------------------------------------------

  @doc "A saved script as a scenario keeps it: frozen, its text included."
  def freeze(%RC.Scripts.Script{} = s) do
    %{
      "id" => s.id,
      "name" => s.name,
      "description" => s.description,
      "digest" => s.digest,
      "source" => s.source,
      "author" => author_name(s),
      "author_id" => s.author_id,
      "saved_at" => s.updated_at && DateTime.to_iso8601(s.updated_at)
    }
  end

  defp author_name(%{author: %RC.Accounts.Account{name: name}}), do: name
  defp author_name(_), do: nil

  @doc "The frozen scripts of a scenario's (or an instance's) `game_data`."
  def scripts(%{"scripts" => scripts}) when is_list(scripts), do: Enum.filter(scripts, &frozen?/1)
  def scripts(_), do: []

  defp frozen?(%{"source" => s, "digest" => d}) when is_binary(s) and is_binary(d), do: true
  defp frozen?(_), do: false

  @doc "Whether `game_data` attaches any script."
  def scripted?(game_data), do: scripts(game_data) != []

  # --- the map ------------------------------------------------------------------

  @doc "What scripts are checked against: the map's mode, factions, time limit and size."
  def facts(game_data) when is_map(game_data) do
    %{
      mode: mode(game_data["speed"]),
      speed: game_data["speed"],
      factions:
        game_data
        |> Map.get("factions", [])
        |> List.wrap()
        |> Enum.map(fn
          %{"key" => key} when is_binary(key) -> key
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        # a map has a handful; a request can't make the check start thousands
        |> Enum.take(8),
      time_limit: number(game_data["time_limit"]) * 60.0,
      systems: length(List.wrap(game_data["systems"]))
    }
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0

  # --- checks -------------------------------------------------------------------

  @doc """
  Check every script `game_data` attaches against its map. Returns one entry
  per script, in order: `%{"id", "name", "digest", "diagnostics" => [%{"severity",
  "message"}]}`.
  """
  def check(game_data) do
    facts = facts(game_data)
    scripts = scripts(game_data)

    scripts
    |> Enum.with_index()
    |> Enum.map(fn {script, i} ->
      diagnostics = check_script(script["source"], facts) ++ conflicts(script, Enum.take(scripts, i))

      %{
        "id" => script["id"],
        "name" => script["name"],
        "digest" => script["digest"],
        "diagnostics" => diagnostics
      }
    end)
  end

  @doc "Check one script's text against a map's `facts/1`. A list of `%{\"severity\", \"message\"}`."
  def check_script(source, facts) when is_binary(source) do
    case Parser.parse(source) do
      {:error, e} ->
        [error("It doesn't read as a script (line #{e.line}: #{e.message}).")]

      {:ok, program} ->
        case Enum.filter(Checker.check(program), &(&1.severity == "error")) do
          [first | _] = errors ->
            [
              error(
                "It has #{count(length(errors), "mistake")} to fix in the Scenario Workshop before it can run (the first: #{first.message})."
              )
            ]

          [] ->
            case Sandbox.run(fn -> setup_and_boot(program, facts) end, timeout: 5_000) do
              {:ok, diagnostics} -> diagnostics
              {:error, reason} -> [warning("It couldn't be started for a check: #{Sandbox.describe(reason)}.")]
            end
        end
    end
  end

  defp setup_and_boot(program, facts) do
    case Runtime.setup_fields(program) do
      {:error, [e | _]} ->
        [error("Its setup fails: #{e.message}")]

      {:ok, fields} ->
        case Scenario.config(fields) do
          {:error, [e | _]} -> [error("Its setup fails: #{e.message}")]
          {:ok, _config} -> setup_warnings(fields, facts) ++ boot(program, facts)
        end
    end
  end

  # The setup describes the world the script was written for. In a match the
  # map makes that world, so the setup must agree with it.
  defp setup_warnings(fields, facts) do
    present = facts.factions

    [
      case fields["factions"] do
        n when is_number(n) and trunc(n) != length(present) ->
          warning(
            "It is written for #{count(trunc(n), "faction")} (factions = #{trunc(n)}), and this map has #{length(present)}."
          )

        _ ->
          nil
      end,
      case fields["faction"] do
        f when is_binary(f) ->
          if f not in present,
            do: warning("Its setup picks the faction #{f}, which isn't on this map (#{Enum.join(present, ", ")}).")

        _ ->
          nil
      end,
      case fields["time_limit"] do
        t when is_number(t) and abs(t - facts.time_limit) > 0.5 ->
          warning(
            "It is timed for a #{duration(t)} run, and this match lasts #{duration(facts.time_limit)}. " <>
              timers_note(t, facts.time_limit)
          )

        _ ->
          nil
      end,
      if(fields["rival"] == true,
        do: warning("It asks for a rival court, which a match doesn't have: its send_agent calls will be refused.")
      ),
      case Enum.filter(["systems", "neighbors"], &Map.has_key?(fields, &1)) do
        [] -> nil
        names -> warning("#{Enum.join(names, " and ")} only shape a daily's world; on this map they change nothing.")
      end
      | missing_patents(fields, facts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Flash and Tactic games have their own, smaller patent trees.
  defp missing_patents(fields, %{speed: speed}) do
    roster = patent_roster(speed)

    names =
      List.wrap(fields["grant_patents"]) ++
        case fields["patent_discounts"] do
          %{} = d -> Map.keys(d)
          _ -> []
        end

    names
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reject(&((Catalog.patent_key(&1) || &1) in roster))
    |> case do
      [] ->
        []

      missing ->
        [
          warning(
            "#{Enum.join(missing, ", ")} #{if length(missing) == 1, do: "isn't a patent", else: "aren't patents"} in #{@speed_names[speed] || "these"} games, so the setup's grants and discounts skip #{if length(missing) == 1, do: "it", else: "them"}."
          )
        ]
    end
  end

  defp patent_roster(speed) do
    module =
      case speed do
        "fast" -> Data.Game.Patent.Content.Fast
        "medium" -> Data.Game.Patent.Content.Medium
        _ -> Data.Game.Patent.Content.Slow
      end

    Enum.map(module.data(), &Atom.to_string(&1.key))
  end

  # The script starts for a model player of each faction: its on start, its
  # first two seconds, its score and its on end.
  defp boot(program, facts) do
    models = facts.factions |> Enum.with_index(1) |> Enum.map(fn {key, i} -> model_player(key, i, facts.speed) end)

    standings =
      facts.factions
      |> Enum.with_index(1)
      |> Enum.map(fn {key, i} -> World.faction(%{key: key, player_count: 1, system_count: 1}, i) end)

    everyone = Enum.map(models, &World.someone/1)

    models
    |> Enum.flat_map(fn model ->
      case Runtime.new(program) do
        {:error, [e | _]} ->
          [{model.faction, e.message}]

        {:ok, rt} ->
          world = fn t ->
            World.build(model,
              clock: %{elapsed: t, left: facts.time_limit - t, limit: facts.time_limit},
              config: rt.config,
              mode: facts.mode,
              factions: standings,
              players: everyone,
              systems: facts.systems
            )
          end

          {rt, first} = Runtime.pulse(rt, world.(0.0), 0.0)
          {rt, second} = Runtime.pulse(rt, world.(1.0), 1.0)
          {_rt, last} = Runtime.finish(rt, world.(1.0), 1.0)

          Enum.map(first.errors ++ second.errors ++ last.errors, &{model.faction, &1.message})
      end
    end)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.take(5)
    |> Enum.map(fn {faction, message} ->
      warning("When it starts for a #{faction} player on this map, it fails: #{message}")
    end)
  end

  defp model_player(faction, i, speed) do
    c = starting_constants(speed)

    %{
      name: "Player #{i}",
      faction: faction,
      credit: %{value: c.player_starting_credit, change: 0},
      technology: %{value: c.player_starting_technology, change: 0},
      ideology: %{value: c.player_starting_ideology, change: 0},
      stellar_systems: [
        %{id: 1000 + i, name: "Home #{i}", workforce: 10, habitation: 15, happiness: 60, production: 20, defense: 0}
      ],
      dominions: [],
      characters: [],
      patents: [],
      wonders_built: [],
      agents_assassinated: 0
    }
  end

  defp starting_constants(speed) do
    module =
      case speed do
        "fast" -> Data.Game.Constant.Content.Fast
        "medium" -> Data.Game.Constant.Content.Medium
        _ -> Data.Game.Constant.Content.Slow
      end

    hd(module.data())
  end

  # Two scripts that discount the same patent: the lower price applies.
  defp conflicts(script, earlier) do
    mine = discounts(script)

    for other <- earlier,
        {name, factor} <- discounts(other),
        Map.has_key?(mine, name) and mine[name] != factor do
      warning(
        "#{other["name"]} discounts #{name} too (to #{percent(factor)}, this one to #{percent(mine[name])}); the lower price applies."
      )
    end
  end

  defp discounts(script) do
    with {:ok, program} <- Parser.parse(script["source"]),
         {:ok, %{"patent_discounts" => %{} = d}} <- Runtime.setup_fields(program) do
      Map.new(d, fn {name, f} -> {Catalog.patent_name(name) || name, f} end)
    else
      _ -> %{}
    end
  end

  # --- what a match boots with -------------------------------------------------------

  @doc """
  The attached scripts' setups, merged for the engine (string keys, the
  engine's patent keys): granted patents (all of them), patent discounts
  (the lowest factor per patent) and mutators (all of them). `nil` when
  nothing is attached. Read by `Instance.Mutators.script_setup/1`.
  """
  def instance_setup(game_data) do
    case scripts(game_data) do
      [] ->
        nil

      scripts ->
        configs = Enum.flat_map(scripts, &config_of/1)

        %{
          "grant_patents" => configs |> Enum.flat_map(& &1["grant_patents"]) |> Enum.uniq(),
          "patent_discounts" =>
            Enum.reduce(configs, %{}, fn c, acc ->
              Map.merge(acc, c["patent_discounts"], fn _k, a, b -> min(a, b) end)
            end),
          "mutators" => configs |> Enum.flat_map(& &1["mutators"]) |> Enum.uniq(),
          "markup_free" => true
        }
    end
  end

  defp config_of(%{"source" => source}) do
    run = fn ->
      with {:ok, program} <- Parser.parse(source),
           {:ok, fields} <- Runtime.setup_fields(program),
           {:ok, config} <- Scenario.config(fields) do
        [config]
      else
        _ -> []
      end
    end

    case Sandbox.run(run, timeout: 2_000) do
      {:ok, configs} -> configs
      {:error, _} -> []
    end
  end

  @doc """
  Prepare a new match's `game_data` from its scenario's: the merged setup
  under `game_data["edict"]["setup"]` and the scripts' mutators added to the
  map's own. Unscripted game data passes untouched.
  """
  def prepare_instance(game_data) when is_map(game_data) do
    case instance_setup(game_data) do
      nil ->
        game_data

      setup ->
        existing = List.wrap(game_data["mutators"])
        have = MapSet.new(existing, &(is_map(&1) && &1["key"]))
        added = for key <- setup["mutators"], not MapSet.member?(have, key), do: %{"key" => key}

        game_data
        |> Map.put("edict", %{"setup" => setup})
        |> Map.put("mutators", existing ++ added)
    end
  end

  # --- wording ------------------------------------------------------------------

  defp error(message), do: %{"severity" => "error", "message" => message}
  defp warning(message), do: %{"severity" => "warning", "message" => message}

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp percent(f) when is_number(f), do: "#{round(f * 100)}%"

  # Messages are plain text, so keywords are quoted, and the note says what
  # the mismatch does rather than how timers work.
  defp timers_note(script, match) when script < match do
    ~s(Its "at" and "every" timers don't stretch to fit: they count from the start of the match, so one set for the #{duration(script)} mark goes off #{duration(match - script)} before the match ends.)
  end

  defp timers_note(script, match) do
    ~s(Its "at" and "every" timers count from the start of the match, so any set after the #{duration(match)} mark never goes off.)
  end

  # 6300 -> "1h45m"; whole days read as days
  defp duration(seconds) when is_number(seconds) do
    s = round(seconds)

    if s >= 86_400 and rem(s, 86_400) == 0 do
      count(div(s, 86_400), "day")
    else
      [{div(s, 3600), "h"}, {div(rem(s, 3600), 60), "m"}, {rem(s, 60), "s"}]
      |> Enum.reject(fn {n, _} -> n == 0 end)
      |> case do
        [] -> "0s"
        parts -> Enum.map_join(parts, fn {n, unit} -> "#{n}#{unit}" end)
      end
    end
  end
end
