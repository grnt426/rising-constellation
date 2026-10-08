---
title: Agent training
kind: guide
icon: building/university_open
terms: [training, school, student, training seat, school queue]
aliases: [schools#two-kinds-of-school, students#students, losing-a-seat#losing-a-seat, school-queue#the-queue]
related: [agent-limits, siege, damaged-buildings, administrative-operations]
sources:
  - lib/game/instance/character/training.ex
  - lib/game/instance/character/character.ex
  - lib/game/instance/stellar_system/school.ex
  - lib/game/instance/stellar_system/stellar_system.ex
  - lib/game/instance/player/player.ex
  - lib/game/instance/player/agent.ex
  - lib/game/instance/faction/stellar_system.ex
  - lib/game/instance/character/actions/assassination.ex
  - lib/game/instance/character/actions/conversion.ex
  - lib/data/game/content/constant-slow.ex
status: draft
---
A school is a building that trains an agent while it stays out of the field. You send an agent there from your deck, as you would a governor.

{shot:system-schools#school,student,seat|A system's schools: a school's building (1), an agent seated in it (2) and a free seat (3).}

## Two kinds of school

A [[building/university_open]] gives its owner one seat. The agent in it gains experience without any order. See [[polytech-training]].

A university trains one type of agent, for a fee. Siderians study at a [[building/monument_dome]], Erased at an [[building/counterintelligence_open]] and Navarchs at an [[building/military_school_dome]]. A course gives experience faster, and it gives neural rewires. See [[university-courses]].

Schools only work in a system a player holds. A school in a [[dominions|dominion]] has no seats.

## Students

An agent in a school is a student. It counts toward your [[agent-limits|agent limit]] and is paid its salary, like any agent on the board. It has no fleet and takes no orders.

A student stays in its system until you recall it or its course ends. An agent back from a school rests for {duration:character_deck_cooldown} in your deck before its next duty.

You cannot recall a student during a [[siege]].

## A student is easier to remove

While a student is in class, its Protection and Determination are multiplied by {const:training_defense_factor}. Its card shows the cut value in orange, and the tooltip gives the base value. A student is never hidden, and an Erased in a school has no cover. An enemy Erased can remove a student. An enemy Siderian can win it over.

## Losing a seat

A school needs its building. If the building is [[damaged-buildings|damaged]] or [[destroy-building|destroyed]], its students go back to their owners' decks. The same happens when the system is conquered, [[liberate|liberated]] or [[abandon|abandoned]]. They keep the experience and the rewires they earned.

No agent can be sent to a school during a [[siege]].

## The queue

When a school has no free seat, one agent can wait behind each student. Hover a student to see the place above its seat.

- The agent stays in your deck. It takes no other duty while it waits.
- It still counts toward your [[agent-limits|agent limit]].
- It takes the seat as soon as the student leaves.
- Its card shows the longest it can have to wait.
- You can take it out of the queue at any time, even during a siege.
- You cannot sell it. You can still fire it, which frees its place.

An agent loses its place if the seat is lost with its building or its system. No agent can join a queue during a siege.

Only your faction sees who waits in a queue.

## The owner of the system

The owner of a system can send any student home, and any agent out of a queue. A student sent home keeps what it earned. The owner cannot send a seated student home during a siege.

## Neural rewires

A rewire lets you move one skill point of the agent to another skill. See [[neural-rewiring]].
