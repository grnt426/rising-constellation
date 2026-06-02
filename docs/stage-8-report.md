# Stage 8 — Info disclosure (report)

## Top-line

- **14 candidates** entered Stage 8, **9 survived** the 2-vote verify, **3 partial** (one verifier flipped), **2 refuted**.
- **Severity breakdown across the 12 surviving + partial findings:**
  - **High: 2** (cross-faction attack notifications at vis=5; undercover-spy identity leak)
  - **Medium: 8** (GlobalChannel get_stats financial leak; doctrine/patent via army.maintenance.details; detected_objects character_id [medium variant]; rankings_view elo float; PublicPlayer elo float; action_status at vis=5; contacts informer list [partial — split]; detected_objects character_id [partial duplicate])
  - **Low: 2** (radar character_id [low variant]; siege.besieger_id [partial])
- **Executive summary.** The dominant pattern is the wire returning the **full authoritative server struct** to viewers the UI only renders a sanitized projection of. Two systemic root causes account for almost every finding:
  - (a) **`Notification.Character.diff/2` defaults to visibility=5** so every cross-faction attack ships the attacker's full skill tree, action_status, on_strike, and bonus.details (doctrine/patent atoms) to the defender — `sabotage.ex` and `assassination.ex` already use an explicit lower `defender_vis`, so the pattern exists but was not applied to the other seven attack actions.
  - (b) **`Faction.StellarSystem.obfuscate`'s details-strip does not recurse into character substructs**, so the system-level `Core.Value.details` are correctly cleared at vis<5 but the same details inside `character.army.maintenance` reach the wire and the UI's tooltip resolves them straight to localized doctrine/tradition names.

  The worst single finding is the **undercover-spy leak**: when `became_discovered? == false`, the system goes out of its way to set `defender_vis = 2`, but vis=2 still emits id, name, illustration, level, and the attacker player's id+name+faction — and the locale strings show the design clearly intended the spy to remain anonymous. The remaining findings are competitive-fairness leaks (exact float ELO, exact bank balance, persistent character_id on radar) that turn UI-bucketed displays into wire-precise intelligence. None of these are auth bypasses, but in a competitive 4X with PvP economy and espionage, they are real strategic asymmetries between a normal UI player and a wire reader.

## Cluster summaries

### Cluster A — Defender-notification visibility cap missing (root cause: `Notification.Character.diff/2` default `visibility=5`)

**What it is.** `lib/game/notification/character.ex:6` defaults visibility to 5 in `Notification.Character.diff/2`. Visibility 5 is the faction-internal tier; it exposes skills, experience, protection, determination, action_status, on_strike on the attacker character, and inside the army/spy/speaker substructs it exposes maintenance, reaction, repair_coef, invasion_coef, raid_coef, make_dominion_coef, encourage_hate_coef, conversion_coef plus each of those `Core.Value`'s `.details` (doctrine/patent/tradition reasons). Seven attack actions call `Notification.Character.diff(prev, curr)` with no visibility arg and ship the same diff to the defender. The pattern of using an explicit `defender_vis` exists in `sabotage.ex` and `assassination.ex`, so this is an oversight not a deliberate choice.

**Findings inside.**
- **F2** — "Cross-faction attack notifications expose attacker at faction-internal visibility (vis=5)" — **high**; lens `character-obfuscation`; `conversion.ex:89, raid.ex:147, conquest.ex:172, loot.ex:160, encourage_hate.ex:110, make_dominion.ex:131, fight.ex:235-236` (verifier-2 note: colonization.ex:113 is attacker-only, so 7 of 8 cited files have the leak).
- **F4** — "Doctrine/Patent identifiers leak via nested Core.Value.details on character.army at cross-faction vis 4" — **medium**; lens `character-obfuscation`; `lib/game/instance/faction/stellar_system.ex:91-97`, `lib/game/instance/faction/character.ex:75-95`. (Overlaps with Cluster A in that the same `.details` payload is the leaked content — but the **delivery vector** here is the cross-faction system-state get, not the defender notification, so a combined fix should strip details inside obfuscate_army/_spy/_speaker so both vectors are closed.)

