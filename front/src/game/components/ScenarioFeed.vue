<template>
  <div
    v-if="messages.length || status"
    class="scenario-feed"
    role="log"
    aria-live="polite"
    :aria-label="$t('scenario_feed.label')">
    <div
      v-if="status"
      class="scenario-status">
      <div class="scenario-status-row">
        <span class="scenario-kind">{{ $t('scenario_feed.playtest') }}</span>
        <span class="scenario-name">{{ status.name }}</span>
        <span
          v-if="status.race"
          class="scenario-score">{{ $t('scenario_feed.race') }}</span>
        <span
          v-else
          class="scenario-score">{{ $t('scenario_feed.score') }} <strong>{{ formatScore(status.score) }}</strong></span>
        <button
          type="button"
          class="scenario-back"
          @click="backToWorkshop">{{ $t('scenario_feed.back') }}</button>
      </div>
      <div
        v-if="status.description"
        class="scenario-goal">{{ status.description }}</div>
    </div>
    <div
      v-for="m in messages"
      :key="m.id"
      class="scenario-message"
      :class="`tone-${tone(m)}`">
      <span
        v-if="m.tone === 'error'"
        class="scenario-kind">{{ $t('scenario_feed.script') }}</span>
      <!-- plain text on purpose: a script wrote this, so it never goes
           through markdown or raw HTML (see Edict.Effects) -->
      <span class="scenario-text">{{ m.text }}</span>
      <button
        type="button"
        class="scenario-close"
        :aria-label="$t('scenario_feed.dismiss')"
        @click="dismiss(m.id)">×</button>
    </div>
  </div>
</template>

<script>
// Messages a scenario script sends the player (notify()), and, in a
// playtest, the script's own errors. Each fades after a while; errors stay
// longer, since the author needs to read them.
const SHOWN_MS = {
  error: 14000, warning: 10000, good: 8000, info: 8000, echo: 6000,
};

export default {
  name: 'scenario-feed',
  data() {
    return { now: Date.now(), timer: null, leaving: false };
  },
  computed: {
    status() { return this.$store.state.game.scenarioStatus; },
    messages() {
      return this.$store.state.game.scenarioMessages
        .filter((m) => this.now - m.at < (SHOWN_MS[m.tone] || SHOWN_MS.info))
        .slice(-4);
    },
  },
  mounted() {
    this.timer = setInterval(() => { this.now = Date.now(); }, 1000);
  },
  beforeDestroy() { clearInterval(this.timer); },
  methods: {
    tone(m) { return ['info', 'good', 'warning', 'error', 'echo'].includes(m.tone) ? m.tone : 'info'; },
    dismiss(id) { this.$store.commit('game/discardScenarioMessage', id); },
    // the same exit as the menu's Quit: end the run server-side, leave, and
    // go back to the workshop
    backToWorkshop() {
      if (this.leaving) return;
      this.leaving = true;
      this.$socket.player.push('quit_daily', {});
      this.$ambiance.changeContext('portal');
      this.$socket.leaveGame();
      this.$store.commit('game/clear');
      this.$router.push('/scenario-workshop');
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

.scenario-feed {
  position: fixed;
  top: 64px;
  left: 50%;
  z-index: 35;
  display: flex;
  flex-direction: column;
  gap: 6px;
  width: 440px;
  max-width: 90vw;
  transform: translateX(-50%);
  pointer-events: none;
}

.scenario-message {
  display: flex;
  align-items: baseline;
  gap: 8px;
  padding: 9px 12px;
  background: rgba(10, 11, 14, .92);
  border: solid 1px rgba(255, 255, 255, .15);
  border-left: solid 3px $white-alt-2;
  color: $white;
  font-size: 1.3rem;
  line-height: 1.4;
  pointer-events: auto;

  &.tone-good {
    border-left-color: $white;
  }

  &.tone-warning,
  &.tone-error {
    border-left-color: $color-alert;
  }
}

.scenario-status {
  padding: 6px 12px;
  background: rgba(10, 11, 14, .92);
  border: solid 1px rgba(255, 255, 255, .15);
  color: $white;
  font-size: 1.25rem;
  pointer-events: auto;
}

.scenario-status-row {
  display: flex;
  align-items: baseline;
  gap: 10px;

  // a label, not an alarm: orange is for warnings and errors
  .scenario-kind {
    color: $white-alt-1;
  }
}

.scenario-goal {
  margin-top: 4px;
  color: $white-alt-1;
  font-size: 1.15rem;
  line-height: 1.35;
}

.scenario-back {
  flex: 0 0 auto;
  padding: 2px 8px;
  border: solid 1px rgba(255, 255, 255, .3);
  background: none;
  color: $white;
  font: inherit;
  font-size: 1.1rem;
  cursor: pointer;

  &:hover {
    background: rgba(255, 255, 255, .08);
  }
}

.scenario-name {
  flex: 1 1 auto;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.scenario-score strong {
  font-variant-numeric: tabular-nums;
}

.scenario-message.tone-echo {
  border-left-color: transparent;
  color: $white-alt-1;
  font-size: 1.15rem;
}

.scenario-kind {
  flex: 0 0 auto;
  color: $color-alert;
  font-size: 1.1rem;
  text-transform: uppercase;
  letter-spacing: .05em;
}

.scenario-text {
  flex: 1 1 auto;
  overflow-wrap: anywhere;
  white-space: pre-line;
}

.scenario-close {
  flex: 0 0 auto;
  padding: 0 4px;
  border: none;
  background: none;
  color: $white-alt-1;
  font: inherit;
  cursor: pointer;
}
</style>
