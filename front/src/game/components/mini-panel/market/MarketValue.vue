<template>
  <div class="mpc-value">
    <div class="mpc-value-side">
      <h2>{{ $t('minipanel.market.value.title') }}</h2>
      <p class="mpc-value-explain">{{ $t('minipanel.market.value.explain') }}</p>

      <div
        v-for="s in stats"
        :key="`stat-${s.key}`"
        class="mpc-value-stat">
        <span
          class="mpc-value-swatch"
          :style="{ background: s.color }" />
        <svgicon :name="`resource/${s.key}`" />
        <div class="mpc-value-stat-body">
          <div class="mpc-value-stat-label">{{ $t(`minipanel.market.value.${s.key}`) }}</div>
          <div class="mpc-value-stat-number">
            {{ s.price | float(2) }}
            <span class="mpc-value-unit">{{ $t('minipanel.market.value.per_point') }}</span>
          </div>
          <div
            v-if="s.change !== null"
            class="mpc-value-stat-change">
            {{ s.change >= 0 ? '+' : '' }}{{ s.change | float(1) }}% {{ $t('minipanel.market.value.change_day') }}
          </div>
        </div>
      </div>
    </div>

    <div class="mpc-value-chart">
      <div class="mpc-value-ranges">
        <button
          v-for="r in ranges"
          :key="`range-${r}`"
          type="button"
          class="mpc-value-range"
          :class="{ 'is-active': range === r }"
          @click="range = r">
          {{ $t(`minipanel.market.value.range.${r}`) }}
        </button>
      </div>

      <p
        v-if="!points.length"
        class="mpc-value-empty">
        {{ $t(error ? 'minipanel.market.value.unavailable' : 'minipanel.market.value.empty') }}
      </p>

      <div
        v-else
        ref="plot"
        class="mpc-value-plot">
        <svg
          :viewBox="`0 0 ${W} ${H}`"
          class="mpc-value-svg"
          role="img"
          :aria-label="$t('minipanel.market.value.title')">
          <line
            v-for="t in yTicks"
            :key="`grid-${t}`"
            class="mpc-value-grid"
            :x1="padL"
            :x2="W - padR"
            :y1="y(t)"
            :y2="y(t)" />
          <text
            v-for="t in yTicks"
            :key="`ytick-${t}`"
            class="mpc-value-tick"
            :x="padL - 6"
            :y="y(t) + 4"
            text-anchor="end">{{ t }}</text>
          <text
            v-for="tick in xTicks"
            :key="`xtick-${tick.i}`"
            class="mpc-value-tick"
            :x="x(tick.i)"
            :y="H - 6"
            text-anchor="middle">{{ tick.label }}</text>

          <line
            class="mpc-value-baseline"
            :x1="padL"
            :x2="W - padR"
            :y1="y(basePrice)"
            :y2="y(basePrice)" />
          <text
            class="mpc-value-tick"
            :x="padL + 4"
            :y="y(basePrice) - 4">{{ $t('minipanel.market.value.baseline') }}</text>

          <path
            v-for="s in SERIES"
            :key="`line-${s.key}`"
            class="mpc-value-line"
            :stroke="s.color"
            :d="linePath(s.key)" />

          <text
            v-for="label in endLabels"
            :key="`end-${label.key}`"
            class="mpc-value-endlabel"
            :x="W - padR + 6"
            :y="label.y">{{ label.text }}</text>

          <template v-if="hover !== null">
            <line
              class="mpc-value-cross"
              :x1="x(hover)"
              :x2="x(hover)"
              :y1="padT"
              :y2="H - padB" />
            <circle
              v-for="s in SERIES"
              :key="`dot-${s.key}`"
              r="4"
              class="mpc-value-dot"
              :fill="s.color"
              :cx="x(hover)"
              :cy="y(points[hover][s.key])" />
          </template>

          <rect
            class="mpc-value-hit"
            :x="padL"
            :y="padT"
            :width="W - padL - padR"
            :height="H - padT - padB"
            @pointermove="onMove"
            @pointerleave="hover = null" />
        </svg>

        <div
          v-if="hover !== null"
          class="mpc-value-tooltip"
          :style="tooltipStyle">
          <div class="mpc-value-tooltip-time">{{ formatTime(points[hover].at) }}</div>
          <div
            v-for="s in SERIES"
            :key="`tip-${s.key}`">
            <span
              class="mpc-value-swatch"
              :style="{ background: s.color }" />
            {{ $t(`minipanel.market.value.${s.key}`) }}: {{ points[hover][s.key] | float(2) }}
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
// Galactic value of technology and ideology (credits per point), served by
// Instance.ResourceMarket through the player channel. Hourly history on
// Legacy; the same 20-UT cadence at other speeds.

// validated pair (dataviz validator, dark panel surface): SERIES_COLORS 0/1
const SERIES = [
  { key: 'technology', color: '#3987e5' },
  { key: 'ideology', color: '#d95926' },
];
const RANGES = ['day', 'week', 'all'];
const RANGE_SECONDS = { day: 86400, week: 7 * 86400, all: Infinity };
const REFRESH_MS = 60 * 1000;

