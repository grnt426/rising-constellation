<template>
  <div
    class="panel-container is-right"
    :class="theme"
    @click.self="close">
    <overall
      v-show="activePanel === 'overall'"
      :players="sortedPlayers" />
    <best-system
      v-show="['prod', 'credit', 'technology', 'ideology', 'workforce'].includes(activePanel)"
      :type="activePanel"
      :players="sortedPlayers" />
    <scenario-board
      v-if="activePanel === 'scenario'"
      :board="scenarioBoard" />

    <div
      class="panel-navbar"
      role="group"
      :aria-label="$t('a11y.panel_tabs')">
      <button
        type="button"
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.ranking.${panel}`)"
        :key="panel"
        :class="{ 'is-active': activePanel === panel }"
        :aria-label="$t(`panel.ranking.${panel}`)"
        :aria-pressed="String(activePanel === panel)"
        @click="activePanel = panel">
      </button>
    </div>
  </div>
</template>

<script>
import Overall from '@/game/components/panel/ranking/Overall.vue';
import BestSystem from '@/game/components/panel/ranking/BestSystem.vue';
import ScenarioBoard from '@/game/components/panel/ranking/ScenarioBoard.vue';

const PANELS = ['overall', 'prod', 'credit', 'technology', 'ideology', 'workforce'];

export default {
  name: 'ranking-panel',
  data() {
    return {
      activePanel: 'overall',
      players: [],
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    // a scripted match whose scripts keep a score: its own leaderboard tab
    scenarioBoard() { return this.$store.state.game.scenarioBoard || []; },
    panels() { return this.scenarioBoard.length ? [...PANELS, 'scenario'] : PANELS; },
    galaxyPlayers() { return this.$store.state.game.galaxy.players; },
    sortedPlayers() {
      const { players } = this;
      let sortField = '';

      switch (this.activePanel) {
        case 'overall': sortField = 'points'; break;
        case 'prod': sortField = 'best_prod'; break;
        case 'credit': sortField = 'best_credit'; break;
        case 'technology': sortField = 'best_technology'; break;
        case 'ideology': sortField = 'best_ideology'; break;
        case 'workforce': sortField = 'best_workforce'; break;
        default: return '';
      }

      return players
        .sort((a, b) => b[sortField] - a[sortField])
        .map((player) => ({ is_player_active: this.galaxyPlayers[player.player_id]?.is_active ?? true, ...player }));
    },
  },
  methods: {
    open(_data) {
      this.loadStats();
    },
    loadStats() {
      this.$socket.global
        .push('get_stats', {})
        .receive('ok', (stats) => { this.players = stats.players; })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Overall,
    BestSystem,
    ScenarioBoard,
  },
};
</script>
