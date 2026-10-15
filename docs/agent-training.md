# Agent training

Reference for agent training as built in October 2026: basic training at a
Delta Polytech, specialized training at the university of each agent type,
which earns neural rewires, and the three support buildings whose levels
speed training up or make it cheaper for every student of their system. The
original proposal and its expected impact are in `docs/agent-training-impact.md`;
this document follows the final spec of 2026-10-15, which takes precedence
over every earlier ruling, says which of the proposal's open questions were
settled and how, and where the code is.

The Great Pilgrimage from the same proposal is not built.

## The rules

Training has three outcomes: experience, skill points moved (reallocation)
and skill points added. Three kinds of building serve them.

An agent in the deck can be sent to a **school** in place of a governor's seat
or the field. It becomes a **student**: a fourth deployed state beside
governor and on board. A student has no fleet, cover or order queue. It sits
in one system until its owner recalls it to the deck, or until its course
ends.

A student counts as a deployed agent in every way that matters to its owner.
It holds an agent slot of its type, draws its standard salary, and can be
removed or seduced where it sits.

| | Basic: Delta Polytech | Specialized: university |
| --- | --- | --- |
| Building | Delta Polytech (`university_open`) | Monolith for Siderians, Orb-INTEL for Erased, Aerospace Military Academy for Navarchs |
| Places | One per building, whatever its level | Per building: one at levels 1 and 2, two at 3 and 4, three at 5 |
| Who | Agents of the system's owner, any type, from level 1 | Agents of the building's type, from level 5, the owner's included. The faction shares the places: one agent per player and per building, studying or waiting |
| Experience | The governor's rate (24 a day at Legacy), plus what Experiment Stations add | Nothing during the 4 h of settling in (Induction), then twice the governor's rate (48 a day), plus what Experiment Stations add |
| Neural rewires | None | One per day of course, less what Delta Polytechs take off, up to five held |
| Fee | None beyond the salary | Per tick, 2 ideology (Siderian), 2 technology (Navarch) or 20 credits (Erased) times the agent's level plus the university's level, less what Holodomes take off. The salary is paid on top, never discounted |
| Ends | When recalled | At five rewires held, or when the fee cannot be paid. Either way the agent goes straight back to the deck, freeing its place |
| Queue | None | One agent behind each student, when no place is free |
| Defence | Protection and Determination halved | 40% of the agent's own at building level 1, ten points more per level, 80% at level 5 |

At Legacy speed the governor's rate is 1 experience per hour, settling in
takes 4 hours and a course day is 24 hours, so a full course without support
buildings is 5 days and 4 hours.

The Citadel takes no part in training. It and the Holodome seated agents for
a few days of the 2026-10-13 design passes; the final spec gave seats to the
Polytech alone.

### A university course

1. **Settling in.** The student holds its seat and pays the fee, and earns
   nothing yet. Its seat sits in a ring that fills until the course starts,
   its card and its line in the agents list give the time left, and its
   opened card lists settling in as its one action, with the moment it is
   over. No building shortens it.
2. **On its course.** Experience at twice the governor's rate. Each full day
   adds one neural rewire.
3. **Course over.** At five rewires the course ends and the agent is recalled
   to its owner's deck at once, siege or not, which frees its place. Nobody
   has to fetch it. The `:graduated` phase only lives until the owner's
   player agent has read it (`{:update_character, ...}` with a finished
   course triggers the recall).

Rewires belong to the agent and are kept through a recall. An agent with a
rewire left takes no duty of any kind: it cannot be made governor, sent to
the field, sent to a school or put in a queue, and it cannot be sold
(`:reallocations_unspent`). The rest an agent takes after any duty
(`character_deck_cooldown`) runs at the same time: rewires can be spent
while it rests, and both must be over before its next duty. It can take as
many courses as its owner likes, each time once the rewires of the last one
are spent or discarded. Discarding gives up every rewire the agent has left
and leaves its skills alone; the card's button asks twice.

