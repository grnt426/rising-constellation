<template>
  <section
    class="navbar-panel list-panel"
    :class="`is-${side}`"
    :style="{ maxHeight: maxHeightCss }"
    :aria-label="label">
    <div
      class="list-panel-toolbar"
      role="group"
      :aria-label="$t('navbar.list_panel.toolbar', { list: label })">
      <!-- A window splitter for assistive tech: arrow keys resize, the
           value is the height in percent. -->
      <div
        class="list-panel-grip"
        role="separator"
        tabindex="0"
        aria-orientation="horizontal"
        :aria-label="$t('navbar.list_panel.resize_label')"
        :aria-valuenow="Math.round(heightPct)"
        aria-valuemin="15"
        aria-valuemax="85"
        :aria-valuetext="`${Math.round(heightPct)}%`"
        v-tooltip="$t('navbar.list_panel.resize')"
        @pointerdown="onGripDown"
        @keydown="onGripKey">
        <svgicon
          name="resize-grip"
          aria-hidden="true" />
        <span
          v-if="dragging"
          class="list-panel-grip-pct">
          {{ Math.round(livePct) }}%
        </span>
      </div>

      <template v-if="!isSearchOpen">
        <slot name="toolbar"></slot>

        <span class="list-panel-spacer"></span>

        <button
          type="button"
          class="bare-button list-panel-tool"
          aria-expanded="false"
          :aria-label="$t('navbar.list_panel.search')"
          v-tooltip="$t('navbar.list_panel.search')"
          @click="openSearch">
          <svgicon
            name="search"
            aria-hidden="true" />
        </button>
      </template>

      <template v-else>
        <input
          ref="searchInput"
          type="search"
          class="list-panel-search"
          :value="query"
          :aria-label="$t('navbar.list_panel.search_label', { list: label })"
          :placeholder="$t('navbar.list_panel.search_placeholder')"
          @input="setQuery($event.target.value)"
          @keyup.esc="closeSearch" />
        <button
          type="button"
          class="bare-button list-panel-tool"
          :aria-label="$t('navbar.list_panel.search_close')"
          @click="closeSearch">
          <svgicon
            name="close"
            aria-hidden="true" />
        </button>
      </template>
    </div>

    <v-scrollbar
      class="list-panel-body"
      :settings="scrollSettings">
      <slot></slot>
    </v-scrollbar>
  </section>
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
    // Accessible name of the panel ("Systems and dominions", "Agents").
    label: String,
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
    // Keyboard resize (the separator's arrow keys), 5% per press. Saved
    // after a pause so holding a key doesn't post the settings blob on
    // every repeat. (No Home/End: Home is a game hotkey.)
    onGripKey(event) {
      const step = { ArrowUp: 5, ArrowDown: -5 }[event.key];
      if (!step) return;
      const pct = this.heightPct + step;
      event.preventDefault();

      // Rides the drag preview (live height + % bubble) until the save.
      this.dragging = true;
      this.livePct = Math.min(85, Math.max(15, pct));
      clearTimeout(this.keySaveTimer);
      this.keySaveTimer = setTimeout(() => {
        this.dragging = false;
        this.saveHeight(this.livePct);
      }, 600);
    },
    saveHeight(pct) {
      // Hundredths of a percent is plenty of resolution and keeps the
      // stored blob tidy.
      const rounded = Math.round(pct * 100) / 100;
      const current = this.$store.state.portal.settings.list_heights || {};
      this.$store.commit('portal/updateSettings', {
        list_heights: { ...current, [this.panelKey]: rounded },
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
      clearTimeout(this.keySaveTimer);
      this.dragging = true;
      this.livePct = this.heightPct;

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
        this.saveHeight(this.livePct);
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
    clearTimeout(this.keySaveTimer);
  },
};
</script>
