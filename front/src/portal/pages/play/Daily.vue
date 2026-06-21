<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="content is-tutorial">
        <div class="tutorial-box">
          <h2>Daily Challenge</h2>

          <div
            v-if="daily"
            class="info">
            <p>
              <strong>{{ daily.date }}</strong> — optimise a single procedurally-generated
              system. Everyone today faces the same system and twists; only your
              decisions differ.
            </p>
            <p>
              <strong>Goal:</strong> {{ daily.objective.name }} — {{ daily.objective.description }}
            </p>
            <p>
              <strong>System:</strong> {{ daily.system.archetype }}
            </p>
            <p><strong>Mutators:</strong></p>
            <ul class="daily-mutators">
              <li
                v-for="m in daily.mutators"
                :key="m.key"
                :class="`is-${m.polarity}`">
                <strong>{{ polaritySign(m.polarity) }} {{ m.name }}</strong>
                — {{ m.description }}
              </li>
            </ul>
          </div>

          <div class="button">
            <button
              @click="play"
              class="default-button fullsized"
              :class="{ 'disabled': waiting }">
              <template v-if="waiting">Starting…</template>
              <template v-else>Play today's daily</template>
            </button>
          </div>

          <div class="info">
            <p>A fresh attempt each time — your best run is what counts.</p>
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
    };
  },
  computed: {
    activeProfile() { return this.$store.state.portal.activeProfile; },
  },
  async mounted() {
    try {
      const { data } = await this.$axios.get('/daily/today');
      this.daily = data;
    } catch (err) {
      // Preview is best-effort; the Play button still works without it.
    }
  },
  methods: {
    polaritySign(polarity) { return polarity === 'negative' ? '−' : '+'; },
    async play() {
      if (this.waiting) { return; }
      if (!this.activeProfile) {
        this.$toastError('Select a profile first.');
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
        this.$toastError(message || 'Failed to start the daily.');
      }
    },
  },
};
</script>

<style scoped>
.daily-mutators {
  list-style: none;
  margin: 0.25rem 0 0.75rem;
  padding: 0;
}
.daily-mutators li {
  margin-bottom: 0.35rem;
  line-height: 1.4;
}
.daily-mutators li.is-positive strong { color: #8fd19e; }
.daily-mutators li.is-negative strong { color: #e6a3a3; }
</style>
