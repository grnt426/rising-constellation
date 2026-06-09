defmodule RC.Discord.Commands do
  @moduledoc """
  Slash command + component (button) registry and dispatch for the
  Tetrarchy Falls bot.

  ## Adding a slash command

  1. Add an entry to `@commands` with its Discord-side definition
     (name, description, options, type — see Discord's
     ApplicationCommand reference).
  2. Add a `handle_command/2` clause matching the command name.

  Definition + handler live in this single module so they can't drift.
  On `:READY`, `register_all/0` POSTs the @commands list to each
  configured guild via `Nostrum.Api.ApplicationCommand.create_guild_command/2`
  (idempotent — Discord upserts by name).

  ## Adding a component (button / select)

  When you reply with a component, give it a stable `custom_id`. When
  the user interacts with it, Discord fires INTERACTION_CREATE with
  `type == 3` (MESSAGE_COMPONENT); we dispatch by matching the
  custom_id in `handle_component/2`.

  Convention: prefix the custom_id with an action name and use `:`
  as a separator for embedded values (e.g. `"unlink_confirm:1234"`).
  See `prompt_unlink_confirm/3` and its handler.

  Guild commands (vs. global) are used because the bot is private to
  two specific guilds and guild commands propagate instantly to the
  Discord client cache — global commands can take up to an hour.
  """

  require Logger

  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api.Interaction

  # --- Discord API constants ------------------------------------------
  # Discord uses small ints for these; named here so call sites read
  # cleanly. References:
  # https://discord.com/developers/docs/interactions/application-commands
  # https://discord.com/developers/docs/interactions/message-components

  # Application command type — CHAT_INPUT is a slash command.
  @cmd_type_chat_input 1

  # Application command option types — only STRING is used so far.
  @opt_type_string 3

  # Interaction types — dispatched on in `dispatch/1`.
  @itx_type_app_command 2
  @itx_type_message_component 3

  # Interaction response types.
  # 4 = CHANNEL_MESSAGE_WITH_SOURCE (new visible reply)
  # 7 = UPDATE_MESSAGE (replace the message the component was on)
  @response_channel_message 4
  @response_update_message 7

  # Message flags. 64 = EPHEMERAL — visible only to the invoker.
  @ephemeral_flag 64

  # Component types.
  @component_action_row 1
  @component_button 2

  # Button styles — 4 = DANGER (red), 2 = SECONDARY (gray).
  @button_style_secondary 2
  @button_style_danger 4

  # --- Command catalogue ----------------------------------------------

  @commands [
    %{
      name: "ping",
      description: "Sanity check — confirms the bot is alive and connected to the game.",
      type: @cmd_type_chat_input
    },
    %{
      name: "link",
      description: "Link your Discord account to your Tetrarchy Falls account.",
      type: @cmd_type_chat_input,
      options: [
        %{
          name: "code",
          description: "The code shown on your account settings page in the game.",
          type: @opt_type_string,
          required: true
        }
      ]
    },
    %{
      name: "unlink",
      description: "Unlink your Discord account from your Tetrarchy Falls account.",
      type: @cmd_type_chat_input
    }
  ]

  # --- Registration ---------------------------------------------------

  @doc """
  (Re)register every command in `@commands` against every configured
  guild. Idempotent — Discord upserts by name on each :READY.
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

  # --- Top-level dispatch ---------------------------------------------

  @doc """
  Route an incoming INTERACTION_CREATE payload to the right handler.

  Two branches matter:
    * `type: 2` (APPLICATION_COMMAND) — slash command invocation,
      routed by `data.name`.
    * `type: 3` (MESSAGE_COMPONENT) — button/select interaction,
      routed by `data.custom_id`.

  Everything else (modals, autocomplete) is ignored for now.
  """
  def dispatch(%{type: @itx_type_app_command, data: %{name: name}} = interaction) do
    handle_command(name, interaction)
  end

  def dispatch(%{type: @itx_type_message_component, data: %{custom_id: custom_id}} = interaction) do
    handle_component(custom_id, interaction)
  end

  def dispatch(other) do
    Logger.debug("[RC.Discord.Commands] ignoring unhandled interaction: #{inspect(other)}")
    :ok
  end

  # --- Slash command handlers ----------------------------------------

  defp handle_command("ping", interaction) do
    count = safe_instance_count()
    reply(interaction, "pong — #{count} game instances in the database")
  end

  defp handle_command("link", interaction) do
    code = option_value(interaction, "code")
    discord_id = interaction_user_id(interaction)

    cond do
      is_nil(code) or code == "" ->
        # Discord enforces required-option at the client, so this is
        # defensive — we should never actually hit it.
        reply_ephemeral(interaction, "❌ Missing code. Run `/link code:<code>`.")

      is_nil(discord_id) ->
        Logger.error("[RC.Discord.Commands] /link could not extract user id: #{inspect(interaction)}")
        reply_ephemeral(interaction, "❌ Couldn't identify your Discord account. Try again.")

      true ->
        do_link(interaction, code, to_string(discord_id))
    end
  end

  defp handle_command("unlink", interaction) do
    case interaction_user_id(interaction) do
      nil ->
        reply_ephemeral(interaction, "❌ Couldn't identify your Discord account. Try again.")

      user_id ->
        case RC.Accounts.Discord.get_account_by_discord_id(to_string(user_id)) do
          nil ->
            reply_ephemeral(
              interaction,
              "ℹ️ You're not currently linked to a Tetrarchy Falls account."
            )

          account ->
            prompt_unlink_confirm(interaction, account.name, user_id)
        end
    end
  end

  defp handle_command(name, interaction) do
    Logger.warning("[RC.Discord.Commands] no handler for /#{name}")
    reply_ephemeral(interaction, "❌ Command not implemented yet.")
  end

  defp do_link(interaction, code, discord_id) do
    case RC.Accounts.Discord.consume_code(code, discord_id) do
      {:ok, account} ->
        reply_ephemeral(
          interaction,
          "✅ Linked to **#{account.name}**. You can now use bot features that require account knowledge."
        )

      {:error, :not_found} ->
        reply_ephemeral(
          interaction,
          "❌ Code not recognized. Generate a fresh one on your account settings page and try again."
        )

      {:error, :already_consumed} ->
        reply_ephemeral(
          interaction,
          "❌ That code has already been used. Generate a fresh one."
        )

      {:error, :expired} ->
        reply_ephemeral(
          interaction,
          "❌ That code has expired (5-minute window). Generate a fresh one."
        )

      {:error, :discord_already_linked} ->
        reply_ephemeral(
          interaction,
          "❌ Your Discord account is already linked to a Tetrarchy Falls account. " <>
            "Run `/unlink` first if you want to switch to a different account."
        )

      {:error, reason} ->
        Logger.error("[RC.Discord.Commands] /link consume_code failed: #{inspect(reason)}")

        reply_ephemeral(
          interaction,
          "❌ Something went wrong on our end. Try again in a moment."
        )
    end
  end

  # --- Component (button) handlers -----------------------------------

  defp handle_component("unlink_confirm:" <> user_id_str, interaction) do
    handle_unlink_decision(interaction, user_id_str, :confirm)
  end

  defp handle_component("unlink_cancel:" <> user_id_str, interaction) do
    handle_unlink_decision(interaction, user_id_str, :cancel)
  end

  defp handle_component(custom_id, interaction) do
    Logger.warning("[RC.Discord.Commands] unknown component custom_id: #{inspect(custom_id)}")
    update_message_ephemeral(interaction, "❌ Unrecognized button. Try the command again.")
  end

  # The expected user id is encoded into the custom_id so we can
  # reject clicks from someone other than the original invoker. Since
  # the prompt is ephemeral, in practice only the original user can
  # see the buttons — but it costs us nothing to verify.
  defp handle_unlink_decision(interaction, expected_user_id_str, decision) do
    actual_user_id = interaction_user_id(interaction)

    cond do
      is_nil(actual_user_id) ->
        update_message_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      to_string(actual_user_id) != expected_user_id_str ->
        update_message_ephemeral(interaction, "❌ This confirmation isn't for you.")

      decision == :cancel ->
        update_message_ephemeral(interaction, "🚫 Unlink cancelled.")

      decision == :confirm ->
        do_unlink(interaction, actual_user_id)
    end
  end

  defp do_unlink(interaction, discord_id) do
    case RC.Accounts.Discord.get_account_by_discord_id(to_string(discord_id)) do
      nil ->
        update_message_ephemeral(interaction, "ℹ️ You weren't linked anyway.")

      account ->
        case RC.Accounts.Discord.unlink(account.id) do
          {:ok, _updated} ->
            update_message_ephemeral(interaction, "✅ Unlinked **#{account.name}**.")

          {:error, reason} ->
            Logger.error(
              "[RC.Discord.Commands] unlink failed for account #{account.id}: #{inspect(reason)}"
            )

            update_message_ephemeral(interaction, "❌ Something went wrong. Try again.")
        end
    end
  end

  # --- Component construction ----------------------------------------

  defp prompt_unlink_confirm(interaction, account_name, user_id) do
    user_id_str = to_string(user_id)

    components = [
      %{
        type: @component_action_row,
        components: [
          %{
            type: @component_button,
            style: @button_style_danger,
            label: "Confirm unlink",
            custom_id: "unlink_confirm:#{user_id_str}"
          },
          %{
            type: @component_button,
            style: @button_style_secondary,
            label: "Cancel",
            custom_id: "unlink_cancel:#{user_id_str}"
          }
        ]
      }
    ]

    response = %{
      type: @response_channel_message,
      data: %{
        content:
          "Unlink Discord from **#{account_name}**? This won't delete your game account.",
        flags: @ephemeral_flag,
        components: components
      }
    }

    send_response(interaction, response)
  end

  # --- Response helpers ----------------------------------------------

  defp reply(interaction, content) when is_binary(content) do
    send_response(interaction, %{
      type: @response_channel_message,
      data: %{content: content}
    })
  end

  defp reply_ephemeral(interaction, content) when is_binary(content) do
    send_response(interaction, %{
      type: @response_channel_message,
      data: %{content: content, flags: @ephemeral_flag}
    })
  end

  # Replaces the message the user clicked the button on. We clear the
  # buttons (components: []) so a double-click doesn't repeat work,
  # and keep the message ephemeral so the channel stays uncluttered.
  defp update_message_ephemeral(interaction, content) when is_binary(content) do
    send_response(interaction, %{
      type: @response_update_message,
      data: %{content: content, components: [], flags: @ephemeral_flag}
    })
  end

  defp send_response(interaction, response) do
    case Interaction.create_response(interaction, response) do
      {:ok} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[RC.Discord.Commands] interaction response failed: #{inspect(reason)}")
        :error
    end
  end

  # --- Interaction field accessors -----------------------------------

  # Guild interactions deliver the user under `member.user`; DM
  # interactions deliver them directly under `user`. Handle both.
  defp interaction_user_id(%{member: %{user: %{id: id}}}) when not is_nil(id), do: id
  defp interaction_user_id(%{user: %{id: id}}) when not is_nil(id), do: id
  defp interaction_user_id(_), do: nil

  defp option_value(interaction, opt_name) do
    options =
      case interaction do
        %{data: %{options: opts}} when is_list(opts) -> opts
        _ -> []
      end

    Enum.find_value(options, fn opt ->
      if to_string(opt.name) == opt_name, do: opt.value
    end)
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
