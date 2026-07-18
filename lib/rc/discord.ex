defmodule RC.Discord do
  @moduledoc """
  Discord bot integration entry point — Marat, the Tetrarchy Falls bot.

  The bot drives two guilds:
    * the public community server (announcements, lore, feedback)
    * the Legacy-games server (per-match faction categories + chats)

  ## Boot-time on/off semantics

  This module is added unconditionally to `RC.Application`'s children
  list, but only actually starts a supervision sub-tree when both:

    * `:nostrum`'s `:token` is configured (via `DISCORD_BOT_TOKEN` or
      `DISCORD_BOT_TOKEN_FILE` in runtime env), AND
    * `:rc`'s `RC.Discord` block has at least one guild id

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
        Logger.warning(
          "[RC.Discord] token present but neither DISCORD_COMMUNITY_GUILD_ID nor DISCORD_GAME_GUILD_ID is set; bot disabled"
        )

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
          # Faction-government election news + leadership role sync.
          RC.Discord.GovRelay
        ]

        Supervisor.init(children, strategy: :one_for_one)
    end
  end

  # --- Public lookup helpers (used by consumer + command handlers) ----

  @doc "Returns the community guild ID (integer) or nil if unconfigured."
  def community_guild_id, do: get_guild_id(:community_guild_id)

  @doc "Returns the Legacy-games guild ID (integer) or nil if unconfigured."
  def game_guild_id, do: get_guild_id(:game_guild_id)

  @doc "Both configured guild IDs as a list (omits nils)."
  def configured_guild_ids do
    [community_guild_id(), game_guild_id()]
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
  Channel ID of the #news general-broadcast channel where
  `RC.Discord.News` relays Game.News bulletins for discord_ready
  games. nil if unconfigured (relay is best-effort).
  """
  def news_channel_id,
    do: get_snowflake(:news_channel_id)

  @doc """
  Category ID in the game guild under which `/promote` places pairwise
  inter-faction diplomacy channels (prod: the diplo-ground category).
  nil = the bot creates its own per-match category instead.
  """
  def diplo_category_id,
    do: get_snowflake(:diplo_category_id)

  @doc """
  Whether the bot supervisor is actually running (token + guild
  configured, not :test). Callers that post best-effort messages
  gate here so a botless deployment never touches Nostrum.
  """
  def running?, do: Process.whereis(__MODULE__) != nil

  # --- Internal -------------------------------------------------------

  defp has_token?, do: Application.get_env(:nostrum, :token) not in [nil, ""]

  defp has_guild_config? do
    cfg = Application.get_env(:rc, __MODULE__, [])
    cfg[:community_guild_id] not in [nil, ""] or cfg[:game_guild_id] not in [nil, ""]
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
