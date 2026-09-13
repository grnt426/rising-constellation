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
      @mousemove="onMove"
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
        text-anchor="end">{{ format(t) }}</text>
      <text
        v-for="i in xTicks"
        :key="`xtick-${i}`"
        class="archive-tick"
        :x="x(i)"
        :y="height - 6"
        text-anchor="middle">{{ xLabel(i) }}</text>

      <template v-for="s in drawn">
        <path
          v-if="s.area"
          :key="`area-${s.key}`"
          :d="s.area"
          :fill="s.color"
          :fill-opacity="stacked ? .4 : .1" />
      </template>
      <template v-for="s in drawn">
        <path
          :key="`line-${s.key}`"
          :d="s.line"
          :stroke="s.color"
          :stroke-opacity="s.muted ? .25 : 1"
          :stroke-dasharray="s.dashed ? '5 4' : null"
          class="archive-line" />
      </template>
      <template v-for="s in drawn">
        <circle
          v-if="s.end && !s.muted"
          :key="`end-${s.key}`"
          :cx="s.end[0]"
          :cy="s.end[1]"
          r="4"
          :fill="s.color"
          class="archive-end-dot" />
      </template>

      <line
        v-if="hover"
        class="archive-crosshair"
        :x1="x(hover.i)"
        :x2="x(hover.i)"
        :y1="padT"
        :y2="height - padB" />
    </svg>

    <archive-tooltip
      v-if="hover"
      :x="x(hover.i)"
      :y="hover.top"
      :container-width="width"
      :title="xLabel(hover.i, true)"
      :rows="hoverRows" />
  </div>
</template>

<script>
import ChartSize from './ChartSize';
import ArchiveLegend from './ArchiveLegend.vue';
import ArchiveTooltip from './ArchiveTooltip.vue';
import { compact, niceTicks } from './format';

// Day-indexed line / stacked-area chart. `series[].values[i]` is day i+1;
// nulls (days without a snapshot sample) are bridged by the line.
export default {
  name: 'archive-line-chart',
  mixins: [ChartSize],
  props: {
    // [{ key, label, color, values: [number|null], dashed?, muted? }]
    series: { type: Array, required: true },
    height: { type: Number, default: 220 },
    format: { type: Function, default: compact },
    stacked: { type: Boolean, default: false },
    stepped: { type: Boolean, default: false },
    area: { type: Boolean, default: false },
    legend: { type: Boolean, default: true },
    dayLabel: { type: String, default: 'D' },
  },
  data() {
    return { hover: null, padT: 10, padR: 14, padB: 24 };
  },
  computed: {
    count() {
      return this.series.reduce((m, s) => Math.max(m, s.values.length), 0);
    },
    stackedValues() {
      // Cumulative tops per series; a day where every series is null
      // stays null so the stack bridges it like a plain line.
      if (!this.stacked) return null;
      const tops = this.series.map(() => []);
      for (let i = 0; i < this.count; i += 1) {
        const present = this.series.some((s) => s.values[i] !== null && s.values[i] !== undefined);
        let acc = 0;
        this.series.forEach((s, k) => {
          if (present) {
            acc += s.values[i] || 0;
            tops[k].push(acc);
          } else {
            tops[k].push(null);
          }
        });
      }
      return tops;
    },
    domain() {
      const lists = this.stacked ? this.stackedValues : this.series.map((s) => s.values);
      let min = 0;
      let max = 0;
      lists.forEach((vals) => vals.forEach((v) => {
        if (v === null || v === undefined) return;
        if (v < min) min = v;
        if (v > max) max = v;
      }));
      return [min, max];
    },
    yTicks() {
      return niceTicks(this.domain[0], this.domain[1], this.height < 160 ? 2 : 4);
    },
    padL() {
      const longest = this.yTicks.reduce((m, t) => Math.max(m, this.format(t).length), 1);
      return 10 + longest * 7;
    },
    plotW() {
      return Math.max(10, this.width - this.padL - this.padR);
    },
    xTicks() {
      const room = Math.max(1, Math.floor(this.plotW / 44));
      const step = Math.max(1, Math.ceil(this.count / room));
      const ticks = [];
      for (let i = 0; i < this.count; i += step) ticks.push(i);
      if (ticks[ticks.length - 1] !== this.count - 1 && this.count - 1 - ticks[ticks.length - 1] >= step / 2) {
        ticks.push(this.count - 1);
      }
      return ticks;
    },
    drawn() {
      return this.series.map((s, k) => {
        const tops = this.stacked ? this.stackedValues[k] : s.values;
        const bottoms = this.stacked && k > 0 ? this.stackedValues[k - 1] : null;
        const pts = [];
        tops.forEach((v, i) => {
          if (v !== null && v !== undefined) pts.push([this.x(i), this.y(v), i]);
        });
        let line = '';
        pts.forEach((p, j) => {
          if (j === 0) line += `M${p[0]},${p[1]}`;
          else if (this.stepped) line += `H${p[0]}V${p[1]}`;
          else line += `L${p[0]},${p[1]}`;
        });
        let areaPath = null;
        if ((this.area || this.stacked) && pts.length > 1) {
          const base = pts
            .map((p) => [p[0], bottoms ? this.y(bottoms[p[2]] || 0) : this.y(Math.max(0, this.domain[0]))])
            .reverse();
          areaPath = `${line}${base.map((b) => `L${b[0]},${b[1]}`).join('')}Z`;
        }
        return {
          key: s.key,
          color: s.color,
          dashed: s.dashed,
          muted: s.muted,
          line,
          area: areaPath,
          end: pts.length ? pts[pts.length - 1] : null,
        };
      });
    },
    legendItems() {
      return this.series
        .filter((s) => !s.muted)
        .map((s) => ({ label: s.label, color: s.color, kind: this.stacked ? 'rect' : 'line' }));
    },
    hoverRows() {
      if (!this.hover) return [];
      return this.series
        .filter((s) => !s.muted || s.highlightInTooltip)
        .map((s) => ({ color: s.color, label: s.label, value: this.format(s.values[this.hover.i]) }));
    },
  },
  methods: {
    y(v) {
      const [lo, hi] = [this.yTicks[0], this.yTicks[this.yTicks.length - 1]];
      const h = this.height - this.padT - this.padB;
      return this.padT + h - ((v - lo) / (hi - lo || 1)) * h;
    },
    x(i) {
      if (this.count <= 1) return this.padL + this.plotW / 2;
      return this.padL + (i * this.plotW) / (this.count - 1);
    },
    xLabel(i, long = false) {
      return long ? `${this.$t('page.play.archive.day')} ${i + 1}` : `${this.dayLabel}${i + 1}`;
    },
    onMove(e) {
      if (this.count === 0) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const ratio = (px - this.padL) / this.plotW;
      const i = Math.min(this.count - 1, Math.max(0, Math.round(ratio * (this.count - 1))));
      this.hover = { i, top: e.clientY - rect.top };
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
  overflow: visible;
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

.archive-line {
  fill: none;
  stroke-width: 2;
  stroke-linejoin: round;
  stroke-linecap: round;
}

.archive-end-dot {
  stroke: $grey-lighter;
  stroke-width: 2;
}

.archive-crosshair {
  stroke: rgba(255, 255, 255, .35);
  stroke-width: 1;
}
</style>
