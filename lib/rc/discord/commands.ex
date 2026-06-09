defmodule RC.Discord.Commands do
  @moduledoc """
  Slash command registry + dispatch for the Tetrarchy Falls bot.

  ## Adding a command

  1. Add an entry to `@commands` with its Discord-side definition
     (name, description, options — see Discord's ApplicationCommand
     reference for the schema).
  2. Add a `handle/2` clause matching the command name.

  Both happen in this single module so the definition and handler stay
  in sync. On bot startup (`RC.Discord.Consumer` :READY handler) we
  call `register_all/0`, which POSTs the definitions to each configured
  guild via `Nostrum.Api.ApplicationCommand.create_guild_command/2`.

  Guild commands are used (vs. global) for two reasons: instant
  propagation (global commands take up to an hour to refresh in the
  Discord client cache), and because the bot is intentionally private
  to two specific guilds.
  """

  require Logger

  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api.Interaction

  # Discord application command type 1 = CHAT_INPUT (a.k.a. slash command).
  # Interaction response type 4 = CHANNEL_MESSAGE_WITH_SOURCE
  #   (immediate visible reply; deferred replies use type 5).
  @cmd_type_chat_input 1
  @response_channel_message 4

  @commands [
    %{
      name: "ping",
      description: "Sanity check — confirms the bot is alive and connected to the game.",
      type: @cmd_type_chat_input
    }
  ]

  # --- Registration ---------------------------------------------------

  @doc """
  (Re)register every command in `@commands` against every configured
  guild. Idempotent: Discord upserts by name, so re-running on each
  :READY just refreshes the definitions.
  """
  def register_all do
    guilds = RC.Discord.configured_guild_ids()

    if guilds == [] do
      Logger.warning("[RC.Discord.Commands] no guilds configured; skipping command registration")
    else
      for guild_id <- guilds, command <- @commands do
        register_one(guild_id, command)
      end
    end

    :ok
  end

  defp register_one(guild_id, command) do
    case ApplicationCommand.create_guild_command(guild_id, command) do
      {:ok, _registered} ->
        Logger.warning("[RC.Discord.Commands] registered /#{command.name} on guild #{guild_id}")

      {:error, reason} ->
        Logger.error(
          "[RC.Discord.Commands] failed to register /#{command.name} on guild #{guild_id}: " <>
            inspect(reason)
        )
    end
  end

  # --- Dispatch -------------------------------------------------------

  @doc """
  Route an incoming INTERACTION_CREATE payload to the right handler.
  Unknown command names are logged and ignored.
  """
  def dispatch(%{data: %{name: name}} = interaction) do
    handle(name, interaction)
  end

  def dispatch(other) do
    Logger.debug("[RC.Discord.Commands] ignoring interaction without command name: #{inspect(other)}")
    :ok
  end

  # --- Command handlers ----------------------------------------------

  defp handle("ping", interaction) do
    instance_count = safe_instance_count()

    reply(interaction, "pong — #{instance_count} game instances in the database")
  end

  defp handle(name, interaction) do
    Logger.warning("[RC.Discord.Commands] no handler for /#{name}")
    reply(interaction, "command not implemented yet")
  end

  # --- Helpers --------------------------------------------------------

  defp reply(interaction, content) when is_binary(content) do
    response = %{
      type: @response_channel_message,
      data: %{content: content}
    }

    case Interaction.create_response(interaction, response) do
      {:ok} -> :ok
      :ok -> :ok
      {:error, reason} ->
        Logger.error("[RC.Discord.Commands] interaction response failed: #{inspect(reason)}")
        :error
    end
  end

  # Wrap the Repo query so a DB blip doesn't make /ping hard-fail. The
  # response should still come back — just with a less interesting number.
  defp safe_instance_count do
    RC.Repo.aggregate(RC.Instances.Instance, :count)
  rescue
    e ->
      Logger.warning("[RC.Discord.Commands] instance count failed: #{Exception.message(e)}")
      "?"
  end
end
