defmodule RC.Discord.News do
  @moduledoc """
  Rendering layer for Game.News bulletins bound for Discord. Pure
  templates + display-name/emoji maps live here; the actual posting,
  gating (channel configured + `discord_ready`), and batching windows
  live in `RC.Discord.NewsRelay`, which only runs when the bot is up.

  ## Broadcast semantics

  Two destinations, same event stream, different cadence:

    * **Legacy #news** (game guild) — map ownership changes (sector
      control, colonizations, dominion flips, liberations,
      abandonments) batch into one message per 5-minute bucket
      (`map_digest/3`); the relay edits the bucket's message as
      events accrue. Victory-point movement keeps its own per-faction
      roll-up. Sector-control changes ride in the same bucket as the
      ownership changes that caused them — they always go together.
    * **Community #game-news** (community guild) — the same events
      batch into one message per 6-hour bucket (`community_digest/2`),
      organized as one section per faction (sectors gained/lost,
      systems settled/lost, dominions flipped/lost — every entry
      signed `+`/`−`), with a running total of system/dominion
      changes by faction and by sector at the bottom.

  The feed is deliberately narrow (player decision 2026-07): only
  events every player can already see on the galaxy map. Battles,
  raids, pillages, conquests, and galaxy firsts are withheld and land
  in the once-a-day summary (`RC.Discord.DailyBulletin`).

  The payloads arriving here are already stripped by
  `Game.News.Server.publish/3` (no attacker faction on covert ops, no
  winner bookkeeping), so even a template bug can't leak more than the
  public payload contains.

  Faction names render with their custom guild emoji appended, e.g.
  `Tetrarchy <:tetrarchy:1521144218742034463>`. The community server
  and the Legacy game server are separate Discords with separate
  emoji uploads, hence two maps — every renderer takes a `guild`
  (`:game` | `:community`) to pick the right set.
  """

  # Custom emoji in the Legacy game guild, one per playable faction.
  @faction_emoji %{
    "ark" => "<:ark:1521144064374739145>",
    "cardan" => "<:cardan:1521144119605329961>",
    "myrmezir" => "<:myrmezir:1521144307728519208>",
    "synelle" => "<:synelle:1521144259015868577>",
    "tetrarchy" => "<:tetrarchy:1521144218742034463>"
  }

  # Custom emoji in the community guild (separate Discord, separate
  # uploads).
  @community_faction_emoji %{
    "ark" => "<:ark:1528019447812456519>",
    "cardan" => "<:cardan:1528019517744091136>",
    "myrmezir" => "<:myrmezir:1528019561117516013>",
    "synelle" => "<:synelle:1528019609725435934>",
    "tetrarchy" => "<:tetrarchy:1528019668617658458>"
  }

  # Display names live in the frontend locale files; the backend Data
  # structs don't carry them, so the relay keeps its own copy.
  @faction_names %{
    "ark" => "A.R.K.",
    "cardan" => "Cardan",
    "myrmezir" => "Myrmezir",
    "synelle" => "Synelectic Federation",
    "tetrarchy" => "Tetrarchy"
  }

  # Map ownership changes — batched together per bucket. Sector-control
  # keys ride in the same bucket (a sector never flips without a
  # system/dominion changing hands), but are excluded from the
  # system/dominion running totals.
  @ownership_keys ["discord.colonized", "discord.dominion", "news.dominion.liberated", "news.system.abandoned"]
  @sector_keys ["news.sector.flipped", "news.sector.claimed", "news.sector.lost"]
  @map_keys @ownership_keys ++ @sector_keys
  @vp_key "discord.vp_changed"

  @doc "Is this bulletin kind part of the batched map-ownership digest?"
  def map_key?(key), do: key in @map_keys

  @doc "Is this bulletin kind the victory-point movement kind?"
  def vp_key?(key), do: key == @vp_key

  @doc """
  Fire-and-forget relay. Casts to `RC.Discord.NewsRelay`, which owns
  the gating (channel configured + `discord_ready`) and the actual API
  calls. Casting to the unregistered name (bot disabled, :test) is a
  silent no-op — GenServer.cast never fails.
  """
  def post_async(instance_id, bulletin_key, payload) do
    GenServer.cast(RC.Discord.NewsRelay, {:bulletin, instance_id, bulletin_key, payload})
    :ok
  end

  @doc """
  Fire-and-forget victory announcement. `info` carries `:winner`
  (faction key atom or string), `:victory_points`, `:victory_type`.
  The relay posts to BOTH the community announce channel (community
  emoji) and the Legacy #news channel (game-guild emoji).
  """
  def post_victory_async(instance_id, info) do
    GenServer.cast(RC.Discord.NewsRelay, {:victory, instance_id, info})
    :ok
  end

  @doc """
  Victory announcement embed. `guild` picks the emoji upload set:
  `:community` or `:game` (separate Discords, separate emoji ids).

  Wording per user spec 2026-07-18 — title "Congrats to [FACTION]!",
  body "[Scenario] has concluded in a victory with [VP] VP in favor
  of [emoji][faction]." No other emoji.
  """
  def victory_embed(scenario_name, faction_key, victory_points, guild)
      when guild in [:community, :game] do
    key = to_string(faction_key)
    name = Map.get(@faction_names, key, key)
    emoji = faction_emoji(key, guild)

    %{
      title: "Congrats to #{name}!",
      description:
        "#{scenario_name} has concluded in a victory with #{victory_points} VP " <>
          "in favor of #{emoji}#{name}.",
      color: 0x57F287,
      footer: %{text: "Marat · Friend of the People"}
    }
  end

  @doc "Player name with their faction's game-guild emoji appended."
  def player_display(name, faction_key) do
    case Map.get(@faction_emoji, faction_key) do
      nil -> to_string(name)
      emoji -> "#{name} #{emoji}"
    end
  end

  # Roll-up lines: when one faction colonizes / flips several systems
  # inside a bucket, the digest renders one aggregated line instead of
  # one line per system (anti-flood — same policy the old battle
  # roll-up enforced).

  @rollup_max_names 8

  @doc "Aggregated colonization line for a bucket."
  def colonized_rollup(faction_key, system_names, guild \\ :game) do
    "#{faction_display(faction_key, guild)} has colonized #{length(system_names)} systems: #{name_list(system_names)}."
  end

  @doc "Aggregated dominion line for a bucket."
  def dominion_rollup(faction_key, system_names, guild \\ :game) do
    "#{faction_display(faction_key, guild)} has taken #{length(system_names)} dominions: #{name_list(system_names)}."
  end

  defp name_list(names) do
    {shown, dropped} = Enum.split(Enum.uniq(names), @rollup_max_names)

    case dropped do
      [] -> Enum.join(shown, ", ")
      more -> Enum.join(shown, ", ") <> " and #{length(more)} more"
    end
  end

  @doc """
  Render the headline for a bulletin, or nil for kinds that don't post
  to Discord. Pure — unit-tested without the bot. `guild` picks the
  emoji set (`:game` default).

  Only publicly-visible-on-the-map events render here (sector control,
  colonization, dominion flips, victory points). Battles, raids,
  pillages, conquests, covert ops, and galaxy firsts return nil — they
  are withheld from the rolling feed and surface in the daily summary
  bulletin instead (player decision 2026-07).
  """
  def render(bulletin_key, payload, guild \\ :game)

  def render("news.dominion.liberated", p, guild),
    do: "#{system(p)} has been freely liberated from #{faction(p, guild)} control."

  def render("news.system.abandoned", p, guild),
    do: "#{faction(p, guild)} has abandoned #{system(p)}."

  def render("news.sector.flipped", p, guild),
    do: "#{faction(p, guild)} has taken control of sector #{sector(p)} from #{faction_display(p[:prev_faction], guild)}."

  def render("news.sector.claimed", p, guild),
    do: "#{faction(p, guild)} has taken control of sector #{sector(p)}."

  def render("news.sector.lost", p, guild),
    do: "#{faction_display(p[:prev_faction], guild)} has lost control of sector #{sector(p)}."

  # Every colonization, not just the galaxy first — settled ownership
  # is public map knowledge in-game, so Discord may name it too.
  def render("discord.colonized", p, guild),
    do: "#{faction(p, guild)} has colonized #{system(p)}."

  def render("discord.dominion", p, guild) do
    case p[:prev_faction] do
      nil -> "#{faction(p, guild)} has taken #{system(p)} as a dominion."
      prev -> "#{faction(p, guild)} has taken the dominion of #{system(p)} from #{faction_display(prev, guild)}."
    end
  end

  # Victory-track movement — the in-game victory panel shows this to
  # everyone, so the bot may announce it the moment a star changes.
  def render("discord.vp_changed", p, guild) do
    verb = if (p[:vp] || 0) >= (p[:prev_vp] || 0), do: "risen", else: "fallen"
    "#{faction(p, guild)} has #{verb} to #{p[:vp]} victory points."
  end

  # Everything else stays off the rolling feed: battles, raids,
  # pillages, conquests, and firsts belong to the daily bulletin;
  # covert-ops stories stay in-game only.
  def render(_key, _payload, _guild), do: nil

  ## Batched digests -----------------------------------------------------

  # Discord caps messages at 2000 chars; cut at a line boundary so a
  # slice can't bisect a custom-emoji token and post visible garbage.
  @max_message_chars 1900

  @doc """
  The Legacy 5-minute bucket message: every map-ownership change (and
  the sector flips they caused) since the bucket opened, as one
  message. `events` is the bucket's `{bulletin_key, payload}` list in
  arrival order. A single event keeps the classic one-line format; a
  bucket with more renders one bulleted line per story, with
  same-faction colonizations/dominions aggregated.
  """
  def map_digest(instance_name, events, guild \\ :game) do
    case digest_lines(events, guild) do
      [line] -> "📰 **#{instance_name}**: #{line}"
      lines -> truncate_at_line("📰 **#{instance_name}**:\n" <> Enum.map_join(lines, "\n", &"• #{&1}"))
    end
  end

  @doc """
  The community 6-hour bucket message, organized per faction: each
  faction that moved gets a section listing its sectors gained/lost,
  systems settled/lost, and dominions flipped/lost, every entry
  signed `+`/`−` (community-guild emoji). Below the sections: a
  victory-track line with each faction's latest VP, and a running
  total of system/dominion changes by faction and by sector.
  """
  def community_digest(instance_name, events) do
    {vp_events, map_events} = Enum.split_with(events, fn {key, _p} -> key == @vp_key end)

    sections =
      map_events
      |> faction_ledger()
      |> Enum.map(fn {faction, categories} -> faction_section(faction, categories, :community) end)

    vp_lines =
      case vp_line(vp_events, :community) do
        nil -> []
        line -> [line]
      end

    parts =
      ["📰 **#{instance_name}** — rolling 6-hour digest"] ++
        sections ++ vp_lines ++ totals_section(map_events, :community)

    truncate_at_line(Enum.join(parts, "\n\n"))
  end

  ## Per-faction ledger (community digest) -------------------------------

  # Fold the bucket's events into an ordered `{faction, categories}`
  # assoc list (first faction to move renders first). Each category
  # holds signed `{:+ | :-, name}` entries in arrival order.
  defp faction_ledger(events) do
    Enum.reduce(events, [], fn {key, payload}, acc ->
      Enum.reduce(ledger_entries(key, payload), acc, &ledger_add(&2, &1))
    end)
  end

  # Who gained/lost what, per event kind. A dominion taken from a
  # previous holder ledgers on both sides; a sector flip likewise.
  defp ledger_entries("discord.colonized", p),
    do: [{p[:faction], :systems, :+, system(p)}]

  defp ledger_entries("discord.dominion", p) do
    gain = {p[:faction], :dominions, :+, system(p)}

    case p[:prev_faction] do
      nil -> [gain]
      prev -> [gain, {prev, :dominions, :-, system(p)}]
    end
  end

  defp ledger_entries("news.dominion.liberated", p),
    do: [{p[:faction], :dominions, :-, system(p)}]

  defp ledger_entries("news.system.abandoned", p),
    do: [{p[:faction], :systems, :-, system(p)}]

  defp ledger_entries("news.sector.claimed", p),
    do: [{p[:faction], :sectors, :+, sector(p)}]

  defp ledger_entries("news.sector.lost", p),
    do: [{p[:prev_faction], :sectors, :-, sector(p)}]

  defp ledger_entries("news.sector.flipped", p),
    do: [{p[:faction], :sectors, :+, sector(p)}, {p[:prev_faction], :sectors, :-, sector(p)}]

  defp ledger_entries(_key, _payload), do: []

  defp ledger_add(acc, {faction, category, sign, name}) do
    categories =
      case List.keyfind(acc, faction, 0) do
        nil -> %{sectors: [], systems: [], dominions: []}
        {^faction, categories} -> categories
      end

    categories = Map.update!(categories, category, &(&1 ++ [{sign, name}]))
    List.keystore(acc, faction, 0, {faction, categories})
  end

  defp faction_section(faction, categories, guild) do
    lines =
      for {label, key} <- [{"Sectors", :sectors}, {"Systems", :systems}, {"Dominions", :dominions}],
          entries = categories[key],
          entries != [] do
        "• #{label}: #{entry_list(entries)}"
      end

    Enum.join([faction_header(faction, guild) | lines], "\n")
  end

  defp faction_header(faction, guild) when is_binary(faction) do
    case faction_emoji(faction, guild) do
      "" -> "**#{faction_name(faction)}**"
      emoji -> "**#{faction_name(faction)}** #{emoji}"
    end
  end

  defp faction_header(_faction, _guild), do: "**An unknown power**"

  # Signed name list for one category: gains first, then losses, each
  # kept in arrival order; deduplicated; capped like the roll-ups.
  defp entry_list(entries) do
    {gains, losses} = entries |> Enum.uniq() |> Enum.split_with(fn {sign, _name} -> sign == :+ end)
    {shown, dropped} = Enum.split(gains ++ losses, @rollup_max_names)

    base = Enum.map_join(shown, ", ", fn {sign, name} -> "#{sign_glyph(sign)}#{name}" end)

    case dropped do
      [] -> base
      more -> base <> " and #{length(more)} more"
    end
  end

  defp sign_glyph(:+), do: "+"
  defp sign_glyph(:-), do: "−"

  # One line per story: sector-control changes first (rare and
  # momentous), then colonizations and dominion flips aggregated per
  # faction, then liberations/abandonments.
  defp digest_lines(events, guild) do
    sector_lines =
      for {key, p} <- events, key in @sector_keys, do: render(key, p, guild)

    colonized_lines = grouped_lines(events, "discord.colonized", guild, &colonized_rollup/3)
    dominion_lines = grouped_lines(events, "discord.dominion", guild, &dominion_rollup/3)

    other_lines =
      for {key, p} <- events,
          key in ["news.dominion.liberated", "news.system.abandoned"],
          do: render(key, p, guild)

    sector_lines ++ colonized_lines ++ dominion_lines ++ other_lines
  end

  defp grouped_lines(events, wanted_key, guild, rollup_fun) do
    events
    |> Enum.filter(fn {key, _p} -> key == wanted_key end)
    |> Enum.map(fn {_key, p} -> p end)
    |> group_by_faction()
    |> Enum.map(fn
      {_faction, [payload]} ->
        render(wanted_key, payload, guild)

      {faction, payloads} ->
        rollup_fun.(faction, Enum.map(payloads, &(&1[:system_name] || "an uncharted system")), guild)
    end)
  end

  # Group payloads by faction, preserving first-arrival order (Map
  # grouping would alphabetize the factions).
  defp group_by_faction(payloads) do
    Enum.reduce(payloads, [], fn p, acc ->
      faction = p[:faction]

      case List.keyfind(acc, faction, 0) do
        nil -> acc ++ [{faction, [p]}]
        {^faction, list} -> List.keyreplace(acc, faction, 0, {faction, list ++ [p]})
      end
    end)
  end

  # Latest VP per faction, highest first.
  defp vp_line([], _guild), do: nil

  defp vp_line(vp_events, guild) do
    latest =
      Enum.reduce(vp_events, [], fn {_key, p}, acc ->
        List.keystore(acc, p[:faction], 0, {p[:faction], p[:vp] || 0})
      end)

    body =
      latest
      |> Enum.sort_by(fn {_faction, vp} -> -vp end)
      |> Enum.map_join(" · ", fn {faction, vp} -> "#{faction_display(faction, guild)} at #{vp} VP" end)

    "Victory track: #{body}."
  end

  # Running total of system/dominion ownership changes (sector-control
  # events excluded — they're consequences, not systems). Per-faction
  # counts are signed: `+gained/−lost`.
  defp totals_section(map_events, guild) do
    ownership = for {key, p} <- map_events, key in @ownership_keys, do: {key, p}

    if ownership == [] do
      []
    else
      by_faction =
        ownership
        |> faction_deltas()
        |> Enum.sort_by(fn {_faction, gained, lost} -> -(gained + lost) end)
        |> Enum.map_join(" · ", fn {faction, gained, lost} ->
          "#{faction_label(faction, guild)} #{delta_label(gained, lost)}"
        end)

      by_sector =
        ownership
        |> Enum.reduce([], fn {_key, p}, acc ->
          sector = p[:sector_name] || "uncharted space"

          case List.keyfind(acc, sector, 0) do
            nil -> acc ++ [{sector, 1}]
            {^sector, n} -> List.keyreplace(acc, sector, 0, {sector, n + 1})
          end
        end)
        |> Enum.sort_by(fn {_sector, n} -> -n end)
        |> Enum.map_join(" · ", fn {sector, n} -> "#{sector} #{n}" end)

      [
        Enum.join(
          [
            "**System & dominion changes** (running total)",
            "By faction: #{by_faction}",
            "By sector: #{by_sector}"
          ],
          "\n"
        )
      ]
    end
  end

  # Ordered `{faction, gained, lost}` counts across ownership events.
  defp faction_deltas(ownership) do
    Enum.reduce(ownership, [], fn {key, p}, acc ->
      Enum.reduce(delta_entries(key, p), acc, fn {faction, sign}, acc ->
        {gained, lost} =
          case List.keyfind(acc, faction, 0) do
            nil -> {0, 0}
            {^faction, g, l} -> {g, l}
          end

        entry =
          case sign do
            :+ -> {faction, gained + 1, lost}
            :- -> {faction, gained, lost + 1}
          end

        List.keystore(acc, faction, 0, entry)
      end)
    end)
  end

  defp delta_entries("discord.colonized", p), do: [{p[:faction], :+}]

  defp delta_entries("discord.dominion", p) do
    case p[:prev_faction] do
      nil -> [{p[:faction], :+}]
      prev -> [{p[:faction], :+}, {prev, :-}]
    end
  end

  defp delta_entries("news.dominion.liberated", p), do: [{p[:faction], :-}]
  defp delta_entries("news.system.abandoned", p), do: [{p[:faction], :-}]
  defp delta_entries(_key, _payload), do: []

  defp faction_label(faction, guild) when is_binary(faction),
    do: "#{faction_emoji(faction, guild)}#{faction_name(faction)}"

  defp faction_label(_faction, _guild), do: "Unaligned"

  defp delta_label(gained, 0), do: "+#{gained}"
  defp delta_label(0, lost), do: "−#{lost}"
  defp delta_label(gained, lost), do: "+#{gained}/−#{lost}"

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

  ## Param helpers — nil-tolerant so a malformed payload degrades the
  ## sentence, never crashes the relay.

  @doc "Faction display name with the guild's emoji appended."
  def faction_display(key, guild \\ :game)

  def faction_display(key, guild) when is_binary(key) do
    name = Map.get(@faction_names, key, key)

    case faction_emoji(key, guild) do
      "" -> name
      emoji -> "#{name} #{emoji}"
    end
  end

  def faction_display(_, _guild), do: "An unknown power"

  @doc "Bare display name (no emoji) for a faction key."
  def faction_name(key) when is_binary(key), do: Map.get(@faction_names, key, key)
  def faction_name(key), do: faction_name(to_string(key))

  @doc "Emoji string for a faction key in the given guild, or empty string."
  def faction_emoji(key, guild \\ :game)

  def faction_emoji(key, :community) when is_binary(key), do: Map.get(@community_faction_emoji, key, "")
  def faction_emoji(key, :game) when is_binary(key), do: Map.get(@faction_emoji, key, "")
  def faction_emoji(key, guild), do: faction_emoji(to_string(key), guild)

  defp faction(p, guild), do: faction_display(p[:faction], guild)
  defp system(p), do: p[:system_name] || "an uncharted system"
  defp sector(p), do: p[:sector_name] || "an uncharted region"
end
