# Security audit — state summary

Compact log of what's been audited and fixed. Used to rehydrate context across stages without dragging the full chat through each prompt.

## Stage results (counts after 2-vote adversarial verify)

| Stage | Scope | Crit | High | Med | Low | Info | Refuted |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Auth boundary (JWT, login, cookies, Steam) | 1 | 7 | 3 | 4 | 2 | – |
| 2 | Authorization plugs (HTTP) | 1 | 8 | 3 | 5 | 2 | – |
| 3 | Channel join + topic isolation | 1 | 3 | 2 | 2 | – | – |
| 4 | Game actions (PlayerChannel handle_in) | 5 | 8 | 2 | 4 | 1 | 1 |
| 5 | HTTP resource APIs | 0 | 6 | 7 | 8 | – | 1 |
| 6 | Admin surface | 3 | 10 | 7 | 4 | – | – |
| 7 | GenServer crash resilience | 1 | 9 | 10 | 6 | – | 0 |
| 8 | Info disclosure | 0 | 2 | 6 | 1 | – | 2 |
| **Total** | | **12** | **53** | **40** | **34** | **5** | **4** |

Stage 7 also produced 3 partial findings (1 of 2 votes) — see `docs/stage-7-report.md` Cluster A/D/E for disposition. Stage 8 produced 3 partial findings — see `docs/stage-8-report.md` Cluster F/G/H (largely overlaps of the same root causes from different lenses).

## Fixes landed

All criticals (11) + most highs (~33 of 42). Specifics:

- **Stage 1**: Steam verified-steamid, banned-account gate, 24h JWT TTL, `accounts.token_version` for per-account revocation, registration-token rotation on resigned/dead, Hammer login + password-reset rate limits, `check_origin` removed from prod, cookie `Secure`+`SameSite`+`HttpOnly`+HSTS, separate `:auth_api` plumbing (currently aliased to `:auth` pending SPA Bearer switch).
- **Stage 2**: `Portal.Plug.Authorization` reads `conn.path_params` (closes `?pid=<own>` injection); split changesets for Profile/Instance/BlogPost; new `:fid`/`:upid`/`:bpid` plug clauses + folder/upload/blog-post routes moved into `:own_resource_authorization`; `RegistrationView` strips token from index; `create_conv_group` requires `registered_in_faction?`; tutorial route moved into `:own_resource`.
- **Stage 3**: `Registrations.valid?/3` binds token to JWT account; `portal:instance:<iid>` join requires `own_instance?` or admin; tutorial-mode channel joins verify `own_profile?(galaxy.tutorial_id)`.
- **Stage 4**: faction chat author server-derived; atomic offer state machine via `RC.Offers.transition_status/3`; `hire_character` derives costs from canonical `%Character{}`; `place_offer` requires `is_integer(amount) and amount > 0`; `Player.Agent {:try_debit_send, …}` is atomic; WS `:max_frame_size: 64_000`; `record` macro try/rescue + skip error rows.
- **Stage 5 (Bucket 1+2)**: Scrivener `max_page_size: 200`; `Account.password` 8–128; `Upload.name` ≤ 200; `RC.DisplayName` Unicode/bidi filter on all name+title fields; Markdown protocol-relative URL upgrade; profile-search Hammer; `BlogPost.content_raw` ≤ 200 KB; messenger `profiles_ids` ≤ 100. Plug.Parsers length lowered to 50 MB.
- **Stage 6 (Cluster A+B+C+E)**: `Portal.AdminAuth.on_mount` + `live_session :admin` + same `on_mount` on `live_dashboard`; `Account.changeset_admin` (no `:password` / `:steam_id`); `Accounts.admin_update_account/3` blocks peer-admin; `Group.changeset` no longer `cast_assoc`s nested accounts/instances; `Util.Storage.load` decodes with `:safe`; `Instance.Manager.@snapshot_allowed_modules` allow-list; snapshot handlers verify `snapshot.instance_id` matches target.
- **Stage 7 (Tier 1 + Tier 2)**: TickServer/Manager/Handoff `terminate/2` split — `:normal`/`:shutdown` save+sleep, crash reasons log+discard (closes F11 poison pill, F12 circuit-breaker bypass); `Game.call`/`call_no_log` wrap `GenServer.call` in try/catch `:exit` returning `{:error, :callee_crashed | :callee_timeout}` plus optional per-call timeout arg; explicit `max_restarts/max_seconds` on RC.Supervisor (10/60), Game (10/60), Game.Supervisor Horde (50/60), Instance.Supervisor (100/60), Spatial.Supervisor (50/60); PlayerChannel/FactionChannel/GlobalChannel join+after_join wrap Game.call in `with`/`case` → `"instance_unavailable"`; ChannelWatcher rewritten to use `Process.monitor` + `RC.TaskSupervisor`-dispatched leave callbacks + periodic alive sweep + try/rescue logging; `RC.TaskSupervisor` added to RC.Application and stray `Task.start`/`spawn` in Time autosave / MaintenanceLive restore+save / ReplayRecorder / Portal.Socket.gc / GenServerState.wait_and_clear migrated to it (autosave fail-open: try/rescue + best-effort `Manager.call(:start)`); Galaxy.Agent `claim_initial_system`/`claim_system`/`abandon_system` reject `{:error, _}`/`:process_not_found` returns from StellarSystem.Agent; Instance.Supervisor.continue/2 wraps each restore in try/rescue + drops poisoned blobs + emits `Logger.critical` when DB-running instance has empty CRDT (F28-partial alert); admin `put_instance_supervisor_status` uses 500ms timeout + `_other -> :unknown`; `buy_offer` wrapped in try/rescue with `revert_status("active")` on any escape; Player.Agent gains `on_cast({:add_resources, ...})` and the buy_offer seller-credit path now uses `Game.cast` (closes F9 Player ↔ Player deadlock).
- **Stage 8 (Tier 1 + Tier 2)**: `Instance.Faction.Character.obfuscate/3` accepts a `viewer_faction_key` arg + adds vis=1 anonymous tier (only `[:type, :level]`); recursive `Core.Value.details` strip in `obfuscate_army`/`_spy`/`_speaker` for non-own viewers (closes F4 doctrine/patent leak); `:action_status` dropped at vis=5 for non-own-faction viewers (F8); `Notification.Character.diff/4` forwards `viewer_faction_key`; conquest/raid/loot/conversion/encourage_hate/make_dominion attack notifications send the defender a vis=3 attacker_diff and the attacker still gets vis=5 with their own faction key (closes F2); fight.ex sends per-recipient `admirals` with own-faction at vis=5 and cross-faction at vis=3; assassination/sabotage undercover branch now uses vis=1 (closes F3 spy identity leak); AssassinationNotif.vue + SabotageNotif.vue render an "unknown spy" placeholder when `data.spy.current.name` is null + sabotage gets `defender_anonymous` locale variants (en/fr); colonization + infiltration attacker-only paths pass viewer_faction_key; `RC.PlayerStats.get_last_player_stat_by_instance_id/1` drops `stored_credit`/`output_credit`/`output_technology`/`output_ideology` from the player-facing SELECT (F1); `Faction.Agent` `sanitize_detected_objects/2` filters own-faction blips server-side and drops `character_id` before broadcasting (F5/F9), `map-data.js` updated; `Profile.elo` rounded in rankings_view + `Instance.Player.PublicPlayer.elo` rounded at construction (F6+F7); `StellarSystem.obfuscate/5` accepts + forwards `viewer_faction_key` and `Faction.Agent` `get_system_state`/`get_character_state` pass `state.data.key`.

