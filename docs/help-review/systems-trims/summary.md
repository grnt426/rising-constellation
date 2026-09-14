# Trim review (2026-09-14)

Pages were reviewed for sentences squeezed to fit the old hard length cap (style rule 18 revised).

## siege

- Accepted: no
- Voter score: 3
- Restored:
  - Restored the `[[system-penalties]]` link after "The system makes no production." — dropped only to get under the cap.
  - Restored "take Control of" instead of using Control as a bare verb.
  - Restored "depending on its result" for population/building damage from an attack.
  - Restored the full description of which buildings can be damaged (never infrastructure, damaged, or under repair).
  - Restored the "55% of what it would take at 100" phrasing for pillage yield.
  - Restored the specific trigger and amount for a Navarch dying/fleeing mid-attack lowering yield.
  - Restored "before its own attack lowers the yield" for pillage loot timing.
  - Added `length: long` and `length_reason` frontmatter; page is now 205 words.
- Left as is:
  - Opening sentences, "No one can order..." and "No other conquest..." bullets, defense-twice bullet, upgrade-refund sentence, hidden 0-100 sentence, output-stock-multiple sentence, refill rate, success/failure sentence.
  - "No colonization while besieged" not added (never on this page; already unreachable via a hand fix).
  - Per-outcome numbers not added (owned by Navarch actions, which has no page yet).
  - Refill example duration not restored (never shipped; recovery timing changed since #131).
  - The "besieger leaves some other way" backstop path not mentioned (not player-facing).
- Marked long: yes
- Remaining must_fix: none

## self-development

- Accepted: no
- Voter score: 2
- Restored:
  - Restored that only the first building decision in a cycle falls at a random time.
  - Restored and clarified step 3 (starter buildings, "main" habitable planet definition, ordering with "and then").
  - Restored "infrastructure on a planet that has none" wording for steps 4 and 5.
  - Restored the random-building step following starter buildings in step 6, and clarified "10 buildings"/"tries an upgrade first."
  - Restored both sentences of the workforce-scaling rule (more buildings = more workforce needed; builds nothing if workforce is short).
  - Restored the consequence that only moon/asteroid buildings get upgraded, since infrastructure caps a planet's building levels.
  - Fixed pluralization of `{name:}` tokens for single-building outputs.
  - Added `length: long` and `length_reason` frontmatter; page is now 260 words.
- Left as is:
  - Steps 1–2, "never builds a Monolith or Metamaterials Factory," "a fully built system only repairs," screenshot caption, opening sentence.
  - "Under siege, it orders nothing" kept out — owned by the siege page.
  - Not restored: the missing `wait_for_population_growth(4)` branch (never previously on the page; would require renumbering steps) and the hidden development profile (out of scope, per Q7).
- Marked long: yes
- Remaining must_fix:
  - Lines 49: "Once the system has 10 finished buildings, half the time it tries to upgrade a random building instead. If that building can't be upgraded, it does nothing that cycle. If none can be upgraded, it builds." — self-contradictory and inaccurate; the Upgrade and build_random branches are select siblings, so a failed upgrade always falls through to a build attempt in the same cycle, not "nothing." Replace with an accurate single fallback statement (e.g., "If nothing can be upgraded, it builds instead.").

## stability

- Accepted: no
- Voter score: 3
- Restored:
  - Restored a full-sentence caption naming what the two numbered highlighted lines show (stability from buildings, stability lost to population).
  - Restored the negative-stability-drops-population sentence under the growth bullet, with a link to `[[population]]`.
  - Restored the defense bullet's explanation of how stability affects a Siderian's Destabilize/Control odds, and the below-0-counts-as-0 rule.
- Left as is:
  - Intro sentence, temporary penalties section, "Buildings add more" line, growth cap of 25 (left to the population guide), second screenshot caption, status line.
  - No `length: long` added — page is ~143 words, under the leaf target.
- Marked long: no
- Remaining must_fix:
  - The revised "What it does" bullet 3 ("Higher stability makes a Siderian's Destabilize or Control more likely to fail. Stability below 0 counts as 0 here, so it does not make either action easier.") is cryptic: "here" has no clear antecedent and the sentence silently switches from the defender's point of view to the attacker's. It also half-explains a mechanic (`max(stability, 0)`) that the guide map assigns to the dominions/Siderians pages. Drop the floor-at-0 explanation from this page, or restate it without the double negative and name whose odds it affects.

## population-class

- Accepted: no
- Voter score: 3
- Restored:
  - Restored "Hover them to see the system's class" after the sentence about the system view showing points next to the owner's name.
- Left as is:
  - "The class uses the exact population..." sentence, "Each class is worth the points..." sentence, the faction score/Path of Influence sentence, the "?" intel note and neutral-systems note (never on the page, not restored as new edge cases).
  - No `length: long` added — page is ~85 words.
- Marked long: no
- Remaining must_fix: none

## mobility

- Accepted: no
- Voter score: 3
- Restored:
  - Restored the reason a percentage bonus from a Lex or tradition does not raise the Mobility bonus, plus a worked 30/33 example.
  - Restored the naming of the building trait (turning mobility/workforce into another resource) that changes this, with named examples (Reflect District, Business Arch, Monolith) and a link to `[[bonus-stacking]]`.
  - Restored the "On top of that" framing distinguishing the Reflect District/Business Arch credit bonus as a separate line from the Mobility bonus.
- Left as is:
  - Intro, Mobility bonus line name, rate sentence, worked example, negative-credit sentence.
  - Daily mutators (Prosperous Masses, Hungry Mouths) not added — no page exists to link them under rule 17.
  - Flash's Business Arch naming left unchanged (prior review already accepted it).
  - No `length: long` needed at 162 words.
- Marked long: no
- Remaining must_fix: none

## system-outputs

- Accepted: no
- Voter score: 3
- Restored:
  - Restored clearer wording for how a building that grows with defense/mobility/workforce counts as a flat bonus, so percentages apply to it too.
  - Restored the four-sentence explanation of how the Mobility bonus reads mobility from before its own percentage bonuses, with a 30/33 example.
  - Restored the sentence on buildings that change this (raising the counted Mobility bonus to 33), linked to `[[mobility]]`.
  - Restored "A credit percentage never counts the Mobility bonus."
- Left as is:
  - Output list, dominion sentence, sources list, penalties sentence, the flat-then-percentage bullets and production example.
  - Building names (Monument Dome, etc.) and the full mobility-buildings list not restored here — owned by mobility.md.
  - No `length: long` needed at ~300 words.
- Marked long: no
- Remaining must_fix:
  - The credit-Lex worked example ("...the system makes 100 + 10 + 30 = 140") is factually wrong: every credit Lex in the code is empire-level (`player_credit` to `player_credit`), so it does count the Mobility bonus's credits (143, not 140) once applied at the empire level. Only a system-level credit percentage (e.g., the Erased "mafioso" +5% skill) produces 140. Cut the paragraph or rewrite it around a system-level source.
  - The restored Mobility-bonus/percentage-stacking paragraphs duplicate content the guide map assigns to mobility.md (which owns the Mobility bonus topic). Replace with a single pointer sentence plus `[[mobility]]` link; keep the worked example and building exception only on the mobility page.
  - The new "How bonuses add up" closing sentence is a 45-word run-on once tokens expand, violating the ~15/25-word style rule; the mechanical lint doesn't catch it because it strips tokens before counting. Split the setup sentence from the worked math, using an indented example block like the page's existing production example.

## dominions

- Accepted: yes
- Voter score: 4
- Restored:
  - Restored the plain-wording explanation that a successful pillage takes loot from the defender's own credit/technology/ideology (not the dominion), based on the dominion's full output even though the owner receives only a share.
  - Restored the explanation of how a negative-output dominion lowers income (your share of a negative value is negative too).
  - Restored what happens when another player's Siderian uses Control on a dominion (it becomes their dominion).
  - Restored naming the Abandon action explicitly instead of using it as a bare verb.
  - Restored the contrast that, unlike a player's own systems, a dominion's population gives it no defense.
- Left as is:
  - The Administer bullet was not re-added to "Losing a dominion" (Administer is not a loss).
  - What Abandon keeps (buildings, population, self-development) stays on administrative-operations.md.
  - Pillage multiplier, yield, and bombard effects stay on the siege page.
  - No `length: long` needed at 338 words.
- Marked long: no
- Remaining must_fix: none

## population

- Accepted: no
- Voter score: 3
- Restored:
  - Restored a fuller screenshot caption explaining the negative growth label and shrinking bar, tied to population exceeding housing.
  - Restored the fact that population drops twice as fast below −10 stability.
  - Restored a full sentence for the stability-cost bullet under "What population gives," replacing a dangling fragment.
  - Restored the explanation that taxes/stability cost/defense use the rounded-down workforce number, while growth uses the exact value including fractions.
- Left as is:
  - Defense bullet, taxes bullet, stability-bullet split, growth-stops-when-stability-runs-out sentence, size bullet, growth-target intro, chart caption, formula block, closing Navarch/siege sentence.
  - First-draft content on workforce mobilization, taxes/mobility per point, and per-point stability numbers not restored — moved to their owning pages.
  - No `length: long` needed.
- Marked long: no
- Remaining must_fix: none

## dominion-tax-rate

- Accepted: no
- Voter score: 3
- Restored:
  - Restored the reasoning for how rate bonuses add (straight-onto-rate, not compounding like a percentage bonus), with a worked +20% example (30% → 50%, 500 credits → 250 paid).
  - Restored the "negative output → negative share → lowers income, with no limit/floor" explanation.
  - Restored the sentence naming this income as "Dominions" in the empire's income breakdowns, before the screenshot.
- Left as is:
  - First example (30% rate, 500 credits → 150 paid), "rate starts at 30%" bullet, share-taken-after-penalties sentence, production/defense-never-shared sentence, screenshot caption.
  - Unexplained Lex/tradition types in the table not addressed — no Lex page exists yet.
  - No `length: long` needed at 176 words.
- Marked long: no
- Remaining must_fix: none

## system-limits

- Accepted: no
- Voter score: 3
- Restored:
  - Restored a full caption for the Systems counter explaining what it shows and that its bar fills as the limit nears.
  - Restored the hover instruction for finding your limit and its sources via the Systems/Dominions counter tooltip.
  - Restored "The tables below list which Lexes [raise each limit]."
  - Restored clarity on what finishes and triggers the limit recheck (Navarch or Siderian finishing the action), and what happens at the limit (colonization/Control cancelled).
  - Restored the conquest edge case: a conquest can still kill population and damage buildings even if the system isn't taken due to being at the limit.
- Left as is:
  - Opening definitions, start values (1/0), both "refused" lists, Lex unslot sentence.
  - "Conquest" stays unlinked — no conquest page exists yet.
  - Whether a cancelled colonization keeps its ship not addressed — belongs to the colonization page.
  - No `length: long` needed.
- Marked long: no
- Remaining must_fix:
  - "Administer, which turns one of your dominions back into a system (see [[administrative-operations]])" and the equivalent Liberate bullet violate rule 4 (point instead of half-explaining): they restate, inline, the fact that administrative-operations.md itself owns, duplicating content across pages. Revert both bullets to bare pointers: "Administer (see [[administrative-operations]])" and "Liberate (see [[administrative-operations]])."
