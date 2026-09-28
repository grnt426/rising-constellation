defmodule RC.Archive.SnapshotStats do
  @moduledoc """
  Pure metric extraction from ONE decoded instance snapshot
  (`%{instance_data:, agents_data: [%{module:, state: %Core.GenState{}}]}`).

  Deliberately works on plain maps with `Map.get` everywhere: archive
  imports read snapshots written by older releases, whose structs may lack
  fields added since (see the snapshot-tolerant-fields rule). Nothing here
  touches the DB or the running game.

  `extract/1` returns:

      %{
        factions: %{"tetrarchy" => %{metric => number | list}},
        players: [%{id, registration_id, name, faction, metrics}],
        unlocks: %{"patent" => %{key => %{faction => count}}, "lex" => ...},
        sector_owners: %{sector_id => faction | nil},
        system_codes: %{system_id => {faction | nil, kind}},
        galaxy: %{size, sectors, systems},  # static geometry
        victory: %{winner, ut_time_left}
      }

  ## Faction metric keys

  Income is per game ut (slow: 20 ut per real hour) and summed over the
  faction's players:

    * `<res>_net` — Σ DynamicValue.change (what the player sees)
    * `<res>_gross` / `<res>_expense` — Σ positive / negative detail parts
    * `<res>_src_<type>` — Σ parts per detail type (system, dominion,
      doctrine, tradition, government, character_wages, fleet_maintenance …)
    * `<res>_stock` — Σ stockpile

  Territory / victory: `players`, `players_active`, `systems`, `dominions`,
  `sectors`, `sector_vp`, `victory_points`, `track_<t>_points`,
  `track_<t>_index`, `track_<t>_milestones`, `population_points`,
  `population_value`, `visibility_count`.

  Per-system averages, split by scope (`sys_` = player systems,
  `dom_` = dominions), e.g. `sys_avg_defense`: see `@system_stats`.
  `*_avg_malware` = enemy informers sitting on the scope's systems.

  Espionage: `malware_planted_enemy` (on other factions' systems),
  `malware_planted_neutral`, `malware_suffered` (on own systems).

  Research: `avg_lex_slots`, `avg_patents`, `avg_lex`, `avg_active_lex`.

  Military & agents: `agents_<type>`, `agents_<type>_avg_level`,
  `agents_in_deck`, `ships_<class>`, `ships_total`, `ships_avg_xp`,
  `ships_avg_level`, `fleet_maintenance`, `sieges_by_<type>`,
  `sieges_suffered`, `megastructures_<key>`.
  """

  @resources [:credit, :technology, :ideology]

  # {metric suffix, stellar_system field, reader}
  @system_stats [
    {"defense", :defense, :value},
    {"intelligence", :counter_intelligence, :value},
    # UI "Cybersecurity" shows the per-ut rate, not the progress counter.
    {"cybersecurity", :remove_contact, :change},
    {"stability", :happiness, :value},
    {"population", :workforce, :raw},
    {"housing", :habitation, :value},
    {"production", :production, :value},
    {"credit", :credit, :value},
    {"technology", :technology, :value},
    {"ideology", :ideology, :value},
    {"slsd", :radar, :value},
    {"mobility", :mobility, :value},
    {"xp_fighter", :fighter_lvl, :value},
    {"xp_corvette", :corvette_lvl, :value},
    {"xp_frigate", :frigate_lvl, :value},
    {"xp_capital", :capital_lvl, :value}
  ]

  @megastructures [:monument_dome, :high_factory_dome]

  def system_stat_keys, do: Enum.map(@system_stats, &elem(&1, 0))

  @doc "Trusted input only (our own snapshot files) — not `:safe`."
  def decode(binary) when is_binary(binary), do: :erlang.binary_to_term(binary)

  def extract(%{agents_data: agents}) do
    groups =
      agents
      |> Enum.filter(fn a -> is_map(a.state) and is_map(Map.get(a.state, :data)) end)
      |> Enum.group_by(fn a -> Map.get(a.state, :type) end, fn a -> a.state.data end)

    factions = Map.get(groups, :faction, [])
    players = Map.get(groups, :player, [])
    systems = Map.get(groups, :stellar_system, [])
    characters = Map.get(groups, :character, [])
    victory = groups |> Map.get(:victory, [nil]) |> hd()
    galaxy = groups |> Map.get(:galaxy, [nil]) |> hd()

    faction_by_char =
      Map.new(characters, fn c -> {c.id, c |> Map.get(:owner) |> owner_faction()} end)

    informers = informers_by_system(factions)

    faction_metrics =
      Map.new(factions, fn f ->
        key = f.key
        f_players = Enum.filter(players, &(&1.faction == key))

        f_systems =
          Enum.filter(systems, fn s -> owner_faction(Map.get(s, :owner)) == key end)

        metrics =
          %{}
          |> Map.merge(player_metrics(f_players))
          |> Map.merge(income_metrics(f_players))
          |> Map.merge(territory_metrics(key, f_systems, galaxy, victory))
          |> Map.merge(system_avg_metrics("sys", scope(f_systems, :inhabited_player), key, informers))
          |> Map.merge(system_avg_metrics("dom", scope(f_systems, :inhabited_dominion), key, informers))
          |> Map.merge(malware_metrics(f, systems, f_systems, informers))
          |> Map.merge(research_metrics(f_players))
          |> Map.merge(agent_metrics(key, characters, f_players))
          |> Map.merge(siege_metrics(key, systems, f_systems, faction_by_char))
          |> Map.merge(megastructure_metrics(f_systems))

        {to_string(key), round_values(metrics)}
      end)

    %{
      factions: faction_metrics,
      players: Enum.map(players, &player_row/1),
      unlocks: unlocks(players),
      sector_owners: sector_owners(galaxy),
      system_codes: system_codes(systems),
      galaxy: galaxy_geometry(galaxy),
      victory: %{
        winner: victory && Map.get(victory, :winner) && to_string(victory.winner),
        ut_time_left: victory && Map.get(victory, :ut_time_left)
      }
    }
  end

  # --- players -----------------------------------------------------------

  defp player_metrics(players) do
    %{
      players: length(players),
      players_active: Enum.count(players, &Map.get(&1, :is_active, true))
    }
  end

  defp income_metrics(players) do
    Enum.reduce(@resources, %{}, fn res, acc ->
      dvs = Enum.map(players, &Map.get(&1, res))

      parts =
        dvs
        |> Enum.flat_map(fn dv ->
          dv |> details() |> Enum.flat_map(fn {type, ps} -> Enum.map(ps, &{type, &1.value}) end)
        end)

      sources =
        parts
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {type, values} -> {"#{res}_src_#{type}", Enum.sum(values)} end)

      acc
      |> Map.put("#{res}_net", dvs |> Enum.map(&num(Map.get(&1, :change))) |> Enum.sum())
      |> Map.put("#{res}_gross", parts |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(&1 > 0)) |> Enum.sum())
      |> Map.put("#{res}_expense", parts |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(&1 < 0)) |> Enum.sum())
      |> Map.put("#{res}_stock", dvs |> Enum.map(&num(Map.get(&1, :value))) |> Enum.sum())
      |> Map.merge(sources)
    end)
  end

  defp research_metrics(players) do
    %{
      avg_lex_slots: avg(players, &num(Map.get(&1, :max_policies))),
      avg_patents: avg(players, &length(Map.get(&1, :patents) || [])),
      avg_lex: avg(players, &length(Map.get(&1, :doctrines) || [])),
      avg_active_lex: avg(players, &length(Map.get(&1, :policies) || []))
    }
  end

  defp player_row(p) do
    %{
      id: p.id,
      registration_id: Map.get(p, :registration_id),
      name: p.name,
      faction: to_string(p.faction),
      metrics:
        round_values(%{
          credit_net: num(p.credit.change),
          technology_net: num(p.technology.change),
          ideology_net: num(p.ideology.change),
          credit_stock: num(p.credit.value),
          systems: length(Map.get(p, :stellar_systems) || []),
          dominions: length(Map.get(p, :dominions) || []),
          patents: length(Map.get(p, :patents) || []),
          lex: length(Map.get(p, :doctrines) || []),
          lex_slots: num(Map.get(p, :max_policies)),
          agents: length(Map.get(p, :characters) || []) + length(Map.get(p, :character_deck) || []),
          is_active: Map.get(p, :is_active, true)
        })
    }
  end

  defp unlocks(players) do
    for {kind, field} <- [{"patent", :patents}, {"lex", :doctrines}], into: %{} do
      counts =
        players
        |> Enum.flat_map(fn p ->
          (Map.get(p, field) || []) |> Enum.uniq() |> Enum.map(&{to_string(&1), to_string(p.faction)})
        end)
        |> Enum.frequencies()
        |> Enum.reduce(%{}, fn {{key, faction}, n}, acc ->
          Map.update(acc, key, %{faction => n}, &Map.put(&1, faction, n))
        end)

      {kind, counts}
    end
  end

  # --- territory & victory -------------------------------------------------

  defp territory_metrics(key, f_systems, galaxy, victory) do
    sectors = if galaxy, do: Enum.filter(galaxy.sectors, &(Map.get(&1, :owner) == key)), else: []
    vf = victory && Enum.find(victory.factions, &(&1.key == key))

    base = %{
      systems: Enum.count(f_systems, &(&1.status == :inhabited_player)),
      dominions: Enum.count(f_systems, &(&1.status == :inhabited_dominion)),
      sectors: length(sectors),
      sector_vp: sectors |> Enum.map(&num(Map.get(&1, :victory_points))) |> Enum.sum()
    }

    if vf do
      tracks =
        for t <- [:conquest, :population, :visibility], reduce: %{} do
          acc ->
            track = Map.get(vf, :"#{t}_track") || %{}

            acc
            |> Map.put("track_#{t}_points", num(Map.get(track, :points)))
            |> Map.put("track_#{t}_index", num(Map.get(track, :index)))
            |> Map.put("track_#{t}_milestones", Map.get(track, :milestones) || [])
        end

      base
      |> Map.merge(tracks)
      |> Map.merge(%{
        victory_points: num(Map.get(vf, :victory_points)),
        population_points: num(Map.get(vf, :population_points)),
        population_value: num(Map.get(vf, :population_value)),
        visibility_count: num(Map.get(vf, :visibility_count))
      })
    else
      base
    end
  end

  defp scope(systems, status), do: Enum.filter(systems, &(&1.status == status))

  defp system_avg_metrics(prefix, systems, faction_key, informers) do
    stats =
      Map.new(@system_stats, fn {name, field, reader} ->
        {"#{prefix}_avg_#{name}", avg(systems, &read(Map.get(&1, field), reader))}
      end)

    malware =
      avg(systems, fn s ->
        informers
        |> Map.get(s.id, %{})
        |> Enum.reject(fn {f, _} -> f == faction_key end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()
      end)

    stats
    |> Map.put("#{prefix}_avg_malware", malware)
    |> Map.put("#{prefix}_count", length(systems))
  end

  # %{system_id => %{faction_key => informer_count}}
  defp informers_by_system(factions) do
    Enum.reduce(factions, %{}, fn f, acc ->
      Enum.reduce(Map.get(f, :contacts) || %{}, acc, fn {sid, contact}, acc ->
        case contact |> details() |> Map.get(:informer, []) |> length() do
          0 -> acc
          n -> Map.update(acc, sid, %{f.key => n}, &Map.put(&1, f.key, n))
        end
      end)
    end)
  end

  defp malware_metrics(faction, systems, f_systems, informers) do
    owner_of = Map.new(systems, fn s -> {s.id, owner_faction(Map.get(s, :owner))} end)

    suffered =
      f_systems
      |> Enum.flat_map(fn s -> informers |> Map.get(s.id, %{}) |> Enum.reject(fn {f, _} -> f == faction.key end) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    planted =
      Enum.reduce(Map.get(faction, :contacts) || %{}, %{enemy: 0, neutral: 0}, fn {sid, contact}, acc ->
        n = contact |> details() |> Map.get(:informer, []) |> length()

        case Map.get(owner_of, sid) do
          nil -> %{acc | neutral: acc.neutral + n}
          f when f == faction.key -> acc
          _ -> %{acc | enemy: acc.enemy + n}
        end
      end)

    %{malware_planted_enemy: planted.enemy, malware_planted_neutral: planted.neutral, malware_suffered: suffered}
  end

  defp siege_metrics(key, systems, f_systems, faction_by_char) do
    by_type =
      systems
      |> Enum.map(&Map.get(&1, :siege))
      |> Enum.filter(&(&1 && Map.get(faction_by_char, Map.get(&1, :besieger_id)) == key))
      |> Enum.frequencies_by(&"sieges_by_#{Map.get(&1, :type)}")

    Map.put(by_type, :sieges_suffered, Enum.count(f_systems, &Map.get(&1, :siege)))
  end

  defp megastructure_metrics(f_systems) do
    built =
      f_systems
      |> Enum.flat_map(&tiles/1)
      |> Enum.filter(&(&1.building_status == :built and &1.building_key in @megastructures))
      |> Enum.frequencies_by(& &1.building_key)

    Map.new(@megastructures, fn k -> {"megastructures_#{k}", Map.get(built, k, 0)} end)
  end

  defp tiles(system) do
    (Map.get(system, :bodies) || [])
    |> Enum.flat_map(fn b -> [b | Map.get(b, :bodies) || []] end)
    |> Enum.flat_map(&(Map.get(&1, :tiles) || []))
  end

  # --- agents & fleets -----------------------------------------------------

  defp agent_metrics(key, characters, f_players) do
    active =
      Enum.filter(characters, fn c ->
        owner_faction(Map.get(c, :owner)) == key and c.status in [:governor, :on_board]
      end)

    by_type =
      for type <- [:admiral, :spy, :speaker], reduce: %{} do
        acc ->
          of_type = Enum.filter(active, &(&1.type == type))

          acc
          |> Map.put("agents_#{type}", length(of_type))
          |> Map.put("agents_#{type}_avg_level", avg(of_type, &num(&1.level)))
      end

    ships =
      active
      |> Enum.flat_map(fn c -> c |> Map.get(:army) |> army_tiles() end)
      |> Enum.filter(&(Map.get(&1, :ship_status) == :filled and is_map(Map.get(&1, :ship))))
      |> Enum.map(& &1.ship)

    classes =
      ships
      |> Enum.frequencies_by(&ship_class/1)
      |> Map.new(fn {class, n} -> {"ships_#{class}", n} end)

    maintenance =
      active
      |> Enum.map(fn c -> c |> Map.get(:army) |> then(&(&1 && read(Map.get(&1, :maintenance), :value))) end)
      |> Enum.map(&num/1)
      |> Enum.sum()

    by_type
    |> Map.merge(Map.new(~w(fighter corvette frigate capital), &{"ships_#{&1}", 0}))
    |> Map.merge(classes)
    |> Map.merge(%{
      agents_in_deck: f_players |> Enum.map(&length(Map.get(&1, :character_deck) || [])) |> Enum.sum(),
      ships_total: length(ships),
      ships_avg_xp: avg(ships, &num(Map.get(&1, :experience))),
      ships_avg_level: avg(ships, &num(Map.get(&1, :level))),
      fleet_maintenance: maintenance
    })
  end

  defp army_tiles(nil), do: []
  defp army_tiles(army), do: Map.get(army, :tiles) || []

  defp ship_class(ship), do: ship.key |> to_string() |> String.split("_") |> hd()

  # --- map -----------------------------------------------------------------

  defp sector_owners(nil), do: %{}

  defp sector_owners(galaxy) do
    Map.new(galaxy.sectors, fn s -> {s.id, s |> Map.get(:owner) |> maybe_string()} end)
  end

  defp system_codes(systems) do
    Map.new(systems, fn s ->
      kind =
        case s.status do
          :inhabited_player -> "player"
          :inhabited_dominion -> "dominion"
          :inhabited_neutral -> "neutral"
          _ -> "empty"
        end

      {s.id, {s |> Map.get(:owner) |> owner_faction() |> maybe_string(), kind}}
    end)
  end

  defp galaxy_geometry(nil), do: nil

  defp galaxy_geometry(galaxy) do
    %{
      size: galaxy.size,
      sectors:
        Enum.map(galaxy.sectors, fn s ->
          %{
            id: s.id,
            name: s.name,
            points: Enum.map(s.points || [], &point/1),
            centroid: Map.get(s, :centroid),
            victory_points: Map.get(s, :victory_points)
          }
        end),
      systems:
        galaxy.stellar_systems
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn s ->
          %{
            id: s.id,
            name: s.name,
            x: s.position.x,
            y: s.position.y,
            sector_id: s.sector_id,
            type: to_string(s.type)
          }
        end),
      blackholes:
        Enum.map(Map.get(galaxy, :blackholes) || [], fn b ->
          %{x: b.position.x, y: b.position.y, radius: b.radius}
        end)
    }
  end

  defp point([x, y]), do: [x, y]
  defp point(%{"x" => x, "y" => y}), do: [x, y]
  defp point(%{x: x, y: y}), do: [x, y]
  defp point({x, y}), do: [x, y]

  # --- helpers -------------------------------------------------------------

  defp owner_faction(%{faction: f}) when not is_nil(f), do: f
  defp owner_faction(_), do: nil

  defp maybe_string(nil), do: nil
  defp maybe_string(v), do: to_string(v)

  # Market DynamicValues carry `details: []` rather than a map.
  defp details(%{details: d}) when is_map(d), do: d
  defp details(_), do: %{}

  defp read(nil, _), do: 0
  defp read(v, :raw) when is_number(v), do: v
  defp read(%{change: c}, :change), do: c
  defp read(%{value: v}, _), do: v
  defp read(v, _) when is_number(v), do: v
  defp read(_, _), do: 0

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  defp avg([], _), do: nil
  defp avg(list, fun), do: (list |> Enum.map(fun) |> Enum.map(&num/1) |> Enum.sum()) / length(list)

  defp round_values(map) do
    Map.new(map, fn
      {k, v} when is_float(v) -> {to_string(k), Float.round(v, 3)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
