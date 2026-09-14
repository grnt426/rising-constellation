# Backlog

## population
- In a system you own, each whole point adds {const:system_base_defense} [[defense]].: Optional: keep the constant and let the defense page carry the Flash case, or add "(none in a Flash game)" if the style rules allow.
- Growth (1, 2) is negative here because population is above the system's housing (3).: Optional: "...because population is far above the system's housing (3)." Or "above its growth target"
- "At 120 population or more, a system grows at a fifth of the speed of an empty one" is slightly ambiguous on first read.: Consider "...a fifth of the speed of a system with no population" or similar, to remove the need to infer what "empty" refers to.
- The formula block mixes a true minus sign (−10, in "stability below −10") with hyphen-minus signs from the {rate:} tokens (-0.002, -0.001).: Not strictly actionable since the rate token's glyph is compiler-generated, but worth flagging to the compiler owner if a consistent minus glyph is wanted across manually-typed and token-generated numbers.
- The workforce (2/15) and stability (22) readouts in the screenshot still have no labels. Labeling all five marks would need more than the one caption sentence rule 8 allows. The workforce and stability pages cover those readouts.
- The formula's housing factor is not tied back in words to the "housing + 0.75" bullet. Formula blocks are for players who want them, and adding a connecting sentence would repeat the bullet.
- At Flash speed the defense bullet reads "adds 0 defense". It is true, but a little stiff. If reviewers prefer, the other option is "population adds defense, except in a Flash game", which drops the number.
- Minus glyphs in the formula block: typed −10 vs '-0.002' from {rate:} tokens. The compiler generates the token glyph, so the page cannot fix it. This is for the compiler owner.
- Voter stumble: stability (22) in the shot is still unmarked. It does not bear on the growth caption, and the stability page has its own shots. Adding a fifth mark would crowd the caption.
- Voter stumble: the chart's three stability lines seem to end at the same population. How the lines look comes from the RC.Help.Charts generator, and the prose already explains the plateau. Changing the chart's arguments or generator is outside this revision.
- Voter stumble: the formula block is dense. Rule 9 puts the exact formula last, in an indented block, so it stays.

## stability
- The leaf's opening (before the first screenshot) runs three sentences: "Stability is how happy a system's population is. It starts at 35. Each whole point of population changes it by -1.": Either trim to two sentences, or move the numeric detail after the screenshot alongside the What-it-does list, keeping the very first line to a pure one-sentence definition.
- "It defends the system against a Siderian's Control and Destabilize. See [[dominions]].": Split the two: keep "It defends the system against a Siderian's Control. See [[dominions]]." as its own bullet, and mention Destabilize only in the Temporary penalties section where it already lives.
- "Each whole point of population changes it by {const:system_population_negative_happiness_factor}.": Add a short concrete example, e.g. "20 population lowers it by 20.", the way the housing and mobility leaves show a worked number alongside the rate.
- Recapture stability-tooltip-destabilized with a penalty of 20 or less, so the line matches the 15/20 costs on the page. Needs a fixture and capture change outside stability.md.
- Voter stumble: 'Stability per Appeal Potential' and 'per Local Population' in the generated buildings table are not explained. The rows come from the generator, and explaining them would mean prose links outside this leaf's brief.
- Voter stumble: the table's arrow notation is explained only after the table. The generator prints that legend line itself, so the page cannot move it.

## population-class
- The system view shows the points next to the owner's name.: Optionally reword to "The system view shows the points next to the owner block" or "at the top of the system's properties".

## housing
- The bullet "Buildings on moons and asteroids still mobilize workforce." sits inside housing's list of body-share edge cases.: Drop the sentence from housing or move it to the workforce leaf.
- The heading "Population on each body" is followed immediately by "The system's workforce is shared out across its planets", switching terms from population to workforce without connecting them.: Either retitle the heading to "Workforce on each body" or add a short clause the first time workforce appears.

