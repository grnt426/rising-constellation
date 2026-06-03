# Mutator ideas

Catalog of mutator concepts for the Forge — flavorful names, mechanical
description, where the engine would hook them, and a rough difficulty
read so future stages can pick the cheapest next slice.

The first section is **what's already shipped**. Everything below the
"Future ideas" heading is fertile ground — not necessarily ranked,
mostly things to discuss before implementing.

For the architecture (catalog module, dispatch, hook points), see
[`lib/data/game/mutator.ex`](../lib/data/game/mutator.ex) and
[`lib/game/instance/mutators.ex`](../lib/game/instance/mutators.ex).

---

## Shipped (Stage 5 mini)

Resource scalers — pure construction-time multipliers in
`Player.new/4`. Zero new hook points. Validated the catalog +
dispatch architecture.

| Name                 | Effect                                      | Hook            |
|----------------------|---------------------------------------------|-----------------|
| Empire of Wealth     | 2× starting credit                          | `on_player_init`|
| Frontier Stockpile   | 3× starting credit                          | `on_player_init`|
| Lean Years           | 0.5× starting credit                        | `on_player_init`|
| Old Knowledge        | 2× starting technology                      | `on_player_init`|
| Faith Reborn         | 2× starting ideology                        | `on_player_init`|

---

## Future ideas

Grouped by where they hook into the engine, because that's the
operative variable for cost-to-build.

### Construction-time variants

Same family as the shipped batch — applied once in `Player.new` or
during galaxy spawn, no ongoing tick cost. Cheapest to add.

| Name                  | Effect                                                                                  | Notes                                                  |
|-----------------------|-----------------------------------------------------------------------------------------|--------------------------------------------------------|
| **Boom Times**        | All system production yields +50%.                                                       | Apply to `c.system_*_base_production` via mutator-aware Constant lookup. |
| **Pioneer Charter**   | Every player starts with the warp drive patent unlocked.                                | Populate `player.patents` in `Player.new`. Doc'd in stage 5 as item #2. |
| **Inherited Doctrine**| Every player starts with one random faction-appropriate doctrine.                       | Same hook as Pioneer Charter, different content table. |
| **Crowded Heavens**   | Every sector gets one extra inhabitable system spawned in.                              | Hook at sector spawn in `init_from_model`'s galaxy step. |
| **Lonely Stars**      | Every sector loses 25% of its systems at spawn.                                         | Symmetric inverse of Crowded Heavens. Use the same code path. |
| **Wild Frontier**     | More neutral-owned systems (vs. NPC/unclaimed).                                          | _User-suggested._ Tunable: what fraction? |

### Map / galaxy-shape variants

Modify the map's spawn or initial owner assignment.

| Name             | Effect                                                                                       | Notes |
|------------------|----------------------------------------------------------------------------------------------|-------|
| **High Alert**   | Neutral-owned systems start defended by AI fleets of random strength that attack any Navarch entering the system. | _User-suggested._ Needs an "NPC fleet" entity + combat-on-arrival hook. Could reuse existing pirate AI if any exists. |
| **Forgotten Remains** | New non-removable "rubble" building takes a building slot until 10,000 credits is spent to clear it. | _User-suggested._ Needs new building type + clearance action. Moderate scope — touches building catalog. |

### Combat hooks

Anything wired into `Game.Fight.Manager` or the fleet lifecycle.
Higher risk because combat semantics ripple into balance.

| Name                  | Effect                                                                                          | Notes |
|-----------------------|-------------------------------------------------------------------------------------------------|-------|
| **Fleet Revenge**     | When a fleet is destroyed in combat, the survivor takes proportional damage (non-cascading).    | Doc's stage 5 item #3. Needs cascade guard — see the original redesign doc. |
| **Letters of Marque** | When any member of a faction wins a battle, all members get +0.5% credit income for 12hr.       | _User-suggested ("Privateering")._ Needs faction-scoped temporary modifier table. Stacking rules need design. |
| **Honor Lost**        | Every Seduction or Assassination of an enemy agent grants the attacker's faction +0.5% ideology income for 12hr. | _User-suggested._ Same plumbing as Letters of Marque, different trigger + resource. |

### Character / world-state hooks

Things that watch a per-system or per-faction predicate every tick.

| Name                  | Effect                                                                                       | Notes |
|-----------------------|----------------------------------------------------------------------------------------------|-------|
| **Governor's Aura**   | A governor's local bonuses leak into neighboring systems at 50% strength.                    | Doc's stage 5 item #4. Crosses process boundaries — needs a spike. |
| **Monument Vigil**    | When a faction controls every monument in a sector, those monuments produce extra.            | Doc's stage 5 item #5. Cross-entity predicate — cache on faction. |
| **Court of Stars**    | When 3+ Navarchs (admirals) share a system, every Navarch's salary in that system triples.    | _User-suggested ("Rank and Largesse")._ Tick-time predicate per system. Watch for stacking with other admiral-related mutators. |

### Cross-cutting / weird

Things that don't fit a tidy hook category. Listed mostly as design
fodder; some are deliberately whimsical to spark variants.

| Name                  | Effect                                                                                       |
|-----------------------|----------------------------------------------------------------------------------------------|
| **Twin Suns**         | The map renders + plays as if doubled — two copies of every system, edges respected.        |
| **Black Market**      | Resource costs for one random unit type are halved; another are doubled.                    |
| **Silent Stars**      | Diplomacy is disabled — no messages between players for the first N in-game days.           |
| **Whispers of Empire**| Spies cost half but reveal half as much per success.                                         |
| **Faded Borders**     | Sector ownership doesn't grant per-sector victory points; only system count matters.         |
| **Iron Will**         | Ideology decay is doubled; every faction must keep their followers happy or lose them.       |
| **Tide of Industry**  | Production rates oscillate ±25% on a 7-day cycle — busy and lean weeks alternate.            |

---

## Adding a new mutator

1. Pick a name. Mutators should have flavorful names rather than the
   `:starting_credit_x2` mechanical labels — that's the contract
   players read when picking variants.
2. Decide which hook the effect needs:
   - **`on_player_init`** — applied once when each Player struct is
     constructed. Cheap. The shipped resource scalers all live here.
   - **`on_galaxy_spawn`** — applied to the spawned systems list
     during `init_from_model`. Used for map-shape variants.
   - **`on_combat_cleanup`** — fires from `Game.Fight.Manager.do_cleaning/2`.
   - **`on_action_complete`** — fires when a Seduction / Assassination /
     conquest action finishes. Needs an `:action_kind` predicate.
   - **`on_tick`** — runs every system or faction tick. Most
     expensive; use only when the effect is a continuous predicate.
3. Add the catalog entry to [`lib/data/game/mutator.ex`](../lib/data/game/mutator.ex)
   with `implemented: false` first — the UI will surface it as
   "coming soon" so authors know it's on the roadmap.
4. Wire the hook. If a new hook category is needed, write the
   dispatcher helper in `Instance.Mutators` first so callers stay
   uniform.
5. Flip to `implemented: true`. The picker enables the checkbox.
