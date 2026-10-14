---
title: Training seats
kind: mechanic
guide: agent-training
icon: building/university_open
terms: [Delta Polytech seat, Citadel seat, Holodome seat, passive experience, training bonus]
aliases: [polytech-seat, citadel-seat, holodome-seat, training-bonuses#what-the-buildings-add]
related: [agent-training, university-courses, agent-limits]
length: long
length_reason: one page owns the three training seats and what their buildings add to every course in their system
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex
  - lib/game/instance/stellar_system/school.ex
  - lib/data/game/content/constant-slow.ex
  - lib/data/game/content/building-slow.ex
status: draft
---
Each [[building/university_open]], each [[building/ideo_open]] and each [[building/ideo_dome]] in one of your systems gives you one training seat. An agent in that seat gains experience without any order.

- The seat takes a Navarch, an Erased or a Siderian, from level 1.
- Only the owner of the system can use it.
- The agent gains {rate:character_passive_xp_gain|experience}, the same as a governor.
- It costs nothing beyond the agent's salary.
- It gives no neural rewires.
- The agent stays until you recall it. You cannot recall it during a [[siege]].
- One more agent can wait behind it in the [[school-queue|queue]].

A system with several of these buildings has one seat for each. The building's level does not change the number of seats.

## What the buildings add

Each of the three buildings also helps the agents in training in its system, in its own way.

- Each level of a [[building/university_open]] adds 3% to the experience they gain. This counts the agents in a training seat and the students of its universities.
- Each level of a [[building/ideo_open]] takes 1.5% off the time a [[neural-rewiring|neural rewire]] takes.
- Each level of a [[building/ideo_dome]] takes 4% off the [[course-fee|fee]] of its university courses.

Every building of the system counts, and the percentages add up. A damaged building gives nothing.

    two Holodomes of level 5: 2 × 5 × 4% = 40% off the fee

A rewire never takes less than a quarter of its normal time. A course never costs less than a quarter of its fee. The details page of a system gives its three totals.
