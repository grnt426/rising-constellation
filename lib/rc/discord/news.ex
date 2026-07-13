defmodule RC.Discord.News do
  @moduledoc """
  Relays Game.News bulletins into the community #news channel.

  Called (async, best-effort) from `Game.News.Server.publish/3` after a
  bulletin persists. Posting is gated three ways:

    * the bot supervisor must be running (`RC.Discord.running?/0`),
    * `DISCORD_NEWS_CHANNEL_ID` must be configured,
    * the instance must be flagged `discord_ready`.

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

  require Logger

  alias Nostrum.Api.Message

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
  Fire-and-forget relay. Never raises, never blocks the caller — the
  Discord round-trip runs on `RC.TaskSupervisor` (same pattern as
  `RC.Instances.InstanceEventLog.emit/3`).
  """
  def post_async(instance_id, bulletin_key, payload) do
    Task.Supervisor.start_child(RC.TaskSupervisor, fn -> post(instance_id, bulletin_key, payload) end)
    :ok
  rescue
    e ->
      Logger.error("[RC.Discord.News] failed to enqueue relay: #{inspect(e)}")
      :ok
  end

  @doc false
  def post(instance_id, bulletin_key, payload) do
    with true <- RC.Discord.running?(),
         channel_id when not is_nil(channel_id) <- RC.Discord.news_channel_id(),
         %{discord_ready: true, name: instance_name} <- RC.Instances.get_instance(instance_id),
         headline when is_binary(headline) <- render(bulletin_key, payload) do
      content = "📰 **#{instance_name}** — #{headline}"

      case Message.create(channel_id, %{content: content}) do
        {:ok, _msg} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[RC.Discord.News] relay failed (channel #{channel_id}, instance ##{instance_id}): " <>
              inspect(reason)
          )

          :error
      end
    else
      # Bot off, channel unset, instance missing / not discord_ready,
      # or a bulletin kind with no Discord template — all silent no-ops.
      _ -> :skip
    end
  rescue
    e ->
      Logger.warning("[RC.Discord.News] relay crashed: #{inspect(e)}")
      :error
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
