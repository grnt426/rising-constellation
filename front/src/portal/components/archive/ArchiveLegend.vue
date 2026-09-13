<template>
  <div class="archive-legend">
    <span
      v-for="(item, i) in items"
      :key="`legend-${i}`"
      class="archive-legend-item">
      <span
        class="archive-legend-key"
        :class="`is-${item.kind || 'rect'}`"
        :style="{ background: item.color }" />
      {{ item.label }}
    </span>
  </div>
</template>

<script>
export default {
  name: 'archive-legend',
  props: {
    // [{ label, color, kind: 'line' | 'rect' | 'ring' }]
    items: { type: Array, required: true },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 14px;
  margin-bottom: 8px;
  font-size: 1.2rem;
  color: $white-alt-1;
}

.archive-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}

.archive-legend-key {
  display: inline-block;

  &.is-rect {
    width: 10px;
    height: 10px;
    border-radius: 2px;
  }

  &.is-line {
    width: 14px;
    height: 2px;
  }

  &.is-ring {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: transparent !important;
    box-shadow: inset 0 0 0 2px currentColor;
  }
}
</style>