export default {
  name: 'market-value',
  data() {
    return {
      SERIES,
      ranges: RANGES,
      range: 'week',
      market: null,
      error: false,
      hover: null,
      W: 640,
      H: 240,
      padL: 40,
      padR: 64,
      padT: 12,
      padB: 26,
      refresh: undefined,
    };
  },
  computed: {
    basePrice() { return (this.market && this.market.base_price) || 10; },
    history() { return (this.market && this.market.history) || []; },
    points() {
      if (!this.history.length) return [];
      const newest = this.history[this.history.length - 1].at;
      const cutoff = newest - RANGE_SECONDS[this.range];
      return this.history.filter((p) => p.at >= cutoff);
    },
    bounds() {
      const values = this.points.flatMap((p) => SERIES.map((s) => p[s.key]));
      values.push(this.basePrice);
      const lo = Math.min(...values);
      const hi = Math.max(...values);
      const pad = Math.max((hi - lo) * 0.1, 0.5);
      return { lo: lo - pad, hi: hi + pad };
    },
    yTicks() {
      const { lo, hi } = this.bounds;
      const raw = (hi - lo) / 4;
      const mag = 10 ** Math.floor(Math.log10(raw));
      const step = [1, 2, 5, 10].map((m) => m * mag).find((s) => s >= raw) || raw;
      const ticks = [];
      for (let t = Math.ceil(lo / step) * step; t <= hi; t += step) {
        ticks.push(Number(t.toFixed(6)));
      }
      return ticks;
    },
    xTicks() {
      const n = this.points.length;
      if (n < 2) return [];
      const count = Math.min(5, n);
      return Array.from({ length: count }, (_, k) => {
        const i = Math.round((k * (n - 1)) / (count - 1));
        return { i, label: this.formatTick(this.points[i].at) };
      });
    },
    stats() {
      if (!this.market) return [];
      return SERIES.map((s) => ({
        ...s,
        price: this.market.prices[s.key],
        change: this.dayChange(s.key),
      }));
    },
    endLabels() {
      if (!this.points.length) return [];
      const last = this.points[this.points.length - 1];
      const labels = SERIES
        .map((s) => ({ key: s.key, value: last[s.key], y: this.y(last[s.key]) + 4 }))
        .sort((a, b) => a.y - b.y);
      // keep the two end labels from overlapping
      if (labels.length === 2 && labels[1].y - labels[0].y < 12) labels[1].y = labels[0].y + 12;
      return labels.map((l) => ({ ...l, text: l.value.toFixed(2) }));
    },
    tooltipStyle() {
      const left = (this.x(this.hover) / this.W) * 100;
      return left > 60 ? { right: `${100 - left + 2}%` } : { left: `${left + 2}%` };
    },
  },
  methods: {
    x(i) {
      const n = Math.max(this.points.length - 1, 1);
      return this.padL + (i / n) * (this.W - this.padL - this.padR);
    },
    y(v) {
      const { lo, hi } = this.bounds;
      return this.padT + (1 - (v - lo) / (hi - lo)) * (this.H - this.padT - this.padB);
    },
    linePath(key) {
      return this.points
        .map((p, i) => `${i ? 'L' : 'M'}${this.x(i).toFixed(1)},${this.y(p[key]).toFixed(1)}`)
        .join(' ');
    },
    dayChange(key) {
      if (this.history.length < 2) return null;
      const last = this.history[this.history.length - 1];
      const dayAgo = this.history.find((p) => p.at >= last.at - 86400) || this.history[0];
      if (!dayAgo || dayAgo === last || !dayAgo[key]) return null;
      return ((last[key] / dayAgo[key]) - 1) * 100;
    },
    onMove(event) {
      const svg = event.currentTarget.ownerSVGElement;
      const pt = svg.createSVGPoint();
      pt.x = event.clientX;
      pt.y = event.clientY;
      const local = pt.matrixTransform(svg.getScreenCTM().inverse());
      const n = this.points.length - 1;
      const i = Math.round(((local.x - this.padL) / (this.W - this.padL - this.padR)) * n);
      this.hover = Math.max(0, Math.min(n, i));
    },
    formatTick(at) {
      const opts = this.range === 'day'
        ? { hour: '2-digit', minute: '2-digit', hour12: false }
        : { month: 'short', day: 'numeric' };
      return new Intl.DateTimeFormat(this.$i18n.locale, opts).format(new Date(at * 1000));
    },
    formatTime(at) {
      return new Intl.DateTimeFormat(this.$i18n.locale, {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
      }).format(new Date(at * 1000));
    },
    fetch() {
      this.$socket.player
        .push('get_resource_market', {})
        .receive('ok', ({ market }) => {
          this.market = market;
          this.error = false;
        })
        .receive('error', () => { this.error = true; });
    },
  },
  mounted() {
    this.fetch();
    this.refresh = setInterval(this.fetch, REFRESH_MS);
  },
  beforeDestroy() {
    clearInterval(this.refresh);
  },
};
</script>
