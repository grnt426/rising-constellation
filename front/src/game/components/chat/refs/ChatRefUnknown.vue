<template>
  <span
    class="chat-ref chat-ref-unknown"
    v-tooltip="tooltip">
    <span class="chat-ref-icon">?</span>
    <span class="chat-ref-label">{{ displayLabel }}</span>
  </span>
</template>

<script>
/**
 * Fallback for ref kinds the client doesn't recognize (or that the
 * parser produced but no ChatRef* component is registered for).
 * Non-interactive on purpose — clicking would be ambiguous.
 */
export default {
  name: 'chat-ref-unknown',
  props: {
    kind: { type: String, required: true },
    id: { type: String, required: true },
    label: { type: String, default: null },
  },
  computed: {
    displayLabel() {
      return this.label || `${this.kind}:${this.id}`;
    },
    tooltip() {
      return this.$t ? this.$t('in_game_chat.ref.unknown_ref') : 'Unknown reference';
    },
  },
};
</script>
