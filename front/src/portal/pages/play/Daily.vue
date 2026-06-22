<template>
  <div class="panel-fragment">
    <div class="panel-content is-large">
      <div class="content daily-scroll">
        <div class="daily-card">
          <h2 class="daily-card-title">{{ $t('page.play.daily.title') }}</h2>

          <div class="daily-columns">
            <section class="daily-column daily-column--main">
              <div
                v-if="daily"
                class="daily-info">
                <p>
                  <strong>{{ daily.date }}</strong>
                </p>
                <p class="daily-rotation">
                  {{ $t('page.play.daily.next_challenge_in') }} <strong>{{ rotation }}</strong>
                </p>
                <p>
                  {{ $t('page.play.daily.intro') }}
                </p>
                <p v-if="daily.faction">
                  <strong>{{ $t('page.play.daily.faction') }}</strong>
                  <span
                    class="daily-faction"
                    :style="daily.faction.color ? { color: daily.faction.color } : null">
                    {{ $t(`data.faction.${daily.faction.key}.name`) }}
                  </span>
                </p>
                <p>
                  {{ daily.objective.name }}: {{ daily.objective.description }}
                </p>
                <p class="daily-label"><strong>{{ $t('page.play.daily.mutators') }}</strong></p>
                <ul class="daily-mutators">
                  <li
                    v-for="m in daily.mutators"
                    :key="m.key"
                    :class="`is-${m.polarity}`">
                    <strong>{{ polaritySign(m.polarity) }} {{ $t(`data.mutator.${m.key}.name`) }}:</strong>
                     {{ $t(`data.mutator.${m.key}.description`) }}
                  </li>
                </ul>
              </div>

              <p class="daily-note">{{ $t('page.play.daily.note') }}</p>
              
              <div class="daily-actions">
                <button
                  @click="play"
                  class="default-button fullsized"
                  :class="{ 'disabled': waiting }">
                  <template v-if="waiting">{{ $t('page.play.daily.starting') }}</template>
                  <template v-else>{{ $t('page.play.daily.play') }}</template>
                </button>
              </div>
            </section>

            <section class="daily-column daily-column--board">
              <h3 class="daily-subtitle">{{ $t('page.play.daily.leaderboard_title') }}</h3>
              <p
                v-if="leaderboard && leaderboard.you"
                class="daily-you">
                {{ $t('page.play.daily.your_best') }} <strong>#{{ leaderboard.you.rank }}</strong>
                ({{ formatScore(leaderboard.you.score) }})
              </p>
              <table
                v-if="leaderboard && leaderboard.entries.length"
                class="daily-board">
                <tbody>
                  <tr
                    v-for="e in leaderboard.entries"
                    :key="e.rank">
                    <td class="rank">{{ e.rank }}</td>
                    <td class="name">{{ e.name }}</td>
                    <td class="score">{{ formatScore(e.score) }}</td>
                  </tr>
                </tbody>
              </table>
              <p
                v-else
                class="daily-empty">
                {{ $t('page.play.daily.no_scores') }}
              </p>
            </section>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'play-daily',
  data() {
    return {
      waiting: false,
      daily: null,
      leaderboard: null,
      now: Date.now(),
      clockTimer: null,
    };
  },
  computed: {
    activeProfile() { return this.$store.state.portal.activeProfile; },
    // Time until the daily rotates. Dailies are keyed by UTC date, so the next
    // one drops at the coming UTC midnight. Deliberately shows only the clock —
    // never a preview of tomorrow's challenge.
    rotation() {
      const d = new Date(this.now);
      const nextUtcMidnight = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
      let s = Math.max(0, Math.floor((nextUtcMidnight - this.now) / 1000));
      const h = Math.floor(s / 3600); s -= h * 3600;
      const m = Math.floor(s / 60); s -= m * 60;
      const pad = (n) => String(n).padStart(2, '0');
      return `${h}h ${pad(m)}m ${pad(s)}s`;
    },
  },
  async mounted() {
    this.clockTimer = setInterval(() => { this.now = Date.now(); }, 1000);

    try {
      const { data } = await this.$axios.get('/daily/today');
      this.daily = data;
    } catch (err) {
      // Preview is best-effort; the Play button still works without it.
    }

    this.loadLeaderboard();
  },
  beforeDestroy() {
    if (this.clockTimer) { clearInterval(this.clockTimer); }
  },
  methods: {
    polaritySign(polarity) { return polarity === 'negative' ? '−' : '+'; },
    formatScore(score) { return Math.round(score).toLocaleString(); },
    async loadLeaderboard() {
      try {
        const profileId = this.activeProfile && this.activeProfile.id;
        const { data } = await this.$axios.get('/daily/leaderboard', { params: { profile_id: profileId } });
        this.leaderboard = data;
      } catch (err) {
        // Best-effort; the page works without the board.
      }
    },
    async play() {
      if (this.waiting) { return; }
      if (!this.activeProfile) {
        this.$toastError(this.$t('page.play.daily.select_profile'));
        return;
      }

      this.waiting = true;

      try {
        const { data } = await this.$axios.post('/daily/play', { profile_id: this.activeProfile.id });

        this.$ambiance.sound('play');
        this.$store.commit('game/init', data);
        this.$ambiance.changeContext('game');

        this.$router.push('/game');
      } catch (err) {
        this.waiting = false;
        const message = err.response && err.response.data && err.response.data.message;
        this.$toastError(message || this.$t('page.play.daily.play_failed'));
      }
    },
  },
};
</script>

