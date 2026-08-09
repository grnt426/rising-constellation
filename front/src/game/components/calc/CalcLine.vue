<template>
  <div
    class="calc-line"
    :class="{ 'is-error': row.isError }">
    <span class="calc-line-src">{{ row.src }}</span>
    <span class="calc-line-result">
      <template v-if="row.isError">{{ row.text }}</template>
      <template v-else>
        {{ row.text }}
        <span
          v-if="row.detail"
          class="calc-line-detail">{{ row.detail }}</span>
      </template>
    </span>
    <span class="calc-line-actions">
      <button
        v-for="action in actions"
        :key="action.key"
        v-tooltip="action.title"
        class="calc-line-action"
        type="button"
        @click="$emit('action', { key: action.key, id: row.id })">
        <svgicon :name="action.icon" />
      </button>
    </span>
  </div>
</template>

<script>
// Purely presentational row: the parent pre-formats results into
// { id, src, text, detail, isError } so this component stays free of the
// CalcMixin's evaluation pulse (one interval per surface, not per line).
export default {
  name: 'calc-line',
  props: {
    row: { type: Object, required: true },
    actions: { type: Array, default: () => [] },
  },
};
</script>

<style scoped>
.calc-line {
  display: flex;
  align-items: baseline;
  gap: 10px;
  padding: 4px 0;
  border-bottom: solid 1px rgba(255, 255, 255, 0.06);
  font-size: 1.2rem;
}

.calc-line-src {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: rgba(255, 255, 255, 0.75);
  font-family: Consolas, Menlo, monospace;
}

.calc-line-result {
  flex-shrink: 0;
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.calc-line.is-error .calc-line-result {
  color: rgba(255, 160, 140, 0.9);
  font-family: inherit;
  font-size: 1.1rem;
}

.calc-line-detail {
  display: block;
  color: rgba(255, 255, 255, 0.45);
  font-size: 1.05rem;
}

.calc-line-actions {
  display: flex;
  gap: 2px;
  opacity: 0;
  transition: opacity linear 120ms;
}

.calc-line:hover .calc-line-actions {
  opacity: 1;
}

.calc-line-action {
  width: 20px;
  height: 20px;
  padding: 2px;
  background: transparent;
  border: none;
  cursor: pointer;
}

.calc-line-action svg {
  width: 14px;
  height: 14px;
  fill: rgba(255, 255, 255, 0.5);
}

.calc-line-action:hover svg {
  fill: #fff;
}
</style>
