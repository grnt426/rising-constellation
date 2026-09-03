<template>
  <div
    ref="container"
    class="system-content-container">
    <template v-if="system.contact.value > 0">
      <div
        class="system-content-menu"
        :style="menuStyle">
        <template v-if="tabs.length > 1">
          <div
            v-for="(tab, index) in tabs"
            class="system-tab-item"
            :key="`tab-${index}`"
            :class="{ 'active': index === activeTab }"
            @click="activeTab = index">
          </div>
        </template>

        <div
          class="system-tab-item is-tool"
          v-tooltip.left="$t(isCollapsed
            ? 'galaxy.system.content.expand_bodies'
            : 'galaxy.system.content.collapse_bodies')"
          @click="isCollapsed = !isCollapsed">
          <svgicon :name="isCollapsed ? 'caret-down' : 'caret-up'" />
        </div>
      </div>

      <v-scrollbar
        v-if="system.bodies.length > 0"
        :settings="scrollbarSettings"
        :class="{ 'is-collapsed': isCollapsed && showsBodies }"
        class="system-content-scrollbar">
        <system-bodies
          v-if="showsBodies && !isCollapsed"
          :system="system"
          :isOwnSystem="isOwnSystem"
          :color="color"
          :hoveredOrbit="hoveredOrbit"
          @enterOrbit="enterOrbit"
          @leaveOrbit="$emit('leaveOrbit')"
          @hoverTile="onHoverTile" />

        <system-details
          v-if="activeTab >= 0 && tabs[activeTab].includes('details')"
          :system="system"
          :isOwnSystem="isOwnSystem"
          :color="color" />

        <system-state
          v-if="activeTab >= 0 && tabs[activeTab].includes('state')"
          :system="system"
          :isOwnProperty="isOwnProperty"
          :color="color" />
      </v-scrollbar>

      <div
        v-else
        class="system-content-orphan">
        <div class="system-content-group-header">
          <div class="main">{{ $t(`system.empty_system.label`) }}</div>
        </div>
        <p>{{ $t(`system.empty_system.content`) }}</p>
      </div>

      <!-- hangs outside the panel (right: -310px), so it must live beside the
           v-scrollbar: the scroll element is position: relative + overflow
           hidden and would clip it -->
      <div
        v-if="hoveredTile && system.contact.value === 5"
        :class="{ 'has-margin-bottom': hoveredTile.showCost || cardPreviewing }"
        class="system-building-card"
        @mouseenter="hoverCardEnter"
        @mouseleave="hoverCardLeave">
        <building-card
          :buildingKey="hoveredTile.tile.building_key"
          :level="hoveredTile.tile.building_level"
          :body="hoveredTile.body"
          :system="system"
          :theme="color"
          :showCost="hoveredTile.showCost"
          :pinned="cardPinned"
          :context="hoveredTile.showCost ? 'blueprint' : 'built'"
          @preview="cardPreviewing = $event"
          @close="hoverCardClose" />
      </div>
    </template>

    <template v-else>
      <div class="system-content-orphan">
        <div class="system-content-group-header">
          <div class="main">{{ $t(`system.hidden_system.label`) }}</div>
        </div>
        <p>{{ $t(`system.hidden_system.content`) }}</p>
      </div>
    </template>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';
import SystemBodies from '@/game/components/galaxy/system/Bodies.vue';
import SystemDetails from '@/game/components/galaxy/system/Details.vue';
import SystemState from '@/game/components/galaxy/system/State.vue';
import BuildingCard from '@/game/components/card/BuildingCard.vue';

export default {
  name: 'system-content',
  mixins: [HoverCardMixin],
  data() {
    return {
      activeTab: 0,
      isCollapsed: false,
      populationHeight: 90,
      scrollbarSettings: VERTICAL_SCROLL_SETTINGS,
      hoveredTile: null,
      cardPreviewing: false,
    };
  },
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
    color: String,
    hoveredOrbit: Number,
  },
  computed: {
    tabs() {
      if (['uninhabitable', 'uninhabited'].includes(this.system.status)) {
        return [['bodies', 'state']];
      }
      return [['bodies'], ['details'], ['state']];
    },
    showsBodies() {
      return this.activeTab >= 0 && this.tabs[this.activeTab].includes('bodies');
    },
    // collapsed, this container is ~0px tall right above the bottom navbar,
    // where the Bottombar panels (higher z-index) would swallow clicks on a
    // strip hung from it — so dock the strip to the population box instead:
    // rising from its top-right corner (320px wide, out-dented -50px =>
    // right edge at 270px), where only the map sits underneath
    menuStyle() {
      if (!(this.isCollapsed && this.showsBodies)) return null;
      return {
        top: 'auto',
        right: 'auto',
        left: '270px',
        bottom: `${this.populationHeight}px`,
      };
    },
  },
  watch: {
    // tile mouseleave never fires when the hovered row unmounts (tab switch,
    // collapse, system change) — clear the card here so it can't go stale
    activeTab() {
      this.hoverCardClose();
    },
    isCollapsed() {
      this.measurePopulation();
      this.hoverCardClose();
    },
    'system.id': function onSystemChange() {
      this.measurePopulation();
      this.hoverCardClose();
    },
  },
  methods: {
    enterOrbit(orbitId) {
      this.$emit('enterOrbit', orbitId);
    },
    onHoverTile(payload) {
      if (payload) {
        this.hoverCardShow(payload);
      } else {
        this.hoverCardHide();
      }
    },
    hoverCardApply(payload) {
      this.hoveredTile = payload;
      this.cardPreviewing = false;
    },
    hoverCardVisible() {
      return !!this.hoveredTile;
    },
    measurePopulation() {
      this.$nextTick(() => {
        const info = this.$el.closest('.system-info');
        const population = info && info.querySelector('.system-population');
        if (population) {
          this.populationHeight = population.offsetHeight;
        }
      });
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { left: -500 })
      .to(this.$refs.container, { left: 0, ease: Expo.easeOut, duration: 1 }, 0);
  },
  components: {
    SystemBodies,
    SystemDetails,
    SystemState,
    BuildingCard,
  },
};
</script>
