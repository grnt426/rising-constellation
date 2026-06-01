# Stage 7 — GenServer crash resilience (report)

## Top-line

- **29 candidates, 26 survived 2-vote verify, 3 partial (1/2 vote), 0 refuted.**
- Severity breakdown (surviving + partial, 29 total):
  - Critical: 1
  - High: 9
  - Medium: 10
  - Low: 6
  - Partial (split verdict): 3
- **Executive summary of the worst chain.** A fully verified poison-pill / supervision-cascade chain that, with a single crash-deterministic value placed in any one of ~10 per-instance GenServer types (`Player.Agent`, `Faction.Agent`, `Character.Agent`, `StellarSystem.Agent`, `Galaxy.Agent`, `Time.Agent`, `Rand.Agent`, `Victory.Agent`, `CharacterMarket.Agent`, `ActionOrchestrator.Agent`), can take down an entire instance permanently and — under sustained pressure — the whole BEAM node. The chain is:

  1. **F11 (critical, `tick_server.ex:65-76`)** — `Core.TickServer.terminate/2` writes the dying agent's state back into `Horde.Registry` CRDT meta on every reason except `{:shutdown, %{kill: true}}`. The next restart reads it back via `load_state/1` (lines 109-121) and crashes again on the same value. There is no validation, no crash counter, no quarantine.
  2. **F5 / F12 (`tick_server.ex:70-76`)** — Each `terminate/2` then sleeps 10 seconds **unconditionally**. With `Instance.Supervisor` using the OTP default `max_restarts: 3 / max_seconds: 5`, the 10s sleep is wider than the 5s window so the supervisor's circuit breaker can NEVER fire — restarts happen forever, silently.
  3. **F13 (`supervisor.ex:40-73`)** — When `Instance.Supervisor` itself does eventually go down, `continue/2` re-reads `Data.GenServerState.list(instance_id)` from the Horde Registry CRDT and tries to start every saved agent again with the same poisoned state. There is no skip-after-N-failures.
  4. **F15 (`data/genserver_state.ex:5-9, 55-70`)** — Saved state lives in the Horde DeltaCRDT, `members: :auto`. Every node that joins replicates the poison. **Pod restart, rolling deploy, and node replacement do not clear it.** Recovery requires an operator to know about `Data.GenServerState.clear/1` and use it from a remote IEx.
  5. **F1 + F3 + F14 (supervision-topology)** — The default `3 in 5s` budget on every supervisor in the tree (`Instance.Supervisor`, `Game.Supervisor`, `Game`, `RC.Supervisor`) means the cascade walks all the way up to BEAM exit if the 10s sleep ever fails to mask the crash window.
  6. **F6 + F7 + F8 (crash-cascades)** — `Game.call` (`lib/game.ex:90`) is a bare `GenServer.call` with no try/catch. 232 cross-agent call sites mean a single leaf-agent crash propagates synchronously up through Galaxy/Faction/Player.Agent, and through into the Phoenix channel process at `join/3` and `handle_info(:after_join, …)` since those are not wrapped (Stage 4 H7 only protected `handle_in`).

  **Independently exploitable vs. amplifier?**

  - **F11 is the load-bearing root cause.** Without F11, F13/F15/F12 lose almost all their teeth — there is no poison to replicate or rehydrate.
  - **F6 (no `catch :exit` in Game.call) is independently severe** even without F11 — it permits a single crash to take down 3+ processes per request, killing per-instance singletons and breaking Phoenix channels at the join layer.
  - **F1 / F3 / F14 (default supervisor budgets)** are amplifiers, not roots. Fixing them is also extremely cheap and provides defense-in-depth.
  - **F12 (terminate sleep ≥ max_seconds)** is structurally critical: it silently disables the supervisor's max-restarts circuit-breaker.
  - **F4 (ChannelWatcher Process.link)** is independently exploitable — a single watcher crash takes every linked Phoenix channel down with it.
  - State-recovery (F10, F16, F26) and observability (F22, F20, F23, F24, F25) are independent quality / data-integrity bugs.

