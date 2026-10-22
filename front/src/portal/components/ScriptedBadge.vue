<template>
  <!-- A scenario (or a match made from one) that runs scenario scripts.
       Script names are player text: the tooltip and label are plain text. -->
  <span
    v-if="scripted"
    class="scripted-badge"
    role="img"
    :aria-label="label"
    v-tooltip="label">
    <svgicon
      name="code"
      aria-hidden="true" />
  </span>
</template>

<script>
import duration from '@/utils/script-length';

export default {
  name: 'scripted-badge',
  props: {
    // a scenario's or an instance's game_metadata
    metadata: { type: Object, default: null },
  },
  computed: {
    scripted() { return !!(this.metadata && this.metadata.scripted); },
    names() {
      const scripts = (this.metadata && Array.isArray(this.metadata.scripts)) ? this.metadata.scripts : [];
      return scripts.map((s) => s && s.name).filter((n) => typeof n === 'string' && n);
    },
    label() {
      const base = this.names.length
        ? this.$t('portal_components.scripted_badge.named', { names: this.names.join(', ') })
        : this.$t('portal_components.scripted_badge.label');
      const length = this.metadata && this.metadata.script_time_limit;
      return length && typeof length.seconds === 'number'
        ? `${base}. ${this.$t('portal_components.scripted_badge.length', { length: duration(length.seconds) })}`
        : base;
    },
  },
};
</script>

<style lang="scss" scoped>
.scripted-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  align-self: center;
  margin-right: 8px;
  padding: 1px 5px;
  border: solid 1px rgba(255, 255, 255, 0.45);
  border-radius: 3px;
  color: rgba(255, 255, 255, 0.85);
  vertical-align: middle;
  line-height: 1;

  svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
  }
}
</style>
