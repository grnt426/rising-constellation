defmodule RC.Discord.RoleSync do
  @moduledoc """
  Phase 2 of lobby automation — keeps faction roles on the community
  guild aligned with `RC.Instances.Registration` rows during a
  promoted match's "active window." (The roles themselves are created
  on demand by `/promote` — see `RC.Discord.LegacyMatch`.)

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

  Four paths can cause a sync:

    1. **Periodic tick** (every 60s) — looks for matches that just
       crossed into the active window and runs a bulk sync; looks
       for matches whose instance ended and flips them off.
    2. **Drift pass** (every 10th tick) — re-reconciles EVERY account
       in every active match. This is the self-healing layer: a
       member stranded by a transient Discord failure (rate limit,
       outage, or the 2026-08-22 role-hierarchy 403s) gets their
       roles within ~10 minutes of the underlying problem clearing,
       with no re-registration or operator action needed.
    3. **`sync_for_registration/1`** — called from
       `RC.Registrations.register_profile/3` and `transition_to/2`
       so changes show up on Discord within seconds, not minutes.
    4. **`sync_for_account/1`** — called from the `/link` path so a
       newly-linked player gets their role immediately if they're
       already registered in an active match.

  All four paths share the same low-level helpers — they differ
  only in scope. Reconciliation is diff-based: the member's current
  roles are fetched once and only missing/stale faction roles
  generate write calls, so the drift pass is one read per linked
  member in the steady state (and silently skips players who are
  not in the guild).

  ## Role hierarchy invariant

  Discord only lets the bot manage roles strictly BELOW its own top
  role (`bots`). The bot creates faction roles at the bottom of the
  role list, which satisfies this — but a human reordering roles in
  Server Settings can drag them above `bots`, at which point every
  add/remove fails with 403 code 50013 (exactly what stranded role
  assignment on 2026-08-22). Keep faction/seat/TZ roles below the
  bot's role; the drift pass heals everyone once the order is fixed.

  ## Resilience

  Every Discord call is wrapped in `try/rescue`, and bulk syncs
  additionally isolate each account, so one failing account cannot
  strand the rest of the roster. A failure to reach Discord logs a
  warning but does NOT propagate to the caller. The game-side flow
  (registration / linking) must never be broken by Discord
  unavailability. Drift is fine — the drift pass will reconcile.

  The GenServer is named (`name: __MODULE__`) so the public API can
  call into it without a registry lookup. In tests, `init/1` returns
  `:ignore` so no real ticks fire.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Nostrum.Api.Guild, as: NostrumGuild
  alias RC.Accounts.Account
  alias RC.Discord.LegacyMatch
  alias RC.Discord.Match
  alias RC.Instances.Faction
  alias RC.Instances.Registration
  alias RC.Repo

  # 60-second tick. Activation latency is bounded by this; if a match
  # crosses T-6h between ticks, role assignment lags by up to a minute.
  @tick_ms 60_000

  # Every Nth tick runs the drift pass (full re-reconcile of every
  # active match). Diff-based reconciliation keeps it to ~1 API read
  # per linked member, so 10 minutes balances healing latency against
  # API chatter.
  @resync_every_ticks 10

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
  Best-effort reconciliation for a specific (account, instance) pair.
  Walks every faction in the instance: if the account currently has
  an active registration to that faction, add the role; otherwise,
  remove it. Used by the unjoin path (where the registration row is
  deleted before we can look it up) and as the core primitive that
  every other sync API delegates to.
  """
  @spec sync_account_in_instance(integer(), integer()) :: :ok
  def sync_account_in_instance(account_id, instance_id)
      when is_integer(account_id) and is_integer(instance_id) do
    safe_cast({:sync_account_in_instance, account_id, instance_id})
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
    tick = Map.get(state, :tick, 0) + 1
    do_tick(rem(tick, @resync_every_ticks) == 0)
    schedule(@tick_ms)
    {:noreply, Map.put(state, :tick, tick)}
  end

  # Operator-forced syncs always include the drift pass — that's
  # usually why someone reaches for sync_now from iex.
  @impl true
  def handle_cast(:sync_now, state) do
    do_tick(true)
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

  @impl true
  def handle_cast({:sync_account_in_instance, account_id, instance_id}, state) do
    safely("sync_account_in_instance #{account_id}/#{instance_id}", fn ->
      reconcile_account_in_instance(account_id, instance_id)
    end)

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

  defp do_tick(resync?) do
    safely("tick: activate", &activate_due_matches/0)
    safely("tick: deactivate", &deactivate_ended_matches/0)
    safely("tick: announce", &post_pending_announcements/0)
    if resync?, do: safely("tick: resync", &resync_active_matches/0)
  end

  # Drift pass: re-reconcile every account in every active match.
  # Activation's bulk sync is one-shot; without this, a member whose
  # sync failed (Discord outage, rate limit, role moved above the
  # bot's) stays stranded until they re-register or re-link.
  defp resync_active_matches do
    query =
      from(m in Match,
        join: i in assoc(m, :instance),
        where: m.role_assignment_active == true,
        where: i.state != "ended",
        preload: [instance: i]
      )

    for match <- Repo.all(query) do
      bulk_sync_match(match)
    end

    :ok
  end

  # Walk every promoted match; for each, check if its current instance
  # state matches an un-announced event (registration / live) and post
  # if so. LegacyMatch.maybe_announce/2 handles the gating (state +
  # timestamp) and the stamp-on-post — this just feeds it candidates.
  defp post_pending_announcements do
    query =
      from(m in Match,
        join: i in assoc(m, :instance),
        # Skip rows that have both announcements already posted —
        # cheap filter for the common steady state.
        where: is_nil(m.announced_registration_at) or is_nil(m.announced_live_at),
        preload: [instance: [:scenario, :factions]]
      )

    for match <- Repo.all(query) do
      LegacyMatch.maybe_announce(match, :registration)
      LegacyMatch.maybe_announce(match, :live)
    end
  end

  # Find matches whose start time is within 6 hours from now (or past)
  # AND aren't yet active AND aren't ended. Activate + bulk sync each
  # one. The operator-entered announced_start_at (from the /promote
  # modal) is authoritative when present; opening_date is the fallback.
  defp activate_due_matches do
    threshold = DateTime.add(DateTime.utc_now(), @lead_seconds, :second)

    query =
      from(m in Match,
        join: i in assoc(m, :instance),
        where: m.role_assignment_active == false,
        where: coalesce(m.announced_start_at, i.opening_date) <= ^threshold,
        where: i.state != "ended",
        preload: [instance: [:factions]]
      )

    for match <- Repo.all(query) do
      Logger.warning(
        "[RC.Discord.RoleSync] activating match for instance ##{match.instance.id} " <>
          "(opening_date #{match.instance.opening_date}); doing bulk sync"
      )

      # mark_active MUST run before bulk_sync_match. reconcile_account_in_instance/2
      # gates on `role_assignment_active = true` (re-queried from the DB), so if we
      # bulk-synced first every reconcile would silently no-op and only players who
      # registered AFTER this tick would get their roles via the event-driven path.
      mark_active(match, true)
      bulk_sync_match(match)
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

  defp bulk_sync_match(%Match{instance: %{id: instance_id}}) do
    # Pull every account that has any registration in this instance,
    # then reconcile each one. Reconciliation walks all factions in
    # the instance and ensures the account has exactly the right
    # role set — including removing stale roles for factions the
    # player isn't currently in.
    account_ids =
      from(r in Registration,
        join: f in assoc(r, :faction),
        join: p in assoc(r, :profile),
        where: f.instance_id == ^instance_id,
        distinct: true,
        select: p.account_id
      )
      |> Repo.all()

    Logger.info("[RC.Discord.RoleSync] bulk sync: #{length(account_ids)} accounts in instance ##{instance_id}")

    # One guild-roles fetch for the whole roster, and each account in
    # its own rescue — a raising API call for one member must not
    # strand everyone after them in the list (the bulk sync at
    # activation runs exactly once).
    with {:ok, _guild_id, _roles_by_name} = ctx <- guild_context() do
      for account_id <- account_ids do
        safely("bulk reconcile account #{account_id} in instance ##{instance_id}", fn ->
          reconcile_account_in_instance(account_id, instance_id, ctx)
        end)
      end

      :ok
    end
  end

  # --- Single-registration sync (event-driven) -----------------------

  # `sync_for_registration/1` is the natural API for hooks in
  # `RC.Registrations.register_profile/3` and `transition_to/2` —
  # they have a registration id but not necessarily (account_id,
  # instance_id) handy. We resolve those here and delegate to the
  # reconciliation primitive. This handles the faction-switch case
  # correctly: if player A had reg in Cardan, then switches to
  # Tetrarchy, reconciliation removes Cardan's role and adds
  # Tetrarchy's because it walks ALL factions for the instance.
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

      is_nil(reg.profile) ->
        :ok

      true ->
        reconcile_account_in_instance(reg.profile.account_id, reg.faction.instance_id)
    end
  end

  # --- Account-wide sync (used by /link) -----------------------------

  # When a player just linked, walk every active match that contains
  # any registration for them and reconcile each one. Handles the
  # case where they registered first, linked second — the link is
  # what tells us their Discord identity.
  defp do_sync_account(account_id) do
    instance_ids =
      from(r in Registration,
        join: p in assoc(r, :profile),
        join: f in assoc(r, :faction),
        join: m in Match,
        on: m.instance_id == f.instance_id,
        where: p.account_id == ^account_id,
        where: m.role_assignment_active == true,
        distinct: true,
        select: f.instance_id
      )
      |> Repo.all()

    for instance_id <- instance_ids do
      reconcile_account_in_instance(account_id, instance_id)
    end

    :ok
  end

  # --- The reconciliation primitive (core of everything) -------------

  # For one (account, instance) pair, walk every faction in the
  # instance:
  #   - If the account has a current registration to THIS faction
  #     in an active state (joined / playing), add that faction's
  #     Discord role.
  #   - Otherwise, remove that faction's role.
  #
  # Effect: stale roles from factions the player switched OUT of
  # are removed, the current faction's role is present. Idempotent
  # — running twice is safe.
  defp reconcile_account_in_instance(account_id, instance_id, ctx \\ nil) do
    match = Repo.get_by(Match, instance_id: instance_id, role_assignment_active: true)

    cond do
      is_nil(match) ->
        # Either not promoted, or not yet in the active window. Do
        # nothing — the periodic tick will pick this up at T-6h.
        :ok

      true ->
        with %Account{discord_id: discord_id} <- Repo.get(Account, account_id),
             false <- is_nil(discord_id) do
          do_reconcile(account_id, instance_id, discord_id, ctx)
        else
          _ -> :ok
        end
    end
  end

  # `ctx` is a prefetched `guild_context/0` result (bulk paths share
  # one guild-roles fetch across the roster); nil = fetch our own.
  defp do_reconcile(account_id, instance_id, discord_id, ctx) do
    with {:ok, guild_id, roles_by_name} <- ctx || guild_context() do
      # Two queries instead of one with a subquery-in-join: Ecto
      # doesn't allow subqueries in `on:` clauses. Q1 lists every
      # faction in the instance; Q2 lists this account's
      # registration state in that instance, keyed by faction_ref.
      # Then we merge in Elixir.
      faction_refs =
        from(f in Faction,
          where: f.instance_id == ^instance_id,
          select: f.faction_ref
        )
        |> Repo.all()

      states_by_faction_ref =
        from(r in Registration,
          join: f in assoc(r, :faction),
          join: p in assoc(r, :profile),
          where: f.instance_id == ^instance_id,
          where: p.account_id == ^account_id,
          select: {f.faction_ref, r.state}
        )
        |> Repo.all()
        # Multiple rows per faction if the player has multiple
        # profiles registered (uncommon but possible). Reduce to
        # "best" registration state: active beats inactive.
        |> Enum.group_by(fn {ref, _} -> ref end, fn {_, state} -> state end)
        |> Map.new(fn {ref, states} ->
          best =
            cond do
              Enum.any?(states, &(&1 in @active_registration_states)) -> :active
              true -> :inactive
            end

          {ref, best}
        end)

      faction_role_states =
        Enum.map(faction_refs, fn ref ->
          role_id =
            case LegacyMatch.find_faction_role(ref, roles_by_name) do
              {:ok, id, _name} -> id
              {:ambiguous, [{_n, id} | _]} -> id
              _ -> nil
            end

          {ref, role_id, Map.get(states_by_faction_ref, ref, :none)}
        end)

      user_id = String.to_integer(to_string(discord_id))

      # Diff against the member's actual roles so reconciliation only
      # writes what changed — the drift pass touching every linked
      # member every 10 minutes must not turn into blind add/remove
      # calls for the whole roster.
      case NostrumGuild.member(guild_id, user_id) do
        {:ok, member} ->
          plan = sync_plan(faction_role_states, member.roles || [])

          for {faction_ref, role_id} <- plan.add,
              do: add_role(guild_id, discord_id, role_id, faction_ref)

          for {faction_ref, role_id} <- plan.remove,
              do: remove_role(guild_id, discord_id, role_id, faction_ref)

          :ok

        {:error, %{status_code: 404}} ->
          # Not being in the guild is the normal case for a chunk of
          # the player base — nothing to reconcile.
          :ok

        {:error, reason} ->
          Logger.warning(
            "[RC.Discord.RoleSync] member fetch failed for account #{account_id}: " <>
              RC.Discord.format_api_error(reason)
          )
      end
    end
  end

  @doc """
  Pure diff planner (public for tests). Given per-faction
  `{faction_ref, role_id | nil, :active | :inactive | :none}` tuples
  and the member's current role ids, returns
  `%{add: [{ref, role_id}], remove: [{ref, role_id}]}` — only the
  writes needed to make the member's faction roles match their
  registrations. Factions whose role could not be resolved are
  skipped (the missing-role warning fires at lookup time).
  """
  def sync_plan(faction_role_states, member_role_ids) do
    member = MapSet.new(member_role_ids)

    {add, remove} =
      Enum.reduce(faction_role_states, {[], []}, fn
        {_ref, nil, _state}, acc ->
          acc

        {ref, role_id, :active}, {add, remove} ->
          if MapSet.member?(member, role_id),
            do: {add, remove},
            else: {[{ref, role_id} | add], remove}

        {ref, role_id, _inactive_or_none}, {add, remove} ->
          # :inactive (resigned/dead) OR :none (not registered) — both
          # mean the player should NOT carry this faction's role.
          if MapSet.member?(member, role_id),
            do: {add, [{ref, role_id} | remove]},
            else: {add, remove}
      end)

    %{add: Enum.reverse(add), remove: Enum.reverse(remove)}
  end

  defp add_role(guild_id, discord_id, role_id, faction_ref) do
    case NostrumGuild.add_member_role(guild_id, String.to_integer(to_string(discord_id)), role_id) do
      {:ok} ->
        Logger.info("[RC.Discord.RoleSync] added '#{faction_ref}' role to #{discord_id}")

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.RoleSync] failed to add '#{faction_ref}' role to #{discord_id}: " <>
            RC.Discord.format_api_error(reason)
        )
    end
  end

  defp remove_role(guild_id, discord_id, role_id, faction_ref) do
    case NostrumGuild.remove_member_role(guild_id, String.to_integer(to_string(discord_id)), role_id) do
      {:ok} ->
        Logger.info("[RC.Discord.RoleSync] removed '#{faction_ref}' role from #{discord_id}")

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RC.Discord.RoleSync] failed to remove '#{faction_ref}' role from #{discord_id}: " <>
            RC.Discord.format_api_error(reason)
        )
    end
  end

  # --- Helpers -------------------------------------------------------

  defp guild_context do
    case RC.Discord.community_guild_id() do
      nil ->
        Logger.warning("[RC.Discord.RoleSync] no community guild configured; skipping sync")
        {:error, :no_guild}

      guild_id ->
        case NostrumGuild.roles(guild_id) do
          {:ok, roles} ->
            {:ok, guild_id, Map.new(roles, fn r -> {r.name, r.id} end)}

          {:error, reason} ->
            Logger.warning("[RC.Discord.RoleSync] could not fetch guild roles: #{inspect(reason)}")
            {:error, :roles_unavailable}
        end
    end
  end
end
