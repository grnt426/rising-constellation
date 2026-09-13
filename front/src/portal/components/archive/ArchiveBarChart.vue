<template>
  <div
    class="archive-chart"
    ref="root">
    <archive-legend
      v-if="legend && series.length > 1"
      :items="legendItems" />

    <svg
      v-if="width > 0"
      :width="width"
      :height="height"
      class="archive-chart-svg"
      @mouseleave="hover = null">
      <line
        v-for="t in yTicks"
        :key="`grid-${t}`"
        class="archive-grid"
        :class="{ 'is-zero': t === 0 }"
        :x1="padL"
        :x2="width - padR"
        :y1="y(t)"
        :y2="y(t)" />
      <text
        v-for="t in yTicks"
        :key="`ytick-${t}`"
        class="archive-tick"
        :x="padL - 6"
        :y="y(t) + 4"
        text-anchor="end">{{ tickFormat(t) }}</text>
      <text
        v-for="i in xTicks"
        :key="`xtick-${i}`"
        class="archive-tick"
        :x="bandX(i) + band / 2"
        :y="height - 6"
        text-anchor="middle">{{ label(i) }}</text>

      <g
        v-for="(col, i) in columns"
        :key="`col-${i}`">
        <rect
          class="archive-band"
          :class="{ 'is-hover': hover && hover.i === i }"
          :x="bandX(i)"
          :y="padT"
          :width="band"
          :height="height - padT - padB"
          @mousemove="onMove($event, i)" />
        <path
          v-for="(seg, k) in col"
          :key="`seg-${i}-${k}`"
          :d="seg.d"
          :fill="seg.color"
          class="archive-bar"
          @mousemove="onMove($event, i)" />
      </g>
    </svg>

    <archive-tooltip
      v-if="hover"
      :x="hover.x"
      :y="hover.top"
      :container-width="width"
      :title="label(hover.i, true)"
      :rows="hoverRows" />
  </div>
</template>

<script>
import ChartSize from './ChartSize';
import ArchiveLegend from './ArchiveLegend.vue';
import ArchiveTooltip from './ArchiveTooltip.vue';
import { compact, niceTicks, percent } from './format';

const GAP = 2;
const MAX_BAR = 24;

// Rounded-top column path: 4px radius on the data end, square baseline.
function column(x, top, w, h, rounded) {
  if (h <= 0) return '';
  const r = rounded ? Math.min(4, h / 2, w / 2) : 0;
  const bottom = top + h;
  return `M${x},${bottom}V${top + r}Q${x},${top} ${x + r},${top}`
    + `H${x + w - r}Q${x + w},${top} ${x + w},${top + r}V${bottom}Z`;
}

