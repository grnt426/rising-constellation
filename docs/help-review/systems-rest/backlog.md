# Backlog

## system-outputs

- A building that grows with mobility changes this, and so does {name:building.monument_dome}. In a system with one of them, the mobility bonus counts 33.: Say "In a system where one of them is built, the mobility bonus counts 33."
- The three bullets under 'Where an output comes from' have no terminal periods, while the bullets under 'Where each output goes' each end with a period.: Add a period to the end of each of the three bullets for consistency with the rest of the page.
- Line 42 opens with 'Last, [[system-penalties|penalties]] can reduce the total.': Consider 'Finally, [[system-penalties|penalties]] can reduce the total.' or fold it into the preceding list as a fourth bullet.
- Voter stumble: production is not marked in the screenshot. A combined shot would need a new capture request.
- Credit-percentage note: the finding also suggested adding it to the mobility page. That page is not mine to edit this run.
- nice_to_have 'In a system where one of them is built, the mobility bonus counts 33': no longer applies, because that sentence was removed under must_fix.
- 8.1's third bullet (a flat conversion bonus... 20 + 66 + 33 = 119) is left out, because must_fix allows only one sentence here. The mobility/credit page should own it.

## production

- Sentence breaks the numeric flow: Consider folding it into the prior sentence or moving it to the end of the paragraph so the two rate facts read together.
- Planned screenshot silently dropped: Add a one-line entry to shot_requests for a recaptured `production-tooltip` so the visual isn't silently forgotten.
- shot_request: recapture production-tooltip (recipe R2) with a translated row label and marks `initial` and optionally `buildings`.
- Renderer issue for the manual developers: the plain-text (--text) path adds a space between a {rate:} token and the punctuation right after it.
- Reader stumble not addressed: the '+3 → +15' arrow format in the buildings_by_output table is not explained on the table itself.
- Reader stumble not addressed: the Lex, Tradition and Agent skill labels have no gloss.

## technology

- sources: lib/game/instance/player/player.ex:1001-1090: Narrow the range to lib/game/instance/player/player.ex:1001-1079.
- The page adds a table and sentence ({table:bonus_sources player_technology}) not listed in the guide map's brief for this leaf: Confirm with the guide map owner whether this belongs on this leaf.
- Generator separator: bonus_sources renders 'Siderian — Knowledge' with an em dash inside the cell.
- Generator units: the player_technology table prints flat Lex effects with no per-tick or per-hour unit.
- Voter stumble: the system-properties screenshot shows technology as 0, not a typical value.
- Voter stumble: 'hiring Navarchs and Siderians' has no reminder of what these agents are.

## ideology

- The four bullets under "What spends it" mix sentence fragments and full sentences inconsistently: Pick one shape for the whole list.
- The page says Lexes matter "while they stay in a slot" twice: State it once and drop the repeat.
- Voter stumble: in the system-properties screenshot the three yield badges look alike and ideology shows 0. Recapture request.
- shot_requests: none new beyond the recapture above.
- Voter stumble: the Lex/tradition table mixes flat and percent effects without saying how they combine; belongs to system-outputs.
- Voter stumble: the rendered table still shows 'Siderian — Wisdom ... +5 % Ideology' with no 'per skill point'; table renderer issue.
- The '[[siege]]' link text renders as lowercase 'siege' in the text output; renderer issue.

## defense

- Speed-split wording for population defense constant: needs a speed-pinned const token or sanctioned way to state per-speed values.
- The two "What it does" bullets restate closely related effects that could be one sentence.
- Pipeline or compiler gap: no speed-conditional token and no computed-product token exist for system_base_defense.
- Generator: show a self-referential :add bonus (from == to, as on the C.N.D.) as a percentage of the flat subtotal instead of '+0.2 → +1 Defense per Defense'.
- Generator: both voters asked what drives the '+4.8 → +24' ranges (building level 1 to max); needs a column header or table note.
- Brief issue: guide-map-rest.md defense item 2 says 'harder and slower' but action time is not monotonic in defense.
- Daily mutator 'The walls have gaps' (-30% system defense) is missing from bonus_sources.
- defense-tooltip has no buildings mark; request a recapture with a defense building when the empire scene exists.
- Stumble: 'C.N.D.' is never spelled out; nothing in the game gives the expansion.
- Stumble: the Other sources table mixes percent and flat effects in one Effect column; generator issue.
- Pipeline request: a speed-pinned const token or a speed-conditional block.

## star-systems

- The status table's last row breaks the pattern set by the other four rows: Make the last cell match the others' shape.
- The table header "What other players can do to it" does not fit every row it labels: Reword the header to something status-neutral.
- The "Who holds a system" section stacks four separate ideas without a sub-break: Consider a second heading.
- Voter stumble: 'sector' has no definition or link; no sector page to link, left as is.
- Voter stumble: 'visibility' has no link; no linkable visibility page exists, left unlinked.

## stellar-bodies

