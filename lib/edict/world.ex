defmodule Edict.World do
  @moduledoc """
  Builds the world a script reads from the live game's player data.

  The result is plain data (string keys, floats, lists, records) shaped
  exactly like `Edict.Catalog.world/0` describes, so the script can't tell a
  live game from the simulator's model. Only what the catalog lists is
  copied: the player's own stocks, incomes, systems, agents, patents and
  wonders, the clock, and the rival court's counters. Nothing about other
  players, nothing from the engine's internals.

  `build/2` takes any map shaped like `Instance.Player.Player` (struct or
  plain map), which is also how the parity tests feed it.
  """

  @doc """
  The world for one pulse. `opts`:

    * `:clock` — `%{elapsed, left, limit}` in seconds (required)
    * `:config` — the scenario's setup
    * `:intelligence` — `%{system_id => counter-intelligence}` for the
      player's systems (the player-side summary doesn't carry it)
    * `:rival` — `%{faction, sent, left}` when the scenario has a rival court
  """
  def build(player, opts) do
    clock = Keyword.fetch!(opts, :clock)
    config = Keyword.get(opts, :config, %{})
    intelligence = Keyword.get(opts, :intelligence, %{})
    rival = Keyword.get(opts, :rival)

    systems = get(player, :stellar_systems, [])
    dominions = get(player, :dominions, [])

    %{
      "time" => %{
        "elapsed" => f(clock.elapsed),
        "left" => f(max(clock.left, 0)),
        "limit" => f(clock.limit)
      },
      "player" => %{
        "name" => text(get(player, :name, "")),
        "faction" => text(get(player, :faction, "")),
        "credit" => stock(player, :credit),
        "technology" => stock(player, :technology),
        "ideology" => stock(player, :ideology),
        "income" => %{
          "credit" => change(player, :credit),
          "technology" => change(player, :technology),
          "ideology" => change(player, :ideology)
        },
        "systems" => systems |> Enum.with_index() |> Enum.map(fn {s, i} -> system(s, i == 0, intelligence) end),
        "systems_owned" => f(length(systems)),
        "dominions" => f(length(dominions)),
        "population" => f(Enum.reduce(systems ++ dominions, 0, &(num(get(&1, :workforce, 0)) + &2))),
        "agents" => player |> get(:characters, []) |> Enum.map(&agent/1),
        "patents" => player |> get(:patents, []) |> Enum.map(&text/1),
        "wonders" => player |> get(:wonders_built, []) |> Enum.map(&text/1),
        "agents_removed" => f(get(player, :agents_assassinated, 0))
      },
      "rival" => %{
        "present" => rival != nil,
        "faction" => rival && text(rival.faction),
        "agents_sent" => f((rival && rival.sent) || 0),
        "agents_left" => f((rival && rival.left) || 0)
      },
      "scenario" => %{
        "name" => Map.get(config, "name", ""),
        "systems" => f(Map.get(config, "systems", 1)),
        "time_limit" => f(clock.limit)
      }
    }
  end

  defp system(s, home?, intelligence) do
    id = get(s, :id, 0)

    %{
      "id" => f(id),
      "name" => text(get(s, :name, "")),
      "home" => home?,
      "population" => f(get(s, :workforce, 0)),
      "housing" => f(get(s, :habitation, 0)),
      "stability" => f(get(s, :happiness, 0)),
      "production" => f(get(s, :production, 0)),
      "intelligence" => f(Map.get(intelligence, id, 0)),
      "defense" => f(get(s, :defense, 0)),
      "income" => %{
        "credit" => f(get(s, :credit, 0)),
        "technology" => f(get(s, :technology, 0)),
        "ideology" => f(get(s, :ideology, 0))
      }
    }
  end

  defp agent(c) do
    %{
      "id" => f(get(c, :id, 0)),
      "name" => text(get(c, :name, "")),
      "type" => agent_type(get(c, :type, nil)),
      "level" => f(get(c, :level, 0)),
      "status" => agent_status(get(c, :status, nil)),
      "system" => if(get(c, :system, nil), do: f(get(c, :system, 0)), else: nil),
      "fleet" => %{
        "raid" => f(get(c, :army_raid, 0) || 0),
        "invasion" => f(get(c, :army_invasion, 0) || 0),
        "upkeep" => f(get(c, :army_maintenance, 0) || 0)
      }
    }
  end

  defp agent_type(:admiral), do: "navarch"
  defp agent_type(:speaker), do: "siderian"
  defp agent_type(:spy), do: "erased"
  defp agent_type(other), do: text(other)

  defp agent_status(:on_board), do: "board"
  defp agent_status(:governor), do: "governor"
  defp agent_status(_), do: "deck"

  defp stock(player, key) do
    case get(player, key, nil) do
      %{value: v} -> f(v)
      v when is_number(v) -> f(v)
      _ -> 0.0
    end
  end

  defp change(player, key) do
    case get(player, key, nil) do
      %{change: c} -> f(c)
      _ -> 0.0
    end
  end

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_, _key, default), do: default

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  defp f(v) when is_number(v), do: v / 1
  defp f(_), do: 0.0

  defp text(nil), do: ""
  defp text(v) when is_atom(v), do: Atom.to_string(v)
  defp text(v) when is_binary(v), do: v
  defp text(v), do: inspect(v)
end