<style scoped>
/* Daily-specific layout: a full-width card (the standard .tutorial-box is a
   fixed 400px, which squeezes two columns) split into a description column and
   a leaderboard column. Semi-transparent so the background art shows through. */
.daily-scroll {
  overflow-y: auto;
}

.daily-card {
  background: rgba(255, 255, 255, 0.05);
  border: solid 1px rgba(255, 255, 255, 0.1);
  backdrop-filter: blur(3px);
}

.daily-card-title {
  padding: 22px 30px;
  text-transform: uppercase;
  font-weight: normal;
  font-size: 2rem;
  border-bottom: solid 1px rgba(255, 255, 255, 0.1);
}

.daily-columns {
  display: grid;
  grid-template-columns: 1.6fr 1fr;
  align-items: stretch;
}

.daily-column {
  min-width: 0;
  padding: 28px 30px;
}

.daily-column--main {
  border-right: solid 1px rgba(255, 255, 255, 0.1);
}

.daily-rotation {
  margin-bottom: 1.25rem;
  font-size: 1.3rem;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  opacity: 0.7;
}
.daily-rotation strong {
  opacity: 1;
  font-variant-numeric: tabular-nums;
}

.daily-info p {
  margin-bottom: 1rem;
  line-height: 1.55;
}

.daily-faction {
  font-weight: bold;
}

.daily-label { margin-bottom: 0.35rem; }

.daily-mutators {
  list-style: none;
  margin: 0;
  padding: 0;
}
.daily-mutators li {
  margin-bottom: 0.6rem;
  line-height: 1.45;
}
.daily-mutators li.is-positive strong { color: #8fd19e; }
.daily-mutators li.is-negative strong { color: #e6a3a3; }

.daily-actions { margin-top: 1.75rem; }
.daily-note { margin-top: 0.85rem; opacity: 0.7; }

.daily-subtitle {
  text-transform: uppercase;
  font-size: 1.3rem;
  opacity: 0.7;
  margin-bottom: 0.85rem;
}
.daily-you { margin-bottom: 1rem; }
.daily-board {
  width: 100%;
  border-collapse: collapse;
}
.daily-board td {
  padding: 0.4rem 0.5rem;
  border-bottom: solid 1px rgba(255, 255, 255, 0.08);
}
.daily-board .rank { width: 2.5rem; opacity: 0.55; }
.daily-board .name { width: 100%; }
.daily-board .score { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.daily-empty { opacity: 0.6; }
</style>
