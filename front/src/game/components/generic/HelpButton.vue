<template>
  <span
    v-if="available"
    class="help-button"
    v-tooltip="hoverTooltip"
    @click.stop="open">?</span>
  <span
    v-else-if="fallback && hint"
    class="info"
    v-tooltip="hint">?</span>
</template>

<script>
import viewport from '@/utils/viewport';

// The "?" that opens a manual page in the help modal. Renders only when the
// help_manual beta is on AND the page exists in the loaded bundle, so
// wiring a slug on a card before its page is written costs nothing. With
// `fallback`, an unavailable page degrades to the classic inert "?" tooltip
// (the `hint` text), which is how ResourceDetail keeps its old behavior.
export default {
  name: 'help-button',
  props: {
    page: String,
    hint: String,
    fallback: Boolean,
  },
  computed: {
    available() {
      return !!this.page && this.$store.getters['help/available'](this.page);
    },
    tooltip() {
      const open = this.$t('help.open_hint');
      return this.hint ? `${this.hint} — ${open}` : open;
    },
    // On touch the tap IS the action: showing a tooltip as well leaves
    // it hanging over the manual page the same tap just opened. The
    // inert `fallback` variant below keeps its tooltip — that is all it
    // has.
    hoverTooltip() {
      return viewport.isMobile ? '' : this.tooltip;
    },
  },
  methods: {
    open() {
      this.$root.$emit('openHelp', { page: this.page });
    },
  },
};
</script>
