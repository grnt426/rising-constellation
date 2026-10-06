---
title: University courses
kind: mechanic
guide: agent-training
icon: building/monument_dome
terms: [university, course, course fee, tuition]
aliases: [university, course-fee]
related: [agent-training, neural-rewiring, polytech-training]
length: long
length_reason: one page owns the three universities, the stages of a course, the fee, non-payment and the rules for faction-mates
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex
  - lib/game/instance/stellar_system/school.ex
  - lib/game/instance/player/player.ex
  - lib/data/game/content/constant-slow.ex
  - lib/data/game/content/building-fast.ex
status: draft
---
A university course trains an agent of one type for a fee. It gives experience and [[neural-rewiring|neural rewires]].

- Siderians study at a [[building/monument_dome]]. They pay {rate:university_fee_ideology|ideology} for each of their levels.
- Navarchs study at an [[building/military_school_dome]]. They pay {rate:university_fee_technology|technology} for each of their levels.
- Erased study at an [[building/counterintelligence_open]]. They pay {rate:university_fee_credit|credits} for each of their levels.

Each level of the building gives one seat. In a Flash game every building has one level, so a university has one seat.

## The course

1. The student settles in for {duration:university_settle_time}. It pays the fee and gains nothing yet.
2. Then it gains experience {const:university_xp_factor} times as fast as a governor.
3. Every {duration:university_reallocation_interval} on the course gives one neural rewire.
4. The course ends when the agent holds {const:university_max_reallocations} rewires.

{shot:student-card#status,defence,recall|A student's card: its school and stage (1), its cut Protection and Determination (2) and the Recall button (3).}

After the course the student pays no fee and gains nothing more. Its seat is free for another agent. It waits in the system until you recall it.

{shot:system-schools#student|The ring around a student has one segment for each rewire of a course. A segment lights up when the rewire is earned.}

An agent can take as many courses as you like. It must first spend or discard every rewire of the last one. See [[neural-rewiring]].

## The fee

The fee is part of your income, like a salary. It follows the agent's level, so it rises as the student gains levels.

    a level 10 Siderian: 10 × {rate:university_fee_ideology|ideology} = {rate:50|ideology}

If your stock of that resource is empty and still falling, the course stops. The student keeps the rewires it earned and waits to be recalled.

## Faction-mates

A player of your faction can send an agent to your university. That agent must be level {const:university_guest_min_level} or higher. Each faction-mate can hold one seat for each university building in the system. They pay the fee themselves.
