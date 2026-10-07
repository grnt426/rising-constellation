# Agent training

Reference for the two agent-training features built in October 2026: the
passive seat at a Delta Polytech and the university course that earns neural
rewires, each of which moves one skill point. The proposal and its expected impact are in
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

| | Delta Polytech | University |
| --- | --- | --- |
| Building | Delta Polytech (`university_open`) | Monolith for Siderians, Orb-INTEL for Erased, Aerospace Military Academy for Navarchs |
| Seats | One per building, whatever its level | One per building level |
| Who | Agents of the system's owner, any type, from level 1 | Agents of the building's type. The owner's from level 1; a faction-mate's from level 5. The faction shares the seats: no limit per player |
| Experience | The governor's passive rate | Nothing while settling in, then twice the governor's rate |
| Neural rewires | None | One per day of course, up to five held |
| Fee | None | Per tick and per agent level: 5 ideology (Siderian), 5 technology (Navarch), 50 credits (Erased) |
| Ends | When recalled | At five rewires held, or when the fee cannot be paid. Either way the agent goes straight back to the deck |
| Queue | One agent behind the student | One agent behind each student |
| Defence | Protection and Determination halved | Protection and Determination halved while in class |

At Legacy speed the governor's rate is 1 experience per hour, settling in
takes 4 hours and a course day is 24 hours, so a full course is 5 days and 4
hours.

### A university course

1. **Settling in.** The student holds its seat and pays the fee, and earns
   nothing yet.
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
A student is seen like a governor: its name, type and portrait from
visibility 2, its progress (`reallocations`) at visibility 5, whatever the
viewer's faction.

The fee is an income line, like wages, and follows the agent's level as it
rises. When the stock of the resource it is paid in is empty and still
falling, every student paying in that resource is sent home: the course ends
there and the agent goes back to the deck with the rewires earned so far.

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
takes it from one skill and gives it to another. Two limits apply to a skill
that gains points, the same two a level-up respects:

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
| Halve the agent's own stats or the whole defence | The agent's own Protection and Determination, as proposed. The host system's Intelligence or Stability still counts in full. `training_defense_factor` holds the 0.5. |
| Is an Erased student visible | Yes. Students are listed apart from on-board agents and cover does not apply. |
| Re-enrolment and limits on moves | Re-enrolment is open, any number of times, once the last course's rewires are spent (decided by the owner, 2026-10-06). Moves respect the cap of 12 and the main-skill rule. |
| What happens at five rewires | The agent is recalled to the deck at once (2026-10-07). The first build left it waiting in the system. |
| Recall during a siege | Refused for a seated student; a queued agent can always leave (2026-10-07). |
| One agent per player per building | Dropped (2026-10-07). University seats are shared by the faction with no limit per player. |
| Who sees a student's progress | Any faction with visibility 5, as for a governor (2026-10-07). The first build kept it to the owner's faction. |
| Selling an agent that holds rewires | Refused (2026-10-07). The first build let the buyer inherit them. |
| A queue | One agent behind each seated student (2026-10-07). See "The queue". |
| Ejection | The owner of the system can turn out students and queued agents (2026-10-07). |
| Fee fixed at entry or following the level | Following the level. |
| Do buildings in a dominion give seats | No. Schools work in a player's own systems only. |
| Which building hosts Navarchs | The Aerospace Military Academy. |
| How an ally's agent enters | From the ally's deck, straight into the seat, like any deployment. The system grants the seat. |
| Does the settling-in period cost the fee | Yes. The seat is held from the first tick. |
| Does the owner's own agent need level 5 | No. Only a faction-mate's does. |
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
| `university_fee_ideology` / `_technology` / `_credit` | 5 / 5 / 50 | same | same |
| `university_guest_min_level` | 5 | 5 | 5 |
| `training_defense_factor` | 0.5 | 0.5 | 0.5 |

The proposal is written in Legacy terms. The Tactic and Flash durations use
the day equivalents the faction-government timers use and have not been
tuned. Flash buildings have a single level, so a Flash university has one
seat.

## Where it lives

Engine:

- `Instance.Character.Training`: the rules with no process access. Schools
  and their buildings, the phases of a course, fees, and the legality of a
  reallocation.
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

Client:

- `front/src/game/training.js`: the client's reading of a `training` map.
- `SchoolBox.vue`: the Schools row at the head of the bodies list in the
  system view. A school is its building's icon, with the name and the rules
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
  ribbon, the cut defence, the reallocation controls, the wait of a queued
  agent with Leave the queue, and Send home on a faction-mate's student in
  one of the player's systems.
- `panel/operation/Agents.vue`: an "In training" list.

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

- `test/game/instance/character/training_test.exs`: the rules.
- `test/game/instance/stellar_system/school_test.exs`: seats, enrolment,
  the queue and eviction.
- `test/game/instance/character/student_test.exs`: the student tick at
  Legacy values, defence, recall, reallocation.
- `test/game/instance/player/agent_training_test.exs`: eight full-instance
  runs through the player agent (Polytech, demolition with a queue, siege,
  the queue seating its agent, leaving and ejection, the wait a queue
  reports, a paid course to five rewires with reallocation and the sale
  guard, unpaid tuition).
- `e2e/tests/agent-training.spec.js`: the same flow through the UI, the
  queue included. The dev fixture's `empire.schools` option places a Polytech
  and an Orb-INTEL.

## Not built

- The Great Pilgrimage.
- A manual screenshot of the reallocation controls. It needs an agent that
  holds rewires, which takes a whole course at Legacy speed.
- German strings beyond the error toasts.
- Bots never enrol agents.
- A browser run of a university queue with two real students. The fixture
  gives one agent slot per type, so the UI test queues a Navarch behind an
  Erased at the Polytech and checks the wording of a timed wait on the card
  directly.