// Day-indexed column chart: stacked (default), grouped, or normalized to
// 100% shares. Non-negative values only.
export default {
  name: 'archive-bar-chart',
  mixins: [ChartSize],
  props: {
    // [{ key, label, color, values: [number|null] }]
    series: { type: Array, required: true },
    height: { type: Number, default: 200 },
    format: { type: Function, default: compact },
    mode: { type: String, default: 'stacked' }, // stacked | grouped | share
    legend: { type: Boolean, default: true },
    labels: { type: Array, default: null },
  },
  data() {
    return { hover: null, padT: 10, padR: 14, padB: 24 };
  },
  computed: {
    count() {
      return this.labels ? this.labels.length : this.series.reduce((m, s) => Math.max(m, s.values.length), 0);
    },
    totals() {
      const t = [];
      for (let i = 0; i < this.count; i += 1) {
        t.push(this.series.reduce((acc, s) => acc + (s.values[i] || 0), 0));
      }
      return t;
    },
    max() {
      if (this.mode === 'share') return 1;
      if (this.mode === 'grouped') {
        return this.series.reduce((m, s) => Math.max(m, ...s.values.map((v) => v || 0)), 0);
      }
      return Math.max(0, ...this.totals);
    },
    yTicks() {
      return this.mode === 'share' ? [0, 0.5, 1] : niceTicks(0, this.max, this.height < 160 ? 2 : 4);
    },
    tickFormat() {
      return this.mode === 'share' ? percent : this.format;
    },
    padL() {
      const longest = this.yTicks.reduce((m, t) => Math.max(m, this.tickFormat(t).length), 1);
      return 10 + longest * 7;
    },
    plotW() {
      return Math.max(10, this.width - this.padL - this.padR);
    },
    band() {
      return this.plotW / Math.max(1, this.count);
    },
    xTicks() {
      const room = Math.max(1, Math.floor(this.plotW / 44));
      const step = Math.max(1, Math.ceil(this.count / room));
      const ticks = [];
      for (let i = 0; i < this.count; i += step) ticks.push(i);
      return ticks;
    },
    columns() {
      const cols = [];
      for (let i = 0; i < this.count; i += 1) {
        const segs = [];
        if (this.mode === 'grouped') {
          const k = this.series.length;
          const groupW = Math.min(this.band * 0.8, MAX_BAR * k + GAP * (k - 1));
          const barW = Math.max(1, (groupW - GAP * (k - 1)) / k);
          const x0 = this.bandX(i) + (this.band - groupW) / 2;
          this.series.forEach((s, j) => {
            const v = s.values[i] || 0;
            const top = this.y(v);
            segs.push({ color: s.color, d: column(x0 + j * (barW + GAP), top, barW, this.y(0) - top, true) });
          });
        } else {
          const barW = Math.max(1, Math.min(MAX_BAR, this.band * 0.7));
          const x0 = this.bandX(i) + (this.band - barW) / 2;
          const total = this.totals[i];
          const visible = this.series
            .map((s) => ({ color: s.color, v: s.values[i] || 0 }))
            .filter((s) => s.v > 0);
          let base = this.y(0);
          visible.forEach((s, j) => {
            const v = this.mode === 'share' ? s.v / (total || 1) : s.v;
            const h = this.y(0) - this.y(v);
            // 2px surface gap between stacked segments.
            const drawH = j > 0 ? h - GAP : h;
            const top = base - h;
            segs.push({ color: s.color, d: column(x0, top, barW, drawH, j === visible.length - 1) });
            base = top;
          });
        }
        cols.push(segs);
      }
      return cols;
    },
    legendItems() {
      return this.series.map((s) => ({ label: s.label, color: s.color, kind: 'rect' }));
    },
    hoverRows() {
      if (!this.hover) return [];
      const { i } = this.hover;
      return this.series.map((s) => {
        const v = s.values[i];
        const value = this.mode === 'share'
          ? `${percent((v || 0) / (this.totals[i] || 1))} · ${this.format(v || 0)}`
          : this.format(v === null || v === undefined ? null : v);
        return { color: s.color, label: s.label, value };
      });
    },
  },
  methods: {
    y(v) {
      const hi = this.yTicks[this.yTicks.length - 1] || 1;
      const h = this.height - this.padT - this.padB;
      return this.padT + h - (v / hi) * h;
    },
    bandX(i) {
      return this.padL + i * this.band;
    },
    label(i, long = false) {
      if (this.labels) return this.labels[i];
      return long ? `${this.$t('page.play.archive.day')} ${i + 1}` : `D${i + 1}`;
    },
    onMove(e, i) {
      const rect = this.$refs.root.getBoundingClientRect();
      this.hover = { i, x: this.bandX(i) + this.band / 2, top: e.clientY - rect.top };
    },
  },
  components: {
    ArchiveLegend,
    ArchiveTooltip,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-chart {
  position: relative;
  width: 100%;
}

.archive-chart-svg {
  display: block;
}

.archive-grid {
  stroke: rgba(255, 255, 255, .06);
  stroke-width: 1;

  &.is-zero { stroke: rgba(255, 255, 255, .18); }
}

.archive-tick {
  fill: $white-alt-2;
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}

.archive-band {
  fill: transparent;

  &.is-hover { fill: rgba(255, 255, 255, .04); }
}
</style>
