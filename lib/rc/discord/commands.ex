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

  # Application command option types.
  @opt_type_subcommand 1
  @opt_type_string 3

  # Interaction types — dispatched on in `dispatch/1`.
  @itx_type_app_command 2
  @itx_type_message_component 3

  # Interaction response types.
  # 4 = CHANNEL_MESSAGE_WITH_SOURCE  (new visible reply)
  # 6 = DEFERRED_UPDATE_MESSAGE      (component ack — edit later)
  # 7 = UPDATE_MESSAGE               (replace component's source message)
  @response_channel_message 4
  @response_deferred_update 6
  @response_update_message 7

  # Message flags. 64 = EPHEMERAL — visible only to the invoker.
  @ephemeral_flag 64

  # Component types.
  @component_action_row 1
  @component_button 2
  @component_string_select 3

  # Button styles — 4 = DANGER (red), 2 = SECONDARY (gray).
  @button_style_secondary 2
  @button_style_danger 4

  # --- Command catalogue ----------------------------------------------
  # Commands are split by which guild(s) they belong on:
  #
  #   * @common_commands   — registered on every configured guild
  #     (community + game). These are user-facing identity / general
  #     utility commands that make sense everywhere.
  #   * @game_only_commands — registered ONLY on the game (Legacy)
  #     guild. These touch game-server-specific Discord state
  #     (categories, faction roles) and have no meaning on the
  #     community server.

  @common_commands [
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
    },
    %{
      name: "standings",
      description: "Show the current top players by ELO.",
      type: @cmd_type_chat_input
    },
    %{
      name: "system",
      description: "List your systems and dominions, or look one up by name.",
      type: @cmd_type_chat_input,
      options: [
        %{
          name: "name",
          description: "Optional. Filter to systems/dominions whose name contains this text.",
          type: @opt_type_string,
          required: false
        }
      ]
    },
    %{
      name: "fleets",
      description: "List your admirals and their fleets in the active game.",
      type: @cmd_type_chat_input
    },
    %{
      name: "agents",
      description: "List your speakers and spies in the active game.",
      type: @cmd_type_chat_input
    }
  ]

  @game_only_commands [
    %{
      name: "promote",
      description: "Promote a Discord-ready match to community-wide channels.",
      type: @cmd_type_chat_input,
      options: [
        %{
          name: "legacy",
          description: "List eligible Legacy matches and pick one to promote.",
          type: @opt_type_subcommand
        }
      ]
    },
    %{
      name: "teardown",
      description: "Tear down a promoted match (deletes its categories and channels).",
      type: @cmd_type_chat_input,
      options: [
        %{
          name: "legacy",
          description: "Pick a promoted Legacy match to tear down.",
          type: @opt_type_subcommand
        }
      ]
    }
  ]

  # --- Registration ---------------------------------------------------

  @doc """
  (Re)register commands against the configured guilds.

    * `@common_commands` go to every configured guild
    * `@game_only_commands` go to the game guild only

  Idempotent — Discord upserts by name on each :READY.
  """
  def register_all do
    community = RC.Discord.community_guild_id()
    game = RC.Discord.game_guild_id()

    if community == nil and game == nil do
      Logger.warning("[RC.Discord.Commands] no guilds configured; skipping command registration")
    else
      for guild_id <- Enum.reject([community, game], &is_nil/1),
          command <- @common_commands do
        register_one(guild_id, command)
      end

      if game do
        for command <- @game_only_commands do
          register_one(game, command)
        end
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

  # /promote dispatches by its first (and currently only) subcommand.
  # The subcommand arrives as the first option in interaction.data.options.
  defp handle_command("promote", interaction) do
    sub = first_subcommand(interaction)
    discord_id = interaction_user_id(interaction)

    cond do
      is_nil(discord_id) ->
        reply_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      not RC.Discord.LegacyMatch.authorized?(discord_id) ->
        # Identical "not found" surface whether you're not linked or
        # linked-as-not-admin. We don't want the bot to enumerate the
        # admin roster via probing.
        reply_ephemeral(
          interaction,
          "❌ This command is restricted. Link a game-admin account via `/link` first."
        )

      sub == "legacy" ->
        handle_promote_legacy_list(interaction)

      true ->
        reply_ephemeral(interaction, "❌ Unknown promote subcommand: #{inspect(sub)}")
    end
  end

  # /teardown — same auth model as /promote (linked admin), same
  # game-server-only catalogue. Two-step UX: select menu of promoted
  # matches → confirm button.
  defp handle_command("teardown", interaction) do
    sub = first_subcommand(interaction)
    discord_id = interaction_user_id(interaction)

    cond do
      is_nil(discord_id) ->
        reply_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      not RC.Discord.LegacyMatch.authorized?(discord_id) ->
        reply_ephemeral(
          interaction,
          "❌ This command is restricted. Link a game-admin account via `/link` first."
        )

      sub == "legacy" ->
        handle_teardown_legacy_list(interaction)

      true ->
        reply_ephemeral(interaction, "❌ Unknown teardown subcommand: #{inspect(sub)}")
    end
  end

  # --- /standings — global top ELO --------------------------------

  defp handle_command("standings", interaction) do
    profiles =
      RC.Rankings.current_standings()
      |> Enum.take(10)

    if profiles == [] do
      reply(interaction, "No ranked players yet. Get out there and pick up some ELO.")
    else
      send_response(interaction, %{
        type: @response_channel_message,
        data: %{embeds: [build_standings_embed(profiles)]}
      })
    end
  end

  # --- /system [name] — list or search own systems ---------------

  defp handle_command("system", interaction) do
    name_query = option_value(interaction, "name")
    discord_id = interaction_user_id(interaction)

    if is_nil(discord_id) do
      reply_ephemeral(interaction, "❌ Couldn't identify your Discord account.")
    else
      case RC.Discord.PlayerLookup.for_discord_id(discord_id) do
        {:ok, ctx} ->
          if is_nil(name_query) or name_query == "" do
            do_system_list(interaction, ctx)
          else
            do_system_lookup(interaction, ctx, name_query)
          end

        {:error, reason} ->
          reply_ephemeral(interaction, player_lookup_error_text(reason))
      end
    end
  end

  # --- /fleets — own admirals + fleets ----------------------------

  defp handle_command("fleets", interaction) do
    with_player_state(interaction, fn ctx, player_state ->
      admirals =
        player_state.characters
        |> Enum.filter(fn ch -> ch.type == :admiral end)

      embed = build_fleets_embed(ctx, admirals)

      send_response(interaction, %{
        type: @response_channel_message,
        data: %{embeds: [embed], flags: @ephemeral_flag}
      })
    end)
  end

  # --- /agents — own speakers + spies -----------------------------

  defp handle_command("agents", interaction) do
    with_player_state(interaction, fn ctx, player_state ->
      agents =
        player_state.characters
        |> Enum.filter(fn ch -> ch.type in [:speaker, :spy] end)

      embed = build_agents_embed(ctx, agents)

      send_response(interaction, %{
        type: @response_channel_message,
        data: %{embeds: [embed], flags: @ephemeral_flag}
      })
    end)
  end

  defp handle_command(name, interaction) do
    Logger.warning("[RC.Discord.Commands] no handler for /#{name}")
    reply_ephemeral(interaction, "❌ Command not implemented yet.")
  end

  # --- Helpers for /system, /fleets, /agents ----------------------

  # Resolves player context, fetches their live game state from
  # the in-process player agent, and invokes `fun.(ctx, state)`.
  # On error, replies with a friendly ephemeral message and skips
  # the callback.
  defp with_player_state(interaction, fun) when is_function(fun, 2) do
    discord_id = interaction_user_id(interaction)

    cond do
      is_nil(discord_id) ->
        reply_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      true ->
        case RC.Discord.PlayerLookup.for_discord_id(discord_id) do
          {:ok, ctx} ->
            case Game.call(ctx.instance.id, :player, ctx.profile.id, :get_state) do
              {:ok, state} ->
                fun.(ctx, state)

              other ->
                Logger.warning(
                  "[RC.Discord.Commands] player state fetch failed: #{inspect(other)}"
                )

                reply_ephemeral(
                  interaction,
                  "❌ Couldn't read your in-game state. Game may not be running."
                )
            end

          {:error, reason} ->
            reply_ephemeral(interaction, player_lookup_error_text(reason))
        end
    end
  end

  defp player_lookup_error_text(:not_linked) do
    "❌ You haven't linked your Discord account. Visit the game's account page and run `/link` here."
  end

  defp player_lookup_error_text(:no_active_game) do
    "❌ You're not currently in an active game (state must be `playing`)."
  end

  defp player_lookup_error_text({:multiple_active_games, ids}) do
    "❌ You're in multiple active games (#{Enum.join(ids, ", ")}). Per-instance picker not yet implemented."
  end

  defp player_lookup_error_text(_), do: "❌ Couldn't resolve your player profile."

  # --- Embed builders ---------------------------------------------

  defp build_standings_embed(profiles) do
    rows =
      profiles
      |> Enum.with_index(1)
      |> Enum.map(fn {p, rank} ->
        "**#{rank}.** #{p.name} — `#{p.elo}` ELO"
      end)
      |> Enum.join("\n")

    %{
      title: "📊 Tetrarchy Falls — Top Players",
      description: rows,
      color: 0x5865F2,
      footer: %{text: "Ranked by current ELO across active profiles"}
    }
  end

  defp do_system_lookup(interaction, ctx, name_query) do
    case Game.call(ctx.instance.id, :player, ctx.profile.id, :get_state) do
      {:ok, player_state} ->
        needle = String.downcase(name_query)

        matches =
          (player_state.stellar_systems ++ player_state.dominions)
          |> Enum.filter(fn s -> String.contains?(String.downcase(s.name), needle) end)
          |> Enum.take(5)

        cond do
          matches == [] ->
            reply_ephemeral(
              interaction,
              "❌ No system matching `#{name_query}` in your possessions. " <>
                "Run `/system` (no args) to see what you own."
            )

          true ->
            send_response(interaction, %{
              type: @response_channel_message,
              data: %{embeds: Enum.map(matches, &build_system_embed/1)}
            })
        end

      other ->
        Logger.warning("[RC.Discord.Commands] /system player fetch failed: #{inspect(other)}")
        reply_ephemeral(interaction, "❌ Couldn't read in-game state.")
    end
  end

  # List mode — show owned systems + dominions so the player can
  # remember what they have. Ephemeral; this is private intel.
  defp do_system_list(interaction, ctx) do
    case Game.call(ctx.instance.id, :player, ctx.profile.id, :get_state) do
      {:ok, player_state} ->
        send_response(interaction, %{
          type: @response_channel_message,
          data: %{
            embeds: [build_possessions_embed(ctx, player_state)],
            flags: @ephemeral_flag
          }
        })

      other ->
        Logger.warning("[RC.Discord.Commands] /system list player fetch failed: #{inspect(other)}")
        reply_ephemeral(interaction, "❌ Couldn't read in-game state.")
    end
  end

  defp build_possessions_embed(ctx, player_state) do
    owned = player_state.stellar_systems || []
    dominions = player_state.dominions || []

    # Discord field values cap at 1024 chars. Sort + cap helps the
    # common case stay readable; long territories get a "+ N more".
    {capitals, regulars} = Enum.split_with(owned, fn s -> s.type == :capital end)

    fields =
      [
        possession_field("👑 Capital", capitals),
        possession_field("🪐 Owned (#{length(regulars)})", regulars),
        possession_field("🌒 Dominions (#{length(dominions)})", dominions)
      ]
      |> Enum.reject(&is_nil/1)

    %{
      title: "🗺️ Your possessions in #{ctx.instance.name || "##{ctx.instance.id}"}",
      description:
        "Run `/system <name>` (or any partial match) to get details on a specific system.",
      color: 0x5865F2,
      fields: fields,
      footer: %{text: "Faction: #{String.capitalize(ctx.faction.faction_ref)}"}
    }
  end

  defp possession_field(_label, []), do: nil

  defp possession_field(label, systems) do
    names =
      systems
      |> Enum.map(& &1.name)
      |> Enum.sort()

    value = truncate_list(names, 1000)

    %{name: label, value: value, inline: false}
  end

  # Build a comma-separated list, but stop and append "+ N more"
  # before exceeding the limit. Keeps Discord happy.
  defp truncate_list(items, max_chars) do
    {acc, dropped} =
      Enum.reduce(items, {[], 0}, fn name, {acc, dropped} ->
        next_acc = [name | acc]
        joined = Enum.join(Enum.reverse(next_acc), ", ")

        # Reserve ~20 chars for a potential "+ N more" tail.
        if String.length(joined) > max_chars - 20 do
          {acc, dropped + 1}
        else
          {next_acc, dropped}
        end
      end)

    list = acc |> Enum.reverse() |> Enum.join(", ")

    cond do
      dropped == 0 and list == "" -> "—"
      dropped == 0 -> list
      list == "" -> "(#{dropped} items, all too long to display)"
      true -> list <> " · + #{dropped} more"
    end
  end

  defp build_system_embed(system) do
    %{
      title: "🪐 #{system.name}",
      description: "#{describe_type(system.type)} · status: `#{system.status}`",
      color: 0x5865F2,
      fields:
        [
          %{name: "Workforce", value: to_string(system.workforce), inline: true},
          %{name: "Habitation", value: to_string(system.habitation), inline: true},
          %{name: "Defense", value: format_number(system.defense), inline: true},
          %{name: "Production", value: format_number(system.production), inline: true},
          %{name: "Technology", value: format_number(system.technology), inline: true},
          %{name: "Ideology", value: format_number(system.ideology), inline: true},
          %{name: "Credit", value: format_number(system.credit), inline: true},
          %{name: "Happiness", value: format_number(system.happiness), inline: true},
          %{name: "Radar", value: format_number(system.radar), inline: true}
        ] ++ siege_field(system.siege)
    }
  end

  defp siege_field(nil), do: []
  defp siege_field(siege), do: [%{name: "⚠️ Siege", value: to_string(siege), inline: false}]

  defp describe_type(:capital), do: "Capital"
  defp describe_type(:occupation), do: "Occupied"
  defp describe_type(:dominion), do: "Dominion"
  defp describe_type(other), do: to_string(other)

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n), do: to_string(n)

  defp build_fleets_embed(ctx, []) do
    %{
      title: "⚓ Your Fleets",
      description: "You have no admirals in this game.",
      footer: %{text: "Instance: #{ctx.instance.name || "##{ctx.instance.id}"}"}
    }
  end

  defp build_fleets_embed(ctx, admirals) do
    fields =
      Enum.map(admirals, fn ch ->
        loc = location_text(ch)
        army = army_text(ch)
        action = action_text(ch)

        %{
          name: "#{ch.name} (lvl #{ch.level})",
          value: "📍 #{loc}\n🛡️ #{army}\n⚙️ #{action}",
          inline: false
        }
      end)

    %{
      title: "⚓ Your Fleets",
      description: "**#{length(admirals)}** admiral#{plural(length(admirals))} in **#{ctx.instance.name || "##{ctx.instance.id}"}**",
      color: 0x5865F2,
      fields: fields
    }
  end

  defp build_agents_embed(ctx, []) do
    %{
      title: "🕵️ Your Agents",
      description: "You have no speakers or spies in this game.",
      footer: %{text: "Instance: #{ctx.instance.name || "##{ctx.instance.id}"}"}
    }
  end

  defp build_agents_embed(ctx, characters) do
    fields =
      Enum.map(characters, fn ch ->
        loc = location_text(ch)
        action = action_text(ch)
        discovered = if ch.type == :spy and ch.is_discovered == true, do: " 👁️ exposed", else: ""

        %{
          name: "#{type_icon(ch.type)} #{ch.name} (lvl #{ch.level})#{discovered}",
          value: "📍 #{loc}\n⚙️ #{action}",
          inline: false
        }
      end)

    %{
      title: "🕵️ Your Agents",
      description:
        "**#{length(characters)}** non-admiral character#{plural(length(characters))} in **#{ctx.instance.name || "##{ctx.instance.id}"}**",
      color: 0x5865F2,
      fields: fields
    }
  end

  defp type_icon(:speaker), do: "📢"
  defp type_icon(:spy), do: "🕵️"
  defp type_icon(_), do: "•"

  defp location_text(%{system: nil}), do: "in transit"
  defp location_text(%{system: id}), do: "system ##{id}"

  defp army_text(%{army_size: nil}), do: "not deployed"

  defp army_text(%{army_size: %{filled: f, planned: p}}) do
    "#{f}/#{f + p} ships"
  end

  defp army_text(_), do: "—"

  defp action_text(%{action_status: nil}), do: "idle"
  defp action_text(%{action_status: status}), do: "#{status}"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # --- /teardown legacy: list promoted + show select menu ---

  defp handle_teardown_legacy_list(interaction) do
    promoted = RC.Discord.LegacyMatch.list_promoted()

    if promoted == [] do
      reply_ephemeral(
        interaction,
        "ℹ️ No promoted matches to tear down."
      )
    else
      send_response(interaction, %{
        type: @response_channel_message,
        data: %{
          content: "Pick a promoted Legacy match to tear down. " <>
                     "**This deletes all of its faction categories and channels.**",
          flags: @ephemeral_flag,
          components: [
            %{
              type: @component_action_row,
              components: [
                %{
                  type: @component_string_select,
                  custom_id: "teardown_legacy_select:#{interaction_user_id(interaction)}",
                  placeholder: "Select a match to tear down",
                  min_values: 1,
                  max_values: 1,
                  options:
                    Enum.map(promoted, fn instance ->
                      %{
                        label: instance_label(instance),
                        value: "instance:#{instance.id}",
                        description: instance_description(instance)
                      }
                    end)
                }
              ]
            }
          ]
        }
      })
    end
  end

  # --- /promote legacy: list eligible + show select menu ---

  defp handle_promote_legacy_list(interaction) do
    eligible = RC.Discord.LegacyMatch.list_eligible()

    if eligible == [] do
      reply_ephemeral(
        interaction,
        "ℹ️ No eligible matches. Need an instance whose scenario is marked **Discord ready** " <>
          "in admin and is in `created` or `open` state and not already promoted."
      )
    else
      send_response(interaction, %{
        type: @response_channel_message,
        data: %{
          content: "Pick a Legacy match to promote:",
          flags: @ephemeral_flag,
          components: [
            %{
              type: @component_action_row,
              components: [
                %{
                  type: @component_string_select,
                  custom_id: "promote_legacy_select:#{interaction_user_id(interaction)}",
                  placeholder: "Select a match",
                  min_values: 1,
                  max_values: 1,
                  options:
                    Enum.map(eligible, fn instance ->
                      %{
                        label: instance_label(instance),
                        value: "instance:#{instance.id}",
                        description: instance_description(instance)
                      }
                    end)
                }
              ]
            }
          ]
        }
      })
    end
  end

  defp instance_label(instance) do
    name = instance.name || "Game ##{instance.id}"
    # Discord caps option labels at 100 chars.
    String.slice(name, 0, 100)
  end

  defp instance_description(instance) do
    scenario_name =
      get_in(instance.scenario.game_metadata || %{}, ["name"]) || "scenario ##{instance.scenario_id}"

    faction_count = length(instance.factions || [])

    text = "#{scenario_name} · #{faction_count} factions · state: #{instance.state}"
    # Discord caps option descriptions at 100 chars.
    String.slice(text, 0, 100)
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

  defp handle_component("teardown_legacy_select:" <> initiator_id_str, interaction) do
    actual_id = interaction_user_id(interaction)

    cond do
      is_nil(actual_id) ->
        update_message_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      to_string(actual_id) != initiator_id_str ->
        update_message_ephemeral(interaction, "❌ This selection isn't for you.")

      true ->
        case interaction.data.values do
          [<<"instance:", id_str::binary>>] ->
            case Integer.parse(id_str) do
              {instance_id, ""} ->
                prompt_teardown_confirm(interaction, instance_id, actual_id)

              _ ->
                update_message_ephemeral(interaction, "❌ Bad selection payload.")
            end

          _ ->
            update_message_ephemeral(interaction, "❌ Bad selection payload.")
        end
    end
  end

  defp handle_component("teardown_confirm:" <> rest, interaction) do
    handle_teardown_decision(interaction, rest, :confirm)
  end

  defp handle_component("teardown_cancel:" <> rest, interaction) do
    handle_teardown_decision(interaction, rest, :cancel)
  end

  defp handle_component("promote_legacy_select:" <> initiator_id_str, interaction) do
    actual_id = interaction_user_id(interaction)

    cond do
      is_nil(actual_id) ->
        update_message_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

      to_string(actual_id) != initiator_id_str ->
        # Defense in depth — ephemeral messages are normally invisible
        # to other users so this branch is unlikely to be hit, but if
        # someone is replaying a stolen interaction we reject.
        update_message_ephemeral(interaction, "❌ This selection isn't for you.")

      true ->
        case interaction.data.values do
          [<<"instance:", id_str::binary>>] ->
            case Integer.parse(id_str) do
              {instance_id, ""} -> do_promote_legacy(interaction, instance_id, actual_id)
              _ -> update_message_ephemeral(interaction, "❌ Bad selection payload.")
            end

          _ ->
            update_message_ephemeral(interaction, "❌ Bad selection payload.")
        end
    end
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

  # --- /promote legacy: actually create the channels -----------------

  # Channel creation can take 5–10s (5 categories × 7 channels worst
  # case, each its own Discord API round-trip with rate-limit
  # waits). The 3s initial-response window forces us to defer first
  # and edit the original message with the result.
  defp do_promote_legacy(interaction, instance_id, promoter_discord_id) do
    case defer_update(interaction) do
      :ok -> :ok
      _ -> Logger.error("[RC.Discord.Commands] defer_update failed before promote")
    end

    result = RC.Discord.LegacyMatch.promote(instance_id, promoter_discord_id)
    edit_promote_result(interaction, instance_id, result)
  end

  defp edit_promote_result(interaction, instance_id, {:ok, match}) do
    n = map_size(match.faction_categories)

    edit_original(
      interaction,
      "✅ Promoted instance ##{instance_id}. Created **#{n}** faction categories with channels. " <>
        "Players will get role assignments at game start - 6h (Phase 2)."
    )
  end

  defp edit_promote_result(interaction, _instance_id, {:error, :not_found}),
    do: edit_original(interaction, "❌ Instance not found (deleted?).")

  defp edit_promote_result(interaction, _instance_id, {:error, :not_eligible}),
    do:
      edit_original(
        interaction,
        "❌ Instance is no longer eligible (state changed, or scenario lost discord_ready)."
      )

  defp edit_promote_result(interaction, _instance_id, {:error, :already_promoted}),
    do:
      edit_original(
        interaction,
        "❌ Instance is already promoted — someone may have just done this. Check the channel list."
      )

  defp edit_promote_result(interaction, _instance_id, {:error, :game_guild_not_configured}),
    do: edit_original(interaction, "❌ `DISCORD_GAME_GUILD_ID` env var is unset.")

  defp edit_promote_result(interaction, _instance_id, {:error, {:roles_fetch_failed, reason}}) do
    Logger.error("[RC.Discord.Commands] roles fetch failed: #{inspect(reason)}")
    edit_original(interaction, "❌ Couldn't read guild roles. Check bot permissions.")
  end

  defp edit_promote_result(interaction, _instance_id, {:error, {:category_create_failed, ref, reason}}) do
    Logger.error("[RC.Discord.Commands] category create failed (#{ref}): #{inspect(reason)}")

    edit_original(
      interaction,
      "❌ Failed to create category for faction `#{ref}`. " <>
        "Likely a permissions issue — bot needs Manage Channels on the game server."
    )
  end

  defp edit_promote_result(interaction, _instance_id, {:error, {:channels_create_failed, ref, ch, reason}}) do
    Logger.error("[RC.Discord.Commands] channel create failed (#{ref}/#{ch}): #{inspect(reason)}")

    edit_original(
      interaction,
      "❌ Created the category for `#{ref}` but failed at channel `##{ch}`. " <>
        "Some channels may already be in place — check the server."
    )
  end

  defp edit_promote_result(interaction, instance_id, {:error, reason}) do
    Logger.error("[RC.Discord.Commands] /promote legacy failed for ##{instance_id}: #{inspect(reason)}")
    edit_original(interaction, "❌ Promotion failed. Check the server logs for details.")
  end

  # --- /teardown legacy: confirm prompt + decision ------------------

  defp prompt_teardown_confirm(interaction, instance_id, user_id) do
    user_id_str = to_string(user_id)

    components = [
      %{
        type: @component_action_row,
        components: [
          %{
            type: @component_button,
            style: @button_style_danger,
            label: "Confirm teardown",
            custom_id: "teardown_confirm:#{instance_id}:#{user_id_str}"
          },
          %{
            type: @component_button,
            style: @button_style_secondary,
            label: "Cancel",
            custom_id: "teardown_cancel:#{instance_id}:#{user_id_str}"
          }
        ]
      }
    ]

    response = %{
      type: @response_update_message,
      data: %{
        content:
          "Tear down promoted match for instance ##{instance_id}? " <>
            "This deletes every Discord channel and category created by `/promote` for this match. " <>
            "Players' faction roles are NOT removed; manage those manually if needed.",
        flags: @ephemeral_flag,
        components: components
      }
    }

    send_response(interaction, response)
  end

  defp handle_teardown_decision(interaction, custom_id_rest, decision) do
    actual_id = interaction_user_id(interaction)

    with [instance_id_str, expected_user_id_str] <- String.split(custom_id_rest, ":"),
         {instance_id, ""} <- Integer.parse(instance_id_str) do
      cond do
        is_nil(actual_id) ->
          update_message_ephemeral(interaction, "❌ Couldn't identify your Discord account.")

        to_string(actual_id) != expected_user_id_str ->
          update_message_ephemeral(interaction, "❌ This confirmation isn't for you.")

        decision == :cancel ->
          update_message_ephemeral(interaction, "🚫 Teardown cancelled.")

        decision == :confirm ->
          do_teardown(interaction, instance_id)
      end
    else
      _ ->
        update_message_ephemeral(interaction, "❌ Malformed confirmation token.")
    end
  end

  defp do_teardown(interaction, instance_id) do
    case defer_update(interaction) do
      :ok -> :ok
      _ -> Logger.error("[RC.Discord.Commands] defer_update failed before teardown")
    end

    case RC.Discord.LegacyMatch.teardown(instance_id) do
      {:ok, %{categories_deleted: cats, channels_deleted: chans}} ->
        edit_original(
          interaction,
          "✅ Torn down instance ##{instance_id}. Deleted **#{cats}** categories " <>
            "and **#{chans}** channels."
        )

      {:error, :not_promoted} ->
        edit_original(
          interaction,
          "ℹ️ Instance ##{instance_id} isn't promoted (or was already torn down)."
        )

      {:error, :game_guild_not_configured} ->
        edit_original(interaction, "❌ `DISCORD_GAME_GUILD_ID` env var is unset.")

      {:error, reason} ->
        Logger.error(
          "[RC.Discord.Commands] /teardown failed for ##{instance_id}: #{inspect(reason)}"
        )

        edit_original(
          interaction,
          "❌ Teardown failed partway through. " <>
            "Some channels may be left over — check the server and delete manually if needed."
        )
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

  # Deferred update — acks a component interaction without changing
  # the message yet. Discord shows "thinking…" on the button/select
  # until we follow up with `edit_original/2`. Required for any
  # work that doesn't fit in the 3-second initial-response window.
  defp defer_update(interaction) do
    send_response(interaction, %{type: @response_deferred_update})
  end

  # Edit the message that hosted the component (the original select
  # menu / button prompt) with the final result. Clears components
  # so the prompt can't be re-clicked.
  defp edit_original(interaction, content) when is_binary(content) do
    case Interaction.edit_response(interaction, %{content: content, components: []}) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} ->
        Logger.error("[RC.Discord.Commands] edit_response failed: #{inspect(reason)}")
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

  # For commands with subcommand options, the first option is the
  # subcommand (type 1). Returns its name as a string, or nil.
  defp first_subcommand(interaction) do
    case interaction do
      %{data: %{options: [%{name: name, type: @opt_type_subcommand} | _]}} -> to_string(name)
      _ -> nil
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
