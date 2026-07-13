defmodule RC.Discord.News do
  @moduledoc """
  Rendering layer for Game.News bulletins bound for the community
  #news channel. Pure templates + display-name/emoji maps live here;
  the actual posting, gating (channel configured + `discord_ready`),
  and Discord-side dedup policy live in `RC.Discord.NewsRelay`, which
  only runs when the bot is up.

  ## Broadcast semantics

  \\#news is a **general-broadcast** channel — every player from every
  faction can read it. Messages therefore render ONLY the public tier
  of each story, mirroring the `news.*.public` templates in
  `front/src/locales/en/portal.json` (keep the two in sync when
  wording changes). The payloads arriving here are already stripped by
  `Game.News.Server.publish/3` (no attacker faction on covert ops, no
  winner bookkeeping), so even a template bug can't leak more than the
  public payload contains.

  Faction names render with their custom guild emoji appended, e.g.
  `Tetrarchy <:tetrarchy:1521144218742034463>`.
  """

  # Custom emoji in the community guild, one per playable faction.
  @faction_emoji %{
    "ark" => "<:ark:1521144064374739145>",
    "cardan" => "<:cardan:1521144119605329961>",
    "myrmezir" => "<:myrmezir:1521144307728519208>",
    "synelle" => "<:synelle:1521144259015868577>",
    "tetrarchy" => "<:tetrarchy:1521144218742034463>"
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

  @building_names %{
    "high_factory_dome" => "Metamaterials Factory",
    "monument_dome" => "Monolith"
  }

  @ship_names %{
    "capital_1" => "Destroyer",
    "capital_2" => "Cruiser",
    "capital_3" => "Coordinator"
  }

  @doc """
  Fire-and-forget relay. Casts to `RC.Discord.NewsRelay`, which owns
  Discord's dedup policy (battle roll-up by message edit) and the
  actual API calls. Casting to the unregistered name (bot disabled,
  :test) is a silent no-op — GenServer.cast never fails.
  """
  def post_async(instance_id, bulletin_key, payload) do
    GenServer.cast(RC.Discord.NewsRelay, {:bulletin, instance_id, bulletin_key, payload})
    :ok
  end

  @doc """
  Aggregated battle line for the roll-up message.

  `counts` maps sector name → engagement count; `records` maps
  `{player_name, faction_key}` → `{wins, losses}` accumulated inside
  the current roll-up window (never all-time).

  A lone battle reads as a story naming victor and vanquished; from
  the second battle on, the line becomes a per-sector tally plus each
  involved player's window record.
  """
  def battle_rollup(counts, records \\ %{})

  def battle_rollup(counts, records) when map_size(counts) == 1 do
    case {Map.to_list(counts), split_single_battle(records)} do
      {[{sector, 1}], {[_ | _] = winners, [_ | _] = losers}} ->
        "A skirmish took place in sector #{sector} — " <>
          "#{player_list(winners)} defeated #{player_list(losers)}."

      {[{sector, 1}], _} ->
        "A small skirmish took place in sector #{sector}."

      {[{sector, n}], _} ->
        "Fleet engagements reported in sector #{sector} ×#{n}#{records_suffix(records)}"
    end
  end

  def battle_rollup(counts, records) do
    tally =
      counts
      |> Enum.sort_by(fn {sector, n} -> {-n, sector} end)
      |> Enum.map_join(", ", fn {sector, n} -> "sector #{sector} ×#{n}" end)

    "Fleet engagements reported: #{tally}#{records_suffix(records)}"
  end

  # A single battle's records split cleanly into pure winners (1-0)
  # and pure losers (0-1). Anything else (draw, missing data) falls
  # back to the anonymous line.
  defp split_single_battle(records) do
    {Enum.filter(records, fn {_, {w, l}} -> w > 0 and l == 0 end) |> Enum.map(&elem(&1, 0)),
     Enum.filter(records, fn {_, {w, l}} -> l > 0 and w == 0 end) |> Enum.map(&elem(&1, 0))}
  end

  defp player_list(players),
    do: Enum.map_join(players, ", ", fn {name, faction} -> player_display(name, faction) end)

  defp records_suffix(records) when map_size(records) == 0, do: "."

  defp records_suffix(records) do
    line =
      records
      |> Enum.sort_by(fn {{name, _f}, {w, l}} -> {-w, l, name} end)
      |> Enum.map_join(" · ", fn {{name, faction}, {w, l}} ->
        "#{player_display(name, faction)} #{record_label(w, l)}"
      end)

    " — #{line}."
  end

  defp record_label(w, 0), do: "#{w}W"
  defp record_label(0, l), do: "#{l}L"
  defp record_label(w, l), do: "#{w}W #{l}L"

  @doc "Player name with their faction's guild emoji appended."
  def player_display(name, faction_key) do
    case Map.get(@faction_emoji, faction_key) do
      nil -> to_string(name)
      emoji -> "#{name} #{emoji}"
    end
  end

  @doc """
  Render the public-tier headline for a bulletin, or nil for kinds
  that don't post to Discord. Pure — unit-tested without the bot.

  Wording mirrors the `news.*.public` templates in
  front/src/locales/en/portal.json.
  """
  def render(bulletin_key, payload)

  def render("news.colonize.first", p),
    do: "#{faction(p)} has founded the galaxy's first new colony, on #{system(p)}."

  def render("news.dominion.first", p),
    do: "#{faction(p)} has taken the galaxy's first dominion. #{system(p)} now answers to foreign rule."

  def render("news.dominion.liberated", p),
    do: "#{system(p)} has been freely liberated from #{faction(p)} control."

  def render("news.system.abandoned", p),
    do: "#{faction(p)} has abandoned #{system(p)}."

  def render("news.conquest", p),
    do: "A system in sector #{sector(p)} has fallen to #{faction(p)} after a siege."

  def render("news.sector.flipped", p),
    do: "#{faction(p)} has taken control of sector #{sector(p)} from #{faction_display(p[:prev_faction])}."

  def render("news.sector.claimed", p),
    do: "#{faction(p)} has taken control of sector #{sector(p)}."

  def render("news.sector.lost", p),
    do: "#{faction_display(p[:prev_faction])} has lost control of sector #{sector(p)}."

  def render("news.raid", p),
    do: "An orbital bombardment has been reported in sector #{sector(p)}."

  def render("news.raid.summary", p),
    do: "Bombardments continue in sector #{sector(p)}. At least #{p[:count]} more strikes have been reported."

  def render("news.battle", p),
    do: "A small skirmish took place in sector #{sector(p)}."

  def render("news.battle.summary", p),
    do: "Fighting continues in sector #{sector(p)}. At least #{p[:count]} more engagements have been reported."

  def render("news.agent.assassinated", p) do
    "Governor #{p[:target_name]}, one of the most distinguished administrators in the galaxy, " <>
      "has been assassinated. There are no suspects."
  end

  def render("news.agent.converted", p) do
    "Governor #{p[:target_name]}, long admired throughout the galaxy, has renounced their post. " <>
      "No explanation has been given."
  end

  def render("news.faction.erased", p),
    do: "#{faction(p)} has trained a formidable shadow organization to safeguard their systems from spies."

  def render("news.faction.navarchs", p),
    do: "#{faction(p)} has assembled a formidable corps of Navarchs to command its fleets across the galaxy."

  def render("news.faction.siderians", p),
    do: "#{faction(p)} has cultivated a formidable circle of Siderians to sway hearts and minds across the galaxy."

  def render("news.building.first", p),
    do: "#{faction(p)} has completed the galaxy's first #{building(p)}, on #{system(p)}."

  def render("news.ship.capital", p),
    do: "#{faction(p)} employs the #{ship(p)} to mark a new age of ship warfare."

  def render("news.income.first", p),
    do: "#{faction(p)} is the first to raise its #{p[:resource]} output above 100."

  def render("news.credit.first", p),
    do: "The treasury of #{faction(p)} is the first to exceed ten million credits."

  def render("news.doctrine.first", p),
    do: "#{faction(p)} is the first to bring fifteen lexes into law."

  # Unknown bulletin kinds stay off Discord — a generic "something
  # happened" line is noise in a chat channel (unlike the in-game
  # ticker, where the fallback keeps layout stable).
  def render(_key, _payload), do: nil

  ## Param helpers — nil-tolerant so a malformed payload degrades the
  ## sentence, never crashes the relay.

  @doc "Faction display name with its guild emoji appended."
  def faction_display(key) when is_binary(key) do
    name = Map.get(@faction_names, key, key)

    case Map.get(@faction_emoji, key) do
      nil -> name
      emoji -> "#{name} #{emoji}"
    end
  end

  def faction_display(_), do: "An unknown power"

  defp faction(p), do: faction_display(p[:faction])
  defp system(p), do: p[:system_name] || "an uncharted system"
  defp sector(p), do: p[:sector_name] || "an uncharted region"
  defp building(p), do: Map.get(@building_names, p[:building], p[:building])
  defp ship(p), do: Map.get(@ship_names, p[:ship], p[:ship])
end
