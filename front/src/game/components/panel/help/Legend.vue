<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.legend_title') }}
      </h1>

      <h2 class="help-legend-section">
        {{ $t('panel.help.legend_systems_title') }}
      </h2>
      <table class="help-legend-table">
        <tbody>
          <tr
            v-for="row in systemRows"
            :key="row.id">
            <th>
              <div class="help-legend-system">
                <span
                  v-if="row.halo"
                  class="help-legend-halo"
                  :style="{ backgroundColor: row.color }"></span>
                <span
                  class="help-legend-layer"
                  :class="`is-base-${row.base}`"></span>
                <span
                  v-if="row.overlay"
                  class="help-legend-layer help-legend-layer-tinted"
                  :class="`is-overlay-${row.overlay}`"
                  :style="{ backgroundColor: row.color }"></span>
              </div>
            </th>
            <td>
              <div class="help-legend-name">
                {{ row.name }}<span
                  v-if="row.asterisk"
                  class="help-legend-asterisk">*</span>
              </div>
              <div class="help-legend-desc">
                {{ $t(`panel.help.legend_${row.id}`) }}
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <h2 class="help-legend-section">
        {{ $t('panel.help.legend_agents_title') }}
      </h2>
      <table class="help-legend-table">
        <tbody>
          <tr
            v-for="row in agentRows"
            :key="row.id">
            <th>
              <div
                class="help-legend-agent help-legend-layer-tinted"
                :class="`is-agent-${row.icon}`"
                :style="{ backgroundColor: row.color }"></div>
            </th>
            <td>
              <div class="help-legend-name">{{ row.name }}</div>
              <div class="help-legend-desc">
                {{ $t(`panel.help.legend_${row.id}`) }}
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <h2 class="help-legend-section">
        {{ $t('panel.help.legend_modes_title') }}
      </h2>
      <table class="help-legend-table">
        <tbody>
          <tr
            v-for="row in modeRows"
            :key="row.id">
            <th class="is-wide-pair">
              <div
                v-if="row.kind === 'pair'"
                class="help-legend-mode-pair">
                <div class="help-legend-system">
                  <span
                    class="help-legend-disc"
                    :class="row.discClass"
                    :style="{ backgroundColor: row.discColor }"></span>
                  <span class="help-legend-layer is-base-inhabited"></span>
                  <span class="help-legend-number">{{ row.value }}</span>
                </div>
                <div class="help-legend-system is-dim">
                  <span class="help-legend-layer is-base-inhabited"></span>
                </div>
              </div>
              <div
                v-else-if="row.kind === 'radar'"
                class="help-legend-system">
                <span
                  class="help-legend-dashed-disk"
                  :style="{ borderColor: row.diskColor }"></span>
                <span class="help-legend-layer is-base-inhabited"></span>
              </div>
            </th>
            <td>
              <div class="help-legend-name">{{ row.name }}</div>
              <div class="help-legend-desc">
                {{ $t(`panel.help.legend_${row.id}`) }}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="help-legend-hint">{{ $t('panel.help.legend_modes_hint') }}</p>

      <div class="help-legend-notes">
        <p>{{ $t('panel.help.legend_note_asterisk') }}</p>
        <p>{{ $t('panel.help.legend_note_detection') }}</p>
        <p>{{ $t('panel.help.legend_note_allies') }}</p>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'help-legend-panel',
  computed: {
    factions() {
      return this.$store.state.game.data.faction || [];
    },
    playerFactionKey() {
      return this.$store.state.game.player && this.$store.state.game.player.faction;
    },
    playerFaction() {
      return this.factions.find((f) => f.key === this.playerFactionKey);
    },
    opposingFactions() {
      return this.factions.filter((f) => f.key !== this.playerFactionKey);
    },
    detectedExampleFaction() {
      return this.opposingFactions[0] || this.factions[0];
    },
    systemRows() {
      const rows = [
        {
          id: 'uninhabited',
          name: this.$t('panel.help.legend_uninhabited_name'),
          base: 'uninhabited',
          asterisk: false,
        },
        {
          id: 'inhabited_neutral',
          name: this.$t('panel.help.legend_inhabited_neutral_name'),
          base: 'inhabited',
          asterisk: true,
        },
      ];

      this.opposingFactions.forEach((f) => {
        rows.push({
          id: `inhabited_other_${f.key}`,
          name: this.$t('panel.help.legend_inhabited_other_name', {
            faction: this.$t(`data.faction.${f.key}.name`),
          }),
          base: 'inhabited',
          overlay: 'player',
          color: f.color,
          asterisk: true,
        });
      });

      if (this.playerFaction) {
        rows.push({
          id: 'inhabited_self',
          name: this.$t('panel.help.legend_inhabited_self_name'),
          base: 'inhabited',
          overlay: 'player',
          color: this.playerFaction.color,
          halo: true,
          asterisk: false,
        });
      }

      return rows;
    },
    modeRows() {
      const color = this.playerFaction ? this.playerFaction.color : '#ffffff';

      return [
        {
          id: 'mode_visibility',
          name: this.$t('panel.help.legend_mode_visibility_name'),
          kind: 'pair',
          discClass: 'is-visibility-disc',
          discColor: color,
          value: '5',
        },
        {
          id: 'mode_population',
          name: this.$t('panel.help.legend_mode_population_name'),
          kind: 'pair',
          discClass: 'is-population-disc',
          discColor: color,
          value: '4',
        },
        {
          id: 'mode_radar',
          name: this.$t('panel.help.legend_mode_radar_name'),
          kind: 'radar',
          diskColor: color,
        },
      ];
    },
    agentRows() {
      const ownColor = this.playerFaction ? this.playerFaction.color : '#ffffff';
      const detectedColor = this.detectedExampleFaction
        ? this.detectedExampleFaction.color
        : '#ffffff';

      return [
        {
          id: 'navarch',
          name: this.$tc('data.character.admiral.name', 1),
          icon: 'admiral',
          color: ownColor,
        },
        {
          id: 'siderian',
          name: this.$tc('data.character.speaker.name', 1),
          icon: 'speaker',
          color: ownColor,
        },
        {
          id: 'erased',
          name: this.$tc('data.character.spy.name', 1),
          icon: 'spy',
          color: ownColor,
        },
        {
          id: 'detected',
          name: this.$t('panel.help.legend_detected_name'),
          icon: 'character',
          color: detectedColor,
        },
      ];
    },
  },
};
</script>