**Suggested fix shape.** **One combined fix** in `lib/game/instance/faction/character.ex` `obfuscate_army`/`_spy`/`_speaker` that, for `visibility_level < 5`, replaces each nested `%Core.Value{details: details}` with `%{value | details: %{}}` (or filters details to only `:ship`/`:misc` ValuePart keys). That closes the doctrine/patent/tradition reason leak via both the notification path and the system-state path. Then separately add an explicit `defender_vis` argument (≤3) to the seven attack-action `create_notifs` callsites so non-`.details` fields (skills, action_status, on_strike) are also capped for defenders. The fix template already exists in `sabotage.ex` and `assassination.ex`.

---

### Cluster B — Faction.Character.obfuscate vis=5 over-shares for cross-faction-visible enemies (action_status, skills)

**What it is.** `lib/game/instance/faction/character.ex:38-43` puts `:action_status` (and the wider vis=5 field set: skills, experience, protection, determination, on_strike) in the level-5 allowlist. `Faction.resolve_character_visibility/3` returns 5 not only for own-faction (intended) but also for any enemy character whose host system has `contact.value == 5` (3 informers — reachable cross-faction). The UI never renders enemy `action_status` (`ClosedCharacterCard.vue` only renders it for own characters; the icon branch requires `character.actions.queue` which doesn't exist on `Faction.Character` at all).

**Findings inside.**
- **F8** — "Enemy character action_status leaked on faction wire at visibility 5" — **medium**; lens `movement-action-prediction`; `lib/game/instance/faction/character.ex:38-43`.

**Note on overlap with Cluster A.** Cluster A also exposes `action_status` via the defender-notification path (same field, different delivery). A single fix that splits `obfuscate/2` into "own-faction" and "non-own-faction at vis 5" branches and removes `action_status` (plus the doctrine/patent details from Cluster A) from the latter would close both.

**Suggested fix shape.** Split `obfuscate/2` on `character.owner.faction == state.key`. Own-faction keeps the existing struct; non-own-faction at vis 5 drops `:action_status`, and the doctrine-details strip from Cluster A is layered on top.

---

### Cluster C — Spy attack: undercover branch still leaks attacker identity

**What it is.** `assassination.ex:85,116` and `sabotage.ex:88,119` deliberately try to cap defender visibility — when `became_discovered? == false`, they set `defender_vis = 2`. But vis=2 still unconditionally fills `[:id, :status, :type, :name, :illustration, :level, :owner, :system]`, where `:owner` is a `Character.Player` containing id+name+faction+faction_id. So the defender's WebSocket frame ships the spy's name+level+illustration and the attacker player's id+name+faction even though `became_discovered? == false` is meant to model "attacker escaped unidentified". The UI worsens it: `AssassinationNotif.vue`/`SabotageNotif.vue` unconditionally render the spy tab with `<character-card :character="data.spy.previous" :theme="theme(data.spy.current.owner.faction)">` — no `v-if` branch on the discovered flag. The locale strings prove the original design intent (`critical_success` says "their identity is known by authorities", treating identity disclosure as the exceptional branch).

**Findings inside.**
- **F3** — "Undercover-spy sabotage/assassination still leaks attacker identity to defender" — **high**; lens `character-obfuscation`; `assassination.ex:85,116`, `sabotage.ex:88,119`.

**Suggested fix shape.** **Per-finding fix** — distinct from the rest of the clusters. Introduce a new `:anonymous` visibility tier in `Faction.Character.obfuscate` that fills only `[:type]` (or `[:type, :level]`), and use it for the undercover branch. Or set `spy: nil` and have the UI render an "Unknown assailant" card. Also add a `v-if` on the spy tab in `AssassinationNotif.vue` and `SabotageNotif.vue` so the tab is hidden when the spy struct is anonymized.

---

### Cluster D — Exact ELO float on the wire vs integer in UI

**What it is.** `RC.Accounts.Profile.elo` is a `:float` and accumulates non-integer values from `RC.Rankings.change_by_faction` (`pts / divider`, float division). Two surfaces serialize it raw: the standings HTTP view and the in-game `PublicPlayer` struct. The UI in both `Standings.vue` and `ProfileCard.vue` applies `| integer` (`Math.round(value).toLocaleString()`), so the human display is integer-only. The wire carries up to 3 decimals (after `JasonUtils.encode` rounding) — enough to disambiguate two players tied at integer 1247, detect ranked-game participation that the integer UI hides, and infer pre/post-match deltas. Admin LiveViews already call `round(@profile.elo)`, confirming integer is the intended public granularity.

**Findings inside.**
- **F6** — "Profile.elo serialized as raw float on standings/ranked_profile endpoint" — **medium**; lens `espionage-exact-vs-bucket`; `lib/portal/views/rankings_view.ex:17`.
- **F7** — "Instance.Player.PublicPlayer.elo carries raw float to any opponent via GlobalChannel get_player" — **medium**; lens `espionage-exact-vs-bucket`; `lib/game/instance/player/public_player.ex:21,39`; `lib/game/instance/player/agent.ex:37-42`; `lib/portal/channels/controllers/global_channel.ex:76-79`.

**Suggested fix shape.** **One combined fix** with two touchpoints: change `elo: profile.elo` to `elo: round(profile.elo)` in both `lib/portal/views/rankings_view.ex:17` and `lib/game/instance/player/public_player.ex:39`. Same root cause, same fix, two callsites.

---

### Cluster E — GlobalChannel cross-player projection over-shares server-side numbers

**What it is.** `GlobalChannel.record("get_stats", ...)` returns `RC.PlayerStats.get_last_player_stat_by_instance_id(instance_id)` to any authenticated instance member. The SQL projects `output_credit, output_technology, output_ideology, stored_credit` per player with no faction or owner filter. The UI consumers (`RankingPanel.vue` → `Overall.vue`/`BestSystem.vue`) only render `total_systems, total_population, points` and `best_*` — repo-wide grep across `front/` finds zero references to the four leaked fields. The leaked values are the same authoritative numbers the server uses for cost gating (`state.credit.value` is exactly `stored_credit`; `state.credit.change` is exactly `output_credit`).

**Findings inside.**
- **F1** — "GlobalChannel `get_stats` leaks per-player exact bank balance and resource flow rates" — **medium**; lens `other-player-payloads`; `lib/portal/channels/controllers/global_channel.ex:81-88`, `lib/rc/player_stats.ex:18-63`, `lib/game/instance/player/player.ex:739`.

**Suggested fix shape.** **Per-finding fix.** Project only UI-rendered columns at the channel handler, or drop the four extra columns from the SELECT in `RC.PlayerStats.get_last_player_stat_by_instance_id/1`. The admin path `get_players_stats_by_instance_id` (`charts_live.ex`) is the appropriate place to keep the full projection.

---

### Cluster F — Radar `character_id` defeats deliberate UI anonymity (3 overlapping findings, same root cause, different severity ratings)

**What it is.** `Faction.update_detected_object/1` (`lib/game/instance/faction/faction.ex:240-244`) builds detected_objects entries as `%{faction, character_id, position, angle}` and broadcasts the whole list via `FactionChannel.broadcast_change` on every radar tick. `character_id` is the canonical stable integer id (same one used for `get_character`/`get_system`/`hire_character`). The UI renderer `detected-object.js:39` destructures only `{angle, position, faction}` and paints an anonymous faction-colored sprite — that's the whole point of radar: anonymous "an enemy is around here". `map-data.js:124` does use `character_id` as an own-character exclusion filter, but the server could perform that filter server-side.

**Findings inside (three findings, same root cause — agents surfaced this independently from three lenses).**
- **F5** — "detected_objects radar broadcast leaks character_id, enabling per-character tracking the UI never shows" — **medium**; lens `system-obfuscation`; same file/line.
- **F9** — "Raw character_id leaked in radar detected_objects broadcast" — **low**; lens `movement-action-prediction`; same file/line.
- **P3** (partial) — "detected_objects radar payload leaks character_id the UI deliberately keeps anonymous" — medium; lens `espionage-exact-vs-bucket`; same file/line. Refuted by one verifier on the grounds that the UI does use `character_id` for own-character filtering (verifier flagged the mischaracterization in the original finding), but the underlying leak is the same — verifier-1 confirmed real with high confidence and noted the fix needs to also move the own-character filter server-side.

**Overlap note.** F5, F9, P3 are three reports of the same leak from three lenses. The severity range (low → medium) reflects how different verifiers weighed "stable identity for fingerprinting" vs "position is already on the wire". The substantive disagreement is whether the proposed naive fix (drop `character_id`) breaks the existing own-character filter on the JS side.

**Suggested fix shape.** **One combined fix.** (i) Drop `character_id` from the broadcast payload. (ii) Move the own-character filter server-side in `update_detected_object/1` (the server already has the faction's character set). (iii) If a per-blip key is needed for Vue rendering, use an ephemeral per-tick token like `:erlang.phash2({tick_no, character_id}, 2_000_000_000)` so blips dedupe within a frame but cannot be correlated across ticks.

---

### Cluster G — Visibility-2 siege struct leaks besieger_id even when besieger character is not separately resolvable

**What it is.** `Faction.StellarSystem.obfuscate/4` puts `:siege` in the level-2 field bucket and copies the `%Siege{type, days, duration, besieger_id}` struct verbatim. The UI uses `besieger_id` only to apply a CSS `is-active` highlight when the besieger is one of the viewer's own admirals (`Actions.vue:65`); for enemy/third-party sieges the besieger's identity is never rendered. The contention is whether this leaks extra info: verifier-1 says yes (a viewer with vis 2 on the besieged system learns `besieger_id` without ever resolving the besieger's character via `get_character` on its home system); verifier-2 says no (at vis 2, the `:characters` field is also exposed, so the besieger is already in `system.characters[]` with full id/name/owner because the besieger character must be physically on the besieged system to issue raid/loot/conquest).

**Findings inside.**
- **P2** (partial) — "siege.besieger_id exposed at visibility 2 reveals the besieging character's ID even when the besieger itself is invisible" — **low**; lens `system-obfuscation`; `lib/game/instance/faction/stellar_system.ex:54-70`, `lib/game/instance/stellar_system/siege.ex:8-13`. Verifier-2's refutation is mechanically sound and should likely close this — needs a main-context decision on whether the verifier-2 invariant (besieger always docked at besieged system) is universal.

**Suggested fix shape.** **Defer pending main-context review.** If verifier-2's invariant holds, no fix needed. Otherwise, in `obfuscate/4` after `:siege` is copied at level 2, replace `besieger_id` with `nil` when `resolve_character_visibility/3` on the besieger would return below 2, and drive the UI highlight from a server-set `is_own_besieger` boolean.

---

### Cluster H — Faction contacts informer list (intra-faction; one verifier refuted)

**What it is.** `Faction.Faction.contacts :: %{system_id => %Core.VisibilityValue{value, details, minimum}}` is broadcast to every faction member as `%{faction_faction: data}` or `%{faction_faction_contact: %{system_id, contact}}` from many `Faction.Agent` callsites. `contact.value` is clamped to 0..5, but `contact.details.informer` is the raw per-drop list (each entry `%ValuePart{reason: player_name, value: 1}`). Verifier-1 confirmed (canonical wire>UI Stage 8 pattern). Verifier-2 refuted, citing that `Properties.vue:374-390`'s `groupContactDetails` already exposes per-player counts to the same faction-internal viewer, so there's no UI-vs-wire gap, and the leak does not cross the faction trust boundary.

**Findings inside.**
- **P1** (partial) — "Faction-channel `contacts` map leaks raw informer/explorer counts and identities (UI clamps to 0-5)" — **high (as stated in finding)**; lens `other-player-payloads`; `lib/game/instance/faction/faction.ex` (struct), `lib/game/instance/faction/agent.ex` (broadcast sites), `lib/game/core/visibility_value.ex` (struct shape).

**Suggested fix shape.** **Defer pending main-context review** — the verifiers disagree on whether the popover (`groupContactDetails`) already discloses the same total, and the data is intra-faction. If kept, replace per-drop list with `[{reason, count_capped_at_5}, ...]` or a `VisibilityValue.public_view/1` helper that emits only `value`. [ambiguous — needs main-context review on whether the `details.informer.length` exceeds the popover-sum disclosure in any practical scenario]

---

## Full finding list

| # | Sev | Lens | File:line | Title | UI vs wire (short) |
|---|---|---|---|---|---|
| F1 | medium | other-player-payloads | `lib/portal/channels/controllers/global_channel.ex:81-88` + `lib/rc/player_stats.ex:18-63` | GlobalChannel `get_stats` leaks per-player exact bank balance + flow rates | UI shows `total_systems`/`points`; wire ships `stored_credit`, `output_credit`, `output_technology`, `output_ideology` |
| F2 | high | character-obfuscation | `conversion.ex:89, raid.ex:147, conquest.ex:172, loot.ex:160, encourage_hate.ex:110, make_dominion.ex:131, fight.ex:235-236` | Cross-faction attack notifications expose attacker at vis=5 | UI shows name+level+illustration on CharacterCard; wire ships skills array, action_status, on_strike, doctrine/patent .details |
| F3 | high | character-obfuscation | `assassination.ex:85,116; sabotage.ex:88,119` | Undercover-spy sabotage/assassination still leaks attacker identity | UI locale strings designed to omit spy identity on failure; wire ships spy id+name+level+illustration and attacker id+name+faction |
| F4 | medium | character-obfuscation | `stellar_system.ex:91-97; character.ex:75-95` | Doctrine/Patent/Tradition keys leak via nested Core.Value.details on character.army at cross-faction vis 4 | UI tooltip resolves localized doctrine/tradition name from wire reason key; wire ships raw doctrine/tradition atom keys via maintenance.details |
| F5 | medium | system-obfuscation | `lib/game/instance/faction/faction.ex:210-247` + `faction/agent.ex:180` | detected_objects radar broadcast leaks `character_id`, enabling per-character tracking | UI paints anonymous faction-colored sprite from {angle, position, faction}; wire ships stable integer `character_id` |
| F6 | medium | espionage-exact-vs-bucket | `lib/portal/views/rankings_view.ex:11-19` (line 17) | Profile.elo serialized as raw float on standings endpoint | UI: `{{ standing.elo \| integer }}` → 1247; wire: 1247.833 |
| F7 | medium | espionage-exact-vs-bucket | `lib/game/instance/player/public_player.ex:21,39`; `player/agent.ex:37-42`; `global_channel.ex:76-79` | PublicPlayer.elo carries raw float to any opponent via GlobalChannel get_player | UI: `{{ profile.elo \| integer }}`; wire: float (3-decimal after JasonUtils) |
| F8 | medium | movement-action-prediction | `lib/game/instance/faction/character.ex:38-43` | Enemy character action_status leaked at vis=5 | UI never renders enemy action_status (gated on own character); wire ships :raid/:conquest/:colonization/:infiltration/:assassination/:sabotage/:make_dominion/:encourage_hate/:conversion/:fight |
| F9 | low | movement-action-prediction | `lib/game/instance/faction/faction.ex:210-247` | Raw character_id leaked in radar detected_objects (duplicate of F5; different lens) | Same as F5 — UI anonymizes sprite, wire carries id |
| P1 | high (claimed) | other-player-payloads | `lib/game/instance/faction/faction.ex` (struct) + `faction/agent.ex` (broadcasts) + `core/visibility_value.ex` | Faction-channel `contacts` map leaks raw informer/explorer counts and identities (partial: intra-faction, verifier-2 refuted) | UI popover groups informers by reason; wire ships full per-drop `details.informer` list with `reason: player_name, value: 1` per drop |
| P2 | low | system-obfuscation | `stellar_system.ex:54-70`; `stellar_system/siege.ex:8-13` | siege.besieger_id exposed at vis=2 (partial: verifier-2 refuted on grounds besieger must be physically at the besieged system) | UI uses besieger_id only for own-character CSS highlight; wire ships integer besieger_id |
| P3 | medium | espionage-exact-vs-bucket | `lib/game/instance/faction/faction.ex:240-247` + `faction/agent.ex:180` | detected_objects character_id (partial; duplicate of F5/F9 from a third lens; verifier-2 refuted on UI mischaracterization) | Same as F5/F9 |

---

## Recommended fix scope

### Tier 1 — must-fix before release (high-severity competitive-fairness leaks)

1. **F3 — undercover-spy identity leak.** This is the clearest design-intent violation in the report: the code deliberately tries to cap defender visibility (`defender_vis = 2`) and the locale strings deliberately omit the spy from failure outcomes. The miss is that vis=2 still includes attacker identity. Fix: introduce an `:anonymous` tier in `Faction.Character.obfuscate` (fills only `[:type]` or `[:type, :level]`), use it for `became_discovered? == false`, and add `v-if` on the spy tab in `AssassinationNotif.vue`/`SabotageNotif.vue`.

2. **F2 — defender notifications at vis=5.** Seven attack-action paths (conversion, raid, conquest, loot, encourage_hate, make_dominion, fight) ship the attacker's full skill tree, action_status, on_strike, and bonus.details to the defender. The fix template exists in sabotage.ex/assassination.ex. Add explicit `defender_vis` ≤ 3 to the 7 `create_notifs` callsites.

3. **F4 — doctrine/patent/tradition keys via army.maintenance.details (cross-faction vis 4).** Strategic-intel asymmetry that bypasses the system-level details strip. Fix: extend the details strip recursively into `obfuscate_army`/`_spy`/`_speaker` for `visibility_level < 5`. This single fix also closes part of F2 (the `.details` leak inside the defender notification).

### Tier 2 — should-fix before release (medium-severity competitive leaks)

4. **F1 — GlobalChannel get_stats exposes exact bank balance + flow rates.** Drop `stored_credit, output_credit, output_technology, output_ideology` from the player-facing SELECT or project only UI-rendered columns at the channel handler. Trivial fix, real strategic impact.

5. **F5/F9/P3 — detected_objects character_id (three reports of the same leak).** Drop `character_id` from the broadcast payload; move the own-character filter server-side; if a Vue key is needed, use a per-tick opaque token.

6. **F6 + F7 — exact ELO float (two callsites, same root cause).** One-line fix each: `elo: round(profile.elo)` in `rankings_view.ex:17` and `public_player.ex:39`. Mirrors the existing admin-LiveView pattern that already calls `round/1`.

7. **F8 — enemy action_status at vis=5.** Split `obfuscate/2` into own-faction vs non-own-faction-at-vis-5 branches and drop `:action_status` from the latter (or bucket to `:idle | :busy | :docking`).

### Tier 3 — defer

8. **P1 — faction contacts informer list.** Intra-faction disclosure. Verifier-2's refutation is mechanically credible (the UI popover already exposes the same per-player totals to the same viewer). Defer pending a main-context decision on whether `details.informer.length > popover-sum` ever holds in practice.

9. **P2 — siege.besieger_id.** Verifier-2 argues the besieger character is necessarily already present in `system.characters[]` at the same visibility tier (besieger must be docked to issue raid/loot/conquest). If that invariant holds universally, no fix needed. Otherwise, simple null-out of `besieger_id` when the besieger's character visibility is below 2.

---

## Refuted findings

Two candidates were refuted by both verifiers (unanimous refutation, not the partial split-vote refutation):

### R1 — "system.contact.details.informer array length leaks raw informer count" (lens `system-obfuscation`)
This is conceptually the same leak as **P1** (Cluster H) but raised from a different lens. Refuted because:
- The data flow is **faction-internal only**: `Faction.StellarSystem.obfuscate/4` is called from `Faction.Agent.on_call({:get_system_state, ...})` where `contact` is sourced from the asking faction's own `state.contacts` map. The viewer is on the same side of the trust boundary as the data owner.
- The faction-channel topic `instance:faction:<iid>:<fid>` is JWT-gated to `registration.faction_id == faction_id` at join (`faction_channel.ex:50`).
- The UI popover `groupContactDetails` (`Properties.vue:374-390`) already exposes the per-player drop totals to the same viewer — there is no UI-vs-wire gap.
- An explicit server endpoint `:get_system_informer_count` exists for faction-internal bookkeeping, confirming the count is not modeled as confidential within a faction.
- The finding's own description concedes "the leak only crosses the UI/wire boundary, not the faction/non-faction boundary" — i.e., not a Stage 8 information-disclosure pattern.

### R2 — "army.tiles ship_status array exposed at visibility 2 reveals enemy admiral's exact filled-tile count" (lens `system-obfuscation`)
Refuted because:
- The wire genuinely carries `ship_status: :filled` with `ship: :hidden` at visibility 2 — but the UI **renders exactly that**: `Army.vue:121-144` explicitly draws a `frame_ship_hidden` icon for every filled tile when `ship === 'hidden'`. The grid of hidden-frame icons is the intended product feature; players are meant to see the count of built ships as a row of frame icons even before unlocking detailed stats.
- The finding's own Fix section concedes: "Acceptable as-is if the army grid display at visibility 2 is intended product behavior — in which case this is info-only."
- Per the verification rubric, "if the UI shows raw, it is not a leak — it is the intended design." Wire and UI are consistent here; this is not an obfuscation bypass.

---

## Leverage notes

- The biggest leverage point is the **details-strip recursion in `obfuscate_army`/`_spy`/`_speaker`** (`lib/game/instance/faction/character.ex:75-95`). Doing this once closes part of F2 and all of F4 — a single ~10-line change covering two findings with combined high+medium severity.
- The **second biggest leverage point** is making `Notification.Character.diff/2` either default-low-visibility, or just take an explicit `defender_vis` at the 7 attack-action callsites. The template exists; this is a mechanical apply.
- **F3 (undercover spy)** stands alone — it needs a new `:anonymous` visibility tier rather than reusing tier 2.
- **F5/F9/P3** are three lenses surfacing one leak; treat as a single fix and ship.
