<template>
  <div
    class="archive-tooltip"
    :style="style">
    <div
      v-if="title"
      class="archive-tooltip-title">
      {{ title }}
    </div>
    <div
      v-for="(row, i) in rows"
      :key="`row-${i}`"
      class="archive-tooltip-row">
      <span
        v-if="row.color"
        class="archive-tooltip-key"
        :class="{ 'is-muted': row.muted }"
        :style="{ background: row.color }" />
      <strong>{{ row.value }}</strong>
      <span class="archive-tooltip-label">{{ row.label }}</span>
    </div>
  </div>
</template>

<script>
// Positioned inside a relatively-positioned chart root; flips to the left
// of the pointer when it would overflow the chart's right edge.
export default {
  name: 'archive-tooltip',
  props: {
    x: { type: Number, required: true },
    y: { type: Number, required: true },
    containerWidth: { type: Number, required: true },
    title: { type: String, default: '' },
    rows: { type: Array, default: () => [] },
  },
  computed: {
    style() {
      const flip = this.x > this.containerWidth - 220;
      return {
        top: `${Math.max(0, this.y - 10)}px`,
        left: flip ? 'auto' : `${this.x + 14}px`,
        right: flip ? `${this.containerWidth - this.x + 14}px` : 'auto',
      };
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-tooltip {
  position: absolute;
  z-index: 5;
  min-width: 120px;
  max-width: 260px;
  padding: 8px 10px;
  pointer-events: none;

  background: $grey-darker;
  border: solid 1px rgba(255, 255, 255, .08);
  border-radius: 3px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, .35);
  font-size: 1.2rem;
}

.archive-tooltip-title {
  margin-bottom: 4px;
  color: $white-alt-1;
  text-transform: uppercase;
  font-size: 1.1rem;
  letter-spacing: .5px;
}

.archive-tooltip-row {
  display: flex;
  align-items: center;
  gap: 6px;
  line-height: 1.8rem;
  white-space: nowrap;

  strong {
    color: $white;
    font-variant-numeric: tabular-nums;
  }
}

.archive-tooltip-key {
  flex-shrink: 0;
  width: 10px;
  height: 2px;

  &.is-muted { opacity: .5; }
}

.archive-tooltip-label {
  overflow: hidden;
  text-overflow: ellipsis;
  color: $white-alt-1;
}
</style>
