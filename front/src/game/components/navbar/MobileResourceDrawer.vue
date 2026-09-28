<template>
  <!-- Phone stand-in for the desktop resource hover tooltips.
       Two heights: a peek strip listing all three resources with their
       income, and an expanded sheet that pages one full breakdown at a
       time (the desktop <resource-detail>). A full breakdown is far too
       tall to show three abreast on a phone, so the expanded state is a
       horizontal pager — swipe, tap a dot, or tap the peek row. -->
  <div class="mobile-resource-drawer-root">
    <div
      class="mrd-backdrop"
      :class="{ 'is-dim': expanded }"
      @click="close" />

    <div
      class="mobile-resource-drawer"
      :class="{ 'is-expanded': expanded }"
      @touchstart.passive="onTouchStart"
      @touchmove="onTouchMove"
      @touchend="onTouchEnd">
      <div
        class="mrd-grip"
        @click="toggleExpanded" />

      <!-- Peek: every resource at once. Tapping a row expands straight
           to that resource's page. -->
      <div
        v-if="!expanded"
        class="mrd-peek">
        <div
          v-for="res in resources"
          :key="`peek-${res}`"
          class="mrd-peek-row"
          @click="expandTo(res)">
          <svgicon
            class="mrd-peek-icon"
            :name="`resource/${res}`" />
          <span class="mrd-peek-name">{{ resourceName(res) }}</span>
          <span class="mrd-peek-stock">{{ player[res].value | float(0) }}</span>
          <span
            class="mrd-peek-income"
            :class="{ 'is-negative': player[res].change < 0 }">
            {{ player[res].change | income(1) }}
          </span>
          <svgicon
            class="mrd-peek-caret"
            name="caret-right" />
        </div>
        <div class="mrd-peek-hint">
          {{ $t('navbar.resource_drawer.peek_hint') }}
        </div>
      </div>

      <!-- Expanded: one resource per page. -->
      <template v-else>
        <div class="mrd-tabs">
          <div
            v-for="(res, i) in resources"
            :key="`tab-${res}`"
            class="mrd-tab"
            :class="{ 'active': i === page }"
            @click="goTo(i)">
            <svgicon :name="`resource/${res}`" />
            {{ resourceName(res) }}
          </div>
          <div
            class="mrd-close"
            @click="close">
            <svgicon name="close" />
          </div>
        </div>

        <div
          class="mrd-pager"
          ref="pager">
          <div
            class="mrd-track"
            :style="trackStyle">
            <div
              v-for="res in resources"
              :key="`page-${res}`"
              class="mrd-page">
              <v-scrollbar
                class="mrd-page-scroll"
                :settings="scrollSettings">
                <resource-detail
                  :income="true"
                  :title="resourceName(res)"
                  :help="res"
                  :description="$t(`resource-description.${res}`)"
                  :value="player[res].change"
                  :rates="resourceRates(player[res])"
                  :totals="resourceTotals(player[res])"
                  :details="player[res].details" />
              </v-scrollbar>
            </div>
          </div>
        </div>

        <div class="mrd-dots">
          <span
            v-for="(res, i) in resources"
            :key="`dot-${res}`"
            class="mrd-dot"
            :class="{ 'active': i === page }"
            @click="goTo(i)" />
        </div>
      </template>
    </div>
  </div>
</template>

<script>
import ResourceDetail from '@/game/components/generic/ResourceDetail.vue';
import ResourceRatesMixin from '@/game/mixins/ResourceRatesMixin';
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';

// Horizontal travel that commits to the neighbouring page, and the
// vertical travel that counts as a deliberate drag rather than a tap.
const SWIPE_COMMIT_PX = 45;
const DRAG_SLOP_PX = 10;

export default {
  name: 'mobile-resource-drawer',
  mixins: [ResourceRatesMixin],
  props: {
    // Which resource the bar tap landed on; the drawer opens peeking but
    // remembers it so the first expand lands on the right page.
    initial: { type: String, default: 'credit' },
  },
  data() {
    return {
      resources: ['credit', 'technology', 'ideology'],
      expanded: false,
      page: 0,
      // live finger offset, in px, applied on top of the page transform
      dragX: 0,
      dragY: 0,
      dragging: false,
      axis: null,
      startX: 0,
      startY: 0,
      scrollSettings: VERTICAL_SCROLL_SETTINGS,
    };
  },
  computed: {
    player() { return this.$store.state.game.player; },
    trackStyle() {
      const base = -this.page * 100;
      return {
        transform: `translateX(calc(${base}% + ${this.dragX}px))`,
        transition: this.dragging ? 'none' : 'transform 220ms ease',
      };
    },
  },
  methods: {
    resourceName(res) {
      return this.$t(`data.bonus_pipeline_in.player_${res}.name`);
    },
    close() {
      this.$emit('close');
    },
    toggleExpanded() {
      if (this.expanded) this.close();
      else this.expand();
    },
    expand() {
      this.page = Math.max(0, this.resources.indexOf(this.initial));
      this.expanded = true;
    },
    expandTo(res) {
      this.expanded = true;
      this.page = Math.max(0, this.resources.indexOf(res));
    },
    goTo(i) {
      this.page = Math.min(this.resources.length - 1, Math.max(0, i));
    },
    // --- gestures ---------------------------------------------------
    // One handler for both states: while peeking a swipe up expands and a
    // swipe down closes; while expanded a horizontal swipe pages and a
    // downward swipe from the grip closes. The axis is locked on the
    // first move past the slop so a vertical scroll inside a page never
    // drags the pager sideways.
    onTouchStart(event) {
      const touch = event.touches[0];
      this.startX = touch.clientX;
      this.startY = touch.clientY;
      this.axis = null;
      this.dragging = false;
      this.dragX = 0;
      this.dragY = 0;
    },
    onTouchMove(event) {
      const touch = event.touches[0];
      const dx = touch.clientX - this.startX;
      const dy = touch.clientY - this.startY;

      if (!this.axis) {
        if (Math.abs(dx) < DRAG_SLOP_PX && Math.abs(dy) < DRAG_SLOP_PX) return;
        this.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
      }

      if (this.axis === 'x' && this.expanded) {
        this.dragging = true;
        // Rubber-band at the ends so the track can't be pulled into
        // empty space.
        const atStart = this.page === 0 && dx > 0;
        const atEnd = this.page === this.resources.length - 1 && dx < 0;
        this.dragX = atStart || atEnd ? dx * 0.3 : dx;
        event.preventDefault();
      }

      if (this.axis === 'y') {
        this.dragY = dy;
      }
    },
    onTouchEnd() {
      const wasDragging = this.dragging;
      const dx = this.dragX;
      const dy = this.dragY;
      this.dragging = false;
      this.dragX = 0;
      this.dragY = 0;

      if (this.axis === 'x' && wasDragging) {
        if (dx <= -SWIPE_COMMIT_PX) this.goTo(this.page + 1);
        else if (dx >= SWIPE_COMMIT_PX) this.goTo(this.page - 1);
        this.axis = null;
        return;
      }

      // A vertical drag inside an expanded page is that page's own
      // scroll — only the peek state reads it as open/close.
      if (this.axis === 'y' && !this.expanded) {
        if (dy <= -DRAG_SLOP_PX) this.expand();
        else if (dy >= SWIPE_COMMIT_PX) this.close();
      }

      this.axis = null;
    },
  },
  components: { ResourceDetail },
};
</script>
