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
    <mutators v-show="activePanel === 'mutators'" />
  </div>
</template>

<script>
import Overall from '@/game/components/panel/empire/Overall.vue';
import Possessions from '@/game/components/panel/empire/Possessions.vue';
import GalacticSurvey from '@/game/components/panel/empire/GalacticSurvey.vue';
import Mutators from '@/game/components/panel/empire/Mutators.vue';

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
    panels() {
      const base = ['overall', 'possessions', 'galactic_survey'];
      return this.isDaily ? [...base, 'mutators'] : base;
    },
  },
  methods: {
    open(_data) {
      // ...
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Overall,
    Possessions,
    GalacticSurvey,
    Mutators,
  },
};
</script>
