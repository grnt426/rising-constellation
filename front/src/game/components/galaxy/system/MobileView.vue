<template>
  <!-- Phone system view: three focused screens instead of one long
       scroll. Summary / Construction / Agents, paged by swipe, by the
       tab strip, or by the edge chevrons. The tab strip is the standing
       affordance — it is always visible and always says which of three
       you are on, so the swipe never has to be discovered to be used. -->
  <div
    class="mobile-system-view"
    :class="`f-${color}`">
    <div class="msv-header">
      <div class="msv-title">
        <span class="name">{{ system.name }}</span>
        <span class="coords">{{ coords }}</span>
      </div>
      <button
        @click="$emit('close')"
        class="system-close-button">
        <svgicon name="close" />
      </button>
    </div>

    <div class="msv-tabs">
      <div
        v-for="(p, i) in pages"
        :key="p.key"
        class="msv-tab"
        :class="{ 'active': i === page }"
        @click="goTo(i)">
        <svgicon :name="p.icon" />
        <span>{{ $t(`galaxy.system.mobile.tab_${p.key}`) }}</span>
        <span
          v-if="p.badge"
          class="msv-tab-badge">{{ p.badge }}</span>
      </div>
    </div>

    <div
      class="msv-pager"
      @touchstart.passive="onTouchStart"
      @touchmove="onTouchMove"
      @touchend="onTouchEnd">
      <div
        class="msv-track"
        :style="trackStyle">
        <!-- 1. summary: what this system produces and who runs it -->
        <div class="msv-page">
          <v-scrollbar
            class="msv-page-scroll"
            :settings="scrollSettings">
            <div class="mobile-system-summary">
              <system-properties
                :isOwnSystem="isOwnSystem"
                :isOwnProperty="isOwnProperty"
                :system="system"
                :color="color"
                @toggleQueue="goTo(1)" />

              <system-population
                :isOwnSystem="isOwnSystem"
                :system="system" />
            </div>

            <production-box
              class="mobile-production"
              :system="system"
              :isOwnProperty="isOwnProperty"
              :color="color"
              @toggleQueue="goTo(1)" />

            <station-box
              :system="system"
              :color="color" />

            <system-details
              v-if="isVisible"
              :system="system"
              :isOwnSystem="isOwnSystem"
              :color="color" />

            <system-state
              v-if="isVisible"
              :system="system"
              :isOwnProperty="isOwnProperty"
              :color="color" />
          </v-scrollbar>
        </div>

        <!-- 2. construction: dock on top, celestials below -->
        <div class="msv-page">
          <mobile-build-dock
            :system="system"
            :color="color"
            :isOwnSystem="isOwnSystem"
            :inspect="inspectedTile"
            @clearInspect="inspectedTile = null" />

          <v-scrollbar
            class="msv-page-scroll is-under-dock"
            :settings="scrollSettings">
            <system-bodies
              v-if="isVisible && system.bodies.length > 0"
              :system="system"
              :isOwnSystem="isOwnSystem"
              :color="color"
              :hoveredOrbit="hoveredOrbit"
              @enterOrbit="$emit('enterOrbit', $event)"
              @leaveOrbit="$emit('leaveOrbit')"
              @inspectTile="onInspectTile" />

            <div
              v-else
              class="system-content-orphan">
              <div class="system-content-group-header">
                <div class="main">{{ $t(emptyLabel) }}</div>
              </div>
              <p>{{ $t(emptyBody) }}</p>
            </div>
          </v-scrollbar>
        </div>

        <!-- 3. agents: dock on top, rosters below -->
        <div class="msv-page">
          <mobile-agent-dock
            :summary="inspectedCharacter"
            @close="inspectedCharacter = null" />

          <v-scrollbar
            class="msv-page-scroll is-under-dock"
            :settings="scrollSettings">
            <component
              :is="agentDisplayComponent"
              :isOwnSystem="isOwnSystem"
              :isOwnProperty="isOwnProperty"
              :system="system"
              @inspectCharacter="inspectedCharacter = $event" />
          </v-scrollbar>
        </div>
      </div>
    </div>

    <button
      v-if="page > 0"
      class="msv-edge is-left"
      @click="goTo(page - 1)">
      <svgicon name="caret-left" />
    </button>
    <button
      v-if="page < pages.length - 1"
      class="msv-edge is-right"
      @click="goTo(page + 1)">
      <svgicon name="caret-right" />
    </button>

    <div class="msv-dots">
      <span
        v-for="(p, i) in pages"
        :key="`dot-${p.key}`"
        class="msv-dot"
        :class="{ 'active': i === page }"
        @click="goTo(i)" />
    </div>
  </div>
</template>

<script>
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';