## Tests

107 security regression tests across 10 files in `test/security/` (Stage 8 added `info_disclosure_test.exs` with 11 tests). Full suite: 521 tests, 1 pre-existing Waffle file-system flake unrelated to security fixes.

## Deliberately deferred

- **Stage 1 #14, 2 #14, 2 #15** (low/info): update_restricted deny-list pattern, admin? ignores status (handled in Stage 6 via on_mount status check).
- **Stage 5 deferred items**: `preview_edges` O(N²) (see `docs/preview-edges-proposal.md`), `Instance.game_data`/`metadata` size cap, `Account.settings` cap, `Fight` army caps, image pixel-dimension cap + ImageMagick `policy.xml` (latent — no ImageMagick installed), `/api/standings` LIMIT+cache, per-account upload quota.
- **Stage 6 Clusters D/F/G/H**: audit-trail-with-actor on logs/money_transactions, confirmation rails on destructive admin actions, LiveDashboard `ecto_repos` env-gating, dead routes / reserved-folder admin overrides.
- **Stage 4 H1–H6**: residual `handle_in` crash-by-payload family (mode atoms, action types, missing offer IDs). Partially mitigated by replay-recorder `try/rescue` in Stage 4 fix; the GenServer crashes themselves still happen.
- **Stage 8 — info disclosure**: deferred from the start (espionage-track exact-value leak).

## Stages remaining

(none — the 8-stage audit is complete.)

## Stage 7 Tier 3 / deferred

Documented in `docs/stage-7-report.md` "Tier 3 — defer":
- F19+F26+F29 (TickServer `on_info` catchall softening — soften to `Logger.warning` + `{:noreply, state}`).
- F21 (drop dead `trap_exit` in `Instance.Manager` / `Spatial.Handoff`).
- F22 (call `next_tick` in `handle_continue(:load_state)` after `load_state` so a restarted agent's tick re-arms).
- F23 (wrap `Instance.Manager.init_from_model` in try/rescue with cleanup).
- F16 (validate `state` struct shape in `load_state`).
- F17 (cap per-restore concurrency in continue/2 with `Task.async_stream`).
- F27 partial (Spatial.Supervisor `:rest_for_one` + `Spatial.Handoff` `handle_continue(:reload)` + periodic snapshot).
- F28 partial — `:fast`-instance autosave (only `:slow` instances currently autosave; needs product call on loss-window SLA).
- F1 topology split — keep `Instance.Supervisor` flat for now; F14 (Tier 1) widens budget enough that the split is deferrable. Long-term: split into per-aggregate sub-supervisors (Players, Characters, StellarSystems, Infrastructure) with `:rest_for_one` at the top.
