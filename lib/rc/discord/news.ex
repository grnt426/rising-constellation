defmodule RC.Discord.News do
  @moduledoc """
  Rendering layer for Game.News bulletins bound for Discord. Pure
  templates + display-name/emoji maps live here; the actual posting,
  gating (channel configured + `discord_ready`), and batching windows
  live in `RC.Discord.NewsRelay`, which only runs when the bot is up.

  ## Broadcast semantics

  Two destination channels (both in the community guild), same event
  stream, different cadence:

    * **Match feed** — map ownership changes (sector control,
      colonizations, dominion flips, liberations, abandonments) batch
      into one message per 5-minute bucket (`map_digest/2`); the relay
      edits the bucket's message as events accrue. Victory-point
      movement keeps its own per-faction roll-up. Sector-control
      changes ride in the same bucket as the ownership changes that
      caused them — they always go together.
    * **#game-news** — the same events batch into one message per
      6-hour bucket (`community_digest/2`), organized as one section
      per faction (sectors gained/lost, systems settled/lost,
      dominions flipped/lost — every entry signed `+`/`−`), with a
      running total of system/dominion changes by faction and by
      sector at the bottom.

  The feed is deliberately narrow (player decision 2026-07): only
  events every player can already see on the galaxy map. Battles,
  raids, pillages, conquests, and galaxy firsts are withheld and land
  in the once-a-day summary (`RC.Discord.DailyBulletin`).

  The payloads arriving here are already stripped by
  `Game.News.Server.publish/3` (no attacker faction on covert ops, no
  winner bookkeeping), so even a template bug can't leak more than the
  public payload contains.

  Faction names render with their custom guild emoji appended, e.g.
  `Tetrarchy <:tetrarchy:1528019668617658458>` — the community
  guild's uploads. (Until the 2026-08 consolidation there was a
  second emoji set on the Legacy-games guild and every renderer took
  a `:game | :community` flavor; those ids became unusable when the
  bot left that guild, so the flavor parameter is gone.)
  """

  # Custom emoji in the community guild, one per playable faction.
  @faction_emoji %{
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
  Does this bulletin kind feed the 6-hour digest windows? Everything
  the rolling feed renders, plus conquests: a conquest is a territory
  change and belongs on the territory report, even though it stays out
  of the instant Legacy feed (the 2026-07 withholding decision covers
  the one-line rolling posts, not the batched digest).
  """
  def digest_feed_key?(key), do: map_key?(key) or vp_key?(key) or key == "news.conquest"

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
  The relay posts to the community announce channel and the match-feed
  channel (when distinct).
  """
  def post_victory_async(instance_id, info) do
    GenServer.cast(RC.Discord.NewsRelay, {:victory, instance_id, info})
    :ok
  end

  @doc """
  Victory announcement embed.

  Wording per user spec 2026-07-18 — title "Congrats to [FACTION]!",
  body "[Scenario] has concluded in a victory with [VP] VP in favor
  of [emoji][faction]." No other emoji.
  """
  def victory_embed(scenario_name, faction_key, victory_points) do
    key = to_string(faction_key)
    name = Map.get(@faction_names, key, key)
    emoji = faction_emoji(key)

    %{
      title: "Congrats to #{name}!",
      description:
        "#{scenario_name} has concluded in a victory with #{victory_points} VP " <>
          "in favor of #{emoji}#{name}.",
      color: 0x57F287,
      footer: %{text: "Marat · Friend of the People"}
    }
  end

  @doc "Player name with their faction's emoji appended."
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
  def colonized_rollup(faction_key, system_names) do
    "#{faction_display(faction_key)} has colonized #{length(system_names)} systems: #{name_list(system_names)}."
  end

  @doc "Aggregated dominion line for a bucket."
  def dominion_rollup(faction_key, system_names) do
    "#{faction_display(faction_key)} has taken #{length(system_names)} dominions: #{name_list(system_names)}."
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
  to Discord. Pure — unit-tested without the bot.

  Only publicly-visible-on-the-map events render here (sector control,
  colonization, dominion flips, victory points). Battles, raids,
  pillages, conquests, covert ops, and galaxy firsts return nil — they
  are withheld from the rolling feed and surface in the daily summary
  bulletin instead (player decision 2026-07).
  """
  def render(bulletin_key, payload)

  def render("news.dominion.liberated", p),
    do: "#{system(p)} has been freely liberated from #{faction(p)} control."

  def render("news.system.abandoned", p),
    do: "#{faction(p)} has abandoned #{system(p)}."

  def render("news.sector.flipped", p),
    do: "#{faction(p)} has taken control of sector #{sector(p)} from #{faction_display(p[:prev_faction])}."

  def render("news.sector.claimed", p),
    do: "#{faction(p)} has taken control of sector #{sector(p)}."

  def render("news.sector.lost", p),
    do: "#{faction_display(p[:prev_faction])} has lost control of sector #{sector(p)}."

  # Every colonization, not just the galaxy first — settled ownership
  # is public map knowledge in-game, so Discord may name it too.
  def render("discord.colonized", p),
    do: "#{faction(p)} has colonized #{system(p)}."

  def render("discord.dominion", p) do
    case p[:prev_faction] do
      nil -> "#{faction(p)} has taken #{system(p)} as a dominion."
      prev -> "#{faction(p)} has taken the dominion of #{system(p)} from #{faction_display(prev)}."
    end
  end

  # Victory-track movement — the in-game victory panel shows this to
  # everyone, so the bot may announce it the moment a star changes.
  # The delta is spelled out: "risen to 12" alone reads as a standings
  # statement, not a movement.
  def render("discord.vp_changed", p) do
    delta = (p[:vp] || 0) - (p[:prev_vp] || 0)
    verb = if delta >= 0, do: "risen", else: "fallen"
    "#{faction(p)} has #{verb} to #{p[:vp]} victory points (#{signed_vp(delta)})."
  end

  # Everything else stays off the rolling feed: battles, raids,
  # pillages, conquests, and firsts belong to the daily bulletin;
  # covert-ops stories stay in-game only.
  def render(_key, _payload), do: nil

  ## Batched digests -----------------------------------------------------

  # Discord caps messages at 2000 chars; cut at a line boundary so a
  # slice can't bisect a custom-emoji token and post visible garbage.
  @max_message_chars 1900

  @doc """
  The match-feed 5-minute bucket message: every map-ownership change
  (and the sector flips they caused) since the bucket opened, as one
  message. `events` is the bucket's `{bulletin_key, payload}` list in
  arrival order. A single event keeps the classic one-line format; a
  bucket with more renders one bulleted line per story, with
  same-faction colonizations/dominions aggregated.
  """
  def map_digest(instance_name, events) do
    case digest_lines(events) do
      [line] -> "📰 **#{instance_name}**: #{line}"
      lines -> truncate_at_line("📰 **#{instance_name}**:\n" <> Enum.map_join(lines, "\n", &"• #{&1}"))
    end
  end

  @doc """
  The 6-hour bucket message for #game-news, organized per faction:
  each faction that moved gets a section listing its sectors
  gained/lost, systems settled/lost, and dominions flipped/lost,
  every entry signed `+`/`−`. Below the sections: the victory track —
  this window's net VP movement per mover, plus the full current
  standings for every faction — and a running total of
  system/dominion changes by faction and by sector.
  """
  def community_digest(instance_name, events) do
    {vp_events, map_events} = Enum.split_with(events, fn {key, _p} -> key == @vp_key end)

    sections =
      map_events
      |> faction_ledger()
      |> Enum.map(fn {faction, categories} -> faction_section(faction, categories) end)

    vp_parts =
      case vp_section(vp_events) do
        nil -> []
        part -> [part]
      end

    parts =
      ["📰 **#{instance_name}** — rolling 6-hour digest"] ++
        sections ++ vp_parts ++ totals_section(map_events)

    truncate_at_line(Enum.join(parts, "\n\n"))
  end

  @doc """
  The match-feed 5-minute VP roll-up message for one faction's bucket:
  the headline carries the net movement across the bucket as an
  explicit signed delta, followed by the full victory track when the
  payload carries the standings snapshot (older events without one
  degrade to the headline alone).
  """
  def vp_rollup(instance_name, events) do
    {_first_key, first} = List.first(events)
    {_latest_key, latest} = List.last(events)

    net = (latest[:vp] || 0) - (first[:prev_vp] || 0)

    verb =
      cond do
        net > 0 -> "risen"
        net < 0 -> "fallen"
        true -> "returned"
      end

    headline = "#{faction(latest)} has #{verb} to #{latest[:vp]} victory points (#{signed_vp(net)})."

    case standings_body(vp_standings(events)) do
      nil -> "📰 **#{instance_name}**: #{headline}"
      body -> "📰 **#{instance_name}**: #{headline} Victory track: #{body}."
    end
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

  defp faction_section(faction, categories) do
    lines =
      for {label, key} <- [{"Sectors", :sectors}, {"Systems", :systems}, {"Dominions", :dominions}],
          entries = categories[key],
          entries != [] do
        "• #{label}: #{entry_list(entries)}"
      end

    Enum.join([faction_header(faction) | lines], "\n")
  end

  defp faction_header(faction) when is_binary(faction) do
    case faction_emoji(faction) do
      "" -> "**#{faction_name(faction)}**"
      emoji -> "**#{faction_name(faction)}** #{emoji}"
    end
  end

  defp faction_header(_faction), do: "**An unknown power**"

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
  defp digest_lines(events) do
    sector_lines =
      for {key, p} <- events, key in @sector_keys, do: render(key, p)

    colonized_lines = grouped_lines(events, "discord.colonized", &colonized_rollup/2)
    dominion_lines = grouped_lines(events, "discord.dominion", &dominion_rollup/2)

    other_lines =
      for {key, p} <- events,
          key in ["news.dominion.liberated", "news.system.abandoned"],
          do: render(key, p)

    sector_lines ++ colonized_lines ++ dominion_lines ++ other_lines
  end

  defp grouped_lines(events, wanted_key, rollup_fun) do
    events
    |> Enum.filter(fn {key, _p} -> key == wanted_key end)
    |> Enum.map(fn {_key, p} -> p end)
    |> group_by_faction()
    |> Enum.map(fn
      {_faction, [payload]} ->
        render(wanted_key, payload)

      {faction, payloads} ->
        rollup_fun.(faction, Enum.map(payloads, &(&1[:system_name] || "an uncharted system")))
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

  # Victory-track part of the community digest: one line of net deltas
  # for the factions that moved this window (explicitly signed — a bare
  # total reads as a standings statement), one line of full standings
  # for ALL factions from the newest snapshot the bucket carries.
  defp vp_section([]), do: nil

  defp vp_section(vp_events) do
    changes =
      vp_events
      |> vp_net_deltas()
      |> Enum.sort_by(fn {_faction, delta, _vp} -> -delta end)
      |> Enum.map_join(" · ", fn {faction, delta, _vp} ->
        "#{faction_display(faction)} #{signed_vp(delta)} VP"
      end)

    standings =
      case standings_body(vp_standings(vp_events)) do
        nil ->
          # Pre-snapshot payloads: fall back to the movers' latest
          # values — a partial track beats none.
          fallback =
            vp_events
            |> vp_net_deltas()
            |> Enum.map(fn {faction, _delta, vp} -> {faction, vp} end)

          standings_body(fallback)

        body ->
          body
      end

    "**Victory track** — changes this window: #{changes}\nStandings: #{standings}"
  end

  # Net movement per faction across the bucket: from the first event's
  # prev_vp to the last event's vp, in first-mover order. Returns
  # `{faction, net_delta, latest_vp}` tuples.
  defp vp_net_deltas(vp_events) do
    vp_events
    |> Enum.reduce([], fn {_key, p}, acc ->
      faction = p[:faction]

      case List.keyfind(acc, faction, 0) do
        nil ->
          acc ++ [{faction, p[:prev_vp] || 0, p[:vp] || 0}]

        {^faction, first_prev, _latest} ->
          List.keyreplace(acc, faction, 0, {faction, first_prev, p[:vp] || 0})
      end
    end)
    |> Enum.map(fn {faction, first_prev, latest} -> {faction, latest - first_prev, latest} end)
  end

  # The newest full-scoreboard snapshot in the bucket, as
  # `{faction, vp}` tuples — or nil when no event carries one.
  defp vp_standings(vp_events) do
    vp_events
    |> Enum.reverse()
    |> Enum.find_value(fn {_key, p} ->
      case p[:standings] do
        [_ | _] = standings -> Enum.map(standings, fn entry -> {entry[:faction], entry[:vp] || 0} end)
        _ -> nil
      end
    end)
  end

  defp standings_body(nil), do: nil

  defp standings_body(entries) do
    entries
    |> Enum.sort_by(fn {_faction, vp} -> -vp end)
    |> Enum.map_join(" · ", fn {faction, vp} -> "#{faction_display(faction)} #{vp} VP" end)
  end

  defp signed_vp(delta) when delta > 0, do: "+#{delta}"
  defp signed_vp(delta) when delta < 0, do: "−#{-delta}"
  defp signed_vp(_delta), do: "±0"

  # Running total of system/dominion ownership changes (sector-control
  # events excluded — they're consequences, not systems). Per-faction
  # counts are signed: `+gained/−lost`.
  defp totals_section(map_events) do
    ownership = for {key, p} <- map_events, key in @ownership_keys, do: {key, p}

    if ownership == [] do
      []
    else
      by_faction =
        ownership
        |> faction_deltas()
        |> Enum.sort_by(fn {_faction, gained, lost} -> -(gained + lost) end)
        |> Enum.map_join(" · ", fn {faction, gained, lost} ->
          "#{faction_label(faction)} #{delta_label(gained, lost)}"
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

  defp faction_label(faction) when is_binary(faction),
    do: "#{faction_emoji(faction)}#{faction_name(faction)}"

  defp faction_label(_faction), do: "Unaligned"

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

  @doc "Faction display name with the emoji appended."
  def faction_display(key) when is_binary(key) do
    name = Map.get(@faction_names, key, key)

    case faction_emoji(key) do
      "" -> name
      emoji -> "#{name} #{emoji}"
    end
  end

  def faction_display(_), do: "An unknown power"

  @doc "Bare display name (no emoji) for a faction key."
  def faction_name(key) when is_binary(key), do: Map.get(@faction_names, key, key)
  def faction_name(key), do: faction_name(to_string(key))

  @doc "Emoji string for a faction key, or empty string."
  def faction_emoji(key) when is_binary(key), do: Map.get(@faction_emoji, key, "")
  def faction_emoji(key), do: faction_emoji(to_string(key))

  defp faction(p), do: faction_display(p[:faction])
  defp system(p), do: p[:system_name] || "an uncharted system"
  defp sector(p), do: p[:sector_name] || "an uncharted region"
end
