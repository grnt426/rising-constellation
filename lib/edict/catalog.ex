defmodule Edict.Catalog do
  @moduledoc """
  Everything a script can name: the builtin functions, the actions, the world
  it can read, the events it can react to and the setup it can declare.

  This table is the scripting system's capability list. Nothing outside it
  is reachable from a script, and everything in it is reachable from both the
  text and the visual editor: the checker validates against it, the
  interpreter dispatches on it, and the editor builds its node palette from
  it (`GET /api/edict/catalog`). Adding a function or an action here (with its
  implementation) is how the language grows.

  Types, used by the checker and to color pins in the editor:
  `number`, `text`, `bool`, `list`, `record`, `fn`, `any`, plus
  `{:list, type}`, `{:record, fields}` and `{:enum, values}`.
  """

  @resources ["credit", "technology", "ideology"]
  @factions ["tetrarchy", "myrmezir", "cardan", "synelle", "ark"]

  def resources, do: @resources
  def factions, do: @factions

  # --- builtins (pure functions) ---------------------------------------------

  # {name, group, params, returns, doc}. A param is {name, type} or
  # {name, type, :optional}; `:rest` collects any further values.
  @builtins [
    # math
    {"abs", "math", [{"x", "number"}], "number", "The value without its sign: abs(-3) is 3."},
    {"floor", "math", [{"x", "number"}], "number", "Round down to a whole number."},
    {"ceil", "math", [{"x", "number"}], "number", "Round up to a whole number."},
    {"trunc", "math", [{"x", "number"}], "number", "Drop the fraction: trunc(2.7) is 2 and trunc(-2.7) is -2."},
    {"round", "math", [{"x", "number"}, {"digits", "number", :optional}], "number",
     "Round to the nearest whole number, or to `digits` decimals."},
    {"sqrt", "math", [{"x", "number"}], "number", "Square root."},
    {"pow", "math", [{"x", "number"}, {"y", "number"}], "number", "x to the power y."},
    {"min", "math", [{"values", "any", :rest}], "number",
     "The smallest of the values given (or of one list): min(3, 5) is 3."},
    {"max", "math", [{"values", "any", :rest}], "number", "The largest of the values given (or of one list)."},
    {"clamp", "math", [{"x", "number"}, {"low", "number"}, {"high", "number"}], "number",
     "x, kept between low and high."},
    {"mod", "math", [{"x", "number"}, {"y", "number"}], "number", "The remainder of x divided by y: mod(17, 5) is 2."},
    {"lerp", "math", [{"from", "number"}, {"to", "number"}, {"t", "number"}], "number",
     "The point a fraction t of the way from `from` to `to`: lerp(0, 100, 25%) is 25."},
    # text
    {"str", "text", [{"value", "any"}], "text", "The value written as text."},
    {"upper", "text", [{"text", "text"}], "text", "The text in capitals."},
    {"lower", "text", [{"text", "text"}], "text", "The text in lower case."},
    {"join", "text", [{"list", "list"}, {"separator", "text", :optional}], "text",
     "The list's items written one after another, with the separator between."},
    {"fmt_time", "text", [{"seconds", "number"}], "text", "Seconds as a clock: fmt_time(185) is \"3:05\"."},
    {"fmt_number", "text", [{"x", "number"}], "text", "A number with thousands separators: \"1,250,000\"."},
    # lists
    {"len", "list", [{"value", "any"}], "number",
     "How many items a list (or characters a text, or keys a record) has."},
    {"first", "list", [{"list", "list"}], "any", "The first item, or nil for an empty list."},
    {"last", "list", [{"list", "list"}], "any", "The last item, or nil for an empty list."},
    {"range", "list", [{"from", "number"}, {"to", "number", :optional}], "list",
     "Whole numbers from `from` up to `to` (included): range(1, 3) is [1, 2, 3]. range(3) is [1, 2, 3]."},
    {"push", "list", [{"list", "list"}, {"item", "any"}], "list", "A copy of the list with the item added at the end."},
    {"concat", "list", [{"a", "list"}, {"b", "list"}], "list", "The two lists, one after the other."},
    {"reverse", "list", [{"list", "list"}], "list", "The list back to front."},
    {"slice", "list", [{"list", "list"}, {"start", "number"}, {"count", "number", :optional}], "list",
     "`count` items starting at position `start` (the first item is at 0)."},
    {"contains", "list", [{"in", "any"}, {"item", "any"}], "bool",
     "Whether a list holds the item (or a text holds the smaller text)."},
    {"unique", "list", [{"list", "list"}], "list", "The list with repeated items removed."},
    {"sort", "list", [{"list", "list"}], "list", "The list from smallest to largest."},
    {"sum", "list", [{"list", "list"}, {"fn", "fn", :optional}], "number",
     "The total of a list of numbers, or of fn(item) for each item."},
    {"count", "list", [{"list", "list"}, {"fn", "fn", :optional}], "number",
     "How many items there are, or how many make fn(item) true."},
    {"map", "list", [{"list", "list"}, {"fn", "fn"}], "list", "fn(item) for each item: map(xs, x => x * 2)."},
    {"filter", "list", [{"list", "list"}, {"fn", "fn"}], "list", "The items for which fn(item) is true."},
    {"find", "list", [{"list", "list"}, {"fn", "fn"}], "any", "The first item for which fn(item) is true, or nil."},
    {"any", "list", [{"list", "list"}, {"fn", "fn", :optional}], "bool",
     "Whether fn(item) is true for at least one item."},
    {"all", "list", [{"list", "list"}, {"fn", "fn", :optional}], "bool", "Whether fn(item) is true for every item."},
    {"sort_by", "list", [{"list", "list"}, {"fn", "fn"}], "list", "The list ordered by fn(item), smallest first."},
    {"max_by", "list", [{"list", "list"}, {"fn", "fn"}], "any", "The item with the largest fn(item), or nil."},
    {"min_by", "list", [{"list", "list"}, {"fn", "fn"}], "any", "The item with the smallest fn(item), or nil."},
    # records
    {"keys", "record", [{"record", "record"}], "list", "The record's keys."},
    {"values", "record", [{"record", "record"}], "list", "The record's values."},
    {"get", "record", [{"record", "record"}, {"key", "text"}, {"default", "any", :optional}], "any",
     "The value under key, or the default (nil if none) when it's missing."},
    {"put", "record", [{"record", "record"}, {"key", "text"}, {"value", "any"}], "record",
     "A copy of the record with key set to value."},
    {"has", "record", [{"record", "record"}, {"key", "text"}], "bool", "Whether the record has the key."},
    # chance: the same keys always give the same roll, for every player of a scenario
    {"random", "chance", [{"keys", "any", :rest}], "number",
     "A number from 0 up to (not including) 1. The same keys give the same number in every run of this scenario, so every player faces the same rolls: random(\"wave\", 3)."},
    {"random_int", "chance", [{"low", "number"}, {"high", "number"}, {"keys", "any", :rest}], "number",
     "A whole number from low to high (both included), fixed by the keys like random()."},
    {"chance", "chance", [{"p", "number"}, {"keys", "any", :rest}], "bool",
     "True with probability p (25% is one time in four), fixed by the keys like random()."},
    {"pick", "chance", [{"list", "list"}, {"keys", "any", :rest}], "any",
     "One item of the list, fixed by the keys like random()."}
  ]

  # --- actions (the only way a script changes the game) ----------------------

  @actions [
    {"give", "resources", [{"resource", {:enum, @resources}}, {"amount", "number"}], [],
     "Give the player an amount of credit, technology or ideology."},
    {"take", "resources", [{"resource", {:enum, @resources}}, {"amount", "number"}], [],
     "Take an amount of credit, technology or ideology from the player. Their stock can go below zero."},
    {"notify", "messages", [{"message", "text"}], [{"tone", {:enum, ["info", "good", "warning"]}}],
     "Show the player a message. Tone colors it: info, good or warning."},
    {"finish", "run", [{"message", "text", :optional}], [],
     "End the run now. The score is counted at once (time.left is the time left), then the on end handlers run."},
    {"end_match", "run", [{"message", "text", :optional}], [{"winner", "text"}],
     "End the match now, for every player. winner: names the winning faction; left out, the match's own rules pick it. In a daily it ends the run, like finish()."},
    {"destabilize", "systems", [{"amount", "number"}], [{"system", "number"}],
     "Lower a system's stability by an amount (the player's first system unless system: names one)."},
    {"send_agent", "rival", [{"type", {:enum, ["erased"]}}], [{"level", "number"}, {"system", "number"}],
     "The rival court sends an agent of the given level into one of the player's systems (the first unless system: names one). Needs rival = true in setup."},
    {"log", "debugging", [{"value", "any"}], [], "Write a value to the simulator's timeline. Players never see it."}
  ]

  @action_limits %{
    "give" => %{"amount" => {0, 1.0e9}},
    "take" => %{"amount" => {0, 1.0e9}},
    "destabilize" => %{"amount" => {0, 100}},
    "send_agent" => %{"level" => {1, 30}}
  }

  @doc "Bounds on action arguments, enforced when an action is called."
  def action_limits, do: @action_limits

  # --- events -------------------------------------------------------------------

  @events [
    %{kind: "on", form: "on start { … }", doc: "Runs once, as the run begins."},
    %{
      kind: "every",
      form: "every 15s [from 1m] [until 20m] [as n] { … }",
      doc: "Runs again and again on a schedule. `as n` counts the runs: 1, 2, 3 …"
    },
    %{kind: "at", form: "at 10m { … }", doc: "Runs once, when the clock reaches that time."},
    %{
      kind: "when",
      form: "when player.credit > 1_000_000 { … }",
      doc: "Runs each time the condition turns true (checked every second)."
    },
    %{kind: "on_end", form: "on end { … }", doc: "Runs once when the run ends, after the score is counted."}
  ]

  # --- the world a script reads ---------------------------------------------------

  @income {:record, %{"credit" => "number", "technology" => "number", "ideology" => "number"}}

  @system {:record,
           %{
             "id" => "number",
             "name" => "text",
             "home" => "bool",
             "population" => "number",
             "housing" => "number",
             "stability" => "number",
             "production" => "number",
             "intelligence" => "number",
             "defense" => "number",
             "income" => @income
           }}

  @fleet {:record, %{"raid" => "number", "invasion" => "number", "upkeep" => "number"}}

  @agent {:record,
          %{
            "id" => "number",
            "name" => "text",
            "type" => {:enum, ["navarch", "siderian", "erased"]},
            "level" => "number",
            "status" => {:enum, ["deck", "board", "governor"]},
            "system" => "number",
            "fleet" => @fleet
          }}

  @faction {:record,
            %{
              "name" => "text",
              "players" => "number",
              "systems" => "number",
              "dominions" => "number",
              "victory_points" => "number",
              "rank" => "number"
            }}

  # what anyone in the match could see of another player
  @someone {:record,
            %{
              "name" => "text",
              "faction" => "text",
              "systems_owned" => "number",
              "dominions" => "number",
              "population" => "number"
            }}

  @modes ["daily", "legacy", "tactic", "flash"]

  @doc "What `scenario.mode` can be: a daily (or a playtest), or a match at one of the three speeds."
  def modes, do: @modes

  @world %{
    "time" =>
      {:record,
       %{
         "elapsed" => "number",
         "left" => "number",
         "limit" => "number"
       }},
    "player" =>
      {:record,
       %{
         "name" => "text",
         "faction" => "text",
         "credit" => "number",
         "technology" => "number",
         "ideology" => "number",
         "income" => @income,
         "systems" => {:list, @system},
         "systems_owned" => "number",
         "dominions" => "number",
         "population" => "number",
         "agents" => {:list, @agent},
         "patents" => {:list, "text"},
         "wonders" => {:list, "text"},
         "agents_removed" => "number"
       }},
    "rival" =>
      {:record,
       %{
         "present" => "bool",
         "faction" => "text",
         "agents_sent" => "number",
         "agents_left" => "number"
       }},
    "scenario" =>
      {:record,
       %{
         "name" => "text",
         "mode" => {:enum, @modes},
         "systems" => "number",
         "time_limit" => "number"
       }},
    "factions" => {:list, @faction},
    "players" => {:list, @someone}
  }

  # Plain-language names for every value a script can read: the editor
  # shows these first, with the path as a hint (players who don't program
  # read "Credits held" more easily than player.credit).
  @world_docs %{
    "time.elapsed" => "Time played: seconds since the run began.",
    "time.left" => "Time left: seconds until the deadline (0 at the deadline).",
    "time.limit" => "Run length, in seconds.",
    "player.name" => "The player's name.",
    "player.faction" => "The player's faction.",
    "player.credit" => "Credits held.",
    "player.technology" => "Technology held.",
    "player.ideology" => "Ideology held.",
    "player.income" => "Income per game day: .credit, .technology, .ideology.",
    "player.income.credit" => "Credit income, per game day.",
    "player.income.technology" => "Technology income, per game day.",
    "player.income.ideology" => "Ideology income, per game day.",
    "player.systems" => "The player's systems (not dominions), home first.",
    "player.systems_owned" => "Number of systems owned.",
    "player.dominions" => "Number of dominions held.",
    "player.population" => "Total population, systems and dominions.",
    "player.agents" => "The player's own agents: Navarchs, Siderians, Erased.",
    "player.patents" => "Patents researched, by name: [\"armoring\", \"precision_cranes\"].",
    "player.wonders" => "Wonders built, by key.",
    "player.agents_removed" => "Enemy agents removed by the player's Erased.",
    "rival.present" => "Whether there is a rival court (rival = true in setup).",
    "rival.faction" => "The rival court's faction.",
    "rival.agents_sent" => "Agents the rival court has sent so far.",
    "rival.agents_left" => "Rival agents still in play.",
    "scenario.name" => "This scenario's name.",
    "scenario.mode" => "What is being played: \"daily\" (a daily or a playtest), \"legacy\", \"tactic\" or \"flash\".",
    "scenario.systems" => "Systems in the starting sector (in a match, on the whole map).",
    "scenario.time_limit" => "The scenario's run length, in seconds.",
    "factions" => "The factions in play, the leader first: .name, .players, .systems, .victory_points …",
    "factions[].name" => "The faction's name, as player.faction gives it: \"tetrarchy\".",
    "factions[].players" => "How many players the faction has.",
    "factions[].systems" => "How many systems the faction owns.",
    "factions[].dominions" => "How many dominions the faction holds.",
    "factions[].victory_points" => "The faction's victory points.",
    "factions[].rank" => "The faction's place in the standings: 1 leads.",
    "players" => "Everyone playing, the player included: .name, .faction, .systems_owned …",
    "players[].name" => "The player's name.",
    "players[].faction" => "The player's faction.",
    "players[].systems_owned" => "How many systems the player owns.",
    "players[].dominions" => "How many dominions the player holds.",
    "players[].population" => "The player's total population.",
    # each item of a list, written with [] (s in `for s in player.systems`)
    "player.systems[].id" => "The system's id (what system: takes).",
    "player.systems[].name" => "The system's name.",
    "player.systems[].home" => "Whether this is the player's first system.",
    "player.systems[].population" => "The system's population.",
    "player.systems[].housing" => "How much population the system can house.",
    "player.systems[].stability" => "The system's stability.",
    "player.systems[].production" => "The system's production.",
    "player.systems[].intelligence" => "The system's Intelligence (its counter-intelligence).",
    "player.systems[].defense" => "The system's defense.",
    "player.systems[].income" => "The system's own income per game day: .credit, .technology, .ideology.",
    "player.systems[].income.credit" => "The system's credit income, per game day.",
    "player.systems[].income.technology" => "The system's technology income, per game day.",
    "player.systems[].income.ideology" => "The system's ideology income, per game day.",
    "player.agents[].id" => "The agent's id.",
    "player.agents[].name" => "The agent's name.",
    "player.agents[].type" => "navarch, siderian or erased.",
    "player.agents[].level" => "The agent's level.",
    "player.agents[].status" => "deck (not in play), board (on the board) or governor.",
    "player.agents[].system" => "The id of the system the agent is in, or nil.",
    "player.agents[].fleet" => "A Navarch's fleet: .raid, .invasion, .upkeep (0 for other agents).",
    "player.agents[].fleet.raid" => "The fleet's raid strength.",
    "player.agents[].fleet.invasion" => "The fleet's invasion strength.",
    "player.agents[].fleet.upkeep" => "The fleet's upkeep."
  }

  # --- setup ------------------------------------------------------------------------

  # {name, type, default, doc}
  @setup [
    {"name", "text", "Untitled scenario", "The scenario's title, as players see it."},
    {"description", "text", "", "One or two sentences telling the player what to do."},
    {"time_limit", "number", 1800.0,
     "How long a run lasts, from 5m to 45m. In a match, a time_limit shorter than the map's sets the match's length."},
    {"faction", {:enum, @factions}, nil, "The player's faction. Left out, the scenario picks one from its seed."},
    {"systems", "number", 1.0, "How many systems the starting sector holds, from 1 to 8. The player starts in one."},
    {"neighbors", {:enum, ["empty", "neutral"]}, "empty",
     "What the other systems are: empty (to colonize) or neutral (to conquer or win over)."},
    {"rival", "bool", false, "Add a rival court: an enemy faction whose agents the scenario can send in."},
    {"mutators", {:list, "text"}, [], "Daily mutators to apply, by key (boons and banes)."},
    {"grant_patents", {:list, "text"}, [], "Patents the player starts with (each with its prerequisites)."},
    {"patent_discounts", "record", %{}, "Price factors for single patents: {armoring: 20%} sells it at a fifth."},
    {"seed", "any", nil, "Fixes the generated world. Left out, it comes from the script itself."},
    {"factions", "number", nil,
     "How many factions the scenario is written for. Attached to a map with a different number, it warns."}
  ]

  @setup_bounds %{"time_limit" => {300, 2700}, "systems" => {1, 8}, "factions" => {1, 8}}

  # --- accessors ------------------------------------------------------------------------

  def builtin_names, do: Enum.map(@builtins, &elem(&1, 0))
  def action_names, do: Enum.map(@actions, &elem(&1, 0))
  def world_roots, do: Map.keys(@world)
  def world, do: @world
  def setup_names, do: Enum.map(@setup, &elem(&1, 0))
  def setup_bounds, do: @setup_bounds

  def builtin(name) when is_binary(name), do: Map.get(builtin_map(), name)
  def builtin(_), do: nil
  def action(name) when is_binary(name), do: Map.get(action_map(), name)
  def action(_), do: nil
  def setup_field(name), do: Enum.find_value(@setup, &(elem(&1, 0) == name && setup_spec(&1)))

  # Signatures by name, built once per lookup table and kept in
  # :persistent_term (the catalog is fixed at compile time).
  defp builtin_map, do: cached(:builtins, fn -> Map.new(@builtins, &{elem(&1, 0), signature(&1, :builtin)}) end)
  defp action_map, do: cached(:actions, fn -> Map.new(@actions, &{elem(&1, 0), signature(&1, :action)}) end)

  defp cached(key, build) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        value = build.()
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  def setup_defaults, do: Map.new(@setup, fn {name, _, default, _} -> {name, default} end)

  defp signature({name, group, params, returns, doc}, :builtin) do
    %{
      name: name,
      group: group,
      params: Enum.map(params, &param/1),
      named: [],
      returns: returns,
      doc: doc,
      kind: :builtin
    }
  end

  defp signature({name, group, params, named, doc}, :action) do
    %{
      name: name,
      group: group,
      params: Enum.map(params, &param/1),
      named: Enum.map(named, &param/1),
      returns: "nil",
      doc: doc,
      kind: :action
    }
  end

  defp param({name, type}), do: %{name: name, type: type, optional: false, rest: false}
  defp param({name, type, :optional}), do: %{name: name, type: type, optional: true, rest: false}
  defp param({name, type, :rest}), do: %{name: name, type: type, optional: true, rest: true}

  defp setup_spec({name, type, default, doc}), do: %{name: name, type: type, default: default, doc: doc}

  @doc "The type of a world path such as [\"player\", \"income\"], or nil if it doesn't exist."
  def world_type([root | path]) do
    Enum.reduce_while(path, Map.get(@world, root), fn
      field, {:record, fields} ->
        case Map.fetch(fields, field) do
          {:ok, t} -> {:cont, t}
          :error -> {:halt, nil}
        end

      _field, _ ->
        {:halt, nil}
    end)
  end

  @doc "The game's internal patent keys (`capital_1`): the Legacy roster the daily runs on."
  def patent_keys do
    Data.Game.Patent.Content.Slow.data() |> Enum.map(&Atom.to_string(&1.key))
  end

  # Scripts name patents the way players read them: the English name in
  # snake_case ("Armoring" -> "armoring", "S.L.S.D. Captors" ->
  # "slsd_captors"), read from the English locale at compile time. The
  # internal keys still work (the checker suggests the name).
  @patent_locale Path.expand("front/src/locales/en/data.json", File.cwd!())
  @external_resource @patent_locale
  @patent_titles (case File.read(@patent_locale) do
                    {:ok, json} ->
                      json
                      |> Jason.decode!()
                      |> get_in(["data", "patent"])
                      |> Kernel.||(%{})
                      |> Map.new(fn {key, entry} -> {key, entry["name"]} end)

                    {:error, _} ->
                      %{}
                  end)

  @doc "Patent names as scripts write them (`armoring`), sorted."
  def patent_names, do: patent_table() |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  @doc "The script name for a patent, given its name or its internal key; nil if neither."
  def patent_name(name_or_key), do: Map.get(patent_lookup(), name_or_key, {nil, nil, nil}) |> elem(1)

  @doc "The internal key for a patent, given its name or its internal key; nil if neither."
  def patent_key(name_or_key), do: Map.get(patent_lookup(), name_or_key, {nil, nil, nil}) |> elem(0)

  @doc "The patent's English title (\"Armoring\"), given its name or key; nil if neither."
  def patent_title(name_or_key), do: Map.get(patent_lookup(), name_or_key, {nil, nil, nil}) |> elem(2)

  # [{key, name, title}]
  defp patent_table do
    cached(:patents, fn ->
      Enum.map(patent_keys(), fn key ->
        title = Map.get(@patent_titles, key) || key
        {key, patent_slug(title), title}
      end)
    end)
  end

  # name or key -> {key, name, title}
  defp patent_lookup do
    cached(:patent_lookup, fn ->
      Enum.reduce(patent_table(), %{}, fn {key, name, _} = row, acc ->
        acc |> Map.put(key, row) |> Map.put(name, row)
      end)
    end)
  end

  defp patent_slug(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.replace(~r/['.]/, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  @doc "Mutator keys a scenario may apply: the implemented ones."
  def mutator_keys do
    Data.Game.Mutator.implemented() |> Enum.map(&Atom.to_string(&1.key))
  end

  # --- the editor's view -------------------------------------------------------------

  @doc "The catalog as JSON for the editor: palette, docs and types."
  def to_json do
    %{
      builtins: Enum.map(@builtins, &json_signature(signature(&1, :builtin))),
      actions: Enum.map(@actions, &json_signature(signature(&1, :action))),
      events: @events,
      world: Map.new(@world, fn {root, type} -> {root, json_type(type)} end),
      world_docs: @world_docs,
      setup:
        Enum.map(@setup, fn {name, type, default, doc} ->
          %{name: name, type: json_type(type), default: default, doc: doc, bounds: bounds_json(name)}
        end),
      mutators:
        Enum.map(Data.Game.Mutator.implemented(), fn m ->
          %{key: m.key, name: m.name, polarity: Map.get(m, :polarity), description: Map.get(m, :description)}
        end),
      keywords: Edict.Lexer.keywords(),
      resources: @resources,
      limits: %{
        fuel_per_pulse: Edict.Limits.fuel_per_pulse(),
        max_effects_per_pulse: Edict.Limits.max_effects_per_pulse()
      }
    }
  end

  defp bounds_json(name) do
    case Map.get(@setup_bounds, name) do
      {lo, hi} -> [lo, hi]
      nil -> nil
    end
  end

  defp json_signature(sig) do
    %{
      name: sig.name,
      group: sig.group,
      params: Enum.map(sig.params, &%{&1 | type: json_type(&1.type)}),
      named: Enum.map(sig.named, &%{&1 | type: json_type(&1.type)}),
      returns: json_type(sig.returns),
      doc: sig.doc,
      kind: sig.kind
    }
  end

  @doc false
  def json_type({:list, t}), do: %{list: json_type(t)}
  def json_type({:record, fields}), do: %{record: Map.new(fields, fn {k, v} -> {k, json_type(v)} end)}
  def json_type({:enum, values}), do: %{enum: values}
  def json_type(t) when is_binary(t), do: t
end
