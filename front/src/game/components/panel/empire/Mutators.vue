<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.empire.mutators_title') }}
      </h1>

      <section v-if="daily">
        <div class="panel-content-number-bloc">
          <div class="label">{{ $t('panel.empire.mutators_objective') }}</div>
          <div class="value">{{ daily.objective.name }}</div>
        </div>
        <p class="daily-desc">{{ daily.objective.description }}</p>

        <h2 class="daily-subtitle">{{ $t('panel.empire.mutators_active') }}</h2>
        <ul class="daily-mutator-list">
          <li
            v-for="m in daily.mutators"
            :key="m.key"
            :class="`is-${m.polarity}`">
            <strong>{{ polaritySign(m.polarity) }} {{ m.name }}</strong>
            <span class="daily-mutator-desc">{{ m.description }}</span>
          </li>
        </ul>
      </section>
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'empire-mutators-panel',
  data() {
    return {
      daily: null,
    };
  },
  async mounted() {
    try {
      const { data } = await this.$axios.get('/daily/today');
      this.daily = data;
    } catch (err) {
      // Best-effort: if the preview can't load, the tab just shows nothing.
    }
  },
  methods: {
    polaritySign(polarity) { return polarity === 'negative' ? '−' : '+'; },
  },
};
</script>

<style scoped>
.daily-desc {
  opacity: 0.8;
  margin: 0.25rem 0 1.25rem;
  line-height: 1.5;
}
.daily-subtitle {
  text-transform: uppercase;
  font-size: 1.2rem;
  opacity: 0.7;
  margin-bottom: 0.75rem;
}
.daily-mutator-list {
  list-style: none;
  padding: 0;
  margin: 0;
}
.daily-mutator-list li {
  margin-bottom: 1rem;
  line-height: 1.4;
}
.daily-mutator-list li.is-positive strong { color: #8fd19e; }
.daily-mutator-list li.is-negative strong { color: #e6a3a3; }
.daily-mutator-desc {
  display: block;
  opacity: 0.8;
  margin-top: 0.15rem;
}
</style>
