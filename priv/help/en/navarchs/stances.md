---
title: Navarch stances
icon: reaction/defend
terms: [stance, stances, fleet stance, Deserter, Prudent, Defender, Interdiction, Fury, interception]
sources:
  - front/src/game/components/panel/help/Stances.vue:44-73
  - lib/game/instance/character/actions/fight.ex:198-236
  - lib/game/instance/character/actions/fight.ex:264-287
  - lib/game/instance/character/actions/jump.ex:177-195
  - lib/data/game/content/constant-slow.ex:48
status: draft
---
{ui:panel.help.stances_intro}

There are four moments a stance can react to:

- **Incoming** — {ui:panel.help.stances_trigger_incoming}
- **Hostile action** — {ui:panel.help.stances_trigger_hostile_action}
- **Arriving** — {ui:panel.help.stances_trigger_arriving}
- **Arriving on a busy fleet** — {ui:panel.help.stances_trigger_arriving_busy}

### {icon:reaction/flee} {ui:panel.help.stances_flee_name}

{ui:panel.help.stances_flee_desc} Reacts to none of the four moments. When attacked, a Deserter rolls once: with a {const:fleeing_chance} chance it escapes to the nearest system, otherwise it fights.

### {icon:reaction/fight_back} {ui:panel.help.stances_fight_back_name}

{ui:panel.help.stances_fight_back_desc} Reacts to none of the four moments; it still fights when attacked.

### {icon:reaction/defend} {ui:panel.help.stances_defend_name}

{ui:panel.help.stances_defend_desc} Reacts to: hostile action, arriving on a busy fleet.

### {icon:reaction/attack_enemies} {ui:panel.help.stances_attack_enemies_name}

{ui:panel.help.stances_attack_enemies_desc} Reacts to: incoming, hostile action.

### {icon:reaction/attack_everyone} {ui:panel.help.stances_attack_everyone_name}

{ui:panel.help.stances_attack_everyone_desc} Reacts to: incoming, hostile action, arriving.

## Notes

- {ui:panel.help.stances_note_passive}
- {ui:panel.help.stances_note_idle}
- {ui:panel.help.stances_note_diplomacy}
