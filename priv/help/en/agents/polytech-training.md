---
title: Training at a Delta Polytech
kind: mechanic
guide: agent-training
icon: building/university_open
terms: [Delta Polytech seat, basic training, passive experience, training bonus, support building]
aliases: [polytech-seat, training-bonuses#what-the-buildings-add]
related: [agent-training, university-courses, agent-limits]
length: long
length_reason: one page owns the basic training seat and what three support buildings add to every course in their system
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex
  - lib/game/instance/stellar_system/school.ex
  - lib/data/game/content/constant-slow.ex
  - lib/data/game/content/building-slow.ex
status: draft
---
Each [[building/university_open]] in one of your systems gives you one training seat. An agent in that seat gains experience without any order.

- The seat takes a Navarch, an Erased or a Siderian, from level 1.
- Only the owner of the system can use it.
- The agent gains {rate:character_passive_xp_gain|experience}, the same as a governor. It starts at once.
- It costs nothing beyond the agent's salary.
- It gives no neural rewires.
- Its Protection and Determination are halved while it is seated.
- The agent stays until you recall it. You cannot recall it during a [[siege]].
- A Delta Polytech has no queue.

A system with several of these buildings has one seat for each. The building's level does not change the number of seats.

## What the buildings add

Three support buildings help the agents in training in their system, each in its own way.

| Building | At level 5 | Helps |
| --- | --- | --- |
| [[building/research_orbital]] | +15% experience | every student, training seats included |
| [[building/university_open]] | 7.5% off the time of a [[neural-rewiring|neural rewire]] | university students |
| [[building/ideo_dome]] | 15% off the [[course-fee|course fee]] | university students |

A building of a lower level gives part of that effect.

| Level | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- |
| Share of the effect | 10% | 25% | 45% | 70% | 100% |

Every building of the system counts, and the percentages add up. A damaged building gives nothing.

    two Holodomes of level 5 and one of level 3: 15% + 15% + 6.75% = 36.75% off the fee

The fee never drops by more than 80%. The salary is never discounted. Settling in takes as long as ever. The details page of a system gives its three totals.
