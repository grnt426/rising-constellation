defmodule RC.Discord.Bulletin do
  @moduledoc """
  Pure logic for the daily summary bulletin: seeded slot selection and
  message rendering. `RC.Discord.DailyBulletin` owns scheduling, DB
  reads, and posting; everything here is side-effect free and
  unit-tested without the bot.

  ## Seeded slots

  Two windows, both US-Eastern wall time in 30-minute increments
  (inclusive endpoints):

    * **post slot** — when today's bulletin goes out: 12:00 to 14:00
    * **cutoff slot** — the hidden data cutoff: 07:00 to 11:00

  Both are pure functions of `(date, salt)` where the salt is the
  match's stored random secret (`discord_matches.bulletin_salt`) —
  never derived from observable data, so even watching weeks of
  public post times can't narrow down the hidden cutoff. Each day's
  window is `(yesterday's cutoff, today's cutoff]`, tracked by a
  stored high-water mark so a missed posting day folds into the next
  bulletin instead of losing events.

  ## Detail tiers

  With more than two factions the bulletin stays deliberately vague:
  per-faction tallies only, no player names, no systems, no times.
  With exactly two factions the enemy already knows what happened to
  them, so player records and system names are included. Firsts name
  the player in both tiers (player decision 2026-07).
  """

  alias RC.Discord.EasternTime
  alias RC.Discord.News

  # Post window 12:00-14:00 ET, cutoff window 07:00-11:00 ET.
  @slot_minutes 30
  @post_base_minutes 12 * 60
  @post_slot_count 5
  @cutoff_base_minutes 7 * 60
  @cutoff_slot_count 9

  # Display caps so a busy day can't blow Discord's 2000-char limit.
  @max_list_names 8
  @max_record_players 12

  @building_names %{
    "high_factory_dome" => "Metamaterials Factory",
    "monument_dome" => "Monolith"
  }

  # --- Seeded slots ----------------------------------------------------

  @doc "Today's bulletin post time (ET) for the given date + salt."
  def post_time(%Date{} = date, salt),
    do: slot_datetime(date, salt, :post, @post_base_minutes, @post_slot_count)

  @doc "Today's hidden data cutoff (ET) for the given date + salt."
  def cutoff_time(%Date{} = date, salt),
    do: slot_datetime(date, salt, :cutoff, @cutoff_base_minutes, @cutoff_slot_count)

  defp slot_datetime(date, salt, kind, base_minutes, slot_count) do
    slot = :erlang.phash2({to_string(salt), Date.to_iso8601(date), kind}, slot_count)
    minutes = base_minutes + slot * @slot_minutes

    date
    |> NaiveDateTime.new!(Time.new!(div(minutes, 60), rem(minutes, 60), 0))
    |> EasternTime.from_naive!()
  end

  # --- Rendering -------------------------------------------------------

  @doc """
  Render the bulletin message. `events` are `RC.Discord.BulletinEvent`
  structs (string-keyed payloads, as read back from JSONB);
  `firsts_lines` are pre-rendered sentences from `first_line/3`.
  """
  def render(instance_name, faction_count, events, firsts_lines) do
    detailed? = faction_count <= 2
    by_kind = Enum.group_by(events, & &1.kind)

    sections =
      [
        battles_section(Map.get(by_kind, "battle", []), detailed?),
        strikes_section("Conquests", Map.get(by_kind, "conquest", []), detailed?, "took"),
        strikes_section("Bombards", Map.get(by_kind, "raid", []), detailed?, "bombarded"),
        strikes_section("Pillages", Map.get(by_kind, "loot", []), detailed?, "pillaged"),
        firsts_section(firsts_lines)
      ]
      |> Enum.reject(&is_nil/1)

    truncate_at_line("📰 **#{instance_name}** daily bulletin\n" <> Enum.join(sections, "\n"))
  end

  # Discord caps messages at 2000 chars. The per-section caps make
  # overflow unlikely, but if it happens, cut at a line boundary — a
  # raw character slice can bisect a custom-emoji token or a markdown
  # pair and post visible garbage.
  @max_message_chars 1900

  defp truncate_at_line(content) when byte_size(content) <= @max_message_chars, do: content

  defp truncate_at_line(content) do
    kept =
      content
      |> String.split("\n")
      |> Enum.reduce_while([], fn line, acc ->
        candidate = Enum.reverse([line | acc]) |> Enum.join("\n")

        if String.length(candidate) > @max_message_chars,
          do: {:halt, acc},
          else: {:cont, [line | acc]}
      end)
      |> Enum.reverse()
      |> Enum.join("\n")

    kept <> "\n(truncated)"
  end

  # --- Battles ---------------------------------------------------------

  defp battles_section([], _detailed?), do: "**Battles**: none reported."

  defp battles_section(battles, detailed?) do
    total = length(battles)
    draws = Enum.count(battles, fn e -> payload(e)["winner"] == "draw" end)

    faction_records =
      Enum.reduce(battles, %{}, fn event, acc ->
        p = payload(event)

        case winner_loser_factions(p) do
          {nil, nil} -> acc
          {winner, loser} -> acc |> bump(winner, :wins) |> bump(loser, :losses)
        end
      end)

    tally =
      faction_records
      |> Enum.sort_by(fn {_f, %{wins: w, losses: l}} -> {-w, l} end)
      |> Enum.map_join(", ", fn {faction, %{wins: w, losses: l}} ->
        "#{News.faction_emoji(faction)}#{News.faction_name(faction)} #{record_label(w, l)}#{ratio_label(w, l)}"
      end)

    draw_note = if draws > 0, do: " (#{draws} inconclusive)", else: ""
    line = "**Battles**: #{total} engagement#{plural(total)}#{draw_note}. #{tally}"
    line = String.trim_trailing(line)

    if detailed? do
      case player_records(battles) do
        "" -> line
        records -> line <> "\nRecords: #{records}."
      end
    else
      line
    end
  end

  defp winner_loser_factions(p) do
    attacker = p["attacker_faction"]
    defender = p["defender_faction"]

    case p["winner"] do
      "attackers" -> {attacker, defender}
      "defenders" -> {defender, attacker}
      _ -> {nil, nil}
    end
  end

  defp bump(acc, nil, _key), do: acc

  defp bump(acc, faction, key) do
    acc
    |> Map.put_new(faction, %{wins: 0, losses: 0})
    |> update_in([faction, key], &(&1 + 1))
  end

  # Two-faction tier only: aggregate each named player's window record
  # from the battle payloads' winners/losers lists.
  defp player_records(battles) do
    battles
    |> Enum.reduce(%{}, fn event, acc ->
      p = payload(event)

      acc
      |> fold_players(p["winners"] || [], fn {w, l} -> {w + 1, l} end)
      |> fold_players(p["losers"] || [], fn {w, l} -> {w, l + 1} end)
    end)
    |> Enum.sort_by(fn {{name, _f}, {w, l}} -> {-w, l, name} end)
    |> Enum.take(@max_record_players)
    |> Enum.map_join(", ", fn {{name, faction}, {w, l}} ->
      "#{News.player_display(name, faction)} #{record_label(w, l)}"
    end)
  end

  defp fold_players(records, players, bump_fun) do
    Enum.reduce(players, records, fn player, acc ->
      key = {player["name"], player["faction"]}
      Map.update(acc, key, bump_fun.({0, 0}), bump_fun)
    end)
  end

  defp record_label(w, 0), do: "#{w}W"
  defp record_label(0, l), do: "#{l}L"
  defp record_label(w, l), do: "#{w}W #{l}L"

  defp ratio_label(w, l) when w + l > 0, do: " (#{round(100 * w / (w + l))}%)"
  defp ratio_label(_w, _l), do: ""

  # --- Conquests / bombards / pillages ---------------------------------

  defp strikes_section(label, [], _detailed?, _verb), do: "**#{label}**: none."

  defp strikes_section(label, events, detailed?, verb) do
    by_faction =
      events
      |> Enum.group_by(fn e -> payload(e)["faction"] end)
      |> Enum.sort_by(fn {_f, list} -> -length(list) end)

    body =
      if detailed? do
        Enum.map_join(by_faction, " ", fn {faction, list} ->
          "#{News.faction_emoji(faction)}#{News.faction_name(faction)} #{verb} #{system_list(list)}."
        end)
      else
        Enum.map_join(by_faction, ", ", fn {faction, list} ->
          "#{News.faction_emoji(faction)}#{News.faction_name(faction)} #{length(list)}"
        end)
      end

    "**#{label}**: #{body}"
  end

  # Named-systems list for the two-faction tier, deduplicated with
  # repeat-strike counts (bombing the same system thrice reads "Vega
  # x3", not three entries).
  defp system_list(events) do
    {names, dropped} =
      events
      |> Enum.map(fn e -> payload(e)["system_name"] || "an uncharted system" end)
      |> Enum.reduce(%{}, fn name, acc -> Map.update(acc, name, 1, &(&1 + 1)) end)
      |> Enum.sort_by(fn {name, n} -> {-n, name} end)
      |> Enum.map(fn
        {name, 1} -> name
        {name, n} -> "#{name} x#{n}"
      end)
      |> Enum.split(@max_list_names)

    case dropped do
      [] -> Enum.join(names, ", ")
      more -> Enum.join(names, ", ") <> " and #{length(more)} more"
    end
  end

  # --- Firsts ----------------------------------------------------------

  defp firsts_section([]), do: nil
  defp firsts_section(lines), do: "**Firsts**: " <> Enum.join(lines, " ")

  @doc """
  One sentence for an `instance_firsts` claim inside the window.
  `who` is the winning profile's name (nil falls back to the faction
  display name, then to "Someone").
  """
  def first_line(first_key, who, faction_ref) do
    subject =
      cond do
        who not in [nil, ""] and faction_ref not in [nil, ""] ->
          "#{who} (#{News.faction_name(faction_ref)})"

        who not in [nil, ""] ->
          to_string(who)

        faction_ref not in [nil, ""] ->
          News.faction_name(faction_ref)

        true ->
          "Someone"
      end

    "#{subject} was first to #{first_deed(first_key)}."
  end

  defp first_deed("colonize.first"), do: "found a colony"
  defp first_deed("dominion.first"), do: "take a dominion"
  defp first_deed("ship.capital.first"), do: "field a capital ship"
  defp first_deed("credit.10m.first"), do: "bank ten million credits"
  defp first_deed("doctrine.15.first"), do: "bring fifteen lexes into law"
  defp first_deed("faction.erased_25.first"), do: "field 25 Erased"
  defp first_deed("faction.navarchs_25.first"), do: "field 25 Navarchs"
  defp first_deed("faction.siderians_25.first"), do: "field 25 Siderians"

  defp first_deed("building." <> rest) do
    building = String.replace_suffix(rest, ".first", "")
    "complete a #{Map.get(@building_names, building, humanize(building))}"
  end

  defp first_deed("income." <> rest) do
    resource = rest |> String.replace_suffix("_100.first", "")
    "raise #{resource} output above 100"
  end

  defp first_deed(other), do: humanize(String.replace_suffix(other, ".first", ""))

  defp humanize(key), do: key |> String.replace(["_", "."], " ")

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # BulletinEvent payloads come back from JSONB string-keyed; tests may
  # hand-build structs with atom keys. Normalize.
  defp payload(%{payload: p}) when is_map(p) do
    Map.new(p, fn {k, v} -> {to_string(k), v} end)
  end

  defp payload(_), do: %{}
end
