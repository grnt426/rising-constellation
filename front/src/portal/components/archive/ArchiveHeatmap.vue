<template>
  <div
    class="archive-chart"
    ref="root"
    @mouseleave="hover = null">
    <svg
      v-if="width > 0"
      :width="width"
      :height="svgHeight"
      class="archive-chart-svg">
      <g
        v-for="(row, r) in rows"
        :key="`row-${r}`">
        <text
          class="archive-heat-label"
          :class="{ 'is-group-start': row.groupStart }"
          :x="labelW - 10"
          :y="rowY(r) + cell / 2 + 4"
          text-anchor="end">{{ row.label }}</text>
        <rect
          class="archive-heat-key"
          :x="labelW - 6"
          :y="rowY(r) + 2"
          width="2"
          :height="cell - 4"
          :fill="row.color" />
        <rect
          v-for="(v, c) in row.values"
          :key="`cell-${r}-${c}`"
          class="archive-heat-cell"
          :class="{ 'is-hover': hover && hover.r === r && hover.c === c }"
          :x="colX(c)"
          :y="rowY(r)"
          :width="cellW"
          :height="cell"
          rx="2"
          :fill="v > 0 ? row.color : 'rgba(255,255,255,.035)'"
          :fill-opacity="v > 0 ? intensity(row, v) : 1"
          @mousemove="onMove($event, r, c)" />
      </g>
      <text
        v-for="c in xTicks"
        :key="`xtick-${c}`"
        class="archive-tick"
        :x="colX(c) + cellW / 2"
        :y="svgHeight - 4"
        text-anchor="middle">D{{ c + 1 }}</text>
    </svg>

    <div class="archive-heat-scale">
      {{ $t('page.play.archive.less') }}
      <span
        v-for="o in [0.15, 0.4, 0.65, 1]"
        :key="`scale-${o}`"
        :style="{ opacity: o }" />
      {{ $t('page.play.archive.more') }}
    </div>

    <archive-tooltip
      v-if="hover"
      :x="hover.x"
      :y="hover.top"
      :container-width="width"
      :title="`${$t('page.play.archive.day')} ${hover.c + 1}`"
      :rows="[{ color: rows[hover.r].color, label: rows[hover.r].label, value: format(rows[hover.r].values[hover.c]) }]" />
  </div>
</template>

<script>
import ChartSize from './ChartSize';
import ArchiveTooltip from './ArchiveTooltip.vue';
import { compact } from './format';

// Rows × days grid. Each row is one hue (its faction); intensity is the
// value relative to the largest value in the row's `scaleGroup`, so rows
// of the same metric are comparable across factions.
export default {
  name: 'archive-heatmap',
  mixins: [ChartSize],
  props: {
    // [{ label, color, values: [number], scaleGroup, groupStart? }]
    rows: { type: Array, required: true },
    format: { type: Function, default: compact },
  },
  data() {
    return { hover: null, cell: 18, gap: 2, labelW: 170 };
  },
  computed: {
    cols() {
      return this.rows.reduce((m, r) => Math.max(m, r.values.length), 0);
    },
    cellW() {
      return Math.max(4, (this.width - this.labelW) / Math.max(1, this.cols) - this.gap);
    },
    svgHeight() {
      return this.rowY(this.rows.length) + 18;
    },
    groupMax() {
      const max = {};
      this.rows.forEach((r) => {
        const m = Math.max(0, ...r.values.map((v) => v || 0));
        max[r.scaleGroup] = Math.max(max[r.scaleGroup] || 0, m);
      });
      return max;
    },
    xTicks() {
      const room = Math.max(1, Math.floor((this.width - this.labelW) / 36));
      const step = Math.max(1, Math.ceil(this.cols / room));
      const ticks = [];
      for (let c = 0; c < this.cols; c += step) ticks.push(c);
      return ticks;
    },
  },
  methods: {
    rowY(r) {
      const groupGaps = this.rows.slice(0, r + 1).filter((row, i) => i > 0 && row.groupStart).length;
      return r * (this.cell + this.gap) + groupGaps * 8;
    },
    colX(c) {
      return this.labelW + c * (this.cellW + this.gap);
    },
    intensity(row, v) {
      const max = this.groupMax[row.scaleGroup] || 1;
      return 0.15 + 0.85 * (v / max);
    },
    onMove(e, r, c) {
      const rect = this.$refs.root.getBoundingClientRect();
      this.hover = { r, c, x: e.clientX - rect.left, top: e.clientY - rect.top };
    },
  },
  components: {
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

.archive-heat-label {
  fill: $white-alt-1;
  font-size: 12px;
}

.archive-heat-cell {
  &.is-hover {
    stroke: $white;
    stroke-width: 1;
  }
}

.archive-tick {
  fill: $white-alt-2;
  font-size: 11px;
}

.archive-heat-scale {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 3px;
  margin-top: 6px;
  font-size: 1.1rem;
  color: $white-alt-2;

  span {
    display: inline-block;
    width: 14px;
    height: 10px;
    border-radius: 2px;
    background: $white;
  }
}
</style>
