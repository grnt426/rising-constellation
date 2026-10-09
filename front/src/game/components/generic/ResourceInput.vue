<template>
  <label
    class="resource-input"
    v-tooltip="label">
    <span class="ri-icon">
      <svgicon :name="`resource/${resource}`" />
    </span>
    <input
      type="number"
      min="0"
      :value="value"
      :aria-label="label"
      @input="onInput($event.target.value)" />
  </label>
</template>

<script>
// An amount of one resource: its icon and the box share one frame, so the
// icon can only be read as belonging to the box it is joined to. No
// stepping buttons:
// the amounts typed here run from thousands to millions, where one more
// or one less means nothing.
export default {
  name: 'resource-input',
  props: {
    value: { type: Number, default: null },
    resource: { type: String, required: true },
    label: { type: String, default: '' },
  },
  methods: {
    onInput(raw) {
      if (raw === '') {
        this.$emit('input', null);
        return;
      }
      const n = Number(raw);
      if (!Number.isNaN(n)) this.$emit('input', n);
    },
  },
};
</script>
