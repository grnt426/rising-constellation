<template>
  <div
    class="navbar-panel list-panel"
    :class="`is-${side}`"
    :style="{ maxHeight: maxHeightCss }">
    <div class="list-panel-toolbar">
      <div
        class="list-panel-grip"
        v-tooltip="$t('navbar.list_panel.resize')"
        @pointerdown="onGripDown">
        <svgicon name="resize-grip" />
        <span
          v-if="dragging"
          class="list-panel-grip-pct">
          {{ Math.round(livePct) }}%
        </span>
      </div>

      <template v-if="!isSearchOpen">
        <slot name="toolbar"></slot>

        <span class="list-panel-spacer"></span>

        <div
          class="list-panel-tool"
          v-tooltip="$t('navbar.list_panel.search')"
          @click="openSearch">
          <svgicon name="search" />
        </div>
      </template>

      <template v-else>
        <input
          ref="searchInput"
          class="list-panel-search"
          :value="query"
          :placeholder="$t('navbar.list_panel.search_placeholder')"
          @input="setQuery($event.target.value)"
          @keyup.esc="closeSearch" />
        <div
          class="list-panel-tool"
          @click="closeSearch">
          <svgicon name="close" />
        </div>
      </template>
    </div>

    <v-scrollbar
      class="list-panel-body"
      :settings="scrollSettings">
      <slot></slot>
    </v-scrollbar>
  </div>
</template>

<script>
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';

// Must mirror $navbar-height in styles/game/variables.scss — the drag
// math converts pointer Y into a percent of the between-navbars area,
// the same base the CSS max-height calc uses.
const NAVBAR_HEIGHT = 54;

// Shared shell of the two bottom-anchored card lists (systems/dominions
// on the left, on-board agents on the right). Owns everything the two
// have in common: the height cap (a percent of the between-navbars
// content area, persisted per-account), the scrollable body, the resize
// grip, and the expanding search field. The panel-specific filter/sort
// tools render into the `toolbar` slot; the cards into the default slot.
export default {
  name: 'list-panel',
  props: {
    // Key into Account.settings.list_heights: 'systems' | 'agents'.
    panelKey: String,
    side: String,
  },
  data() {
    return {
      scrollSettings: VERTICAL_SCROLL_SETTINGS,
      isSearchOpen: false,
      query: '',
      dragging: false,
      livePct: 60,
    };
  },
  computed: {
    storedPct() {
      return this.$store.getters['portal/listHeightPct'](this.panelKey);
    },
    heightPct() {
      return this.dragging ? this.livePct : this.storedPct;
    },
    maxHeightCss() {
      // 100vh minus both navbars = the in-game content area
      // ($content-height in variables.scss).
      return `calc((100vh - ${2 * NAVBAR_HEIGHT}px) * ${this.heightPct / 100})`;
    },
  },
  methods: {
    openSearch() {
      this.isSearchOpen = true;
      this.$nextTick(() => {
        if (this.$refs.searchInput) this.$refs.searchInput.focus();
      });
    },
    setQuery(value) {
      this.query = value;
      this.$emit('search', value);
    },
    // Closing also clears: a hidden query silently filtering the list
    // would look like missing systems/agents.
    closeSearch() {
      this.isSearchOpen = false;
      this.setQuery('');
    },
    onGripDown(event) {
      event.preventDefault();
      // Keep receiving pointer events even when the drag leaves the
      // browser window — without capture, releasing outside would strand
      // the panel in dragging state.
      if (event.target.setPointerCapture && event.pointerId != null) {
        event.target.setPointerCapture(event.pointerId);
      }
      this.dragging = true;
      this.livePct = this.storedPct;

      const contentHeight = () => window.innerHeight - 2 * NAVBAR_HEIGHT;

      this.onGripMove = (e) => {
        // The panel hangs from the bottom navbar, so its height is the
        // distance from the pointer down to that anchor.
        const heightPx = (window.innerHeight - NAVBAR_HEIGHT) - e.clientY;
        const pct = (heightPx / contentHeight()) * 100;
        this.livePct = Math.min(85, Math.max(15, pct));
      };
      this.onGripUp = () => {
        this.teardownGripListeners();
        this.dragging = false;
        // Hundredths of a percent is plenty of resolution and keeps the
        // stored blob tidy.
        const rounded = Math.round(this.livePct * 100) / 100;
        const current = this.$store.state.portal.settings.list_heights || {};
        this.$store.commit('portal/updateSettings', {
          list_heights: { ...current, [this.panelKey]: rounded },
        });
      };

      window.addEventListener('pointermove', this.onGripMove);
      window.addEventListener('pointerup', this.onGripUp);
      window.addEventListener('pointercancel', this.onGripUp);
    },
    teardownGripListeners() {
      window.removeEventListener('pointermove', this.onGripMove);
      window.removeEventListener('pointerup', this.onGripUp);
      window.removeEventListener('pointercancel', this.onGripUp);
    },
  },
  beforeDestroy() {
    this.teardownGripListeners();
  },
};
</script>
