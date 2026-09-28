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
        key="empty"
        class="mpc-value-empty">
        {{ $t(error ? 'minipanel.market.value.unavailable' : 'minipanel.market.value.empty') }}
      </p>

      <!-- The plot is drawn in real pixels at the size of this box (no
           viewBox scaling), so it never outgrows the panel and its text
           stays at a fixed size on any screen width. -->
      <div
        v-show="points.length"
        key="plot"
        ref="plot"
        class="mpc-value-plot">
        <svg
          v-if="W > 0 && H > 0 && points.length"
          :width="W"
          :height="H"
          class="mpc-value-svg"
          role="img"
          :aria-label="$t('minipanel.market.value.title')">
          <!-- y axis: gridlines, ticks, labels, unit -->
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
            :x="padL - 8"
            :y="y(t) + 4"
            text-anchor="end">{{ formatY(t) }}</text>
          <text
            class="mpc-value-axis-title"
            :x="padL"
            :y="11">{{ $t('minipanel.market.value.per_point') }}</text>

          <!-- x axis: ticks at round times, local time -->
          <template v-for="tick in xTicks">
            <line
              :key="`xtick-mark-${tick.t}`"
              class="mpc-value-axis"
              :x1="x(tick.t)"
              :x2="x(tick.t)"
              :y1="H - padB"
              :y2="H - padB + 5" />
            <text
              :key="`xtick-${tick.t}`"
              class="mpc-value-tick"
              :x="x(tick.t)"
              :y="H - padB + 18"
              text-anchor="middle">{{ tick.label }}</text>
          </template>

          <line
            class="mpc-value-axis"
            :x1="padL"
            :x2="padL"
            :y1="padT"
            :y2="H - padB" />
          <line
            class="mpc-value-axis"
            :x1="padL"
            :x2="W - padR"
            :y1="H - padB"
            :y2="H - padB" />

          <!-- 10:1 starting value -->
          <line
            v-if="basePrice >= bounds.lo && basePrice <= bounds.hi"
            class="mpc-value-baseline"
            :x1="padL"
            :x2="W - padR"
            :y1="y(basePrice)"
            :y2="y(basePrice)" />

          <path
            v-for="s in SERIES"
            :key="`line-${s.key}`"
            class="mpc-value-line"
            :stroke="s.color"
            :d="linePath(s.key)" />
          <!-- latest value marker (also the only mark when there is one point) -->
          <circle
            v-for="s in SERIES"
            :key="`last-${s.key}`"
            r="3.5"
            class="mpc-value-dot"
            :fill="s.color"
            :cx="x(last.at)"
            :cy="y(last[s.key])" />

          <text
            v-for="label in endLabels"
            :key="`end-${label.key}`"
            class="mpc-value-endlabel"
            :x="W - padR + 8"
            :y="label.y">{{ label.text }}</text>

          <template v-if="hover !== null">
            <line
              class="mpc-value-cross"
              :x1="x(points[hover].at)"
              :x2="x(points[hover].at)"
              :y1="padT"
              :y2="H - padB" />
            <circle
              v-for="s in SERIES"
              :key="`dot-${s.key}`"
              r="4"
              class="mpc-value-dot"
              :fill="s.color"
              :cx="x(points[hover].at)"
              :cy="y(points[hover][s.key])" />
          </template>

          <rect
            class="mpc-value-hit"
            :x="padL"
            :y="padT"
            :width="Math.max(W - padL - padR, 0)"
            :height="Math.max(H - padT - padB, 0)"
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
const HOUR = 3600;
const DAY = 24 * HOUR;
const RANGE_SECONDS = { day: DAY, week: 7 * DAY, all: Infinity };
// candidate x-tick spacings, smallest first
const TICK_STEPS = [HOUR, 2 * HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR, DAY, 2 * DAY, 7 * DAY, 14 * DAY, 30 * DAY];
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
      // plot box size in CSS pixels (ResizeObserver)
      W: 0,
      H: 0,
      padL: 48,
      padR: 58,
      padT: 20,
      padB: 28,
      refresh: undefined,
      observer: undefined,
    };
  },
  computed: {
    basePrice() { return (this.market && this.market.base_price) || 10; },
    history() { return (this.market && this.market.history) || []; },
    last() { return this.history[this.history.length - 1]; },
    // x domain in unix seconds: Day and Week always span the whole range
    // (ending at the latest price), so the axis keeps its meaning even while
    // the market is young; All spans the recorded history.
    domain() {
      if (!this.last) return { from: 0, to: 1 };
      const to = this.last.at;
      if (this.range !== 'all') return { from: to - RANGE_SECONDS[this.range], to };
      const from = this.history[0].at;
      return { from: Math.min(from, to - HOUR), to };
    },
    points() {
      return this.history.filter((p) => p.at >= this.domain.from);
    },
    bounds() {
      const values = this.points.flatMap((p) => SERIES.map((s) => p[s.key]));
      values.push(this.basePrice);
      const lo = Math.min(...values);
      const hi = Math.max(...values);
      const pad = Math.max((hi - lo) * 0.1, 0.25);
      return { lo: lo - pad, hi: hi + pad };
    },
    yStep() {
      const { lo, hi } = this.bounds;
      const raw = (hi - lo) / Math.max(Math.floor(this.plotHeight / 45), 2);
      const mag = 10 ** Math.floor(Math.log10(raw));
      return [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) || raw;
    },
    yTicks() {
      const { lo, hi } = this.bounds;
      const ticks = [];
      for (let t = Math.ceil(lo / this.yStep) * this.yStep; t <= hi + 1e-9; t += this.yStep) {
        ticks.push(Number(t.toFixed(6)));
      }
      return ticks;
    },
    plotWidth() { return Math.max(this.W - this.padL - this.padR, 1); },
    plotHeight() { return Math.max(this.H - this.padT - this.padB, 1); },
    xTicks() {
      const { from, to } = this.domain;
      const span = to - from;
      const maxTicks = Math.max(Math.floor(this.plotWidth / 90), 2);
      // multi-day spans tick by whole days (dated), however wide the screen
      const minStep = span > 2 * DAY ? DAY : HOUR;
      const step = TICK_STEPS.find((s) => s >= minStep && span / s <= maxTicks) || TICK_STEPS[TICK_STEPS.length - 1];
      // align to round local times (midnight for day steps)
      const offset = -new Date(to * 1000).getTimezoneOffset() * 60;
      const ticks = [];
      for (let t = Math.ceil((from + offset) / step) * step - offset; t <= to; t += step) {
        ticks.push({ t, label: this.formatTick(t, step) });
      }
      return ticks;
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
      if (!this.last) return [];
      const labels = SERIES
        .map((s) => ({ key: s.key, value: this.last[s.key], y: this.y(this.last[s.key]) + 4 }))
        .sort((a, b) => a.y - b.y);
      // keep the two end labels from overlapping
      if (labels.length === 2 && labels[1].y - labels[0].y < 13) labels[1].y = labels[0].y + 13;
      return labels.map((l) => ({ ...l, text: l.value.toFixed(2) }));
    },
    tooltipStyle() {
      const px = this.x(this.points[this.hover].at);
      return px > this.W * 0.6 ? { right: `${this.W - px + 12}px` } : { left: `${px + 12}px` };
    },
  },
  methods: {
    x(at) {
      const { from, to } = this.domain;
      return this.padL + ((at - from) / (to - from)) * this.plotWidth;
    },
    y(v) {
      const { lo, hi } = this.bounds;
      return this.padT + (1 - (v - lo) / (hi - lo)) * this.plotHeight;
    },
    linePath(key) {
      return this.points
        .map((p, i) => `${i ? 'L' : 'M'}${this.x(p.at).toFixed(1)},${this.y(p[key]).toFixed(1)}`)
        .join(' ');
    },
    formatY(t) {
      return this.yStep < 1 ? t.toFixed(this.yStep < 0.5 ? 2 : 1) : String(t);
    },
    dayChange(key) {
      if (this.history.length < 2) return null;
      const dayAgo = this.history.find((p) => p.at >= this.last.at - DAY) || this.history[0];
      if (!dayAgo || dayAgo === this.last || !dayAgo[key]) return null;
      return ((this.last[key] / dayAgo[key]) - 1) * 100;
    },
    onMove(event) {
      const box = this.$refs.plot.getBoundingClientRect();
      const px = event.clientX - box.left;
      let best = 0;
      this.points.forEach((p, i) => {
        if (Math.abs(this.x(p.at) - px) < Math.abs(this.x(this.points[best].at) - px)) best = i;
      });
      this.hover = best;
    },
    formatTick(at, step) {
      // hourly ticks show the date at midnight so the day is never lost
      const date = new Date(at * 1000);
      const midnight = date.getHours() === 0 && date.getMinutes() === 0;
      const opts = step < DAY && !midnight
        ? { hour: '2-digit', minute: '2-digit', hour12: false }
        : { month: 'short', day: 'numeric' };
      return new Intl.DateTimeFormat(this.$i18n.locale, opts).format(date);
    },
    formatTime(at) {
      return new Intl.DateTimeFormat(this.$i18n.locale, {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
      }).format(new Date(at * 1000));
    },
    measure() {
      const el = this.$refs.plot;
      if (!el) return;
      this.W = Math.floor(el.clientWidth);
      this.H = Math.floor(el.clientHeight);
    },
    fetch() {
      this.$socket.player
        .push('get_resource_market', {})
        .receive('ok', ({ market }) => {
          this.market = market;
          this.error = false;
          this.$nextTick(this.measure);
        })
        .receive('error', () => { this.error = true; });
    },
  },
  mounted() {
    this.fetch();
    this.refresh = setInterval(this.fetch, REFRESH_MS);
    if (typeof ResizeObserver !== 'undefined') {
      this.observer = new ResizeObserver(() => this.measure());
      this.observer.observe(this.$refs.plot);
    }
    window.addEventListener('resize', this.measure);
    this.measure();
  },
  beforeDestroy() {
    clearInterval(this.refresh);
    if (this.observer) this.observer.disconnect();
    window.removeEventListener('resize', this.measure);
  },
};
</script>
