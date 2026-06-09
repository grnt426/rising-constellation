defmodule RC.Discord.LegacyMatch do
  @moduledoc """
  Promotion orchestration for community-wide Legacy matches.

  Triggered by `/promote legacy` in the bot. Responsible for:

    * Listing eligible instances (`discord_ready` scenario, not yet
      promoted, in a pre-running state)
    * Authorizing the invoker (linked game admin)
    * Creating one Discord category per faction inside the game
      server, each holding the 6 per-faction text channels
    * Persisting the `discord_matches` bookkeeping row

  This is Phase 1 of lobby automation. Phase 2 (role assignment at
  start - 6h) and Phase 3 (archival) hook into the bookkeeping row
  created here.

  ## Per-faction channel layout

  Each faction in the instance gets a category named like
  `TETRARCHY - LEGACY: <instance>`. Inside, six text channels:

      general / system-reservation / strategy / spotted-enemies
      / need-resources / ask-anything

  Permission overwrites: `@everyone` is denied `VIEW_CHANNEL` at
  category level; the matching faction role (`Tetrarchy - Legacy`,
  etc.) is granted view + send + the usual social channel set. The
  channels inherit the category overwrites by default, so we don't
  need to repeat them per channel.

  ## Role mapping

  Pre-existing Discord roles on the game server are looked up by
  name. The mapping is hardcoded (`@faction_role_names`) — if the
  user renames roles in Discord, update the map here. A faction
  whose role can't be found gets its category created anyway but
  visible to nobody; a warning logs the missing role name.
  """

  import Bitwise
  import Ecto.Query

  require Logger

  alias Nostrum.Api.Channel
  alias Nostrum.Api.Guild, as: NostrumGuild
  alias Nostrum.Api.Message
  alias RC.Accounts.Account
  alias RC.Discord.Match
  alias RC.Instances
  alias RC.Instances.Instance
  alias RC.Repo

  # The six per-faction channels. Discord-standard hyphenated.
  @per_faction_channels [
    "general",
    "system-reservation",
    "strategy",
    "spotted-enemies",
    "need-resources",
    "ask-anything"
  ]

  # Game faction key → list of substring patterns to match against
  # Discord role names. Match is case-insensitive; a role is accepted
  # if its name contains EVERY pattern in the list. So `tetrarchy` +
  # `legacy` matches `Tetrarchy - Legacy`, `tetrarchy-legacy`,
  # `Legacy Tetrarchy`, etc. — anything that's clearly the right
  # role regardless of the exact capitalization or separator the
  # server admin used.
  #
  # We don't hardcode a single canonical name because Discord lets
  # admins rename roles, and a brittle match silently breaks the
  # whole permission setup (chats created but invisible to faction
  # members — which is exactly the bug this replaces).
  #
  # Keyed by string (matches `Faction.faction_ref`); avoiding
  # String.to_atom keeps the atom table bounded.
  @faction_role_patterns %{
    "tetrarchy" => ["tetrarchy", "legacy"],
    "myrmezir" => ["myrmezir", "legacy"],
    "cardan" => ["cardan", "legacy"],
    "synelle" => ["synelle", "legacy"],
    "ark" => ["ark", "legacy"]
  }

  # Discord permission bitfield constants. Discord uses 64-bit ints;
  # Elixir handles them natively. References:
  # https://discord.com/developers/docs/topics/permissions
  @perm_view_channel 0x0000_0000_0000_0400
  @perm_send_messages 0x0000_0000_0000_0800
  @perm_embed_links 0x0000_0000_0000_4000
  @perm_attach_files 0x0000_0000_0000_8000
  @perm_add_reactions 0x0000_0000_0000_0040
  @perm_read_message_history 0x0000_0000_0001_0000
  @perm_use_external_emojis 0x0000_0000_0004_0000

  # Permissions granted to a faction role on its category. Reads &
  # acts like a normal Discord chat channel for that faction's
  # members; no admin-style permissions.
  @faction_role_allow @perm_view_channel |||
                        @perm_send_messages |||
                        @perm_embed_links |||
                        @perm_attach_files |||
                        @perm_add_reactions |||
                        @perm_read_message_history |||
                        @perm_use_external_emojis

  # Denied to @everyone at category level (inherited by all channels).
  @everyone_deny @perm_view_channel

  # Discord overwrite type — 0 = role, 1 = member.
  @overwrite_type_role 0

  # Discord channel types — 4 = GUILD_CATEGORY, 0 = GUILD_TEXT.
  @channel_type_category 4
  @channel_type_text 0

  # Discord caps select menus at 25 options.
  @select_menu_cap 25

  # --- Public API ------------------------------------------------------

  @doc """
  Returns the faction-key → role-pattern-list map.
  """
  def faction_role_patterns, do: @faction_role_patterns

  @doc """
  Given a faction_ref string and a map of `%{role_name => role_id}`
  from `fetch_guild_roles/1`, returns `{:ok, role_id, role_name}` if
  exactly one role matches, `{:error, :no_match, patterns}` if none,
  or `{:ambiguous, candidates}` if more than one. Case-insensitive
  substring match — every pattern in the faction's pattern list must
  appear somewhere in the role name.
  """
  def find_faction_role(faction_ref, roles_by_name) when is_binary(faction_ref) do
    case Map.get(@faction_role_patterns, faction_ref) do
      nil ->
        {:error, :unknown_faction}

      patterns ->
        candidates =
          roles_by_name
          |> Enum.filter(fn {name, _id} ->
            lower = String.downcase(name)
            Enum.all?(patterns, &String.contains?(lower, &1))
          end)

        case candidates do
          [] -> {:error, :no_match, patterns}
          [{name, id}] -> {:ok, id, name}
          many -> {:ambiguous, many}
        end
    end
  end

  @doc """
  Is the given Discord user id authorized to run `/promote`?

  Currently: yes iff that Discord user has linked their account AND
  the linked game account has `role: :admin`.
  """
  @spec authorized?(String.t() | integer()) :: boolean()
  def authorized?(discord_id) do
    case RC.Accounts.Discord.get_account_by_discord_id(to_string(discord_id)) do
      %Account{role: :admin} -> true
      _ -> false
    end
  end

  @doc """
  Returns up to `@select_menu_cap` instances eligible for
  `/promote legacy`:

    * Scenario must be `discord_ready`
    * Instance state must be `created` or `open` (pre-running)
    * Instance must not already have a `discord_matches` row

  Result is preloaded with `:scenario` and `:factions` for downstream
  channel-creation work. Sorted newest first.
  """
  def list_eligible do
    from(i in Instance,
      join: s in assoc(i, :scenario),
      left_join: m in Match,
      on: m.instance_id == i.id,
      where: s.discord_ready == true,
      where: i.state in ["created", "open"],
      where: is_nil(m.id),
      order_by: [desc: i.inserted_at],
      limit: @select_menu_cap,
      preload: [:scenario, :factions]
    )
    |> Repo.all()
  end

  @doc """
  Returns up to `@select_menu_cap` instances that have an active
  `discord_matches` row — i.e., are candidates for `/teardown`.
  Newest first.
  """
  def list_promoted do
    from(i in Instance,
      join: m in Match,
      on: m.instance_id == i.id,
      order_by: [desc: i.inserted_at],
      limit: @select_menu_cap,
      preload: [:scenario, :factions]
    )
    |> Repo.all()
  end

  @doc """
  Tear down a promoted match: delete every Discord channel created
  under the match's faction categories, delete each category, then
  remove the bookkeeping row. Member-level role assignments are NOT
  stripped (operator can clean those up manually).

  Returns `{:ok, %{categories_deleted: n, channels_deleted: n}}` on
  success, or `{:error, reason}` on failure (partial state may exist
  on Discord — log will identify which step failed).
  """
  @spec teardown(integer()) ::
          {:ok, %{categories_deleted: non_neg_integer(), channels_deleted: non_neg_integer()}}
          | {:error, term()}
  def teardown(instance_id) when is_integer(instance_id) do
    case Repo.get_by(Match, instance_id: instance_id) do
      nil ->
        {:error, :not_promoted}

      %Match{} = match ->
        with {:ok, guild_id} <- fetch_game_guild_id(),
             {:ok, counts} <- delete_match_channels(guild_id, match),
             {:ok, _} <- Repo.delete(match) do
          Logger.warning(
            "[RC.Discord.LegacyMatch] tore down instance ##{instance_id}: " <>
              "#{counts.categories_deleted} categories, #{counts.channels_deleted} channels"
          )

          {:ok, counts}
        end
    end
  end

  @doc """
  Promote the given instance: create the per-faction categories +
  channels in the game guild, then write the bookkeeping row.

  Idempotent failure modes:
    * `:not_found` — instance doesn't exist
    * `:not_eligible` — already promoted, wrong state, or scenario
      isn't discord_ready
    * `:game_guild_not_configured` — `DISCORD_GAME_GUILD_ID` unset
    * `{:roles_fetch_failed, reason}`
    * `{:category_create_failed, faction_ref, reason}`
    * `{:channels_create_failed, faction_ref, channel, reason}`

  On success returns `{:ok, %Match{}}`. On failure, channels that
  were created so far are left in place — Discord doesn't have a
  cross-channel transaction. Phase 3 will provide a teardown command;
  for Phase 1, the operator can manually delete stuck channels.
  """
  @spec promote(integer(), String.t() | integer()) ::
          {:ok, Match.t()} | {:error, term()}
  def promote(instance_id, promoter_discord_id) when is_integer(instance_id) do
    with {:ok, instance} <- load_eligible_instance(instance_id),
         {:ok, guild_id} <- fetch_game_guild_id(),
         {:ok, roles_by_name} <- fetch_guild_roles(guild_id),
         {:ok, faction_categories} <-
           create_faction_categories_and_channels(guild_id, instance, roles_by_name),
         {:ok, match} <-
           insert_match(instance.id, faction_categories, to_string(promoter_discord_id)) do
      Logger.info(
        "[RC.Discord.LegacyMatch] promoted instance ##{instance.id} (#{instance.name}) " <>
          "with #{map_size(faction_categories)} faction categories"
      )

      # Community announcement is NOT posted here — it fires on
      # instance state transitions (open / running), driven by
      # RC.Discord.RoleSync's periodic tick. This avoids both
      # announcement fatigue and the awkward case where /promote
      # runs before registration is actually open.

      {:ok, match}
    end
  end

  # --- Eligibility / load helpers -------------------------------------

  defp load_eligible_instance(instance_id) do
    instance =
      Instances.get_instance(instance_id)
      |> case do
        nil -> nil
        inst -> Repo.preload(inst, [:scenario, :factions])
      end

    cond do
      is_nil(instance) ->
        {:error, :not_found}

      not instance.scenario.discord_ready ->
        {:error, :not_eligible}

      instance.state not in ["created", "open"] ->
        {:error, :not_eligible}

      Repo.exists?(from m in Match, where: m.instance_id == ^instance_id) ->
        {:error, :already_promoted}

      true ->
        {:ok, instance}
    end
  end

  defp fetch_game_guild_id do
    case RC.Discord.game_guild_id() do
      nil -> {:error, :game_guild_not_configured}
      id when is_integer(id) -> {:ok, id}
    end
  end

  defp fetch_guild_roles(guild_id) do
    case NostrumGuild.roles(guild_id) do
      {:ok, roles} ->
        {:ok, Map.new(roles, fn role -> {role.name, role.id} end)}

      {:error, reason} ->
        {:error, {:roles_fetch_failed, reason}}
    end
  end

  # --- Channel creation -----------------------------------------------

  # Walks the factions in the instance; for each one creates a
  # category + its 6 text channels. Returns `{:ok, %{faction_ref =>
  # category_id_string}}` or stops on the first error.
  defp create_faction_categories_and_channels(guild_id, instance, roles_by_name) do
    instance.factions
    |> Enum.reduce_while({:ok, %{}}, fn faction, {:ok, acc} ->
      ref = faction.faction_ref

      case create_one_faction(guild_id, instance, ref, roles_by_name) do
        {:ok, category_id} ->
          {:cont, {:ok, Map.put(acc, ref, to_string(category_id))}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp create_one_faction(guild_id, instance, faction_ref, roles_by_name) do
    role_id = resolve_faction_role(faction_ref, roles_by_name)

    category_name = category_name(faction_ref, instance)
    overwrites = build_overwrites(guild_id, role_id)

    with {:ok, %{id: category_id}} <-
           Channel.create(guild_id,
             name: category_name,
             type: @channel_type_category,
             permission_overwrites: overwrites
           )
           |> map_create_error(faction_ref, :category),
         :ok <- create_channels_under(guild_id, category_id, faction_ref) do
      {:ok, category_id}
    end
  end

  defp create_channels_under(guild_id, category_id, faction_ref) do
    # Channels inherit the category's permission overwrites by default,
    # so we don't pass overwrites on each channel. Cleaner and avoids
    # subtle drift if we ever want to relax a category-level deny.
    Enum.reduce_while(@per_faction_channels, :ok, fn channel_name, :ok ->
      case Channel.create(guild_id,
             name: channel_name,
             type: @channel_type_text,
             parent_id: category_id
           ) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:channels_create_failed, faction_ref, channel_name, reason}}}
      end
    end)
  end

  defp build_overwrites(guild_id, nil) do
    [%{id: guild_id, type: @overwrite_type_role, allow: 0, deny: @everyone_deny}]
  end

  defp build_overwrites(guild_id, role_id) do
    [
      %{id: guild_id, type: @overwrite_type_role, allow: 0, deny: @everyone_deny},
      %{id: role_id, type: @overwrite_type_role, allow: @faction_role_allow, deny: 0}
    ]
  end

  # Wraps `find_faction_role/2` with channel-creation-shaped error
  # handling: log warnings, return either the matched id or nil.
  # On `nil`, channels are created with @everyone-deny only, which is
  # safe (visible to nobody) but operationally wrong — the warning is
  # the alarm bell for the admin.
  defp resolve_faction_role(faction_ref, roles_by_name) do
    case find_faction_role(faction_ref, roles_by_name) do
      {:ok, id, name} ->
        Logger.info(
          "[RC.Discord.LegacyMatch] faction '#{faction_ref}' → role '#{name}' (#{id})"
        )

        id

      {:error, :no_match, patterns} ->
        Logger.warning(
          "[RC.Discord.LegacyMatch] no Discord role found for faction '#{faction_ref}' " <>
            "(needed all of #{inspect(patterns)} in the role name, case-insensitive). " <>
            "Channels will be created visible to nobody. " <>
            "Available role names: #{inspect(Map.keys(roles_by_name))}"
        )

        nil

      {:ambiguous, candidates} ->
        names = Enum.map(candidates, fn {n, _} -> n end)
        {first_name, first_id} = hd(candidates)

        Logger.warning(
          "[RC.Discord.LegacyMatch] multiple Discord roles match faction '#{faction_ref}': " <>
            "#{inspect(names)}. Using '#{first_name}' (#{first_id}); " <>
            "rename one of the others to disambiguate."
        )

        first_id

      {:error, :unknown_faction} ->
        Logger.warning(
          "[RC.Discord.LegacyMatch] unknown faction key '#{faction_ref}' — " <>
            "not in @faction_role_patterns. Add it to RC.Discord.LegacyMatch."
        )

        nil
    end
  end

  defp map_create_error({:ok, _} = ok, _faction_ref, _which), do: ok

  defp map_create_error({:error, reason}, faction_ref, :category),
    do: {:error, {:category_create_failed, faction_ref, reason}}

  defp category_name(faction_ref, instance) do
    instance_label = instance.name || "##{instance.id}"
    "#{String.upcase(faction_ref)} - LEGACY: #{instance_label}"
  end

  # --- Teardown ------------------------------------------------------

  # Lists all channels in the guild, filters to children of our
  # categories, deletes children then categories. Returns a count.
  # Errors during deletion are accumulated but the loop continues —
  # partial deletion is better than abandoned channels.
  defp delete_match_channels(guild_id, %Match{faction_categories: faction_categories}) do
    target_category_ids =
      faction_categories
      |> Map.values()
      |> Enum.map(&parse_snowflake/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    case NostrumGuild.channels(guild_id) do
      {:ok, channels} ->
        children =
          Enum.filter(channels, fn ch ->
            parent_id = Map.get(ch, :parent_id) || Map.get(ch, "parent_id")
            parent_id != nil and MapSet.member?(target_category_ids, parent_id)
          end)

        {channels_deleted, channel_errors} = delete_each(children)

        categories_to_delete =
          Enum.filter(channels, fn ch ->
            MapSet.member?(target_category_ids, Map.get(ch, :id))
          end)

        {categories_deleted, category_errors} = delete_each(categories_to_delete)

        # Even with errors, return the counts; the caller logs partial
        # state and the operator can clean up the rest manually.
        if channel_errors == [] and category_errors == [] do
          {:ok, %{categories_deleted: categories_deleted, channels_deleted: channels_deleted}}
        else
          Logger.warning(
            "[RC.Discord.LegacyMatch] teardown had errors — channels: #{inspect(channel_errors)} " <>
              "categories: #{inspect(category_errors)}"
          )

          {:ok, %{categories_deleted: categories_deleted, channels_deleted: channels_deleted}}
        end

      {:error, reason} ->
        {:error, {:list_channels_failed, reason}}
    end
  end

  defp delete_each(channels) do
    Enum.reduce(channels, {0, []}, fn ch, {count, errors} ->
      id = Map.get(ch, :id)

      case Channel.delete(id) do
        {:ok, _} -> {count + 1, errors}
        :ok -> {count + 1, errors}
        {:error, reason} -> {count, [{id, reason} | errors]}
      end
    end)
  end

  defp parse_snowflake(nil), do: nil
  defp parse_snowflake(""), do: nil
  defp parse_snowflake(n) when is_integer(n), do: n

  defp parse_snowflake(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # --- Community-server announcement ---------------------------------
  #
  # Driven by RC.Discord.RoleSync's periodic tick, NOT by /promote.
  # Two events trigger posts:
  #
  #   :registration → instance moved into "open" state
  #   :live         → instance moved into "running" state
  #
  # Each is one-shot per match: the corresponding `announced_*_at`
  # timestamp on RC.Discord.Match acts as a "did we post this
  # already?" flag. The tick handles the read/post/stamp cycle
  # idempotently — restarts, mid-state-machine reruns, late /promote
  # calls all behave correctly.

  @doc """
  Post the matching announcement if (a) the instance state matches
  the kind, (b) the corresponding `announced_*_at` is still nil, and
  (c) an announce channel is configured. Stamps the timestamp on
  success. Best-effort: failure logs but doesn't change the row.
  """
  def maybe_announce(%Match{} = match, kind) when kind in [:registration, :live] do
    expected_state = state_for_kind(kind)
    timestamp_field = timestamp_field_for_kind(kind)

    cond do
      match.instance.state != expected_state ->
        :not_yet

      not is_nil(Map.get(match, timestamp_field)) ->
        :already_announced

      true ->
        do_announce(match, kind, timestamp_field)
    end
  end

  defp state_for_kind(:registration), do: "open"
  defp state_for_kind(:live), do: "running"

  defp timestamp_field_for_kind(:registration), do: :announced_registration_at
  defp timestamp_field_for_kind(:live), do: :announced_live_at

  defp do_announce(match, kind, timestamp_field) do
    case RC.Discord.community_announce_channel_id() do
      nil ->
        Logger.info(
          "[RC.Discord.LegacyMatch] DISCORD_COMMUNITY_ANNOUNCE_CHANNEL_ID unset; " <>
            "skipping #{kind} announce for instance ##{match.instance_id}"
        )

        :no_channel

      channel_id ->
        embed = build_announcement_embed(kind, match.instance)

        case Message.create(channel_id, %{embeds: [embed]}) do
          {:ok, _msg} ->
            now = DateTime.utc_now()

            match
            |> Ecto.Changeset.change(%{timestamp_field => now})
            |> Repo.update()

            Logger.warning(
              "[RC.Discord.LegacyMatch] announced #{kind} for instance ##{match.instance_id} " <>
                "in channel #{channel_id}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[RC.Discord.LegacyMatch] #{kind} announce failed (channel #{channel_id}): " <>
                inspect(reason)
            )

            :error
        end
    end
  end

  defp build_announcement_embed(:registration, instance) do
    opening_unix = DateTime.to_unix(instance.opening_date)

    base_embed(instance,
      title: "📜 Registration open: #{instance.name || "##{instance.id}"}",
      description:
        "A new community-wide Legacy game is now open for registration. Jump in and " <>
          "pick your faction — there's still time to balance teams before kickoff.",
      extra_fields: [
        %{
          name: "Opens",
          value: "<t:#{opening_unix}:F> (<t:#{opening_unix}:R>)",
          inline: false
        },
        %{
          name: "How to participate",
          value:
            "Register for a faction in the game. Run `/link` here on the community server " <>
              "(or in the Legacy server) so the bot can put you in the right faction chats " <>
              "automatically at start - 6h.",
          inline: false
        }
      ]
    )
  end

  defp build_announcement_embed(:live, instance) do
    base_embed(instance,
      title: "🚀 Game is live: #{instance.name || "##{instance.id}"}",
      description:
        "The match has started! Faction chats are active in the Legacy server. " <>
          "Faction switching is now locked.",
      color: 0x57F287,
      extra_fields: [
        %{
          name: "Haven't linked yet?",
          value:
            "Last call — run `/link` to be auto-roled into your faction's Discord channels.",
          inline: false
        }
      ]
    )
  end

  defp base_embed(instance, opts) do
    scenario_name =
      get_in(instance.scenario.game_metadata || %{}, ["name"]) ||
        "scenario ##{instance.scenario_id}"

    factions_field =
      instance.factions
      |> Enum.map(& &1.faction_ref)
      |> Enum.sort()
      |> Enum.map(fn ref -> "• " <> String.capitalize(ref) end)
      |> Enum.join("\n")

    %{
      title: Keyword.fetch!(opts, :title),
      description: Keyword.fetch!(opts, :description),
      color: Keyword.get(opts, :color, 0x5865F2),
      fields:
        [
          %{name: "Scenario", value: scenario_name, inline: true},
          %{name: "Factions", value: factions_field, inline: true}
        ] ++ Keyword.get(opts, :extra_fields, []),
      footer: %{text: "Tetrarchy Falls — Legacy match"}
    }
  end

  # --- Bookkeeping ----------------------------------------------------

  defp insert_match(instance_id, faction_categories, promoter_discord_id) do
    %Match{}
    |> Match.changeset(%{
      instance_id: instance_id,
      faction_categories: faction_categories,
      promoted_by_discord_id: promoter_discord_id
    })
    |> Repo.insert()
    |> case do
      {:ok, _} = ok ->
        ok

      {:error, changeset} ->
        Logger.error(
          "[RC.Discord.LegacyMatch] failed to insert match row for instance #{instance_id}: " <>
            inspect(changeset)
        )

        {:error, {:bookkeeping_failed, changeset}}
    end
  end
end
