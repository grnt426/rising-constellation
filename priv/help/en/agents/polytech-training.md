---
title: Training at a Delta Polytech
kind: mechanic
guide: agent-training
icon: building/university_open
terms: [Delta Polytech seat, passive experience]
aliases: [polytech-seat]
related: [agent-training, university-courses, agent-limits]
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex
  - lib/game/instance/stellar_system/school.ex
  - lib/data/game/content/constant-slow.ex
status: draft
---
Each [[building/university_open]] in one of your systems gives you one training seat. An agent in that seat gains experience without any order.

- The seat takes a Navarch, an Erased or a Siderian, from level 1.
- Only the owner of the system can use it.
- The agent gains {rate:character_passive_xp_gain|experience}, the same as a governor.
- It costs nothing beyond the agent's salary.
- It gives no neural rewires.
- The agent stays until you recall it. You cannot recall it during a [[siege]].
- One more agent can wait behind it in the [[school-queue|queue]].

A system with several of these buildings has one seat for each. The building's level does not change the number of seats.