- "Some game modes change the body and star rolls.": Keep the sentence about bodies only.
- The sentence "Sterile Planets are barren planets." reads as an unrelated aside; move it next to where barren planets are first introduced.
- The page never states in prose that moons orbit planets/gas giants and asteroids sit in belts.
- Generator fix: make the buildings_by_input 'Built on' column use stellar_body names instead of patent_class names.
- Per-subsection lead-ins for the three potential tables: skipped to stay within the leaf length cap.
- Tile order (tile 1 is the leftmost square): voter leaned on the screenshot; rule 8 says show via shot not words.

## colonization

- If a requirement above is not met when you start, the colonization is cancelled and you get a notification: optional rewording.
- The opening two sentences both state the same uninhabited-system requirement from opposite angles: consider folding into one.
- The sector-adjacency requirement bullet repeats the word "sector" twice: tighten wording.
- Voter stumble: '15.8 population' looks oddly precise; value comes from a token and must stay as the code gives it.
- Voter stumble: what happens when your Navarch is intercepted; left at the [[stances]] link rather than state an unverified outcome.

## system-limits

- Your System Limit starts at 1 and your Dominion Limit at 0. Lexes raise them: add one plain sentence about game modes.
- At your System Limit, these are refused: needs correction — colonization/conquest/Control are cancelled at start not refused outright, and mobile map action wheel bypasses the greyed-out button entirely.
- Line packs two distinct edge cases into one run: split by limit.
- "conquest" is the one item in either refused-actions list with no link; no conquest page exists to link to.
- Reader stumble 'conquest' has no link; stays plain text.
- Voter stumble 'Lexes' never defined; Lex is not a linkable page yet.
- Voter stumble 'Control' not explained; covered by the [[dominions]] link.

## administrative-operations

- Anyone can then conquer it or take it with a Siderian's Control, you included: optionally reword to scope the reach rule.
- The Cost section chains three sentences that each open on the same pronoun: vary the subject.
- The closing sentence reads awkwardly with 'you included' tacked on: front-load it.
- Phrase mismatch: 'in this game' vs 'in total' for the same idea: use the same phrase in both places.
- Governor sentence: developer defect, not for the manual — galaxy-side claim/abandon runs before prepare_leaving_system, causing a state desync under siege. Report separately.
- The in-game example line always shows Legacy numbers; a per-speed total would need a new computed token in RC.Help.Compiler.
- Shot `status` mark dropped intentionally; a third mark would push the caption past one sentence.
- 'governor' has no context; no governor page exists and Agents are out of scope for this run.
- Voter stumble, Administer is not pictured; needs a new shot `dominion-state#administer` from the empire scene.

## siege

- Heading "When it ends" is followed by content describing ongoing attack mechanics, not end-of-siege behavior: rename heading or restructure.
- The pillage-yield example sentence is oddly phrased: reword so each number is attached to one clear referent.
- The two bullet lists use inconsistent capitalization and punctuation: pick one list style for the whole page.
- "A pillage reads the yield before its own siege lowers it" is ambiguous: spell out the actor once.
- Refill example {duration:180}: blocked on a compiler feature (a derived-value token for a ratio of two constants).
- Known issue wording 'or one whose Navarch is beaten': accurate but cut to stay under the word cap.
- The drop is actually min(yield, 45), so a low yield falls to 0: skipped as an extra edge case and for length.
- Plain-text pointers about damaged buildings/repairs and multipliers per result: cut for the length cap.
- Shot request: a besieged system view needs an enemy fleet present; no capture scene provides one.
- 'A cancelled attack keeps the siege until its time runs out.': cut to stay under the word cap; needs a short accurate version.
- Refill duration example blocked on a speed-aware derived {duration:} value.

## dominions

- The "Losing a dominion" heading includes an item (Administer) that isn't actually a loss: retitle the section or move the bullet.
- "autonomous system" is not linked on first mention even though the status is owned by star-systems.
- The related: frontmatter list omits several pages this guide actually links to: add credit, technology, ideology, defense, and stances.
- No visual yet: the dominion-properties#owner shot (R7) needs the empire capture scene (D6).
- 'Lexes' has no link or definition on this page because no Lexes page is linkable yet.
- 'Siderian' and 'Control' on first mention have no link because the Siderians chapter does not exist yet.
- Planner note: the traditions half of a sentence is not in the OWNS list; the guide map should add it.
- --text output shows links to stances and siege as lowercase slugs, not their titles; compiler/renderer issue.
- No shot on this page. shot_request: dominion-properties with the owner mark, taken from a dominion's system view.

## dominion-tax-rate

- The 30% figure is stated twice within two sentences of each other: fold the base-rate fact into the intro sentence.
- "however low that goes" is vague: consider a more literal phrasing.
- Frontmatter `related:` omits system-outputs, the guide the prose actually links to.
- Voter stumble: Lex names in the rate table are not explained on the page; no linkable Lex page.
- Voter stumble: the UI-location bullet sits among rule bullets; a planned screenshot would replace it but is not captured yet.

## self-development

