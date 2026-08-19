defmodule RC.Discord.TimezoneRole do
  @moduledoc """
  Mirrors an account's timezone as a Discord role tag, e.g. `TZ: Europe/Paris`.

  Players opt in per account (`accounts.discord_timezone_role`); the tag
  helps match scheduling across a community that spans many timezones.

  Roles are **created on demand**: there are hundreds of IANA zones and
  pre-generating a role per zone would drown the guilds in dead roles.
  On sync we look the role up by name (case-insensitive), create it only
  if this is the first player in the guild using that zone, and swap the
  member's old `TZ: *` role out when their timezone changes. Roles left
  empty when the last member departs are NOT garbage-collected — that
  would need a member scan per role; revisit if role clutter becomes real.

  Everything is best-effort and event-driven (timezone/toggle change,
  Discord link, unlink) — a failed Discord call never fails the account
  update that triggered it, mirroring `RC.Discord.RoleSync`.
  """

  require Logger

  alias Nostrum.Api.Guild, as: NostrumGuild

  @prefix "TZ: "

  @doc "The guild role name for an IANA zone."
  def role_name(timezone) when is_binary(timezone), do: @prefix <> timezone

  @doc """
  Whether a guild role name is one of ours. Case-insensitive, like the
  desired-role lookup — an admin hand-renaming "TZ: x" to "tz: x" must
  not orphan the role from the swap-out logic.
  """
  def timezone_role?(name) when is_binary(name),
    do: name |> String.downcase() |> String.starts_with?(String.downcase(@prefix))

  def timezone_role?(_), do: false

  @doc """
  Pure sync plan for one guild. Given the desired role name (nil when the
  tag is disabled or no timezone is set), the member's current role ids,
  and the guild's roles (structs/maps with `:id` and `:name`), returns

      %{remove: [role_id], add: role_id | nil, create: role_name | nil}

  `create` implies a follow-up add of the newly-created role.
  """
  def plan(desired_name, member_role_ids, guild_roles) do
    member_set = MapSet.new(member_role_ids)
    tz_roles = Enum.filter(guild_roles, &timezone_role?(&1.name))

    desired =
      desired_name &&
        Enum.find(tz_roles, fn role ->
          String.downcase(role.name) == String.downcase(desired_name)
        end)

    remove =
      for role <- tz_roles,
          MapSet.member?(member_set, role.id),
          desired == nil or role.id != desired.id,
          do: role.id

    cond do
      desired_name == nil -> %{remove: remove, add: nil, create: nil}
      desired == nil -> %{remove: remove, add: nil, create: desired_name}
      MapSet.member?(member_set, desired.id) -> %{remove: remove, add: nil, create: nil}
      true -> %{remove: remove, add: desired.id, create: nil}
    end
  end

  @doc """
  Reconcile the timezone role for one account across the configured
  guilds, in a detached task. Safe to call from any write path — no-op
  when the bot is down or the account has no linked Discord.
  """
  def sync_for_account_async(account_id) do
    if RC.Discord.running?() do
      Task.start(fn -> safe_sync(account_id) end)
    end

    :ok
  end

  defp safe_sync(account_id), do: safely("sync", fn -> sync_for_account(account_id) end)

  @doc false
  def sync_for_account(account_id) do
    # Reload — callers hand us an id right after a write, and the sync
    # must see the committed values.
    case RC.Repo.get(RC.Accounts.Account, account_id) do
      %{discord_id: discord_id} = account when is_binary(discord_id) ->
        desired =
          if account.discord_timezone_role && is_binary(account.timezone),
            do: role_name(account.timezone),
            else: nil

        Enum.each(guild_ids(), &sync_guild(&1, snowflake(discord_id), desired))

      _ ->
        :ok
    end
  end

  @doc """
  Strip any `TZ: *` roles from a Discord user in the configured guilds.
  Used on unlink (the account row has already lost the discord_id, so
  this takes the raw snowflake). Detached + best-effort like the sync.
  """
  def clear_for_discord_id_async(discord_id) do
    if RC.Discord.running?() do
      Task.start(fn -> safe_clear(discord_id) end)
    end

    :ok
  end

  defp safe_clear(discord_id) do
    safely("clear", fn ->
      Enum.each(guild_ids(), &sync_guild(&1, snowflake(discord_id), nil))
    end)
  end

  # --- Guild reconcile ------------------------------------------------

  defp sync_guild(guild_id, user_id, desired_name) do
    with {:member, {:ok, member}} <- {:member, NostrumGuild.member(guild_id, user_id)},
         {:roles, {:ok, guild_roles}} <- {:roles, NostrumGuild.roles(guild_id)} do
      execute(plan(desired_name, member.roles, guild_roles), guild_id, user_id)
    else
      # Not being in a guild is the normal case for half the player base —
      # only surface real errors.
      {:member, {:error, %{status_code: 404}}} ->
        :ok

      {step, {:error, reason}} ->
        Logger.warning("[RC.Discord.TimezoneRole] #{step} lookup failed in guild #{guild_id}: #{inspect(reason)}")
    end
  end

  defp execute(%{remove: remove, add: add, create: create}, guild_id, user_id) do
    Enum.each(remove, fn role_id ->
      log_api("remove", NostrumGuild.remove_member_role(guild_id, user_id, role_id))
    end)

    cond do
      create != nil ->
        case NostrumGuild.create_role(
               guild_id,
               %{name: create, permissions: 0, hoist: false, mentionable: false},
               "timezone tag (created on demand)"
             ) do
          {:ok, role} ->
            Logger.info("[RC.Discord.TimezoneRole] created role '#{create}' in guild #{guild_id}")
            log_api("add", NostrumGuild.add_member_role(guild_id, user_id, role.id))

          {:error, reason} ->
            Logger.warning("[RC.Discord.TimezoneRole] create '#{create}' failed: #{inspect(reason)}")
        end

      add != nil ->
        log_api("add", NostrumGuild.add_member_role(guild_id, user_id, add))

      true ->
        :ok
    end
  end

  defp log_api(_label, {:ok}), do: :ok
  defp log_api(_label, :ok), do: :ok
  defp log_api(_label, {:ok, _}), do: :ok

  defp log_api(label, {:error, reason}),
    do: Logger.warning("[RC.Discord.TimezoneRole] #{label} failed: #{inspect(reason)}")

  # --- Helpers --------------------------------------------------------

  defp guild_ids do
    [RC.Discord.community_guild_id(), RC.Discord.game_guild_id()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp snowflake(discord_id), do: String.to_integer(to_string(discord_id))

  defp safely(label, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[RC.Discord.TimezoneRole] #{label} failed: #{Exception.message(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )
  end
end
