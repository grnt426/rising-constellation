<template>
  <div class="panel-content is-medium">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">{{ $t('panel.ranking.scenario_title') }}</h1>
      <p class="scenario-board-hint">{{ $t('panel.ranking.scenario_hint') }}</p>

      <section
        v-for="(script, i) in board"
        :key="i"
        class="scenario-board">
        <!-- script names and player names are player text: plain text only -->
        <h2 class="scenario-board-name">{{ script.name }}</h2>
        <p
          v-if="script.race"
          class="scenario-board-hint">{{ $t('panel.ranking.scenario_race') }}</p>
        <p
          v-if="!script.rows.length"
          class="scenario-board-hint">{{ $t('panel.ranking.scenario_empty') }}</p>
        <table
          v-else
          class="panel-table ranking-table">
          <tr
            v-for="row in script.rows"
            :key="row.player_id"
            :class="{ 'is-me': row.player_id === playerId }">
            <td>#{{ row.rank }}</td>
            <td
              class="name"
              :class="`theme-${getTheme(row.faction)}`"
              @click="openPlayer(row.player_id)">
              {{ row.name }}
            </td>
            <td>
              <template v-if="row.finished">{{ $t('panel.ranking.scenario_finished') }}</template>
            </td>
            <td class="highlighted align-right">
              <template v-if="script.race && !row.finished">–</template>
              <template v-else>{{ formatScore(row.score) }}</template>
            </td>
          </tr>
        </table>
      </section>

      <div class="anchor"></div>
    </v-scrollbar>
  </div>
</template>

<script>
// A scripted match's own leaderboard: each script that keeps a score ranks
// every player by it (Edict.Match pushes it every few seconds).
export default {
  name: 'ranking-scenario-board',
  props: {
    board: { type: Array, default: () => [] },
  },
  computed: {
    playerId() { return this.$store.state.game.player && this.$store.state.game.player.id; },
  },
  methods: {
    getTheme(key) {
      return this.$store.getters['game/themeByKey'](key);
    },
    openPlayer(playerId) {
      this.$store.dispatch('game/openPlayer', { vm: this, id: playerId });
    },
    formatScore(n) {
      if (typeof n !== 'number') return '–';
      return Math.abs(n) >= 1000 ? Math.round(n).toLocaleString('en-US') : Math.round(n * 100) / 100;
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.scenario-board {
  margin-bottom: 24px;
}

.scenario-board-name {
  margin: 0 0 6px;
  font-size: 1.6rem;
  text-transform: uppercase;
}

.scenario-board-hint {
  margin: 0 0 10px;
  color: $white-alt-1;
}

tr.is-me td {
  background: rgba(255, 255, 255, .06);
}
</style>
