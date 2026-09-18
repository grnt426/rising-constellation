import { incomeFactor } from '@/utils/format';

// Real-time projections for a player resource ({ value, change, details }).
//
// Extracted from Bottombar so the phone resource drawer shows exactly the
// same rows as the desktop hover tooltip — the two must not drift.
export default {
  computed: {
    isDailyInstance() { return this.$store.state.game.time.speed === 'daily'; },
  },
  methods: {
    // How many game ticks (UTs) elapse per real hour, at the speed actually
    // in effect (base speed × runtime speed cheat). At 1× a tick is 3 real
    // minutes, so 20 ticks/hour. Undefined until the join payload primes the
    // speed data.
    ticksPerHour() {
      const factor = this.$store.getters['game/effectiveSpeedFactor'];
      return factor ? 20 * factor : undefined;
    },
    // Per-real-time income rates shown directly under the main (per-tick) line.
    // These translate the raw per-tick change into the figures players
    // actually reason about. Dailies run on a ~30-minute clock, so hourly/daily
    // rates are meaningless — they get a per-minute rate instead.
    resourceRates(resource) {
      const perHour = this.ticksPerHour();
      if (!resource || typeof resource.change !== 'number' || !perHour) return [];
      const rateHour = resource.change * perHour;
      if (this.isDailyInstance) {
        return [{ label: this.$t('resource-detail.rate_minute'), value: rateHour / 60 }];
      }
      if (incomeFactor() !== 1) {
        // Income-per-hour display: the main line above is already per hour,
        // so the hourly rate row would repeat it. Show the raw per-tick
        // figure and the daily projection instead.
        return [
          { label: this.$t('resource-detail.rate_tick'), value: resource.change },
          { label: this.$t('resource-detail.rate_day'), value: rateHour * 24 },
        ];
      }
      return [
        { label: this.$t('resource-detail.rate_hour'), value: rateHour },
        { label: this.$t('resource-detail.rate_day'), value: rateHour * 24 },
      ];
    },
    // Projected stockpile totals shown at the foot of the tooltip: current
    // amount plus the income that would accrue over the horizon if nothing
    // changed (ignores future buildings, conquests, agent losses). Dailies
    // last 30 minutes, so they get a near-term 3-minute projection instead.
    resourceTotals(resource) {
      const perHour = this.ticksPerHour();
      if (!resource || typeof resource.value !== 'number' || !perHour) return [];
      const change = resource.change || 0;
      if (this.isDailyInstance) {
        // 3 real minutes = a twentieth of an hour's worth of ticks.
        const per3min = change * (perHour / 20);
        return [{ label: this.$t('resource-detail.projection_3min'), value: resource.value + per3min }];
      }
      const rateHour = change * perHour;
      return [
        { label: this.$t('resource-detail.total_1h'), value: resource.value + rateHour },
        { label: this.$t('resource-detail.total_24h'), value: resource.value + rateHour * 24 },
      ];
    },
  },
};
