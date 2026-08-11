defmodule RC.Discord.BulletinData do
  @moduledoc """
  Assembles the `RC.Discord.Render.Cards.bulletin/1` data map from a
  day's `discord_bulletin_events` rows plus the instance's live galaxy
  state.

  The detail-tier policy matches the text bulletin
  (`RC.Discord.Bulletin`): with more than two factions the card stays
  deliberately vague — per-faction tallies and damage/loot totals, but
  no player names, no system names, and no map markers. With exactly
  two factions the enemy already knows what happened to them, so
  commander records, target lists and map highlights are included.

  Target lists name only non-neutral victims (`victim_faction` set);
  strikes on neutral systems count toward totals but are not mapped or
  named. Event payloads are string-keyed (JSONB round-trip); rows
  written before the loot/raid payload enrichment simply lack the
  value fields and fold in as zero — the card omits a damage/loot line
  that sums to nothing rather than reporting a false zero.
  """

  @max_records 26

  @doc """
  `{:ok, data}` for `Cards.bulletin/1`, or `{:error, reason}` when the
  instance's galaxy agent is unreachable (caller falls back to the
  text bulletin).
  """
  def assemble(instance, instance_name, faction_count, events, date) do
    detailed? = faction_count <= 2
    by_kind = Enum.group_by(events, & &1.kind)
    battles = Map.get(by_kind, "battle", [])
    conquests = Map.get(by_kind, "conquest", [])
    raids = Map.get(by_kind, "raid", [])
    loots = Map.get(by_kind, "loot", [])

    case Game.call(instance.id, :galaxy, :master, :get_state) do
      {:ok, galaxy} ->
        ownership = %{
          systems:
            Map.new(galaxy.stellar_systems, fn s ->
              {s.id, %{faction: s.faction && to_string(s.faction), status: to_string(s.status)}}
            end),
          sectors: Map.new(galaxy.sectors, fn s -> {s.id, s.owner && to_string(s.owner)} end)
        }

        marks = if detailed?, do: highlights(conquests, raids, loots), else: []

        {:ok,
         %{
           instance_name: instance_name,
           date: date,
           battles: %{
             engagements: length(battles),
             factions: battle_factions(battles),
             records: if(detailed?, do: battle_records(battles), else: [])
           },
           spoils: spoils(conquests, raids, loots, detailed?),
           game_data: instance.game_data,
           ownership: ownership,
           highlights: marks,
           legend: legend_for(marks)
         }}

      other ->
        {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  ## Battles -------------------------------------------------------------

  @doc "Per-faction W/L tallies from battle rows (draws count neither)."
  def battle_factions(battles) do
    battles
    |> Enum.reduce(%{}, fn event, acc ->
      p = payload(event)

      case winner_loser(p) do
        {nil, nil} -> acc
        {winner, loser} -> acc |> bump(winner, :wins) |> bump(loser, :losses)
      end
    end)
    |> Enum.map(fn {faction, %{wins: w, losses: l}} -> %{faction: faction, wins: w, losses: l} end)
    |> Enum.sort_by(&{-&1.wins, &1.losses})
  end

  @doc "Per-player records (two-faction tier), sorted best first."
  def battle_records(battles) do
    battles
    |> Enum.reduce(%{}, fn event, acc ->
      p = payload(event)

      acc
      |> fold_players(p["winners"] || [], fn {w, l} -> {w + 1, l} end)
      |> fold_players(p["losers"] || [], fn {w, l} -> {w, l + 1} end)
    end)
    |> Enum.sort_by(fn {{name, _f}, {w, l}} -> {-w, l, name} end)
    |> Enum.take(@max_records)
    |> Enum.map(fn {{name, faction}, {w, l}} -> %{name: name, faction: faction, wins: w, losses: l} end)
  end

  defp winner_loser(p) do
    case p["winner"] do
      "attackers" -> {p["attacker_faction"], p["defender_faction"]}
      "defenders" -> {p["defender_faction"], p["attacker_faction"]}
      _ -> {nil, nil}
    end
  end

  defp bump(acc, nil, _key), do: acc

  defp bump(acc, faction, key) do
    acc
    |> Map.put_new(faction, %{wins: 0, losses: 0})
    |> update_in([faction, key], &(&1 + 1))
  end

  defp fold_players(records, players, bump_fun) do
    Enum.reduce(players, records, fn player, acc ->
      key = {player["name"], player["faction"]}
      Map.update(acc, key, bump_fun.({0, 0}), bump_fun)
    end)
  end

  ## Spoils --------------------------------------------------------------

  def spoils(conquests, raids, loots, detailed?) do
    named_raids = Enum.filter(raids, &non_neutral?/1)
    named_loots = Enum.filter(loots, &non_neutral?/1)

    %{
      conquests: %{
        count: length(conquests),
        names: if(detailed?, do: unique_names(conquests), else: nil)
      },
      bombards: %{
        count: length(raids),
        systems: raids |> Enum.map(&payload(&1)["system_id"]) |> Enum.uniq() |> length(),
        names: if(detailed?, do: unique_names(named_raids), else: nil),
        buildings: sum_field(raids, "damaged_buildings"),
        population: sum_field(raids, "population_lost")
      },
      pillages: %{
        count: length(loots),
        names: if(detailed?, do: counted_names(named_loots), else: nil),
        credits: sum_field(loots, "credit"),
        technology: sum_field(loots, "technology"),
        ideology: sum_field(loots, "ideology")
      }
    }
  end

  defp non_neutral?(event), do: payload(event)["victim_faction"] not in [nil, ""]

  defp unique_names(events) do
    events
    |> Enum.map(&(payload(&1)["system_name"] || "an uncharted system"))
    |> Enum.uniq()
  end

  defp counted_names(events) do
    events
    |> Enum.map(&(payload(&1)["system_name"] || "an uncharted system"))
    |> Enum.reduce(%{}, fn name, acc -> Map.update(acc, name, 1, &(&1 + 1)) end)
    |> Enum.sort_by(fn {name, n} -> {-n, name} end)
    |> Enum.map(fn {name, n} -> %{name: name, count: n} end)
  end

  defp sum_field(events, field) do
    events
    |> Enum.map(fn e ->
      case payload(e)[field] do
        n when is_number(n) -> n
        _ -> 0
      end
    end)
    |> Enum.sum()
    |> round()
  end

  ## Map highlights (two-faction tier only) ------------------------------

  def highlights(conquests, raids, loots) do
    conquest_marks =
      Enum.flat_map(conquests, fn e ->
        p = payload(e)

        case p["system_id"] do
          nil -> []
          id -> [%{system_id: id, kind: :conquest, label: p["system_name"], faction: p["faction"]}]
        end
      end)

    raid_marks =
      raids
      |> Enum.filter(&non_neutral?/1)
      |> Enum.flat_map(fn e ->
        p = payload(e)
        if p["system_id"], do: [%{system_id: p["system_id"], kind: :bombard, label: p["system_name"]}], else: []
      end)
      |> Enum.uniq_by(& &1.system_id)

    pillage_marks =
      loots
      |> Enum.filter(&non_neutral?/1)
      |> Enum.group_by(fn e -> payload(e)["system_id"] end)
      |> Enum.flat_map(fn
        {nil, _} -> []
        {id, list} -> [%{system_id: id, kind: :pillage, count: length(list), label: nil}]
      end)

    taken = MapSet.new(conquest_marks ++ raid_marks, & &1.system_id)
    conquest_marks ++ raid_marks ++ Enum.reject(pillage_marks, &MapSet.member?(taken, &1.system_id))
  end

  def legend_for(marks) do
    kinds = marks |> Enum.map(& &1.kind) |> MapSet.new()

    [{:conquest, "Conquered"}, {:bombard, "Bombarded"}, {:pillage, "Pillaged"}]
    |> Enum.filter(fn {kind, _} -> MapSet.member?(kinds, kind) end)
  end

  # BulletinEvent payloads come back from JSONB string-keyed; tests may
  # hand-build structs with atom keys. Normalize.
  defp payload(%{payload: p}) when is_map(p) do
    Map.new(p, fn {k, v} -> {to_string(k), v} end)
  end

  defp payload(_), do: %{}
end
