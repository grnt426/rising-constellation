<template>
  <div class="number-stepper">
    <button
      type="button"
      class="ns-button"
      :disabled="value !== null && value !== '' && min !== null && value <= min"
      @click="bump(-step)">
      &minus;
    </button>
    <input
      type="number"
      :value="value"
      :min="min"
      :max="max"
      :placeholder="placeholder"
      @input="onInput($event.target.value)" />
    <button
      type="button"
      class="ns-button"
      :disabled="value !== null && value !== '' && max !== null && value >= max"
      @click="bump(step)">
      +
    </button>
  </div>
</template>

<script>
// A number input whose up/down controls sit OUTSIDE the box. The native
// inside-the-input spinners are hidden globally by the panel stylesheet
// (they read as part of the value and look odd at panel font sizes).
export default {
  name: 'number-stepper',
  props: {
    value: { type: Number, default: null },
    min: { type: Number, default: null },
    max: { type: Number, default: null },
    step: { type: Number, default: 1 },
    placeholder: { type: String, default: '' },
  },
  methods: {
    clamp(n) {
      let out = n;
      if (this.min !== null && out < this.min) out = this.min;
      if (this.max !== null && out > this.max) out = this.max;
      return out;
    },
    bump(delta) {
      const base = typeof this.value === 'number' && !Number.isNaN(this.value) ? this.value : 0;
      this.$emit('input', this.clamp(base + delta));
    },
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
