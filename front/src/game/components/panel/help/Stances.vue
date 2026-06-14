<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.stances_title') }}
      </h1>

      <p class="help-stances-intro">{{ $t('panel.help.stances_intro') }}</p>

      <table class="help-stances-table">
        <tbody>
          <tr
            v-for="row in rows"
            :key="row.reaction">
            <th>
              <div
                class="help-stances-icon"
                v-tooltip.right="$t(`character_reaction.${row.reaction}`)">
                <svgicon :name="`reaction/${row.reaction}`" />
              </div>
            </th>
            <td>
              <div class="help-stances-name">{{ $t(`panel.help.stances_${row.reaction}_name`) }}</div>
              <div
                class="help-stances-desc"
                v-html="$t(`panel.help.stances_${row.reaction}_desc`)"></div>
              <ul class="help-stances-triggers">
                <li
                  v-for="trigger in row.triggers"
                  :key="trigger">
                  {{ $t(`panel.help.stances_trigger_${trigger}`) }}
                </li>
              </ul>
            </td>
          </tr>
        </tbody>
      </table>

      <div class="help-stances-notes">
        <p>{{ $t('panel.help.stances_note_passive') }}</p>
        <p>{{ $t('panel.help.stances_note_idle') }}</p>
        <p>{{ $t('panel.help.stances_note_diplomacy') }}</p>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
// Listed from least to most aggressive so the table reads as a
// behavioral ramp. The `triggers` list pins exactly which of the
// three engagement moments each stance reacts to:
//
//   * `incoming` — an unallied Navarch ARRIVES at this fleet's
//     system (defender side of Jump.finish).
//   * `hostile_action` — an unallied Navarch starts a hostile action
//     (raid, loot, conquest, colonization) IN this fleet's system
//     (defender side of those actions' check_interception).
//   * `arriving` — this fleet itself ARRIVES at a system containing
//     an unallied Navarch (arriver side of Jump.finish, Fury-only).
//
// The matrix here MUST match what `Instance.Character.Actions.Fight`
// and `Instance.Character.Actions.Jump.interception_reactions/1`
// actually do.
const STANCES = [
  { reaction: 'flee', triggers: [] },
  { reaction: 'fight_back', triggers: [] },
  { reaction: 'defend', triggers: ['hostile_action'] },
  { reaction: 'attack_enemies', triggers: ['incoming', 'hostile_action'] },
  { reaction: 'attack_everyone', triggers: ['incoming', 'hostile_action', 'arriving'] },
];

export default {
  name: 'help-stances-panel',
  data() {
    return { rows: STANCES };
  },
};
</script>