import SystemProperties from '@/game/components/galaxy/system/Properties.vue';
import SystemPopulation from '@/game/components/galaxy/system/Population.vue';
import SystemDetails from '@/game/components/galaxy/system/Details.vue';
import SystemState from '@/game/components/galaxy/system/State.vue';
import SystemBodies from '@/game/components/galaxy/system/Bodies.vue';
import SystemActions from '@/game/components/galaxy/system/Actions.vue';
import SystemActionsLegacy from '@/game/components/galaxy/system/ActionsLegacy.vue';
import ProductionBox from '@/game/components/galaxy/system/ProductionBox.vue';
import StationBox from '@/game/components/galaxy/system/StationBox.vue';
import MobileBuildDock from '@/game/components/galaxy/system/MobileBuildDock.vue';
import MobileAgentDock from '@/game/components/galaxy/system/MobileAgentDock.vue';

const SWIPE_COMMIT_PX = 55;
const DRAG_SLOP_PX = 12;

export default {
  name: 'mobile-system-view',
  props: {
    system: Object,
    color: String,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
    hoveredOrbit: Number,
  },
  data() {
    return {
      page: 0,
      dragX: 0,
      dragging: false,
      axis: null,
      startX: 0,
      startY: 0,
      // { body, tile } of the building whose card the dock is showing
      inspectedTile: null,
      inspectedCharacter: null,
      scrollSettings: VERTICAL_SCROLL_SETTINGS,
    };
  },
  computed: {
    // No contact means no bodies, no agents and no readings — the
    // construction and agent pages have nothing to draw.
    isVisible() { return this.system.contact.value > 0; },
    production() { return this.$store.state.game.production; },
    coords() {
      return `${Math.trunc(this.system.position.x)}:${Math.trunc(this.system.position.y)}`;
    },
    emptyLabel() {
      return this.isVisible ? 'system.empty_system.label' : 'system.hidden_system.label';
    },
    emptyBody() {
      return this.isVisible ? 'system.empty_system.content' : 'system.hidden_system.content';
    },
    agentCount() {
      return this.system.characters ? this.system.characters.length : 0;
    },
    queueCount() {
      return this.system.queue ? this.system.queue.queue.length : 0;
    },
    pages() {
      return [
        { key: 'summary', icon: 'empire' },
        { key: 'build', icon: 'building/frame_open', badge: this.queueCount || null },
        { key: 'agents', icon: 'agent/admiral', badge: this.agentCount || null },
      ];
    },
    // beta opt-in (Account → Beta Features): the reworked fan/squadron agent
    // display; everyone else keeps the legacy arc
    agentDisplayComponent() {
      const features = this.$store.state.portal.features || {};
      return features.agent_fan_display ? 'system-actions' : 'system-actions-legacy';
    },
    trackStyle() {
      return {
        transform: `translateX(calc(${-this.page * 100}% + ${this.dragX}px))`,
        transition: this.dragging ? 'none' : 'transform 240ms ease',
      };
    },
  },
  watch: {
    // Another system's tile/agent has nothing to do with this one.
    'system.id': function onSystemChange() {
      this.inspectedTile = null;
      this.inspectedCharacter = null;
    },
    // Selecting a slot on the tile grid is a build intent: follow it to
    // the construction page rather than leaving the palette off-screen.
    production(value) {
      if (value && value.data.type === 'building') {
        this.inspectedTile = null;
        this.goTo(1);
      }
    },
  },
  methods: {
    goTo(i) {
      this.page = Math.min(this.pages.length - 1, Math.max(0, i));
    },
    onInspectTile(payload) {
      this.$store.commit('game/clearProduction');
      this.inspectedTile = payload;
      this.goTo(1);
    },
    // Axis-locked drag: a vertical scroll inside a page must never
    // start paging sideways, and vice versa.
    onTouchStart(event) {
      const touch = event.touches[0];
      this.startX = touch.clientX;
      this.startY = touch.clientY;
      this.axis = null;
      this.dragging = false;
      this.dragX = 0;
    },
    onTouchMove(event) {
      const touch = event.touches[0];
      const dx = touch.clientX - this.startX;
      const dy = touch.clientY - this.startY;

      if (!this.axis) {
        if (Math.abs(dx) < DRAG_SLOP_PX && Math.abs(dy) < DRAG_SLOP_PX) return;
        this.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
      }

      if (this.axis !== 'x') return;

      this.dragging = true;
      const atStart = this.page === 0 && dx > 0;
      const atEnd = this.page === this.pages.length - 1 && dx < 0;
      this.dragX = atStart || atEnd ? dx * 0.3 : dx;
      event.preventDefault();
    },
    onTouchEnd() {
      const dx = this.dragX;
      const wasDragging = this.dragging;
      this.dragging = false;
      this.dragX = 0;
      this.axis = null;

      if (!wasDragging) return;
      if (dx <= -SWIPE_COMMIT_PX) this.goTo(this.page + 1);
      else if (dx >= SWIPE_COMMIT_PX) this.goTo(this.page - 1);
    },
  },
  components: {
    SystemProperties,
    SystemPopulation,
    SystemDetails,
    SystemState,
    SystemBodies,
    SystemActions,
    SystemActionsLegacy,
    ProductionBox,
    StationBox,
    MobileBuildDock,
    MobileAgentDock,
  },
};
</script>