## workforce
- The bulleted list under "Which buildings mobilize:" mixes buildings that DO mobilize with entries that don't.: Split the list, or add a short lead-in clause to the last two bullets (e.g. "Exceptions:").
- The over-mobilization block gives the worked example before the general formula.: Swap the two lines (formula first, then the worked example).

## population-status
- {shot:system-population-status#current|The highlighted band is the system's current status.}: Add a short clause, e.g. 'Each band shows the output the system keeps. The highlighted band is the system's current status.'
- frontmatter sources: lib/game/instance/stellar_system/stellar_system.ex:275-330: Replace with stellar_system.ex:560-575, 867-872 and 1204-1222, and add PopulationStatus.vue as the source for the shot.
- The closing bullet stacks three unrelated triggers into one sentence.: Split into two short sentences.
- The generated {table:population_statuses} table appears before the {shot:system-population-status} screenshot.: Move the shot above the table.
- "Tooltips show this penalty as {ui:resource-detail.misc.uprising_penalties}." restates a fact already owned by system-penalties.: Either drop the sentence or rephrase as a forward pointer.

## system-penalties
- Voter stumble asking for concrete sizes in the table for the over-mobilized and insufficient-stability rows: not applied. The guide map gives the sizes to workforce and population-status, and the example now shows one number for each.
- Voter stumble about order (table lists Besieged, Over-mobilized, Insufficient stability, but the example applies workforce, then Protests, then besieged): left as is. The penalties multiply, so order does not change the result.

## credit
- "Your empire's income is the sum of your systems' credits plus a share of your dominions' credits, minus Agents' salaries and Fleet maintenance.": Optionally add a hedge such as "...Some Lex and faction traditions add to or take from this total."
- The Taxes section breaks its own flow with a units aside.: Move the units sentence to sit right before or after the worked-example line, or drop it here since game-time already owns the explanation.
- The income formula is a three-term sentence with no worked example, unlike Taxes.: Add a short example line in the same style as the taxes example.
- Section prose is inconsistent: some headings carry sentences, others jump straight to a table.: Either add a one-sentence lead-in to Buildings/Other sources or confirm the no-prose-before-a-table pattern is intended.

## mobility
- With a {name:building.finance_open}, a {name:building.finance_orbital} or a {name:building.monument_dome} in the system, the bonus counts the raised mobility.: Keep the sentence and widen it slightly to mention daily mutators, or leave it since 'usually' already hedges.
- A {name:building.finance_open} or a {name:building.finance_orbital} also adds its own credits for each point of mobility (and the same building named in the exception sentence).: Accept the small mismatch, or say it without naming buildings per speed.
- The closing sentence duplicates the table directly below it without adding new information.: Either drop the sentence or fold it into the paragraph above with a clear transition.
- The transition between "the bonus counts the raised mobility" and the next sentence about the same buildings' own credit bonus is abrupt.: Add a short connector ("Separately," or "On top of that,").
- Voter stumble 'credits below zero when the bonus is added' (before or after taxes and other bonuses): not changed, [[bonus-stacking]] owns it.
- Voter stumble asking for a worked example of the percentage caveat: not added, would restate bonus-stacking page.
- Voter stumble: 'Monolith is never defined'. A {name:} token cannot link to a building card, and explaining the Monolith here would half-explain a building. It stays as the plain building name.
- Voter stumble about the 'usually ... from before' wording is gone with the rewrite. There is no separate change for it.

## system-outputs
- The closing sentence of "How bonuses add up" is circularly worded and harder to parse than the rest of the page.: Rephrase to state the mechanism once without the self-referential repetition.
- The "other lines" sentence lists five items where only one is a working link, with no visual or textual cue for why.: Consider a short parenthetical or reordering.
- Voter stumble: 'A percentage adds nothing while the total is below zero' does not say which total, and has no example. Left unchanged; would expose sort-order detail.
- Voter stumble: 'Each percentage then adds its share of that flat total' could say outright that later percentages ignore the running total. Accepted wording already covers this.
- Voter stumble: the second example line recomputes from 100 instead of building on 110. Accepted wording that shows the cumulative sum.
- Optional mirror of the 'credit percentages never count the Mobility bonus' rule and the conversion exception on mobility.md. Outside this task's edit scope.
- Voter stumble: 'A percentage adds nothing while the total is below zero' is not shown in the worked example. Skipped, accepted wording.
- Voter stumble: production (the leftmost readout) is not boxed in the screenshot. Skipped, brief says production lives in a separate box.

## defense
- Each whole point of [[population]] in a system you own adds {const:system_base_defense} defense. In a Flash game, population adds no defense.: Keep the token and make the sentences read well at every speed.
- Defense does nothing against the Erased either. Intelligence defends against them.: Soften it to something like 'The system's Intelligence helps defend against them.'
- "The odds themselves are explained with the Navarch actions." (What it does): Either drop the sentence until the Navarchs category ships a page to link to, or soften it.
- "For example, in a Legacy or Tactic game, 20 population adds 3 defense.": Rewrite as an explicit equation line.
- Heading "Population and defense" immediately under a page already titled "Defense": Consider a leaner heading like "Population".

## production
- {shot:production-tooltip#initial|The highlighted row is the system's base production.}: Name the row in the caption.
- {shot:production-tooltip#initial|...} next to the base-production sentences: Say in the caption that the capture is a capital.

## technology
- A successful pillage on one of your systems takes technology from your stock. See [[siege]].: Say 'on one of your systems or dominions', or leave the dominion case to [[siege]] as it is now.
- The opening paragraph uses three sentences to say what technology is.: Consider merging into two sentences.
- The third bullet under "Where it goes" previews the same ground as the later table.: Either drop the bullet or fold its point into the later heading's intro sentence.
- The heading "What changes your empire's technology income" is noticeably longer than its sibling headings.: Shorten to match brevity.

## ideology
- Voter stumble 'the screenshot has two identical 0 readouts side by side': needs a capture change if it should be fixed.
- Voter stumble 'Your dominions add a share of theirs is vague until you follow the link': left as is, dominion-tax-rate owns the share.
- The accuracy critic noted that technology.md has the same Knowledge-skill gap. Outside this reviser's edit scope.

## star-systems
- Your capital starts with {rate:system_capital_base_production|production}... becomes {rate:system_base_production|production}: Optional softening when the two values match at medium speed.
- Reader stumble: the visibility sentence interrupts the ownership topic: Give it its own short line or fold into a closing remark.
- Awkward elliptical phrasing in the conquest bullet: Reword to "It keeps its buildings and whatever population the attack left behind."
- The status table's two middle rows read as near-duplicates: Consider a small wording tweak so the two rows are easier to tell apart.
- Voter stumble: the dominion screenshot's split diamond marker is only named in the alt text. Needs a new highlight mark (shot request).
- Voter stumble: the Navarch and Siderian roles are not introduced before the table. Explaining the roles belongs to the Navarch and Siderian categories.
- The plain-text search form renders '40 production per tick ,' with a space before the comma. Compiler text-flattening artifact, not page content.

## stellar-bodies
- The guide map's brief item 2 ("Moons orbit planets and gas giants...") is never stated in prose.: Add one short sentence after the body-types table.
- The infrastructure-tile section never points forward to more tile/building mechanics.: Add a short pointer sentence, e.g. "See [[production]]."

## colonization
- {shot:uninhabited-state#status|An uninhabited system says it can be colonized.}: Reword the caption to name the highlight.
- The colonization page links interception to [[stances]] even though the guide map assigns it to the future Navarchs chapter.: Either drop the link and state plain text, or confirm stances is an acceptable interim target.
- Mid-sentence link labels in the requirements list alternate unpredictably between a capitalized page title and a lowercase bare word.: Give the single-word links explicit labels for consistency.
- The link target for the System Limit bullet resolves to a broader page title than the term it follows.: Use a custom label, e.g. [[system-limits|System Limit]].

## system-limits
- Your System Limit starts at 1 and your Dominion Limit at 0. Lexes raise them.: Add one plain-text edge line, e.g. 'Some game modes also raise them.'
- The list format is inconsistent between sibling items.: Match the bullet's shape to its siblings.
- "finishes" has an implicit, slightly ambiguous antecedent.: Add a small clarifying word.

## administrative-operations
- after 3 Liberates or Administers in total: formula with no shown total.: Add a speed-aware total if the compiler can show one.
- The Cost section reorders the three operations relative to how they were just introduced.: Lead with the Liberate/Administer price to match the intro order.
- "in this game" is vague filler in the Cost paragraph.: Drop "in this game".
- The trailing "you included" clause reads as an afterthought.: Front-load it instead.

## siege
- A successful pillage takes a multiple of the system's credit, technology and ideology output from its owner.: Optional clarifying rewrite for the autonomous-system case.
- "At 55 yield, a pillage takes 55 % of the loot at 100." is ambiguous on first read.: Rephrase as an explicit example line.
- "A pillage counts its loot first." is a terse clause with an unclear referent.: Make the order explicit.
- The two bullets under "Each hit picks a random building:" are not grammatically parallel.: Give both bullets the same shape.
- nice_to_have (pillaging an autonomous system takes from no one): skipped for the length cap; still true and worth adding if the page gets room.
- nice_to_have (brief's refill example {duration:180}): not added; {duration:} takes only a number or constant key, not impact/growth.

## dominions
- Opening "Losing a dominion" with Administer reads oddly since Administer means the player keeps the system.: Retitle the section or move the Administer sentence to its own lead-in.
- Two consecutive mentions of [[dominion-tax-rate]] close together feel repetitive.: Combine into a single closing pointer once the pillage paragraph is trimmed.
- Voter stumble: 'Lexes/traditions are unlinked jargon'. Stay plain text until that category ships pages.
- Voter stumble: 'stance' is used as a known term. Already links to [[stances]]; no separate definition added.
- Lexes and traditions have no links: the manual has no lex/tradition page yet.
- dominion-properties screenshot: the half marker described in alt text isn't framed by the highlight box. Out of this file's scope; needs a shot manifest change.
- 'No Navarch can stop a Control, whatever its stance.' reads without a lead-in. It is the brief's one-sentence edge case; left as accepted wording.

## dominion-tax-rate
- Removed bullet naming the {ui:resource-detail.type.dominion} group: Name the group in the caption instead.
- sources: front/src/locales/en/game.json:1581: Remove the source line, or keep only if the caption reuses the token.
- The worked example precedes the fact that 30% is the actual base rate.: Move or fold the base-rate fact ahead of the worked example.
- The screenshot sits right after the negative-output edge case but doesn't visually reinforce it.: Place the screenshot right after the opening paragraph instead.

## self-development
- "Bigger systems need more free workforce to build." sits alone with no link back to which step(s) it modifies.: Attach it to the step it qualifies.
- "From 10 buildings, half the time it tries an upgrade first." has an unclear referent for "10 buildings".: Make the referent explicit.
- The prose refers back to "step 7" and "step 5" by number rather than by content.: Replace the numeric back-reference with a short restatement of the condition.
- Nice to have (starter-step conditions: infrastructure, more than 4 free tiles, only qualifying planet): not added because the page is at the 180-word cap.
- Voter stumble: no thresholds for "Bigger systems pick buildings that need more workforce." Left out because of the length cap.
- Nice to have "first decision comes at a random point in the first cycle": left out because of the length cap.
- "Under siege, it orders nothing." edge case removed to fit the cap; siege.md already covers it.
- Nice to have "It does the first that fits" wording: shortened, not to the longer suggested sentence, because of the length cap.
- Word headroom is only about 2 words under the 180 cap.

## Screenshot requests

(none — see the individual page findings above for shot-manifest changes still needed: a highlight mark on the dominion split-diamond marker (star-systems, dominions), and recapturing stability-tooltip-destabilized with a penalty of 20 or less.)
