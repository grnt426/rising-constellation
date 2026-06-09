defmodule RC.Discord.RoleSync do
  @moduledoc """
  Phase 2 of lobby automation — keeps faction roles on Discord aligned
  with `RC.Instances.Registration` rows during a promoted match's
  "active window."

  ## Active window

  For a `RC.Discord.Match`, the active window is:

      [ instance.opening_date - 6 hours, instance.state == "ended" )

  Before T-6h, registration is fluid — players join/unjoin/switch
  factions freely and the bot doesn't touch their roles. Inside the
  window, the bot mirrors registration changes into Discord role
  assignments. Once the instance enters `ended`, sync stops; existing
  roles are left in place (operator can clean up via `/teardown` if
  desired — see Phase 2's teardown command).

  ## Triggers

  Three paths can cause a sync:

    1. **Periodic tick** (every 60s) — looks for matches that just
       crossed into the active window and runs a bulk sync; looks
       for matches whose instance ended and flips them off.
    2. **`sync_for_registration/1`** — called from
       `RC.Registrations.register_profile/3` and `transition_to/2`
       so changes show up on Discord within seconds, not minutes.
    3. **`sync_for_account/1`** — called from the `/link` path so a
       newly-linked player gets their role immediately if they're
       already registered in an active match.

  All three paths share the same low-level helpers — they differ
  only in scope.

  ## Resilience

  Every Discord call is wrapped in `try/rescue`. A failure to reach
  Discord (network blip, rate limit, permission glitch) logs a
  warning but does NOT propagate to the caller. The game-side flow
  (registration / linking) must never be broken by Discord
  unavailability. Drift is fine — the next periodic tick will
  reconcile.

  The GenServer is named (`name: __MODULE__`) so the public API can
  call into it without a registry lookup. In tests, `init/1` returns
  `:ignore` so no real ticks fire.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Nostrum.Api.Guild, as: NostrumGuild
  alias RC.Discord.LegacyMatch
  alias RC.Discord.Match
  alias RC.Instances.Registration
  alias RC.Repo

  # 60-second tick. Activation latency is bounded by this; if a match
  # crosses T-6h between ticks, role assignment lags by up to a minute.
  @tick_ms 60_000

  # Wait before the first tick so we don't compete with boot-time work.
  @initial_delay_ms 30_000

  # Lead window: roles activate this far ahead of opening_date.
  @lead_seconds 6 * 60 * 60

  # Registration states that earn a role. resigned / dead do not.
  @active_registration_states ["joined", "playing"]

  # --- GenServer boilerplate -----------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:rc, :environment) == :test do
      # No Discord traffic in tests. Tests that exercise RoleSync
      # logic should call the public functions directly with a
      # mocked transport.
      :ignore
    else
      schedule(@initial_delay_ms)
      {:ok, %{}}
    end
  end

  # --- Public API ----------------------------------------------------

  @doc """
  Best-effort sync triggered by a registration insert / state change.
  Idempotent — calling repeatedly with the same id is safe.

  Wrapped in rescue/catch so a not-running RoleSync (tests, dev
  without bot config) never breaks the game-side caller.
  """
  @spec sync_for_registration(integer()) :: :ok
  def sync_for_registration(registration_id) when is_integer(registration_id) do
    safe_cast({:sync_registration, registration_id})
  end

  @doc """
  Best-effort sync triggered after a successful `/link`. Looks up
  every registration for `account_id` in active matches and applies
  the right role.
  """
  @spec sync_for_account(integer()) :: :ok
  def sync_for_account(account_id) when is_integer(account_id) do
    safe_cast({:sync_account, account_id})
  end

  @doc """
  Force a tick now (intended for tests and operator debugging from
  iex). Same code path as the periodic tick.
  """
  @spec sync_now() :: :ok
  def sync_now do
    safe_cast(:sync_now)
  end

  defp safe_cast(message) do
    GenServer.cast(__MODULE__, message)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- Internal dispatch ---------------------------------------------

  @impl true
  def handle_info(:tick, state) do
    do_tick()
    schedule(@tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    do_tick()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_registration, reg_id}, state) do
    safely("sync_registration #{reg_id}", fn -> do_sync_registration(reg_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_account, account_id}, state) do
    safely("sync_account #{account_id}", fn -> do_sync_account(account_id) end)
    {:noreply, state}
  end

  defp safely(label, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[RC.Discord.RoleSync] #{label} failed: #{Exception.message(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  # --- Tick — window management + drift correction ------------------

  defp do_tick do
    safely("tick: activate", &activate_due_matches/0)
    safely("tick: deactivate", &deactivate_ended_matches/0)
  end

  # Find matches whose instance's opening_date is within 6 hours from
  # now (or past) AND aren't yet active AND aren't ended. Activate +
  # bulk sync each one.
  defp activate_due_matches do
    threshold = DateTime.add(DateTime.utc_now(), @lead_seconds, :second)

    query =
      from(m in Match,
        join: i in assoc(m, :instance),
        where: m.role_assignment_active == false,
        where: i.opening_date <= ^threshold,
        where: i.state != "ended",
        preload: [instance: [:factions]]
      )

    for match <- Repo.all(query) do
      Logger.warning(
        "[RC.Discord.RoleSync] activating match for instance ##{match.instance.id} " <>
          "(opening_date #{match.instance.opening_date}); doing bulk sync"
      )

      bulk_sync_match(match)
      mark_active(match, true)
    end
  end

  defp deactivate_ended_matches do
    query =
      from(m in Match,
        join: i in assoc(m, :instance),
        where: m.role_assignment_active == true,
        where: i.state == "ended",
        preload: [:instance]
      )

    for match <- Repo.all(query) do
      Logger.warning(
        "[RC.Discord.RoleSync] deactivating match for instance ##{match.instance_id} " <>
          "(instance state: ended); existing role assignments left in place"
      )

      mark_active(match, false)
    end
  end

  defp mark_active(%Match{} = match, value) do
    match
    |> Ecto.Changeset.change(%{role_assignment_active: value})
    |> Repo.update()
  end

  # --- Bulk sync (used at activation) --------------------------------

  defp bulk_sync_match(%Match{instance: %{id: instance_id}} = _match) do
    with {:ok, guild_id, roles_by_name} <- guild_context() do
      regs =
        from(r in Registration,
          join: f in assoc(r, :faction),
          where: f.instance_id == ^instance_id,
          preload: [faction: :instance, profile: :account]
        )
        |> Repo.all()

      Logger.warning("[RC.Discord.RoleSync] bulk sync: #{length(regs)} registrations")

      for reg <- regs do
        apply_role_for(reg, guild_id, roles_by_name)
      end

      :ok
    end
  end

  # --- Single-registration sync (event-driven) -----------------------

  defp do_sync_registration(reg_id) do
    reg =
      Registration
      |> Repo.get(reg_id)
      |> Repo.preload(faction: :instance, profile: :account)

    cond do
      is_nil(reg) ->
        :ok

      is_nil(reg.faction) ->
        :ok

      true ->
        case find_active_match(reg.faction.instance_id) do
          nil ->
            :ok

          match ->
            with {:ok, guild_id, roles_by_name} <- guild_context() do
              apply_role_for(reg, guild_id, roles_by_name)
              _ = match
              :ok
            end
        end
    end
  end

  # --- Account-wide sync (used by /link) -----------------------------

  defp do_sync_account(account_id) do
    regs =
      from(r in Registration,
        join: p in assoc(r, :profile),
        join: f in assoc(r, :faction),
        join: i in assoc(f, :instance),
        join: m in Match,
        on: m.instance_id == i.id,
        where: p.account_id == ^account_id,
        where: m.role_assignment_active == true,
        preload: [faction: :instance, profile: :account]
      )
      |> Repo.all()

    if regs == [] do
      :ok
    else
      with {:ok, guild_id, roles_by_name} <- guild_context() do
        for reg <- regs do
          apply_role_for(reg, guild_id, roles_by_name)
        end

        :ok
      end
    end
  end

  # --- The actual Discord role-add/remove ----------------------------

  # Resolves "what role should this Discord user have for this
  # registration" and applies it. The four possible outcomes:
  #
  #   1. Player unlinked (discord_id nil)         → skip
  #   2. Player's faction has no Discord role      → skip (already
  #      warned at promote time)
  #   3. Registration state is active and the
  #      Discord user should have the role         → add (idempotent)
  #   4. Registration state is resigned/dead       → remove
  defp apply_role_for(registration, guild_id, roles_by_name) do
    discord_id = get_in(registration, [Access.key(:profile), Access.key(:account), Access.key(:discord_id)])
    faction_ref = registration.faction.faction_ref

    cond do
      is_nil(discord_id) ->
        :skip

      true ->
        role_id =
          case LegacyMatch.find_faction_role(faction_ref, roles_by_name) do
            {:ok, id, _name} -> id
            {:ambiguous, [{_n, id} | _]} -> id
            _ -> nil
          end

        cond do
          is_nil(role_id) ->
            :skip

          registration.state in @active_registration_states ->
            add_role(guild_id, discord_id, role_id, faction_ref)

          true ->
            remove_role(guild_id, discord_id, role_id, faction_ref)
        end
    end
  end

  defp add_role(guild_id, discord_id, role_id, faction_ref) do
    case NostrumGuild.add_member_role(guild_id, String.to_integer(to_string(discord_id)), role_id) do
      {:ok} ->
        Logger.info(
          "[RC.Discord.RoleSync] added '#{faction_ref}' role to #{discord_id}"
        )

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.RoleSync] failed to add '#{faction_ref}' role to #{discord_id}: " <>
            inspect(reason)
        )
    end
  end

  defp remove_role(guild_id, discord_id, role_id, faction_ref) do
    case NostrumGuild.remove_member_role(guild_id, String.to_integer(to_string(discord_id)), role_id) do
      {:ok} ->
        Logger.info(
          "[RC.Discord.RoleSync] removed '#{faction_ref}' role from #{discord_id}"
        )

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.RoleSync] failed to remove '#{faction_ref}' role from #{discord_id}: " <>
            inspect(reason)
        )
    end
  end

  # --- Helpers -------------------------------------------------------

  defp find_active_match(instance_id) do
    Repo.get_by(Match, instance_id: instance_id, role_assignment_active: true)
  end

  defp guild_context do
    case RC.Discord.game_guild_id() do
      nil ->
        Logger.warning("[RC.Discord.RoleSync] no game guild configured; skipping sync")
        {:error, :no_guild}

      guild_id ->
        case NostrumGuild.roles(guild_id) do
          {:ok, roles} -> {:ok, guild_id, Map.new(roles, fn r -> {r.name, r.id} end)}
          {:error, reason} ->
            Logger.warning("[RC.Discord.RoleSync] could not fetch guild roles: #{inspect(reason)}")
            {:error, :roles_unavailable}
        end
    end
  end
end