- Step 6: "It picks a random planet.": should say 'a random body with a free tile' since moons and asteroids are included too.
- Item 6 interleaves the general random-planet step with the barren-planet exception and the upgrade threshold: keep the rule and its exception adjacent.
- The pronoun in item 4 is ambiguous between "workforce" and "infrastructure": reword to repeat the noun.
- The known-issue line sits as a lone paragraph after four bulleted edge cases, breaking list rhythm.
- Barren-planet starter variant (Capsule Cities, Array of Excavators) cut to stay under the leaf cap.
- 'one output building' link to system-outputs: moot, phrase was replaced by the real building name.
- Orbital bodies (moons, asteroids) skip the infrastructure-level guard, so upgrades there can succeed; left out for length.
- Voter stumble 'which building gets upgraded': the pick comes from a hidden development profile; brief says not to document it.
- Voter stumble on the mechanism linking building count to workforce cost: exact bands left as one plain sentence.
- Step 3 precondition (exactly one habitable planet with infrastructure and more than 4 free tiles) is not stated; would add words past the cap.
- A second known issue (the population-growth wait is meant to happen but never does) was left out; may be worth a bug ticket.

## Screenshot requests

- production | production-tooltip recaptured on a vanilla scene (no mutator row): the system's Production breakdown with the 'Initial value' row and, if possible, a building row | initial, buildings | The current capture shows an untranslated mutator row, so the production page ships without a screenshot of where base production appears.
- production | the system's production box with a build queue of two or more items (first item progressing) | queue-first-item, production | To show which item receives production first without describing the queue in words.
- technology | the top-bar technology popover pinned on scene empire, showing the Systems and Dominions groups | systems, dominions | Shows where the empire's technology income comes from (your systems plus the dominion share). The same view with ideology serves the ideology page.
- defense | defense-tooltip on a system with a defense building (for example Planetary Shield) so the Buildings group is present next to the Population row | population, buildings | The brief's optional buildings mark could not be used, because the fresh daily has no defense building.
- star-systems | Properties box of an autonomous system and of a dominion (scene empire), owner block reading 'Autonomous system' / 'Dominion belonging to' | owner | Show the status difference instead of only a table of words; today only the player's own system is capturable.
- colonization | State tab of an uninhabited system (scene empire, recipe R8 uninhabited-state) | status | Show the 'can be colonized by a Navarch with a colonization ship' status line.
- colonization | A Navarch's action bar in an uninhabited system with the colonize action and its duration | colonize | Show where colonization is started and the ship it needs, without describing the UI in words.
- administrative-operations | State tab of an owned dominion (scene empire, recipe R9 dominion-state) with the Administer and Abandon buttons enabled | administer, abandon | The current shot only shows Liberate/Abandon, hatched because it is the only system; Administer is never shown.
- system-limits | The pinned hover popover of the bottom-bar Systems counter showing the System Limit breakdown | limit | The caption tells players to hover for the limit; a shot of the breakdown would show it directly.
- siege | A besieged own system: production box at 0 with the under-siege penalty row, plus the siege indicator in the system view (needs an enemy Navarch conquering the system) | penalty, siege | Show what 'no production while besieged' looks like; not capturable on own-system or empire scenes.
- dominions | dominion-properties (scene empire): a dominion's Properties box with the owner block reading as a dominion of the player | owner | Show what a dominion looks like in the system view instead of describing it.
- dominions | dominion-state (scene empire): the state tab of a dominion with the Administer and Abandon buttons | status, administer, abandon | Losing a dominion section points to Administer and Abandon; a highlighted shot replaces any wording about where they are.
- dominions | map-action-radial-control (scene empire): the map action radial of a Siderian over an autonomous system, showing the Control action | make_dominion | Getting a dominion section names Control; shows where the action is launched.
- dominion-tax-rate | empire-credit-tooltip (scene empire): Bottombar credit popover pinned, with its Systems and Dominions groups | dominions | The leaf says the income appears under Dominions in the empire breakdowns; the shot should replace that sentence.
- self-development | autonomous-state (scene empire): state tab of an autonomous system with the 'develops itself independently' status text, plus its build queue showing an item it ordered | status, queue | The first sentence and step 1 (busy queue) are visible in the UI.

## Chart requests

- pillage_yield: pillage yield of a system over time (ticks or hours) with repeated conquests, bombardments or pillages every N ticks (args: interval=<n> count=<n>), running the refill (system_raid_potential_growth, capped at 100) and the raid_potential_impact drop. It would replace the speed-dependent refill example dropped from siege.
- transform_cost: optional small chart or generated table of the Liberate/Administer price for the 1st to 10th use per speed (transform_initial_cost + n × transform_additional_cost), since the example total cannot be typed per speed.
- self_development_timeline: number of built buildings (and total workforce mobilized) over time for a freshly generated autonomous system, per speed, by running StellarSystem.next_tick with SystemAI on a fixture system; it would show how slowly an autonomous system or dominion develops and where it plateaus.
