<template>
  <div class="daily-result">
    <div class="daily-result-panel">
      <div class="title">
        <template v-if="isRaceWon">{{ $t('daily_result.title_race_won') }}</template>
        <template v-else>{{ $t('daily_result.title_time_up') }}</template>
      </div>

      <template v-if="isRaceWon">
        <div class="line">{{ $t('daily_result.time_taken') }}</div>
        <div class="big-value">{{ formatDuration(elapsedSeconds) }}</div>
        <div class="line sub">{{ $t('daily_result.time_left') }} {{ formatDuration(result.seconds_left) }}</div>
      </template>
      <template v-else-if="isRaceDnf">
        <div class="line">{{ $t('daily_result.dnf') }}</div>
      </template>
      <template v-else>
        <div class="line">{{ $t('daily_result.score') }}</div>
        <div class="big-value">{{ formatScore(result.run_score) }}</div>
      </template>

      <div
        v-if="result.rank"
        class="rank">
        {{ $t('daily_result.rank') }} <span class="num">#{{ result.rank }}</span>
      </div>

      <div class="countdown">
        {{ $t('daily_result.auto_exit', { seconds: countdown }) }}
      </div>
      <div
        class="exit-button"
        @click="exitNow">
        {{ $t('daily_result.exit_now') }}
      </div>
    </div>
  </div>
</template>

<script>
// End-of-daily banner: shown the moment the server pushes `daily_result` on
// the global channel — either a race objective completed live (the run is
// frozen server-side at that instant, the score already recorded) or the
// 30-minute deadline hit. Displays the achieved time / score and today's
// rank, then auto-exits to the daily page after a short countdown (the same
// flow as the in-game "Exit" button, so the instance is torn down cleanly).
const AUTO_EXIT_SECONDS = 15;

export default {
  name: 'daily-result-banner',
  data() {
    return {
      countdown: AUTO_EXIT_SECONDS,
      waiting: false,
    };
  },
  computed: {
    result() { return this.$store.state.game.dailyResult; },
    isRaceWon() { return this.result.reason === 'race_won'; },
    isRaceDnf() { return this.result.reason === 'time_up' && this.result.mode === 'race'; },
    elapsedSeconds() {
      return Math.max(0, (this.result.time_limit_seconds || 0) - (this.result.seconds_left || 0));
    },
  },
  methods: {
    formatDuration(seconds) {
      const total = Math.max(0, Math.round(seconds || 0));
      const m = Math.floor(total / 60);
      const s = (total % 60).toString().padStart(2, '0');
      return `${m}:${s}`;
    },
    formatScore(score) {
      return Math.round(score || 0).toLocaleString();
    },
    exitNow() {
      if (this.waiting) { return; }
      this.waiting = true;

      // Same sequence as the Settings "Exit" daily branch: record + teardown
      // server-side, then straight to the daily page's leaderboard.
      this.$socket.player.push('quit_daily', {});
      this.$ambiance.changeContext('portal');
      this.$socket.leaveGame();
      this.$store.commit('game/clear');
      this.$router.push('/play/daily');
    },
  },
  mounted() {
    this.exitTimer = setInterval(() => {
      this.countdown -= 1;
      if (this.countdown <= 0) {
        clearInterval(this.exitTimer);
        this.exitTimer = null;
        this.exitNow();
      }
    }, 1000);
  },
  beforeDestroy() {
    if (this.exitTimer) { clearInterval(this.exitTimer); }
  },
};
</script>

<style scoped>
.daily-result {
  position: fixed;
  top: 0;
  right: 0;
  bottom: 0;
  left: 0;
  z-index: 40;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
}

.daily-result-panel {
  min-width: 340px;
  max-width: 90vw;
  padding: 28px 36px;
  text-align: center;
  color: rgba(255, 255, 255, 0.9);
  background: #14151a;
  border: 1px solid rgba(255, 255, 255, 0.18);
  box-shadow: 0 0 40px rgba(0, 0, 0, 0.8);
}

.title {
  margin-bottom: 18px;
  font-size: 1.8rem;
  font-weight: bold;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.line {
  font-size: 1.1rem;
  color: rgba(255, 255, 255, 0.7);
}

.line.sub {
  margin-top: 6px;
  font-size: 0.95rem;
}

.big-value {
  margin: 4px 0;
  font-size: 3rem;
  font-weight: bold;
  font-variant-numeric: tabular-nums;
}

.rank {
  margin-top: 14px;
  font-size: 1.2rem;
}

.rank .num {
  font-size: 1.6rem;
  font-weight: bold;
  font-variant-numeric: tabular-nums;
}

.countdown {
  margin-top: 22px;
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.55);
}

.exit-button {
  margin-top: 12px;
  padding: 10px 0;
  border: 1px solid rgba(255, 255, 255, 0.3);
  font-size: 1rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  cursor: pointer;
  user-select: none;
}

.exit-button:hover {
  background: rgba(255, 255, 255, 0.08);
}
</style>