## Cluster summaries

### Cluster A — Supervision topology / restart-budget defaults

Every supervisor in the tree (`RC.Supervisor`, `Game`, `Game.Supervisor` Horde, `Instance.Supervisor`, `Spatial.Supervisor`) inherits the OTP default `max_restarts: 3, max_seconds: 5`. Combined with: a flat `Instance.Supervisor` containing thousands of permanent agents under a single `:one_for_one`; a 10s `Process.sleep` in every TickServer's `terminate` that exceeds the 5s window; and a child `Spatial.Supervisor` co-locating DeltaCrdt + DynamicRtree + Spatial.Handoff, the topology can neither absorb routine flapping nor cleanly escalate to operators.

**Fix order:** F1 first (split `Instance.Supervisor` into per-aggregate sub-supervisors), then F14 (add explicit `max_restarts/max_seconds` to every supervisor), then F3/F2 (tune the Horde + Application supervisors specifically), then F5 (re-shape Instance.Manager.terminate so it doesn't add to shutdown delay). Once F11+F12 are fixed, F1/F3/F14 stop being acute and become defense-in-depth.

**Findings:** F1, F2, F3, F4, F5, F14, F27 (partial)

### Cluster B — State-rehydration crash loop (terminate writes bad state back)

The single most damaging defect class. `Core.TickServer.terminate/2` saves any state to the Horde Registry CRDT regardless of exit reason. `load_state/1` rehydrates it verbatim on restart, with no struct validation, no crash counter, no quarantine. Save-state writes are mirrored cluster-wide via DeltaCRDT, so pod replacement / node restart does not clear poison. Combined with the 10s sleep in terminate making the supervisor's max_restarts window unreachable, a single bad value crash-loops forever without operator alert.

**Fix order: F11 first** (don't save on crash reasons — distinguish `:shutdown`/`:normal` from everything else). That single change makes F12, F13, F15, F16 mostly go away. Then F13 (skip-after-N + try/rescue per child in `continue/2`), then F15 (crash counter and saved_at timestamps in `Data.GenServerState`), then F16 (validate struct shape in `load_state`), then F17 (cap CRDT scan size).

**Findings:** F11 (critical), F12, F13, F15, F16, F17, F18

### Cluster C — Synchronous Game.call cascades (no `catch :exit` anywhere)

`Game.call` at `lib/game.ex:90` is a bare `GenServer.call`. The codebase has 232 cross-agent call sites; none wraps it. A single crashed callee raises an `:exit` in the caller via `gen_server.erl`'s monitor logic — which `rescue` cannot catch, only `catch :exit, _`. A repo-wide grep for `catch.*:exit` returns zero matches. Per-instance singletons (Galaxy.Agent, Faction.Agent) are particularly exposed because their crash blocks every player in scope until restart. Phoenix channel `join/3` and `handle_info(:after_join, …)` (PlayerChannel, FactionChannel, GlobalChannel) all use bare `{:ok, x} = Game.call(...)` and so die on any callee crash — Stage 4 H7 only protected `handle_in`. Player.Agent ↔ Player.Agent cross-calls in `buy_offer` (and `transfer_offer`) create an actual two-process mutual deadlock with 5s timeout → both crash. Mid-call DB transitions persist while in-memory mutations are lost on restart → silent integrity gaps.

**Fix order: F6 first** (one-line try/catch in `Game.call` returning `{:error, :callee_crashed}`) — this single change fully isolates F7, F8, F9, F10 from cascade-style propagation. Then F7 (case-match join/after_join sites in channels), then F9 (Game.cast or dedicated Market.Agent serializer for buy_offer), then F10 (re-order buy_offer DB transition AFTER successful cross-calls). F18 also becomes a clean `{:error, :unknown}` once F6 is in place.

**Findings:** F6 (high), F7, F8, F9, F10, F18

### Cluster D — Trap-exit hygiene / silent-drop bugs

Multiple GenServers set `Process.flag(:trap_exit, true)` without a matching `handle_info({:EXIT, _, _}, state)` clause: `Core.TickServer` (every game agent), `Instance.Manager`, `Spatial.Handoff`. TickServer's default `on_info/2` catchall is `throw(:not_implemented)`, so any unhandled message — including future linked-Task EXITs, stray PubSub messages, debug `Process.send(pid, :hello)` — crashes the agent. `Portal.ChannelWatcher` actively silently drops Task EXIT messages from leave-callback failures (no log, no metric), so missed `:update_client_status :disconnect` calls leak `connected` status forever.

**Fix order:** F20 first (or drop `Process.link` for `Process.monitor` and switch `Task.start_link` to `Task.Supervisor.start_child`) → fixes F4 plus the silent leave-failure swallow. F19 (soft-fail TickServer `on_info` catchall to log+ignore). F21 (drop dead `trap_exit` in Manager/Handoff or add explicit clause). F29 (TickServer trap_exit + catchall — same root issue as F19).

**Findings:** F4 (medium), F19, F20, F21, F29 (partial)

### Cluster E — State-recovery gaps independent of crash loop

Distinct from the F11 cluster: these are recovery gaps that bite during legitimate restarts, not crash loops. F22: a freshly-restarted agent's tick is never re-armed (`handle_continue(:load_state)` does not call `next_tick`) — offline players get zero resource accumulation between a crash and reconnect. F23: `Instance.Manager.init/1` returns empty state with no rehydration, so a crash mid `init_from_model` leaves orphan children running with no way to recover except admin destroy. F26 / F28 (partial): hard BEAM crash wipes all in-memory Horde Registry meta; admin snapshots are operator-triggered only, autosave runs only on `:slow` instances, and `Instance.Supervisor.continue/2` silently no-ops when the CRDT is empty (DB row still says `:running` while no agents exist).

**Fix order:** F26/F28 — add CRITICAL alert in `continue/2` when DB-marked-running instance has empty saved-state list (the only genuinely missing piece, since slow-instance autosave already exists). F22 — call `next_tick` in `handle_continue` after `load_state` when `state.tick.running?`. F23 — wrap `init_from_model` in try/rescue with cleanup; add consistency probe to `:start`.

**Findings:** F22, F23, F26, F28 (partial)

### Cluster F — Orphan tasks / observability gaps / Phoenix-edge resilience

No `Task.Supervisor` exists anywhere in the application tree (repo-wide grep: 0 matches). Stray `Task.start` is scattered through: autosave in `Time.Agent` (can leave instance stopped if it dies between `:stop` and `:start`), maintenance LiveView (admin closes browser → no progress feedback, no idempotency), ReplayRecorder inner spawn (silently swallows raises), `socket.ex` gc helper. F24 (low): `put_instance_supervisor_status` runs `Game.call_no_log` per row in `Enum.map` with default 5s timeout — one hung Time.Agent makes the entire admin instance list 500.

**Fix order:** F25 — add `{Task.Supervisor, name: RC.TaskSupervisor}` to RC.Application and replace `Task.start` with `Task.Supervisor.start_child`. F24 — pass `timeout: 500` and wrap in try/catch :exit → `:unknown` (becomes free with F6 in place).

**Findings:** F24, F25

## Full finding list

| #  | Sev | Lens | File:line | Title | Cluster |
|----|-----|------|-----------|-------|---------|
| F1 | high | supervision-topology | `lib/game/instance/supervisor.ex:37` | Instance.Supervisor flat :one_for_one + default 3/5s — single bad agent kills whole instance | A |
| F2 | medium | supervision-topology | `lib/rc/application.ex:42` | RC.Supervisor default 3/5s over Portal.Endpoint + Repo — startup-time DB failure tears whole BEAM | A |
| F3 | high | supervision-topology | `lib/game.ex:21` | Game.Supervisor (Horde) default 3/5s — quorum churn restarts a few Instance.Supervisors then takes whole Horde down | A |
| F4 | medium | supervision-topology | `lib/portal/channels/channel_watcher.ex:26` | ChannelWatcher uses Process.link (symmetric) — watcher crash kills every linked channel, every connected player | D |
| F5 | low | supervision-topology | `lib/game/instance/time/time.ex:75` | Unsupervised `Task.start` in autosave/maintenance/replay/socket — stray crashes silently swallowed, autosave-mid-flight leaves instance stopped | F |
| F6 | high | crash-cascades | `lib/game.ex:76-104` | No `catch :exit` around any Game.call — every cross-agent call is a cascade point (232 call sites, 0 wrappers) | C |
| F7 | high | crash-cascades | `lib/portal/channels/controllers/player_channel.ex:17,18,61,79` | Channel join/after_join handlers use bare `{:ok, x} = Game.call` — channel dies on any agent crash | C |
| F8 | high | crash-cascades | `lib/game/instance/faction/agent.ex:19,34-35; lib/game/instance/galaxy/agent.ex:36,46,60` | Faction.Agent + Galaxy.Agent are per-instance singletons that crash on any downstream Game.call exit | C |
| F9 | medium | crash-cascades | `lib/game/instance/player/agent.ex:661 (and market.ex:260,277)` | Player.Agent ↔ Player.Agent cross-call enables synchronous deadlock + double crash on simultaneous buy_offer | C |
| F10 | medium | crash-cascades | `lib/game/instance/player/market.ex:78-86, 269-286; agent.ex:658-672` | DB offer transitioned to 'sold' BEFORE seller Game.call — cascade-crash leaves stuck-sold rows with no buyer/seller payout | C |
| F11 | critical | crash-loop-stickiness | `lib/game/core/tick_server.ex:65-76, 109-121` | terminate/2 saves crash-state, load_state restores it — guaranteed crash-loop poison pill across all 10 agent types | B |
| F12 | high | state-recovery | `lib/game/core/tick_server.ex:70-76` | 10s sleep in terminate disables max_restarts circuit-breaker — crash loop never escalates, never alerts | B |
| F13 | high | crash-loop-stickiness | `lib/game/instance/supervisor.ex:40-73` | Instance.Supervisor.continue replays every saved state on cold start with no try/rescue, no skip-after-N | B |
| F14 | high | crash-loop-stickiness | `lib/game.ex:18-36; lib/game/instance/supervisor.ex:36-38; lib/game/spatial/spatial_supervisor.ex:32-36; lib/rc/application.ex:42` | Every supervisor uses default 3-in-5s — no max_restarts override anywhere in repo | A |
| F15 | high | crash-loop-stickiness | `lib/data/genserver_state.ex:5-9, 55-70` | Saved-state poison replicates cluster-wide via Horde Registry DeltaCRDT — node restart does not clear it | B |
| F16 | low | state-recovery | `lib/game/core/tick_server.ex:70-76` | terminate's `Core.GenState.registry_name(state)` raises KeyError on malformed state — skips the very save that would recover, leaves blob stuck | B |
| F17 | medium | crash-loop-stickiness | `lib/game/instance/supervisor.ex:40-72` | continue does not bound size/count of replayed agents; one big instance + 10s terminate sleeps stalls recovery for minutes | B |
| F18 | medium | crash-loop-stickiness | `lib/game/core/tick_server.ex:70-76` | terminate sleeps 10s on every shutdown (incl :normal), amplifying restart-storm windows + saves state for operator-killed agents | B/C |
| F19 | low | trap-exit-hygiene | `lib/game/core/tick_server.ex:52-63, 171` | TickServer catch-all `on_info` `throw(:not_implemented)` turns ANY unexpected info message into a crash | D |
| F20 | medium | trap-exit-hygiene | `lib/portal/channels/channel_watcher.ex:41-50` | ChannelWatcher silently swallows leave-callback Task EXIT failures — leaks 'connected' status forever | D |
| F21 | low | trap-exit-hygiene | `lib/game/spatial/handoff.ex:7; lib/game/instance/manager.ex:201` | Spatial.Handoff + Instance.Manager set trap_exit with no `{:EXIT, _, _}` clause — dead code now, footgun later | D |
| F22 | medium | state-recovery | `lib/game/core/tick_server.ex:13-21, 80-94` | Restarted agent's tick scheduler is silently dead until external interaction — offline players accrue zero resources | E |
| F23 | low | state-recovery | `lib/game/instance/manager.ex:199-205, 270-427` | Manager has no state recovery — crash mid init_from_model leaves zombie instance with orphan children, `created?` blocks retry | E |
| F24 | medium | crash-cascades | `lib/rc/instances.ex:259, 319, 370, 391, 506, 532-544` | Per-row Game.call_no_log in `put_instance_supervisor_status` — single hung Time.Agent → admin instance list 500s after 5s × N | F/C |
| F25 | low | supervision-topology | `lib/game/instance/time/time.ex:75; lib/portal/live/admin/maintenance_live.ex:44,90; lib/portal/channels/replay_recorder.ex:73; lib/portal/channels/socket.ex:34` | Stray Task.start in 4 hot paths runs without Task.Supervisor — orphan PIDs, silent autosave failures | F |
| F26 | low | crash-cascades | `lib/game/core/tick_server.ex:13-14, 52-63, 132-135, 171` | trap_exit + default handle_info catchall throws on stray EXIT — stray Process.send crashes agents | D |
| F27 (partial) | medium | supervision-topology | `lib/game/spatial/spatial_supervisor.ex:32` | Spatial.Supervisor :one_for_one — DDRT crash silently drops spatial index, next visibility query returns [] | A |
| F28 (partial) | medium | state-recovery | `lib/data/genserver_state.ex:5-9` | Agent state saved only in in-memory Horde CRDT — hard BEAM crash silently rewinds every empire to last admin snapshot | E |
| F29 (partial) | high | trap-exit-hygiene | `lib/game/core/tick_server.ex:13-16, 52-63, 171` | TickServer trap_exit self-defeating: future Task.start_link would crash agents via on_info throw | D |

### Duplicates / overlaps

- **F19 + F26 + F29 partial** — same root cause: TickServer's `on_info` catchall throws. One fix closes all three.
- **F11 + F12 + F15 + F16** — facets of the same root cause. One fix in `terminate/2` (gate on `:shutdown`/`:normal`) eliminates F11's poison pill, makes F12's restart-budget-bypass moot, eliminates F15's cluster-wide replication, fixes F16's KeyError.
- **F1 + F3 + F14** — same default-budget issue at different tree levels. One fix is "set explicit `max_restarts/max_seconds` everywhere" — though F1 also wants the topology split.
- **F6 + F7 + F8 + F24** — same `Game.call` cascade. One fix in `Game.call` cleans up F7's channel-edge, F8's faction-wide cascade, F24's listing degradation. F9/F10 still need their own ordering fix.
- **F5 + F25** — both flag the missing `Task.Supervisor`. F25 is the implementation-specific version.
- **F4 + F20** — same ChannelWatcher refactor.

## Recommended fix scope

### Tier 1 — must-fix before release (the critical / node-killer findings)

| # | File | Change |
|---|------|--------|
| F11 | `lib/game/core/tick_server.ex:65-76` | In `terminate/2`, only save state when reason is `:normal`/`:shutdown`/`{:shutdown, _}`. On any other reason (crash), log + delete the registry entry + exit fast. Single change disables F11 as a poison pill, eliminates F15's CRDT-replicated stickiness, makes F13's `continue/2` replay safe-by-construction, removes F16's terminate-self-crash hazard. |
| F6 | `lib/game.ex:76-104` | Wrap `GenServer.call` in `try/catch :exit` returning `{:error, :callee_crashed}`. Eliminates the cross-agent cascade for all 232 call sites. |
| F12 | `lib/game/core/tick_server.ex:70-76` (and `manager.ex:208-210`, `handoff.ex:23-36`) | Gate `Process.sleep(10_000)` to `:shutdown`/`:normal` reasons only. On crash reasons, return immediately so the supervisor's `max_restarts` window actually accumulates. |
| F14 | `lib/game.ex:15`, `lib/game.ex:21-28`, `lib/game/instance/supervisor.ex:36-38`, `lib/rc/application.ex:42`, `lib/game/spatial/spatial_supervisor.ex:32-36` | Add explicit `max_restarts/max_seconds` to every supervisor. Suggested: Instance.Supervisor `100/60`, Game.Supervisor (Horde) `50/60`, top-level Game and RC.Supervisor `10/60`. |

### Tier 2 — should-fix before release (high-severity cascades and channel-edge resilience)

| # | File | Change |
|---|------|--------|
| F7 | PlayerChannel, FactionChannel, GlobalChannel `join/3` + `handle_info(:after_join, …)` | Replace bare `{:ok, x} = Game.call(...)` with `case Game.call(...) do {:ok, x} -> ... ; _ -> {:error, %{reason: "instance_unavailable"}}`. Auto-cleans up once F6 is in. |
| F4 + F20 | `lib/portal/channels/channel_watcher.ex` | Switch `Process.link` → `Process.monitor`. Switch `Task.start_link` → `Task.Supervisor.start_child(RC.TaskSupervisor, ..., restart: :temporary)`. Wrap MFA apply in try/rescue with `Logger.error`. Add periodic `Process.alive?` sweep of `state.channels`. |
| F1 | `lib/game/instance/supervisor.ex` | Split into per-aggregate sub-supervisors (Players, Characters, StellarSystems, Infrastructure). Top-level becomes `:rest_for_one` over those. Deferrable since F14 widens the budget. |
| F3 | `lib/game.ex:21` | F14 already widens this — Tier 2 ensures the Horde-specific budget value is right for expected per-node instance count. |
| F13 | `lib/game/instance/supervisor.ex:40-73` | Wrap each `start_child` in try/catch and skip on first-start failure. Belt-and-suspenders against a single bad blob taking down the whole recovery. |
| F8 | `lib/game/instance/faction/agent.ex`, `lib/game/instance/galaxy/agent.ex` | Wrap downstream Game.calls in case-match on `{:error, _}`. Auto-cleans up once F6 is in. |
| F25 | `lib/rc/application.ex`, `lib/game/instance/time/time.ex:75`, `lib/portal/live/admin/maintenance_live.ex:44,90`, `lib/portal/channels/replay_recorder.ex:73` | Add `{Task.Supervisor, name: RC.TaskSupervisor}` to the supervision tree. Replace stray `Task.start`/`spawn` with `Task.Supervisor.start_child(RC.TaskSupervisor, ..., restart: :temporary)`. Wrap autosave body in try/rescue with fail-open `Manager.call(:start)`. |
| F9 + F10 | `lib/game/instance/player/agent.ex:658-672`, `lib/game/instance/player/market.ex:78-86, 269-286` | Re-order `buy_offer` so DB transition to `'sold'` happens AFTER cross-agent Game.calls succeed. Or wrap the whole flow in try/rescue with `revert_status` on failure. For F9 specifically, convert seller-credit application to `Game.cast`, or introduce a dedicated `Market.Agent` per instance. |
| F24 | `lib/rc/instances.ex:532` | Pass `timeout: 500` to `Game.call_no_log`. Wrap in try/catch :exit → `:unknown`. Becomes automatic once F6 is in. |
| F28 partial follow-on | `lib/game/instance/supervisor.ex` `continue/2` | Add CRITICAL alert when DB-marked-running instance has empty saved-state list. |

### Tier 3 — defer (low/info, hygiene, or transitively mitigated)

| # | File | Notes |
|---|------|-------|
| F19 + F26 + F29 partial | `lib/game/core/tick_server.ex:52-63, 169-171` | Soften `on_info` catch-all to `Logger.warning(...)` + `{:noreply, state}`. Add explicit `handle_info({:EXIT, _, _}, state)` clause. Cheap, real, but no active exploit today since no agent uses `Process.link`/`spawn_link`. |
| F21 | `lib/game/spatial/handoff.ex:7`, `lib/game/instance/manager.ex:201` | Drop dead `Process.flag(:trap_exit, true)` (or add explicit `{:EXIT, _, _}` log clause). |
| F22 | `lib/game/core/tick_server.ex:13-21, 80-94` | Call `next_tick(state)` in `handle_continue(:load_state)` after `load_state` returns when `state.tick.running?` is true. QoS bug, cheap to fix. |
| F23 | `lib/game/instance/manager.ex:199-205, 270-427` | Wrap `init_from_model` in try/rescue with cleanup of partial children. Add consistency probe to `:start`. Cleanup cost > likelihood. |
| F2 | `lib/rc/application.ex:42` | Already covered by Tier 1 F14. |
| F5 | covered by F25 | Adding `RC.TaskSupervisor` subsumes this. |
| F16 | `lib/game/core/tick_server.ex:70-76` | Once F11 is fixed, `terminate` no longer runs the registry-name code on crash paths — F16 hazard disappears. Optional: add `is_struct(state_to_restore, Core.GenState)` check in `load_state`. |
| F17 | `lib/game/instance/supervisor.ex:40-72` | Once F11 + F25 + F14 are in, multi-minute recovery collapses. Optional follow-up: `Task.async_stream` with concurrency cap. |
| F18 | `lib/game/core/tick_server.ex:70-76` | Same fix as F12 (gate `Process.sleep` on `:shutdown`/`:normal`). |
| F27 partial | `lib/game/spatial/spatial_supervisor.ex:32` | Change to `:rest_for_one`; add `handle_continue(:reload, _)` in `Spatial.Handoff`; add periodic snapshot. Real defect, low urgency. |
| F28 partial autosave gap | `lib/data/genserver_state.ex:5-9` | Periodic snapshotter for non-`:slow` speeds — depends on game-mode product call. |

### Open / ambiguous points

- **F1's split of `Instance.Supervisor` into per-aggregate sub-supervisors** is a non-trivial refactor touching `Instance.Manager.create/destroy`, the `start_child` calls at lines 309/315/321/372/378/386/393/408/490/551, and the `continue/2` rehydration loop. Tier 1 F14 widens the budget so a split is safely deferrable, but the long-term resilience target requires it.
- **F9's "convert seller credit to Game.cast"** depends on whether eventual consistency is acceptable for resource transfers. Asynchronous credit application may produce briefly inconsistent balances the buyer can observe. Alternative: dedicated `Market.Agent` per instance.
- **F28 partial autosave coverage**: `Time.Agent.update_next_autosave` IS a periodic snapshotter, but only fires on `speed: :slow` + `is_running: true`. Needs product call on whether `:fast` instances need an equivalent loop.
- **F27 partial (Spatial.Supervisor)** — voters split on whether visibility-loss-on-DDRT-crash is a security finding vs. gameplay-resilience. Apply the structural fix (`:rest_for_one` + handle_continue rehydrate) as defense-in-depth regardless.
- **F29 partial** is the same observation as F19 + F26 from different lenses. Roll into the F19/F26 fix and close.

### Summary fix-order recap

If you can only do four things before release, do:

1. **F11 fix** — gate `terminate` save on `:normal`/`:shutdown` (poison pill goes away)
2. **F12 fix** — gate `Process.sleep` in `terminate` on `:normal`/`:shutdown` (circuit breaker can fire)
3. **F6 fix** — try/catch `:exit` in `Game.call` returning `{:error, :callee_crashed}` (cascades contained)
4. **F14 fix** — explicit `max_restarts/max_seconds` on every supervisor (cascade-to-BEAM closed)

Those four close the whole-node DoS chain. Tier 2 (eight more fixes) hardens the channel edge and per-instance singletons. Tier 3 (six more fixes) is hygiene that becomes much easier after Tier 1+2 land.
