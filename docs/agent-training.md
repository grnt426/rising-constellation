# Agent training

Reference for the agent-training features built in October 2026: the
passive seat at a Delta Polytech, a Citadel or a Holodome, the university course that
earns neural rewires, each of which moves one skill point, and what the
buildings of a system give the agents in training there. The proposal and its expected impact are in
`docs/agent-training-impact.md`; this document says what was built, which of
the proposal's open questions were settled and how, and where the code is.

The Great Pilgrimage from the same proposal is not built.

## The rules

An agent in the deck can be sent to a **school** in place of a governor's seat
or the field. It becomes a **student**: a fourth deployed state beside
governor and on board. A student has no fleet, cover or order queue. It sits
in one system until its owner recalls it to the deck, or until its course
ends.

A student counts as a deployed agent in every way that matters to its owner.
It holds an agent slot of its type, draws wages, and can be removed or seduced
where it sits.

| | Delta Polytech, Citadel and Holodome | University |
| --- | --- | --- |
| Building | Delta Polytech (`university_open`), Citadel (`ideo_open`), Holodome (`ideo_dome`): three schools, each with its own seats | Monolith for Siderians, Orb-INTEL for Erased, Aerospace Military Academy for Navarchs |
| Seats | One per building, whatever its level | One per building level |
| Who | Agents of the system's owner, any type, from level 1 | Agents of the building's type, from level 5, the owner's included. The faction shares the seats: one seat per player and per building, the owner of the system included |
| Experience | The governor's passive rate, plus what the system's buildings add | Nothing while settling in, then twice the governor's rate, plus what the system's buildings add |
| Neural rewires | None | One per day of course, less what the system's buildings take off, up to five held |
| Fee | None | Per tick, once per level of the agent and once per level of the university: 3 ideology (Siderian), 3 technology (Navarch), 30 credits (Erased), less 4% per level of each Holodome of the system |
| Ends | When recalled | At five rewires held, or when the fee cannot be paid. Either way the agent goes straight back to the deck |
| Queue | One agent behind the student | One agent behind each student. A player seated in the building queues behind its own student only |
| Defence | Protection and Determination halved | Protection and Determination halved while in class |

At Legacy speed the governor's rate is 1 experience per hour, settling in
takes 4 hours and a course day is 24 hours, so a full course is 5 days and 4
hours.

### A university course

1. **Settling in.** The student holds its seat and pays the fee, and earns
   nothing yet. Its seat sits in a ring that fills until the course starts,
   its card and its line in the agents list give the time left, and its
   opened card lists settling in as its one action, with the moment it is
   over.
2. **On its course.** Experience at twice the governor's rate. Each full day
   adds one neural rewire.
3. **Course over.** At five rewires the course ends and the agent is recalled
   to its owner's deck at once, siege or not. Nobody has to fetch it. The
   `:graduated` phase only lives until the owner's player agent has read it
   (`{:update_character, ...}` with a finished course triggers the recall).

Rewires belong to the agent and are kept through a recall. An agent with a
rewire left takes no duty of any kind: it cannot be made governor, sent to
the field, sent to a school or put in a queue, and it cannot be sold
(`:reallocations_unspent`). It can take as many courses as its owner likes,
each time once the rewires of the last one are spent or discarded. Discarding
gives up every rewire the agent has left and leaves its skills alone; the
card's button asks twice.

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

### What the system's buildings give

Decided with the players on 2026-10-13: the training buildings were a little
weak, and a system built for the sole purpose of training agents should be
worth building.

| Building | Per level, per building |
| --- | --- |
| Delta Polytech | +3% experience for every student of the system |
| Citadel | -1.5% of the time a rewire takes, and one training seat like the Polytech's |
| Holodome | -4% of the fee of the system's university courses, and one training seat too |

