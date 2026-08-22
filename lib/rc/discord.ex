defmodule RC.Discord do
  @moduledoc """
  Discord bot integration entry point — Marat, the Tetrarchy Falls bot.

  The bot drives ONE guild: the public community server. Everything —
  announcements, per-match faction categories + chats, faction roles,
  news feeds — lives there. (Until 2026-08 there was a second,
  Legacy-games guild; it has been retired and its features folded into
  the community server. `DISCORD_GAME_GUILD_ID` now only identifies
  the retired guild so the bot can clean its slash commands off it —
  see `RC.Discord.Commands.register_all/0`.)

  ## Boot-time on/off semantics

  This module is added unconditionally to `RC.Application`'s children
  list, but only actually starts a supervision sub-tree when both:

    * `:nostrum`'s `:token` is configured (via `DISCORD_BOT_TOKEN` or
      `DISCORD_BOT_TOKEN_FILE` in runtime env), AND
    * `:rc`'s `RC.Discord` block has the community guild id

  Either missing → `start_link/1` returns `:ignore` and the rest of
  the OTP tree comes up unchanged. This means dev environments without
  the secret never have to special-case anything; they just don't get
  a bot.

  Wired in config/runtime.exs.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # NOTE: dev.exs sets logger level to :warning, so we use :warning
    # for these boot-time status messages — they're state-change events
    # an operator wants visible even at the default dev verbosity.
    # In prod the level is :info, so this is a no-op there.
    cond do
      Application.get_env(:rc, :environment) == :test ->
        # Don't connect to Discord during tests. The container's env
        # forwards DISCORD_BOT_TOKEN to all environments (it has to,
        # for dev to work), so we gate here rather than at the
        # config layer. Tests that need to exercise RC.Discord
        # directly can call its functions; nothing should be hitting
        # the gateway in CI / a test run.
        Logger.info("[RC.Discord] skipping bot in :test environment")
        :ignore

      not has_token?() ->
        Logger.warning("[RC.Discord] DISCORD_BOT_TOKEN unset; bot disabled")
        :ignore

      not has_guild_config?() ->
        Logger.warning("[RC.Discord] token present but DISCORD_COMMUNITY_GUILD_ID is not set; bot disabled")

        :ignore

      true ->
        start_nostrum!()
        Logger.warning("[RC.Discord] starting bot supervisor")

        children = [
          RC.Discord.Consumer,
          # Phase 2: periodic + event-driven role sync. Runs alongside
          # the gateway consumer; its own try/rescue keeps Discord
          # failures from cascading.
          RC.Discord.RoleSync,
          # Game.News → #news channel immediate relay + victory
          # announcements. Casts to it from a botless node are silent
          # no-ops.
          RC.Discord.NewsRelay,
          # Once-a-day summary bulletin (seeded post/cutoff slots).
          RC.Discord.DailyBulletin,
          # Daily-challenge winners blast + next-challenge preview
          # (07:45 UTC, configured news channels).
          RC.Discord.DailyChallengeBlast,
          # Faction-government election news + leadership role sync.
          RC.Discord.GovRelay
        ]

        Supervisor.init(children, strategy: :one_for_one)
    end
  end

  # --- Public lookup helpers (used by consumer + command handlers) ----

  @doc "Returns the community guild ID (integer) or nil if unconfigured."
  def community_guild_id, do: get_guild_id(:community_guild_id)

  @doc """
  The RETIRED Legacy-games guild ID (integer) or nil. Only consulted
  by `RC.Discord.Commands.register_all/0` to wipe the bot's slash
  commands off the old guild on boot; no feature posts or reads there.
  Unset the env var once the bot has been kicked from that server.
  """
  def retired_game_guild_id, do: get_guild_id(:retired_game_guild_id)

  @doc "Guild IDs the bot operates in (currently just the community guild)."
  def configured_guild_ids do
    [community_guild_id()]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Channel ID in the community guild where `/promote` posts the
  "new Legacy match" announcement. nil if unconfigured (announce is
  best-effort — promotion still works).
  """
  def community_announce_channel_id,
    do: get_snowflake(:community_announce_channel_id)

  @doc """
  Channel ID of the rolling match-feed channel (community guild) where
  `RC.Discord.News` relays Game.News bulletins for discord_ready
  games: 5-minute map buckets, VP roll-ups, daily bulletins, election
  news. May be the same channel as `community_game_news_channel_id/0` —
  the posters dedup against that. nil if unconfigured (relay is
  best-effort).
  """
  def news_channel_id,
    do: get_snowflake(:news_channel_id)

  @doc """
  Channel ID of #game-news in the community guild: the 6-hour Legacy
  digest, the daily summary bulletin, and the daily-challenge winners
  blast post there. nil if unconfigured (all three are best-effort).
  """
  def community_game_news_channel_id,
    do: get_snowflake(:community_game_news_channel_id)

  @doc """
  Category ID in the community guild under which `/promote` places
  pairwise inter-faction diplomacy channels. nil = the bot creates its
  own per-match category instead. A category from the wrong guild is
  rejected at promote time (falls back to a bot-made category).
  """
  def diplo_category_id,
    do: get_snowflake(:diplo_category_id)

  @doc """
  Whether the bot supervisor is actually running (token + guild
  configured, not :test). Callers that post best-effort messages
  gate here so a botless deployment never touches Nostrum.
  """
  def running?, do: Process.whereis(__MODULE__) != nil

  @doc """
  Render a Nostrum API error for a log line, appending an operator
  hint for the errors whose bare Discord message is famously
  unactionable. 403/50013 on a role change almost always means the
  target role sits at or above the bot's own top role — a human
  reordering roles in Server Settings can cause it at any time
  (it stranded role assignment on 2026-08-22).
  """
  def format_api_error(%{status_code: 403, response: %{code: 50013}} = error) do
    inspect(error) <>
      " — hint: 50013 on a role operation usually means the role sits at/above " <>
      "the bot's top role; in Server Settings → Roles drag it below 'bots'"
  end

  def format_api_error(error), do: inspect(error)

  # --- Internal -------------------------------------------------------

  defp has_token?, do: Application.get_env(:nostrum, :token) not in [nil, ""]

  defp has_guild_config? do
    cfg = Application.get_env(:rc, __MODULE__, [])
    cfg[:community_guild_id] not in [nil, ""]
  end

  defp get_guild_id(key), do: get_snowflake(key)

  defp get_snowflake(key) do
    case Application.get_env(:rc, __MODULE__, [])[key] do
      nil -> nil
      "" -> nil
      str when is_binary(str) -> String.to_integer(str)
      int when is_integer(int) -> int
    end
  end

  defp start_nostrum! do
    # :nostrum is `runtime: false` in mix.exs, so its application is
    # not auto-started by the release. Start it now that we know the
    # token is configured. Crashes loudly on failure — desired: we want
    # a misconfigured token to fail the boot, not silently noop.
    case Application.ensure_all_started(:nostrum) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        raise "Failed to start :nostrum — #{inspect(reason)}"
    end
  end
end
