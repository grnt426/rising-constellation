<template>
  <div :class="`f-${color}`">
    <!-- Phone layout: three swipeable screens (summary / construction /
         agents) instead of the desktop square-overlay-plus-side-panels
         arrangement. Same child components, different frame — see
         MobileView. -->
    <mobile-system-view
      v-if="isMobileView && system"
      :system="system"
      :color="color"
      :isOwnSystem="isOwnSystem"
      :isOwnProperty="isOwnProperty"
      :hoveredOrbit="hoveredOrbit"
      @enterOrbit="enterOrbit"
      @leaveOrbit="leaveOrbit"
      @close="$emit('closeStellarSystem')" />

    <template v-else>
      <div
        @click="$emit('closeStellarSystem')"
        class="stellar-system-view">
      </div>

      <template v-if="system">
        <system-production
          :system="system"
          :color="color"
          :isQueueOpen="isQueueOpen" />

        <div class="system-content">
          <component
            :is="agentDisplayComponent"
            :isOwnSystem="isOwnSystem"
            :isOwnProperty="isOwnProperty"
            :system="system" />

          <station-box
            :system="system"
            :color="color" />

          <system-properties
            :isOwnSystem="isOwnSystem"
            :isOwnProperty="isOwnProperty"
            :system="system"
            :color="color"
            @toggleQueue="toggleProductionQueue" />

          <system-svg
            :key="rerenderKey"
            :hoveredOrbit="hoveredOrbit"
            :system="system"
            @enterOrbit="enterOrbit"
            @leaveOrbit="leaveOrbit" />
        </div>

        <div class="system-info">
          <system-population
            :isOwnSystem="isOwnSystem"
            :system="system" />

          <system-content
            :isOwnSystem="isOwnSystem"
            :isOwnProperty="isOwnProperty"
            :system="system"
            :color="color"
            :hoveredOrbit="hoveredOrbit"
            @enterOrbit="enterOrbit"
            @leaveOrbit="leaveOrbit" />
        </div>
      </template>
    </template>
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import SystemSvg from '@/game/components/galaxy/system/Svg.vue';
import SystemProperties from '@/game/components/galaxy/system/Properties.vue';
import SystemActions from '@/game/components/galaxy/system/Actions.vue';
import SystemActionsLegacy from '@/game/components/galaxy/system/ActionsLegacy.vue';
import SystemPopulation from '@/game/components/galaxy/system/Population.vue';
import SystemContent from '@/game/components/galaxy/system/Content.vue';
import SystemProduction from '@/game/components/galaxy/system/Production.vue';
import StationBox from '@/game/components/galaxy/system/StationBox.vue';
import MobileSystemView from '@/game/components/galaxy/system/MobileView.vue';

export default {
  name: 'system-view',
  data() {
    return {
      isQueueOpen: false,
      rerenderKey: 0,
      hoveredOrbit: undefined,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    color() {
      return ['inhabited_player', 'inhabited_dominion'].includes(this.system.status)
        ? this.$store.getters['game/themeByKey'](this.system.owner.faction)
        : 'null';
    },
    system() { return this.$store.state.game.selectedSystem; },
    // beta opt-in (Account → Beta Features): the reworked fan/squadron agent
    // display; everyone else keeps the legacy arc
    agentDisplayComponent() {
      const features = this.$store.state.portal.features || {};
      return features.agent_fan_display ? 'system-actions' : 'system-actions-legacy';
    },
    isOwnSystem() { return this.$store.state.game.player.stellar_systems.some((s) => s.id === this.system.id); },
    isOwnDominion() { return this.$store.state.game.player.dominions.some((s) => s.id === this.system.id); },
    isOwnProperty() { return this.isOwnSystem || this.isOwnDominion; },
  },
  watch: {
    system(ns, os) {
      if (ns.id !== os.id) {
        this.leaveOrbit();
      }
    },
  },
  methods: {
    toggleProductionQueue() {
      if (this.isOwnSystem) {
        this.$store.commit('game/clearProduction');
        this.isQueueOpen = !this.isQueueOpen;
      }
    },
    enterOrbit(orbitId) { this.hoveredOrbit = orbitId; },
    leaveOrbit() { this.hoveredOrbit = undefined; },
    handleResize() { this.rerenderKey += 1; },
  },
  mounted() {
    window.addEventListener('resize', this.handleResize);
  },
  beforeDestroy() {
    window.removeEventListener('resize', this.handleResize);
  },
  components: {
    SystemSvg,
    SystemContent,
    SystemProperties,
    SystemActions,
    SystemActionsLegacy,
    SystemPopulation,
    SystemProduction,
    StationBox,
    MobileSystemView,
  },
};
</script>
