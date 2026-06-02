<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.hotkeys_title') }}
      </h1>

      <table class="help-hotkeys-table">
        <tbody>
          <tr
            v-for="row in rows"
            :key="row.id">
            <th>
              <span
                v-for="(k, i) in row.keys"
                :key="i">
                <kbd>{{ k }}</kbd><template v-if="i < row.keys.length - 1"> + </template>
              </span>
            </th>
            <td>{{ $t(`panel.help.hotkey.${row.id}`) }}</td>
          </tr>
        </tbody>
      </table>
    </v-scrollbar>
  </div>
</template>

<script>
const HOTKEYS = [
  { id: 'search', keys: ['F'] },
  { id: 'faction', keys: ['O'] },
  { id: 'empire', keys: ['S'] },
  { id: 'operations', keys: ['A'] },
  { id: 'ranking', keys: ['R'] },
  { id: 'victory', keys: ['V'] },
  { id: 'patent', keys: ['P'] },
  { id: 'doctrine', keys: ['L'] },
  { id: 'character_market', keys: ['M'] },
  { id: 'help', keys: ['H'] },
  { id: 'settings', keys: ['Esc'] },
  { id: 'first_system', keys: ['C'] },
  { id: 'next_system', keys: ['.'] },
  { id: 'next_agent', keys: [','] },
  { id: 'center_character', keys: ['Space'] },
  { id: 'select_group', keys: ['1', '…', '9'] },
  { id: 'create_group', keys: ['Ctrl', '1-9'] },
];

export default {
  name: 'help-hotkeys-panel',
  data() {
    return { rows: HOTKEYS };
  },
};
</script>
