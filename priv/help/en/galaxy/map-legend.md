---
title: Map legend
icon: galaxy
terms: [map legend, legend, map view modes, detected, visibility mode, system points mode]
sources:
  - front/src/game/components/panel/help/Legend.vue
  - front/src/game/components/galaxy/Map.vue:85-90
  - lib/game/instance/faction/faction.ex:261-340
  - lib/game/spatial/spatial.ex:10-30
status: draft
---
What the symbols on the galaxy map mean. The Help drawer's {ui:panel.help.legend} tab shows the same entries drawn in your faction's colors.

## {ui:panel.help.legend_systems_title}

- **{ui:panel.help.legend_uninhabited_name}** — {ui:panel.help.legend_uninhabited}
- **{ui:panel.help.legend_inhabited_neutral_name}** — {ui:panel.help.legend_inhabited_neutral}
- **{ui:panel.help.legend_inhabited_other_name}** — {ui:panel.help.legend_inhabited_other}
- **{ui:panel.help.legend_inhabited_self_name}** — {ui:panel.help.legend_inhabited_self}

{ui:panel.help.legend_note_asterisk}

## {ui:panel.help.legend_agents_title}

- {icon:agent/admiral} **{name:character.admiral}** — {ui:panel.help.legend_navarch}
- {icon:agent/speaker} **{name:character.speaker}** — {ui:panel.help.legend_siderian}
- {icon:agent/spy} **{name:character.spy}** — {ui:panel.help.legend_erased}
- **{ui:panel.help.legend_detected_name}** — {ui:panel.help.legend_detected}

Only fleets that are moving can be detected. A fleet sitting in a system is never a radar blip. {ui:panel.help.legend_note_detection} {ui:panel.help.legend_note_allies}

## {ui:panel.help.legend_modes_title}

- **{ui:panel.help.legend_mode_visibility_name}** — {ui:panel.help.legend_mode_visibility}
- **{ui:panel.help.legend_mode_population_name}** — {ui:panel.help.legend_mode_population}
- **{ui:panel.help.legend_mode_radar_name}** — {ui:panel.help.legend_mode_radar}

{ui:panel.help.legend_modes_hint} The S.L.S.D. disk of a system has a radius of its S.L.S.D. value × {const:system_base_radar_size} map units.
