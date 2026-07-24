<template>
  <div id="galaxy-container">
    <system-view
      v-if="selectedSystem"
      @closeStellarSystem="closeStellarSystemView" />

    <!-- Phones: the selection panel minimizes into a draggable bubble
         (map orders come from long-pressing a target system). -->
    <selection-view v-if="selection && !isMobileView" />
    <mobile-selected-agent v-if="selection && isMobileView" />
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import SystemView from '@/game/components/galaxy/system/View.vue';
import SelectionView from '@/game/components/galaxy/selection/View.vue';
import MobileSelectedAgent from '@/game/components/galaxy/MobileSelectedAgent.vue';

export default {
  name: 'galaxy-container',
  computed: {
    isMobileView() { return viewport.isMobile; },
    selectedSystem() { return this.$store.state.game.selectedSystem; },
    selection() { return this.$store.state.game.selectedCharacter; },
  },
  methods: {
    closeStellarSystemView() {
      this.$store.dispatch('game/closeSystem', this);
    },
    handleScroll(event) {
      if (this.selectedSystem && !(this.assignment) && event.deltaY > 0) {
        this.closeStellarSystemView();
      }
    },
  },
  mounted() {
    document.addEventListener('wheel', this.handleScroll);
  },
  destroyed() {
    document.removeEventListener('wheel', this.handleScroll);
  },
  components: {
    SystemView,
    SelectionView,
    MobileSelectedAgent,
  },
};
</script>
