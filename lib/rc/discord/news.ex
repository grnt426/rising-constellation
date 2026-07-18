defmodule RC.Discord.News do
  @moduledoc """
  Rendering layer for Game.News bulletins bound for the community
  #news channel. Pure templates + display-name/emoji maps live here;
  the actual posting, gating (channel configured + `discord_ready`),
  and Discord-side dedup policy live in `RC.Discord.NewsRelay`, which
  only runs when the bot is up.

  ## Broadcast semantics

  \\#news is a **general-broadcast** channel — every player from every
  faction can read it. The immediate feed is deliberately narrow
  (player decision 2026-07): only events every player can already see
  on the galaxy map — sector control changes, colonizations, dominion
  flips, and victory-point movements — post the moment they happen.
  Battles, raids, pillages, conquests, and galaxy firsts are withheld
  and land in the once-a-day summary (`RC.Discord.DailyBulletin`).

  The payloads arriving here are already stripped by
  `Game.News.Server.publish/3` (no attacker faction on covert ops, no
  winner bookkeeping), so even a template bug can't leak more than the
  public payload contains.

  Faction names render with their custom guild emoji appended, e.g.
  `Tetrarchy <:tetrarchy:1521144218742034463>`. The community server
  and the Legacy game server are separate Discords with separate
  emoji uploads, hence two maps.
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
  # uploads — used for the victory announcement there).
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
    emoji_map = if guild == :community, do: @community_faction_emoji, else: @faction_emoji
    emoji = Map.get(emoji_map, key, "")

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
  # in quick succession, the relay EDITS its previous message into one
  # aggregated line instead of posting again (anti-flood — same policy
  # the old battle roll-up enforced).

  @rollup_max_names 8

  @doc "Aggregated colonization line for a roll-up window."
  def colonized_rollup(faction_key, system_names) do
    "#{faction_display(faction_key)} has colonized #{length(system_names)} systems: #{name_list(system_names)}."
  end

  @doc "Aggregated dominion line for a roll-up window."
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
  Render the immediate-feed headline for a bulletin, or nil for kinds
  that don't post to Discord instantly. Pure — unit-tested without
  the bot.

  Only publicly-visible-on-the-map events render here (sector control,
  colonization, dominion flips, victory points). Battles, raids,
  pillages, conquests, covert ops, and galaxy firsts return nil — they
  are withheld from the instant feed and surface in the daily summary
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
  def render("discord.vp_changed", p) do
    verb = if (p[:vp] || 0) >= (p[:prev_vp] || 0), do: "risen", else: "fallen"
    "#{faction(p)} has #{verb} to #{p[:vp]} victory points."
  end

  # Everything else stays off the instant feed: battles, raids,
  # pillages, conquests, and firsts belong to the daily bulletin;
  # covert-ops stories stay in-game only.
  def render(_key, _payload), do: nil

  ## Param helpers — nil-tolerant so a malformed payload degrades the
  ## sentence, never crashes the relay.

  @doc "Faction display name with its game-guild emoji appended."
  def faction_display(key) when is_binary(key) do
    name = Map.get(@faction_names, key, key)

    case Map.get(@faction_emoji, key) do
      nil -> name
      emoji -> "#{name} #{emoji}"
    end
  end

  def faction_display(_), do: "An unknown power"

  @doc "Bare display name (no emoji) for a faction key."
  def faction_name(key) when is_binary(key), do: Map.get(@faction_names, key, key)
  def faction_name(key), do: faction_name(to_string(key))

  @doc "Game-guild emoji string for a faction key, or empty string."
  def faction_emoji(key) when is_binary(key), do: Map.get(@faction_emoji, key, "")
  def faction_emoji(key), do: faction_emoji(to_string(key))

  defp faction(p), do: faction_display(p[:faction])
  defp system(p), do: p[:system_name] || "an uncharted system"
  defp sector(p), do: p[:sector_name] || "an uncharted region"
end
