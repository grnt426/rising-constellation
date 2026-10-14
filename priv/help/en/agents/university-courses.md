---
title: University courses
kind: mechanic
guide: agent-training
icon: building/monument_dome
terms: [university, course, course fee, tuition]
aliases: [university, course-fee]
related: [agent-training, neural-rewiring, polytech-training]
length: long
length_reason: one page owns the three universities, the stages of a course, its end, the fee, non-payment and the rules for faction-mates
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

- Siderians study at a [[building/monument_dome]]. They pay {rate:university_fee_ideology|ideology} for each of their levels and each level of the building.
- Navarchs study at an [[building/military_school_dome]]. They pay {rate:university_fee_technology|technology} for each of their levels and each level of the building.
- Erased study at an [[building/counterintelligence_open]]. They pay {rate:university_fee_credit|credits} for each of their levels and each level of the building.

Each level of the building gives one seat. In a Flash game every building has one level, so a university has one seat.

You can seat one agent in each university building, whatever its level. This holds in your own systems too. The other seats are for the other players of your faction.

Your next agent can wait in the [[school-queue|queue]] behind your own student. It takes the seat when the student leaves.

A university takes agents of level {const:university_min_level} or higher. This holds for your own agents too. A lower agent can train at a [[polytech-training|Delta Polytech]] first.

## The course

1. The student settles in for {duration:university_settle_time}. It pays the fee and gains nothing yet. A ring fills around its seat during that time, and its card gives the time left.
2. Then it gains experience {const:university_xp_factor} times as fast as a governor.
3. Every {duration:university_reallocation_interval} on the course gives one neural rewire. A [[building/ideo_open]] in the system shortens that time, and a [[building/university_open]] adds to the experience. See [[training-bonuses]].
4. The course ends when the agent holds {const:university_max_reallocations} rewires. The agent goes back to your deck at once.

{shot:student-card#status,defence,recall|A student's card: its school and stage (1), its cut Protection and Determination (2) and the Recall button (3).}

The agent comes home by itself, even during a [[siege]]. Its seat goes to the agent waiting behind it in the [[school-queue|queue]], if there is one.

You can recall a student before the end of its course, except during a siege. It keeps the rewires it earned so far.

{shot:system-schools#student|A ring fills around a student while it settles in. Once the course starts, the ring has one segment for each rewire, and a segment lights up when the rewire is earned.}

The segment of the next rewire pulses slowly. It fills as the time for that rewire passes, so you can read the hours left from the ring. The seat's tooltip gives the exact time.

An agent can take as many courses as you like. It must first spend or discard every rewire of the last one. See [[neural-rewiring]].

## The fee

The fee is part of your income, like a salary. It counts the level of the agent and the level of the building, so it rises when either gains a level.

    a level 10 Siderian in a Monolith of level 5: (10 + 5) × {rate:university_fee_ideology|ideology} = {rate:45|ideology}

In a system with several buildings of the same university, the highest level counts for all its students.

Each level of a [[building/ideo_dome]] in the system takes 4% off the fee. See [[training-bonuses]].

If your stock of that resource is empty and still falling, the course stops. The student goes back to your deck with the rewires it earned.

## Faction-mates

A player of your faction can send an agent to your university, under the same level rule as yours. Your whole faction shares the seats of the university, one seat for each player in each building. Each player pays the fee of their own agents.

As the owner you can send any student home. See [[agent-training]].
