<template>
  <div
    class="panel-container is-left"
    :class="theme"
    @click.self="close">
    <div class="panel-navbar">
      <button
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.empire.${panel}`)"
        :key="panel"
        :class="{ 'is-active': activePanel === panel }"
        @click="activePanel = panel">
      </button>
    </div>

    <overall v-show="activePanel === 'overall'" />
    <possessions
      @close="close"
      v-show="activePanel === 'possessions'" />
    <galactic-survey
      @close="close"
      v-show="activePanel === 'galactic_survey'" />
    <financials v-if="calcAvailable" v-show="activePanel === 'financials'" />
    <mutators v-show="activePanel === 'mutators'" />
    <cheats v-if="cheatsAvailable" v-show="activePanel === 'cheats'" />
  </div>
</template>

<script>
import Overall from '@/game/components/panel/empire/Overall.vue';
import Possessions from '@/game/components/panel/empire/Possessions.vue';
import GalacticSurvey from '@/game/components/panel/empire/GalacticSurvey.vue';
import Financials from '@/game/components/panel/empire/Financials.vue';
import Mutators from '@/game/components/panel/empire/Mutators.vue';
import Cheats from '@/game/components/panel/empire/Cheats.vue';

export default {
  name: 'faction-panel',
  data() {
    return {
      activePanel: 'overall',
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    // The Mutators tab only exists for daily challenges (speed === 'daily').
    isDaily() { return this.$store.state.game.time.speed === 'daily'; },
    // The Cheats tab exists for every player of a cheats-enabled instance;
    // creator-only sections are gated inside the tab and the server
    // independently gates every cheat op.
    cheatsAvailable() { return this.$store.getters['game/cheatsAvailable']; },
    // Financials rides the calculator beta flag (Account → Beta Features).
    calcAvailable() { return this.$store.state.portal.features.calculator === true; },
    panels() {
      const base = ['overall', 'possessions', 'galactic_survey'];
      if (this.calcAvailable) base.push('financials');
      if (this.isDaily) base.push('mutators');
      if (this.cheatsAvailable) base.push('cheats');
      return base;
    },
  },
  methods: {
    open(data) {
      // deep-link into a specific tab (QuickCalc's expand button)
      if (data && data.tab && this.panels.includes(data.tab)) {
        this.activePanel = data.tab;
      }
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Overall,
    Possessions,
    GalacticSurvey,
    Financials,
    Mutators,
    Cheats,
  },
};
</script>