The seat of a university student is drawn inside a ring cut into five
segments, one per rewire, and a segment lights up when its rewire is earned.
The segment of the rewire being earned pulses slowly and is drawn over as
its day of course passes, so the hours left can be read off the ring; the
seat's tooltip gives them ("2 of 5 neural rewires, next in 3 H 12 M"). A
viewer who is not shown the rewires earned sees neither.
A student is seen like a governor: its name, type and portrait from
visibility 2, its progress (`reallocations`) at visibility 5, whatever the
viewer's faction.

The fee is an income line, like wages, and follows the agent's level as it
rises. When the stock of the resource it is paid in is empty and still
falling, every student paying in that resource is sent home: the course ends
there and the agent goes back to the deck with the rewires earned so far.

### Defence in class

A student's own Protection and Determination fall while it is in class
(`Training.defense_factor/2`, `Character.effective_protection/1`): to half at
a Polytech (`training_defense_factor`), and at a university to a share set by
the building's level, 40% at level 1, 50%, 60%, 70% and 80% at level 5. With
several buildings of one university the highest level counts. The card prints
the cut value in orange and its tooltip the base ("Protection, base 80: -60%
(training)"). A university student seated before its system told it the
level defends itself at the Polytech's half until then.

### What the support buildings give

Three support buildings, one effect each (the game's rule of three), counted
over every building of the system:

| Building | Effect at level 5 | Applies to |
| --- | --- | --- |
| Experiment Station (`research_orbital`) | +15% of the base training experience | every student of the system, Polytech seats included |
| Delta Polytech (`university_open`) | -7.5% of the base rewire time | university students |
| Holodome (`ideo_dome`) | -15% of the base fee | university students |

A building of level 1 to 5 gives 10, 25, 45, 70 and 100% of its level-5
effect (the progression proposal of 2026-10-15, chosen over the linear rates
of the final spec):

| Level | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- |
| Experiment Station | +1.5% | +3.75% | +6.75% | +10.5% | +15% |
| Delta Polytech | -0.75% | -1.875% | -3.375% | -5.25% | -7.5% |
| Holodome | -1.5% | -3.75% | -6.75% | -10.5% | -15% |

- Bonuses from separate buildings add, each on the base experience, rewire
  time or fee, without compounding. Geography limits the stacking: fifteen
  Experiment Stations of level 5 give +225% experience (156 a day in a
  university), six Delta Polytechs of level 5 take 45% off the rewire time
  (13 h 12 a rewire).
- The fee reduction is capped at 80% from all sources (`@min_cost_factor`
  in `StellarSystem.School`): five Holodomes of level 5 take 75% off, a
  sixth brings it to the cap. The salary is never discounted. Experience
  and rewire time have no cap; a floor of 1% on the rewire time
  (`@min_time_factor`) is a guard no system reaches.
- The experience bonus also raises basic training. Settling in and the
  salary are not affected by any building.
- A damaged building gives nothing.
- The three are ordinary system bonuses: targets `sys_training_xp`,
  `sys_reallocation_time` and `sys_training_cost` (`bonus-pipeline-out.ex`),
  written on each level of the three buildings in
  `building-{slow,medium,fast}.ex` (Flash has no Holodome; its single-level
  Experiment Station and Polytech give the level-1 values), summed by
  `compute_bonus` into the system's `training_xp`, `reallocation_time` and
  `training_cost` values. Building cards and the manual print them as
  percentages with up to three decimals. The dominion AI leaves them out of
  what a building is worth to it (`SystemAI.Weights.gains/1`): a dominion
  has no school.
- The fee counts the level of the university. With several buildings of the
  same university in a system (only Academies today) the highest level
  counts for every student (`School.school_level/3`), since places are
  pooled per school.

**How a student learns of it.** A student ticks by itself, hours apart, so
its system hands it four numbers and they ride in its `training` map
(`xp_bonus`, `time_factor`, `cost_factor`, `school_level`;
`Training.conditions/1` reads a map that carries none as no bonus):

- At enrolment the system stamps them on its copy of the student
  (`StellarSystem.enroll_student/2`) and the player agent starts the
  character agent with that copy's `training`.
- After every `compute_bonus` and every `sync_schools`, `sync_training/1`
  casts `{:training_conditions, conditions}` to each student whose copy
  differs (`School.outdated/1`). The character agent ticks first, so the
  time already spent is played under the old conditions, then takes the new
  ones, re-anchors `training.at`, re-arms its tick and sends its usual
  update to its owner and its system. The system's copy then matches.
- A rewire under way keeps its share done: `Training.set_conditions/2`
  scales `elapsed` with the time a rewire takes.
- Students seated before this shipped run without bonus, pay on the level
  of the agent alone and defend themselves at half, until the next
  recompute in their system.

The client reads the same four numbers (`conditions` in
`front/src/game/training.js`) for the rate on the card, the fee, the
defence and the segment being earned. The tooltip of each school ends with
what its system gives ("In this system: +21.75% training experience,
-12.75% rewire time, -18.75% course fee"), and the system's details page has
an Agent Training section with the three percentages, each with the
breakdown by building every stat of that page has (`Details.vue`;
`ResourceDetail` takes a `unit` for the percent sign).

### One place per player and per building

A university building of level 5 has three places, and they are for three
players: a player holds one place per building, studying or waiting, whatever
its level, and the owner of the system is held to it like anyone else. The
point is that a few high buildings serve many players, and that no rich
player fills every place.

- Places are counted per school and not per building, so the limit is the
  number of host buildings standing in the system
  (`School.player_places/3`). The Aerospace Military Academy is Limited (one
  per body), so a system can hold several and a player one place in each. In
  the content files the Monolith and the Orb-INTEL are Unique (one per
  system).
- A place is a student in class or an agent in the queue, called or not
  (`School.places_held/5`). A player with a student in the building cannot
  queue a second agent there, its own student's place included, and a
  player waiting there enrols no other agent. A refusal is
  `:one_agent_per_building`. An agent the queue has called is not counted
  against itself.
- Joining the queue reserves the agent's deployment slot.
- `settle/2` calls no agent whose owner holds every seat it may, a guard
  for states from before the limit.
- A Polytech has no such limit: it seats one agent per building and its
  owner alone.
- Nobody is turned out for it. A player seated twice before the limit
  existed keeps both seats.
- The client reads `per_player` in the system's `schools` summary: with the
  player's place taken, the free seats and the queue places of that school
  are not offered and the tooltip says why.

### Sieges

Nobody is sent to a school, and nobody joins a queue, while the system is
under siege. A seated student cannot be recalled during a siege either, by
its owner or by the owner of the system, at a Polytech as at a university
(`:no_character_deactivation_under_siege`; kept on 2026-10-15). Only the
system knows it is besieged when the school is a faction-mate's, so the
player agent asks it (`{:check_student_recall, id}`). A course that ends
during a siege still sends its agent home. A queued agent can always
withdraw.

### The queue

A university keeps a queue: one deck agent may wait behind each seated
student, when no place is free. With one free, the agent just enrols. A
Polytech has no queue (`:school_has_no_queue`); a line left at a Polytech
by a game from before is cleared, and its agents keep their place in the
deck.

- The agent stays in the deck. It takes no other duty and cannot be sold
  (`:character_queued`), nor wait in a second queue.
- It holds its agent slot from the moment it joins, so that the seat finds
  it able to come (`Player.character_available_slots?/2` counts it).
- When the student ahead leaves for any reason that leaves the seat usable
  (recalled, sent home, course over, removed), the seat is held for the
  queued agent and its owner's player agent enrols it at once. It then
  settles in like any student. A seat freed with nobody behind it goes to
  the first agent waiting in that school.
- If the seat is lost with the student (building damaged or demolished, a
  level lost, system changed hands), the agent loses its place and stays in
  the deck.
- Its owner can pull it out at any time, a siege included. Dismissing it
  frees its place.
- The agent's card states the longest it can wait: the rest of the course of
  the student ahead ("38hrs to be seated", and the date on hover).
- Only the faction that owns the system is sent the queue
  (`Faction.StellarSystem.obfuscate/4` compares faction ids, not visibility).
  A queued agent is not in the system and cannot be targeted.

A seat that comes free during a siege is held, and the queued agent takes it
when the siege is lifted.

### The owner of the system

The owner may turn out any student of its schools, its own or a
faction-mate's, and any agent waiting in a queue (`eject_student`). A student
goes back to its owner's deck with what it earned; a queued agent only loses
its place. A queued agent can be turned out at any time, a seated student not
during a siege.

### Spending rewires

Rewires are spent from the deck. One rewire moves one skill point: the owner
takes it from one skill and gives it to another. Two rewires add a point to
a skill outright, so that an agent with no point to spare still gets
something from a course, at half the rate: five rewires move five points or
add two. The two can be mixed in one change. A point a skill gains is billed
as a move whenever another skill gave one up, and every point taken has to
be placed (`Training.reallocation_cost/2`; the card's + and - follow the
same count through `reallocationCost` in `training.js`). An agent that adds
points ends up with more skill points than its level gave it.

Two limits apply to a skill that gains points, the same two a level-up
respects:

- no skill passes 12;
- no skill passes the agent's main skill, as the main skill ends up.

Points can be taken from the main skill, which lowers the bar for the others.

### Losing a seat

A school turns students out when it can no longer seat them: the building is
demolished or damaged in a raid, or the system is conquered, liberated or
abandoned. The latest arrivals of a school that lost seats leave first. After
a conquest only students of the new owner's faction stay in the universities,
and nobody stays in the Polytech. A student turned out goes back to its
owner's deck with what it earned.

Agents queued behind a student who is turned out lose their place with it.

## Decisions on the proposal's open questions

| Question | Decision |
| --- | --- |
| One Polytech seat per player or per building | Per building. The proposal's wording, read literally. The Polytech is the one basic school (final spec, 2026-10-15). |
| Does a student use an agent slot | Yes. It stays on the roster like a governor. |
| Deck or map | Map. It has a system, can be targeted and draws wages. |
| Halve the agent's own stats or the whole defence | The agent's own Protection and Determination, as proposed. Since 2026-10-15 a university student keeps 40% to 80% by the building's level, a Polytech student half. The host system's Intelligence or Stability still counts in full. `training_defense_factor` holds the 0.5. The card prints the cut value in orange and its tooltip the base ("Protection, base 80: -50% (training)"). Until 2026-10-08 the card printed the base value in orange: the engine cut it all along, the card passed the cut value to the `obfuscate` filter as the value to test instead of the value to print. |
| Is an Erased student visible | Yes. Students are listed apart from on-board agents and cover does not apply. |
| Re-enrolment and limits on moves | Re-enrolment is open, any number of times, once the last course's rewires are spent (decided by the owner, 2026-10-06). Moves respect the cap of 12 and the main-skill rule. |
| What happens at five rewires | The agent is recalled to the deck at once (2026-10-07). The first build left it waiting in the system. |
| Recall during a siege | Refused for a seated student, at a Polytech as at a university; a queued agent can always leave (2026-10-07, kept 2026-10-15). |
| One agent per player per building | One agent per player and per university building, studying or waiting, the owner of the system included (final spec, 2026-10-15). It was dropped on 2026-10-07, came back on 2026-10-13 counting seats only, with a player's next agent queued behind its own student, and now counts the queue too. |
| Who sees a student's progress | Any faction with visibility 5, as for a governor (2026-10-07). The first build kept it to the owner's faction. |
| Selling an agent that holds rewires | Refused (2026-10-07). The first build let the buyer inherit them. |
| A queue | One agent behind each seated student of a university (2026-10-07). The Polytech lost its queue on 2026-10-15. See "The queue". |
| Ejection | The owner of the system can turn out students and queued agents (2026-10-07). |
| Fee fixed at entry or following the level | Following the level of the agent and the level of the university (highest building of it in the system). 2 ideology or technology, 20 credits, per level of each, since 2026-10-15; 5/5/50 per agent level at first, then 1/1/10 and 3/3/30 during the 2026-10-13 passes. Holodomes cut it, up to 80%. |
| Do the Citadel and the Holodome seat anyone | No (final spec, 2026-10-15). Both did for a few days of the 2026-10-13 passes. The Citadel has no part in training; the Holodome is a support building. |
| What the Holodome gives | Up to -15% of the course fee at level 5, on the 10/25/45/70/100% progression, fee cut capped at 80% (2026-10-15). It was -2% then -4% per level, linear, on 2026-10-13. |
| Can a rewire do more than move a point | Yes (2026-10-13, kept in the final spec): two add a point outright. |
| How the support buildings grow with their level | 10, 25, 45, 70 and 100% of the level-5 effect (2026-10-15, the progression proposal pasted with the final spec, chosen by the owner over the spec's linear rates). |
| Who the experience bonus helps | Every student of the system, Polytech seats included (2026-10-13). It comes from Experiment Stations since 2026-10-15 (Delta Polytechs gave it before), and the Polytech gives the rewire-time bonus (the Citadel gave it before). |
| Do buildings in a dominion give seats | No. Schools work in a player's own systems only. |
| Which building hosts Navarchs | The Aerospace Military Academy. |
| How an ally's agent enters | From the ally's deck, straight into the seat, like any deployment. The system grants the seat. |
| Does the settling-in period cost the fee | Yes. The seat is held from the first tick. |
| Does the owner's own agent need level 5 | Yes (2026-10-08). A university takes nobody under `university_min_level`. The first build asked it of faction-mates only; students seated before the change keep their seats. |
| A seduced student | It leaves its seat and joins the seducer on board in that system, as any seduced agent does. The seducer's agent limit is still unchecked, as before. |

## Naming

Players see **neural rewires**. The word "credit" is kept for the resource
alone, in the UI and in the code: the engine calls what a course earns
`reallocations` (the character field, `university_max_reallocations`,
`university_reallocation_interval`), so the player-facing word lives only in
the locale files and the manual and can change without touching the engine.

## Values

All in `Data.Game.Constant`, per speed (`lib/data/game/content/constant-*.ex`).

| Constant | Legacy | Tactic | Flash |
| --- | --- | --- | --- |
| `polytech_xp_factor` | 1.0 | 1.0 | 1.0 |
| `university_xp_factor` | 2.0 | 2.0 | 2.0 |
| `university_settle_time` (ut) | 80 | 13 | 3 |
| `university_reallocation_interval` (ut) | 480 | 80 | 20 |
| `university_max_reallocations` | 5 | 5 | 5 |
| `university_fee_ideology` / `_technology` / `_credit` (per level of the agent and per level of the university) | 2 / 2 / 20 | same | same |
| `university_min_level` | 5 | 5 | 5 |
| `training_defense_factor` (Polytech students) | 0.5 | 0.5 | 0.5 |

The proposal is written in Legacy terms. The Tactic and Flash durations use
the day equivalents the faction-government timers use and have not been
tuned. Flash buildings have a single level, so a Flash university has one
seat.

## Where it lives

Engine:

- `Instance.Character.Training`: the rules with no process access. Schools
  and their buildings, the phases of a course, fees, and the legality of a
  reallocation. A `training` map also carries `at`, the reading of the
  action clock its `elapsed` was measured at (see "The clock of a course").
- `Instance.Character.Character`: the `:student` status, the `training` map
  and `reallocations` (both read with `Map.get`, since they postdate
  snapshots), the student tick, `effective_protection/1` and
  `effective_determination/1`, `end_course/2`, `reallocate_skills/2`.
- `Instance.StellarSystem.School`: seats from the buildings standing in a
  system, who may enrol or wait, and `settle/2`, which says after any change
  who stays, who is turned out, which queue entries are cleared and which
  are called to a seat.
- `Instance.StellarSystem.StellarSystem`: the `students` roster and the
  `school_queue`, `enroll_student/2`, `join_school_queue/4`,
  `leave_school_queue/2`, `eject_student/3`, and `sync_schools/2`, called
  wherever buildings, ownership, the siege or the roster change.
- `Instance.Player.Player` and `Instance.Player.Agent`: `enroll_character`,
  `queue_character`, `leave_school_queue`, `eject_student`,
  `reallocate_skills`, the tuition income line (`{:character_tuition, name}`),
  the unpaid-tuition check on the player tick, the recall of a student whose
  course is over, and the casts a system sends to an agent's owner:
  `{:student_evicted, id, reason}`, `{:school_seat_ready, id, system, school}`
  and `{:school_queue_cleared, id, reason}`. A queued agent's place is on its
  deck entry (`queue: %{system_id, school, wait}`).
- `Instance.Player.Market`: no deck sale with rewires left or from a queue.
- `Instance.Character.Actions.Assassination` and `Conversion` read the
  effective stats.
- Channel: `enroll_character`, `queue_character`, `leave_school_queue`,
  `eject_student`, `reallocate_skills` and `discard_reallocations` on the
  player channel. Recall is the existing `deactivate_character`.

A seat is handed to a queued agent in two steps, because the system grants
seats and the player agent starts character agents. The system marks the
queue entry `called`, which holds the seat against anyone else, and casts
`{:school_seat_ready, ...}` to the owner. The owner's player agent enrols the
agent as if asked by the player, or gives the place up
(`{:leave_school_queue, id}`) if it no longer can, and the seat goes to the
next in line.

Enrolment takes the seat before anything is committed on the player's side,
so a refusal (school full, damaged, changed hands) leaves the agent in the
deck and starts no process.

### The clock of a course

A student ticks at its next event only (settled in, a rewire, a level), so
the `elapsed` of its `training` map can be hours old in the copies its owner
and its system hold. `training.at` is the reading of the action clock
(`Instance.Time.Time.now/1`: monotonic time minus the pauses) taken when
`elapsed` was measured, as `started_at` is for an action. The client carries
`elapsed` forward from it (`liveElapsed` in `front/src/game/clock.js`,
`settling` in `front/src/game/training.js`).

- Every student tick stamps `at`.
- `Character.Agent`'s `{:start, _}` re-anchors it (`Character.anchor_training/2`).
  After a pause the clock has not moved and nothing changes. After
  enrolment, or after a restore in a new BEAM whose clock has another
  origin, the anchor is replaced and the agent casts
  `{:training_anchor, id, training}` to its owner and its system, which
  patch the `training` of their copy and nothing else.
- A speed change (the cheat) is not followed: copies are carried forward at
  the new factor from an anchor taken at the old one until the next event.
  The client clamps to the length of the phase.
- Maps from before 2026-10-08 have no `at` (`Training.anchored_at/1`); the
  first start gives them one.

Client:

- `front/src/game/training.js`: the client's reading of a `training` map.
- `SchoolBox.vue`: the Schools row at the head of the bodies list in the
  system view. A university student that is settling in sits in one ring
  that fills; the five segments take its place when the course starts, the
  one being earned pulsing and filling (`earning` in `training.js`, the
  same reading of `training.elapsed` and `training.at` as `settling`). A school is its building's icon, with the name and the rules
  in its tooltip, followed by its seats. Free seats open the deck; seated
  agents open their card and can be targeted by a selected Erased or
  Siderian. Hovering a seated agent shows the queue above it: the agent
  waiting (a click takes it out, for its owner or the owner of the system)
  or the place to take. A dot on the seat says someone waits.
- `SchoolQueueSlot.vue` and `styles/shared/school-queue.scss`: that queue
  pop-up. It renders in `<body>` (a `HoverPopover`), because the bodies list
  clips what hangs outside it, so its styles are top-level.
- `BuildingCard.vue`: the four host buildings' cards end with a seats row
  (one for a Polytech, one per level for a university).
- `CharacterCard.vue`: Enrol, Join the queue and Recall, the training
  ribbon (its tooltip says that settling in earns nothing and when it ends),
  the cut defence (tooltip: "Protection, base 80: -50% (training)"), the
  reallocation controls, the wait of a queued agent with Leave the queue,
  and Send home on a faction-mate's student in one of the player's systems.
- `panel/operation/Agents.vue`: an "In training" list.
- `navbar/AgentsListPanel.vue`: students are listed with the on-board
  agents, under their type. Their line (`ClosedCharacterCard.vue`) carries
  the icon of their school's building, their stage and the time left to
  settle in; a click opens their card. One toolbar button goes round three
  states: students listed, only students, students left out.
- `galaxy/selection/TrainingQueue.vue`: the "actions" of a student, shown
  beside its opened card: settling in, with a progress ring and the moment
  it is over. Nothing once the course has started.

## Player manual

- `priv/help/en/agents/`: the guide `agent-training` and its pages
  `polytech-training`, `university-courses` and `neural-rewiring`. All
  four are drafts: they pass the lint but have not been through the
  manual's review run.
- The four building pages (`priv/help/en/building/`) open with a sentence
  on the school they host, and their card carries the seats row
  (`RC.Help.Catalog.training_row/3`).
- Screenshots `system-schools` and `student-card` come from the `training`
  capture scene (`e2e/help-shots/capture.js`). The scene recalls the
  fixture's Erased and waits out its rest at x50 speed, about two and a half
  minutes.

## Tests

- `test/game/instance/character/training_test.exs`: the rules, places by
  level, the defence by level and the conditions of a system.
- `test/game/instance/stellar_system/school_test.exs`: places, enrolment,
  the limit per player (studying or waiting), the queue, the fee cap and
  eviction.
- `test/game/instance/character/student_test.exs`: the student tick at
  Legacy values, defence, recall, reallocation.
- `test/game/instance/player/agent_training_test.exs`: ten full-instance
  runs through the player agent (Polytech, demolition, siege, the
  university queue seating its agent, leaving and ejection, the wait a
  queue reports, a student told of a Polytech built and damaged, the
  Citadel seating nobody, a paid course to five rewires with reallocation
  and the sale guard, unpaid tuition). The fixture gives the player no
  faction-mate, so the student ahead in a queue is a made-up mate's agent
  seated straight in the system (`seat_mate/4`).
- `e2e/tests/agent-training.spec.js`: the same flow through the UI, without
  the queue, which needs a second player of the faction. The dev fixture's
  `empire.schools` option places a Polytech and an Orb-INTEL.

## Not built

- Students in the phone's agent lists (the radial lists on-board agents by
  type), and a selection panel for a student: its card opens instead.
- The Great Pilgrimage.
- A manual screenshot of the reallocation controls. It needs an agent that
  holds rewires, which takes a whole course at Legacy speed.
- German strings beyond the error toasts.
- Bots never enrol agents.
- A browser run of a university queue with two real students. The fixture
  gives one agent slot per type, so the UI test queues a Navarch behind an
  Erased at the Polytech and checks the wording of a timed wait on the card
  directly.
