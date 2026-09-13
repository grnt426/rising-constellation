<template>
  <div
    class="archive-hbars"
    ref="root"
    @mouseleave="hover = null">
    <archive-legend
      v-if="legendItems.length > 1"
      :items="legendItems" />

    <div
      v-for="(row, i) in rows"
      :key="`row-${row.key || i}`"
      class="archive-hbar-row"
      :class="{ 'is-hover': hover && hover.i === i }"
      @mousemove="onMove($event, i)">
      <div
        class="archive-hbar-label"
        :title="row.label">
        {{ row.label }}
        <small v-if="row.sublabel">{{ row.sublabel }}</small>
      </div>
      <div class="archive-hbar-track">
        <div
          class="archive-hbar-fill"
          :style="{ width: `${rowWidth(row)}%` }">
          <span
            v-for="(seg, k) in visibleSegments(row)"
            :key="`seg-${k}`"
            class="archive-hbar-seg"
            :style="{ flexGrow: seg.value, background: seg.color }" />
        </div>
        <span class="archive-hbar-value">{{ total(row) === null ? '—' : format(total(row)) }}</span>
      </div>
    </div>

    <archive-tooltip
      v-if="hover"
      :x="hover.x"
      :y="hover.top"
      :container-width="width"
      :title="rows[hover.i].label"
      :rows="hoverRows" />
  </div>
</template>

<script>
import ChartSize from './ChartSize';
import ArchiveLegend from './ArchiveLegend.vue';
import ArchiveTooltip from './ArchiveTooltip.vue';
import { compact } from './format';

// Horizontal bars with stacked segments; HTML (not SVG) so long labels
// ellipsize cleanly. All rows share one scale unless `max` is given.
export default {
  name: 'archive-hbars',
  mixins: [ChartSize],
  props: {
    // [{ key, label, sublabel?, segments: [{ label, color, value }] }]
    rows: { type: Array, required: true },
    format: { type: Function, default: compact },
    max: { type: Number, default: null },
    legend: { type: Array, default: null },
  },
  data() {
    return { hover: null };
  },
  computed: {
    scaleMax() {
      if (this.max) return this.max;
      return Math.max(1, ...this.rows.map((r) => this.total(r) || 0));
    },
    legendItems() {
      if (this.legend) return this.legend;
      const seen = {};
      this.rows.forEach((r) => r.segments.forEach((s) => { seen[s.label] = s.color; }));
      return Object.keys(seen).map((label) => ({ label, color: seen[label], kind: 'rect' }));
    },
    hoverRows() {
      if (!this.hover) return [];
      return this.rows[this.hover.i].segments.map((s) => ({
        color: s.color,
        label: s.label,
        value: s.value === null || s.value === undefined ? '—' : this.format(s.value),
      }));
    },
  },
  methods: {
    total(row) {
      // Rows may carry an explicit total when segments overlap (e.g. both
      // factions took part in the same battle).
      if (row.total !== undefined && row.total !== null) return row.total;
      if (row.segments.every((s) => s.value === null || s.value === undefined)) return null;
      return row.segments.reduce((acc, s) => acc + (s.value || 0), 0);
    },
    rowWidth(row) {
      return Math.max(0, Math.min(100, ((this.total(row) || 0) / this.scaleMax) * 100));
    },
    visibleSegments(row) {
      return row.segments.filter((s) => s.value > 0);
    },
    onMove(e, i) {
      const rect = this.$refs.root.getBoundingClientRect();
      this.hover = { i, x: e.clientX - rect.left, top: e.clientY - rect.top };
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

.archive-hbars {
  position: relative;
  width: 100%;
}

.archive-hbar-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 3px 4px;
  border-radius: 3px;

  &.is-hover { background: rgba(255, 255, 255, .04); }
}

.archive-hbar-label {
  flex: 0 0 38%;
  max-width: 260px;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  font-size: 1.3rem;
  color: $white-alt-1;

  small {
    margin-left: 6px;
    color: $white-alt-2;
    font-size: 1.1rem;
  }
}

.archive-hbar-track {
  display: flex;
  flex: 1 1 auto;
  align-items: center;
  gap: 8px;
  min-width: 0;
}

.archive-hbar-fill {
  display: flex;
  gap: 2px;
  height: 12px;
  min-width: 0;
}

.archive-hbar-seg {
  flex-basis: 0;
  min-width: 2px;
  height: 100%;

  &:first-child { border-radius: 0; }
  &:last-child { border-radius: 0 4px 4px 0; }
}

.archive-hbar-value {
  flex-shrink: 0;
  font-size: 1.2rem;
  color: $white;
  font-variant-numeric: tabular-nums;
}
</style>
