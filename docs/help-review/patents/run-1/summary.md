# Run 1 summary

| slug | outcome | revisions | kept round | final must_fix (accuracy/clarity) | voter scores |
|---|---|---|---|---|---|
| patents | accepted | 1 | 1 | 0/0 | 3, 4 (mean 3.5) |
| price-scaling | accepted | 1 | 1 | 0/0 | 4, 4 (mean 4) |
| lexes | parked | 2 | 1 | 1/0 | 4, 4 (mean 4) |
| lex-changes | accepted | 0 | 0 | 0/0 | 4, 4 (mean 4) |
| agent-limits | accepted | 2 | 2 | 0/0 | 4, 4 (mean 4) |
| traditions | parked | 2 | 1 | 2/0 | 4, 4 (mean 4) |

## Parked

- lexes: parked after 3 rounds (2 revisions), kept round 1; final round still had must_fix 1/0.
- traditions: parked after 3 rounds (2 revisions), kept round 1; final round still had must_fix 2/0.

## Hand fixes after the run (2026-09-29)

Both parked pages were fixed by hand, then checked by one independent verifier (accuracy against code and a
probe run, plus style), whose corrections were applied. Both now have `status: reviewed`.

- **traditions:** the remaining must_fix was a generator bug, not page text: `{table:traditions}` listed the
  Rebellion, the Rebel Defense bot faction no player can join. `RC.Help.ResearchCatalog` now lists playable
  factions only (test added). The page kept round 1, so round 2's wrong percentage sentence is not in it.
- **lexes:** the lex panel section now describes the layout in one correct sentence ("one tab per branch other
  than Origin, each starting from Age of Exploration"), dropped the Cost Increase Factor bullet (price-scaling
  owns it), and describes the reset and clear buttons.

Consistency findings applied by hand on the new pages: 0 (wait rules owned by lex-changes; picks dropped on close
kept in the lexes panel list only), 1 (Limits links lex-changes), 6 (no hand-typed UI string), 7 ("activate" only
for agents), 9 (patents ties the upgrade patents' info line to the infrastructure cap), and a system-outputs
link on traditions (part of 5).

Left for the linking run (guide map section 7), because they edit existing pages: 2 (system-limits vocabulary and
links), 3 (system-limits should mention the Expansion Charter modifier), 4 (ideology and technology vocabulary),
5 (links into traditions from ideology, technology, dominions, mobility and system-outputs). Finding 10 is
resolved by the generator fix.
