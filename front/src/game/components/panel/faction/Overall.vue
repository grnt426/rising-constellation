<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.faction.overall_title') }}
      </h1>

      <div class="panel-content-number-bloc">
        <div class="label">
          {{ $t('panel.faction.player_count') }}
        </div>
        <div class="value">
          {{ faction.players.length }}
        </div>
      </div>

      <h1 class="panel-default-title">
        {{ $t('page.instance.tradition') }}
      </h1>

      <div
        class="panel-content-text-bloc"
        v-for="tradition in factionData.traditions"
        :key="tradition.key">
        <div class="header">
          <strong>{{ $t(`data.tradition.${tradition.key}.name`) }}</strong>
          <span>{{ traditionBonus(tradition) }}</span>
        </div>
        <div class="body">
          {{ $t(`data.tradition.${tradition.key}.description`) }}
        </div>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import { formatBonusValue } from '@/utils/bonus';

export default {
  name: 'faction-overall-panel',
  computed: {
    faction() { return this.$store.state.game.faction; },
    victory() { return this.$store.state.game.victory; },
    factionData() {
      return this.$store.state.game.data.faction.find((f) => f.key === this.faction.key);
    },
    bonusOut() { return this.$store.state.game.data.bonus_pipeline_out; },
  },
  methods: {
    // Label from i18n, number derived from the engine's own bonus value —
    // see utils/bonus.js for why the number isn't in the locale files.
    traditionBonus(tradition) {
      return this.$t('page.instance.tradition_bonus', {
        label: this.$t(`data.tradition.${tradition.key}.bonus_label`),
        value: formatBonusValue(tradition.bonus, this.bonusOut),
      });
    },
  },
};
</script>