Three buildings, a seat each and one effect each (the game's rule of three).
The second pass of 2026-10-13 gave the Holodome its own effect in place of
two thirds of the two others, and put the fee back up (30 credits, 3
technology or ideology, from 10 and 1): Holodomes are how a player brings
it down, in the middle and the late game. The rate was 2% for a few hours
and went to 4% the same day: two Holodomes of level 5 then took 20% off,
too little to be worth building or to close the mid-game gap. At 4% a low
Holodome already helps early agents, and two at level 5 take 40% off.

- Every student of the system is helped, whatever its school: the agents in
  the Polytech, Citadel and Holodome seats and the students of its
  universities.
  Governors and agents on board are not.
- The percentages add up over every building standing in the system, and a
  damaged building gives nothing. A rewire never takes less than a quarter
  of its time, nor a course less than a quarter of its fee
  (`@min_time_factor` and `@min_cost_factor` in `StellarSystem.School`);
  nothing reaches the first today, and the second takes four Holodomes of
  level 5 (one per sterile body).
- The three are ordinary system bonuses: targets `sys_training_xp`,
  `sys_reallocation_time` and `sys_training_cost` (`bonus-pipeline-out.ex`),
  written on each level of the three buildings in
  `building-{slow,medium,fast}.ex` (Flash has no Holodome), summed by
  `compute_bonus` into the system's `training_xp`, `reallocation_time` and
  `training_cost` values. Building cards and the manual list them like
  any bonus, as percentages. The dominion AI leaves them out of what a
  building is worth to it (`SystemAI.Weights.gains/1`): a dominion has no
  school.
- The fee counts the level of the university: 30 credits (3 technology, 3
  ideology) per tick for each level of the agent and each level of the
  building, times the `cost_factor` the Holodomes leave. With several buildings of the same university in a system (only
  Academies today) the highest level counts for every student
  (`School.school_level/3`), since seats are per school.

**How a student learns of it.** A student ticks by itself, hours apart, so
its system hands it the four numbers and they ride in its `training` map
(`xp_bonus`, `time_factor`, `cost_factor`, `school_level`; `Training.conditions/1` reads a
map that carries none as no bonus):

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
- Students seated before this shipped run without bonus, and pay on the
  level of the agent alone, until the next recompute in their system.

The client reads the same four numbers (`conditions` in
`front/src/game/training.js`) for the rate on the card, the fee, and the
segment being earned. The tooltip of each school ends with what its system
gives ("In this system: +21% training experience, -10.5% rewire time"), and
the system's details page has an Agent training section with the three
percentages, each with the breakdown by building every stat of that page
has (`Details.vue`; `ResourceDetail` takes a `unit` for the percent sign).

### One seat per player and per building

A university building with five levels has five seats, and they are for five
players: a player holds one seat per building, whatever its level, and the
owner of the system is held to it like anyone else (2026-10-13). The point is
that a few high buildings serve many players, and that no rich player fills
every seat.

- Seats are counted per school and not per building, so the limit is the
  number of host buildings standing in the system
  (`School.player_seats/3`). The Aerospace Military Academy is Limited (one
  per body), so a system can hold several and a player one seat in each. In
  the content files the Monolith and the Orb-INTEL are Unique (one per
  system).
- A seat is a student in class or a seat held for an agent the queue has
  called (`School.seats_held/5`). A refusal is `:one_agent_per_building`.
- The queue is how a player lines up its next agent: behind its own
  student, whose seat it takes over. That is open whether the school is
  full or not, since none of the free seats is for that player. A level 1
  building is therefore its player's for as long as it keeps the line fed;
  from level 2 the other seats are for the others.
- Behind another player's student the agent would end up in a second seat,
  so a player holding its seats is refused there, and so is a player who
  already waits for every seat it may hold.
- `settle/2` calls no agent whose owner holds every seat it may. An agent
  behind its owner's student is passed over when another seat comes free,
  and called when that student leaves.
- A Polytech has no such limit: it seats one agent per building and its
  owner alone.
- Nobody is turned out for it. A player seated twice before the limit
  existed keeps both seats, and its agents in line wait until it is back
  under the limit.
- The client reads `per_player` in the system's `schools` summary: with the
  player's seat taken, the free seats of that school are not clickable and
  their tooltip says why, and the place in the queue is offered behind the
  player's own student only.

### Sieges

Nobody is sent to a school, and nobody joins a queue, while the system is
under siege. A seated student cannot be recalled during a siege either, by
its owner or by the owner of the system
(`:no_character_deactivation_under_siege`). Only the system knows it is
besieged when the school is a faction-mate's, so the player agent asks it
(`{:check_student_recall, id}`). A course that ends during a siege still
sends its agent home.

### The queue

One deck agent may wait behind each seated student, at a Polytech or a
university. It is for a school with no free seat: with one free, the agent
just enrols.

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
  the student ahead ("38hrs to be seated", and the date on hover). Behind a
  Polytech student, who never has to leave, there is no latest time.
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
a skill outright (2026-10-13), so that an agent with no point to spare still
gets something from a course, at half the rate: five rewires move five
points or add two. The two can be mixed in one change. A point a skill gains
is billed as a move whenever another skill gave one up, and every point
taken has to be placed (`Training.reallocation_cost/2`; the card's + and -
follow the same count through `reallocationCost` in `training.js`). An agent
that adds points ends up with more skill points than its level gave it.

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
| One Polytech seat per player or per building | Per building. The proposal's wording, read literally. |
| Does a student use an agent slot | Yes. It stays on the roster like a governor. |
| Deck or map | Map. It has a system, can be targeted and draws wages. |
| Halve the agent's own stats or the whole defence | The agent's own Protection and Determination, as proposed. The host system's Intelligence or Stability still counts in full. `training_defense_factor` holds the 0.5. The card prints the cut value in orange and its tooltip the base ("Protection, base 80: -50% (training)"). Until 2026-10-08 the card printed the base value in orange: the engine cut it all along, the card passed the cut value to the `obfuscate` filter as the value to test instead of the value to print. |
| Is an Erased student visible | Yes. Students are listed apart from on-board agents and cover does not apply. |
| Re-enrolment and limits on moves | Re-enrolment is open, any number of times, once the last course's rewires are spent (decided by the owner, 2026-10-06). Moves respect the cap of 12 and the main-skill rule. |
| What happens at five rewires | The agent is recalled to the deck at once (2026-10-07). The first build left it waiting in the system. |
| Recall during a siege | Refused for a seated student; a queued agent can always leave (2026-10-07). |
| One agent per player per building | One seat per player and per university building, the owner of the system included; the next agent queues behind the player's own student (2026-10-13). It was dropped on 2026-10-07, and one player could then fill every seat. See "One seat per player and per building". |
| Who sees a student's progress | Any faction with visibility 5, as for a governor (2026-10-07). The first build kept it to the owner's faction. |
| Selling an agent that holds rewires | Refused (2026-10-07). The first build let the buyer inherit them. |
| A queue | One agent behind each seated student (2026-10-07). See "The queue". |
| Ejection | The owner of the system can turn out students and queued agents (2026-10-07). |
| Fee fixed at entry or following the level | Following the level of the agent and, since 2026-10-13, the level of the university (highest building of it in the system). The rates went from 5/5/50 per agent level to 1/1/10 per level of each, then to 3/3/30 the same day, with the Holodome to bring them down. |
| Do the Citadel and the Holodome seat anyone | Yes (2026-10-13): one seat per building for its owner's agents, as a Polytech does. The first build of that day gave the Holodome its two bonuses and no seat. |
| What the Holodome gives | 4% off the course fee per level (2026-10-13, second pass; 2% at first). It first had two thirds of the Polytech's and the Citadel's bonuses. |
| Can a rewire do more than move a point | Yes (2026-10-13): two add a point outright. |
| Who the experience bonus helps | Every student of the system, universities included (2026-10-13). |
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
| `university_fee_ideology` / `_technology` / `_credit` (per level of the agent and per level of the university) | 3 / 3 / 30 | same | same |
| `university_min_level` | 5 | 5 | 5 |
| `training_defense_factor` | 0.5 | 0.5 | 0.5 |

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

- `test/game/instance/character/training_test.exs`: the rules, the Citadel
  seat and the conditions of a system.
- `test/game/instance/stellar_system/school_test.exs`: seats, enrolment,
  the limit per player, the queue and eviction.
- `test/game/instance/character/student_test.exs`: the student tick at
  Legacy values, defence, recall, reallocation.
- `test/game/instance/player/agent_training_test.exs`: ten full-instance
  runs through the player agent (a student told of a Polytech and a Citadel
  built and of a Polytech damaged, the Citadel seat, Polytech, demolition
  with a queue, siege,
  the queue seating its agent, leaving and ejection, the wait a queue
  reports, a paid course to five rewires with reallocation and the sale
  guard, unpaid tuition).
- `e2e/tests/agent-training.spec.js`: the same flow through the UI, the
  queue included. The dev fixture's `empire.schools` option places a Polytech
  and an Orb-INTEL.

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
