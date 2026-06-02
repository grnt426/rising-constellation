<template>
  <button
    type="button"
    class="chat-ref chat-ref-system"
    :class="{ 'is-unknown': !system }"
    v-tooltip="tooltip"
    @click.stop="onClick">
    <span class="chat-ref-icon">◈</span>
    <span class="chat-ref-label">{{ displayLabel }}</span>
  </button>
</template>

<script>
import { navigateRef } from '../refNavigation';

/**
 * Renders a `[[sys:123|Sol]]` chip in a chat message body.
 * Click flies the galaxy camera to the system. If the user is currently
 * inside a system view, that view is closed first so the camera move is
 * actually visible.
 *
 * If the referenced system isn't in the client's visible data (e.g. zero
 * contact), the chip degrades to a non-interactive label — the click
 * still fires but resolves to a no-op via the unknown branch.
 */
export default {
  name: 'chat-ref-system',
  // Game.vue provides the MapData singleton. The default is `null` so
  // tests/storybook can mount the component in isolation without
  // wiring up an ancestor — the chip just falls back to "Unknown" in
  // that case.
  inject: {
    mapData: { default: null },
  },
  props: {
    id: { type: String, required: true },
    label: { type: String, default: null },
  },
  computed: {
    systemId() {
      const n = parseInt(this.id, 10);
      return Number.isFinite(n) ? n : null;
    },
    system() {
      if (this.systemId == null) return null;
      if (!this.mapData || !this.mapData.systems) return null;
      return this.mapData.systems.find((s) => s.id === this.systemId) || null;
    },
    displayLabel() {
      if (this.label) return this.label;
      if (this.system && this.system.name) return this.system.name;
      return `Sys ${this.id}`;
    },
    tooltip() {
      if (!this.system) {
        return this.$t ? this.$t('in_game_chat.ref.unknown_system') : 'Unknown system';
      }
      const { x, y } = this.system.position || {};
      const coords = (x != null && y != null)
        ? ` (${x.toFixed(1)}, ${y.toFixed(1)})`
        : '';
      return `${this.system.name || this.displayLabel}${coords}`;
    },
  },
  methods: {
    onClick() {
      if (!this.system) return;
      navigateRef(this, 'sys', this.id);
    },
  },
};
</script>
