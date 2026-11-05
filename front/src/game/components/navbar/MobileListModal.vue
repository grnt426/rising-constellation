<template>
  <div class="mobile-list-modal">
    <div
      class="mlm-backdrop"
      @click="close"></div>
    <div class="mlm-sheet">
      <div class="mlm-header">
        <span>{{ title }}</span>
        <button
          class="mlm-close"
          @click="close">
          <svgicon name="close" />
        </button>
      </div>
      <div class="mlm-list">
        <div
          v-for="item in items"
          :key="item.id"
          class="mlm-row"
          @click="select(item)">
          <svgicon
            v-if="item.icon"
            class="mlm-icon"
            :name="item.icon" />
          <div class="mlm-text">
            <div class="mlm-label">{{ item.label }}</div>
            <div
              v-if="item.sub"
              class="mlm-sub">{{ item.sub }}</div>
          </div>
          <div
            v-if="item.right"
            class="mlm-right">{{ item.right }}</div>
        </div>
        <div
          v-if="items.length === 0"
          class="mlm-empty">—</div>
      </div>
    </div>
  </div>
</template>

<script>
// The sheet rises from the bottom edge, right where the bar's buttons
// are: a click left over from the gesture that opened it (a long-press
// released on the agents radial, a pointerup-driven opener) lands on a
// row or the backdrop and picks or closes it. Taps in the first moments
// after opening are therefore ignored.
const GHOST_CLICK_MS = 400;

export default {
  name: 'mobile-list-modal',
  props: {
    title: { type: String, required: true },
    items: { type: Array, required: true },
  },
  created() {
    this.openedAt = Date.now();
  },
  methods: {
    isGhost() {
      return Date.now() - this.openedAt < GHOST_CLICK_MS;
    },
    close() {
      if (!this.isGhost()) this.$emit('close');
    },
    select(item) {
      if (!this.isGhost()) this.$emit('select', item);
    },
  },
};
</script>
