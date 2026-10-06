<template>
  <div
    class="panel-container is-right"
    :class="theme"
    @click.self="close">
    <agents
      v-if="activePanel === 'characters'"
      @close="close" />
    <reports
      v-if="activePanel === 'reports'"
      :initial="initialReport" />
    <events v-if="activePanel === 'events'" />

    <div
      class="panel-navbar"
      role="group"
      :aria-label="$t('a11y.panel_tabs')">
      <button
        type="button"
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.operations.${panel}`)"
        :key="panel"
        :class="{ 'is-active': activePanel === panel }"
        :aria-label="$t(`panel.operations.${panel}`)"
        :aria-pressed="String(activePanel === panel)"
        @click="activePanel = panel">
      </button>
    </div>
  </div>
</template>

<script>
import Agents from '@/game/components/panel/operation/Agents.vue';
import Events from '@/game/components/panel/operation/Events.vue';
import Reports from '@/game/components/panel/operation/Reports.vue';

export default {
  name: 'operations-panel',
  data() {
    return {
      activePanel: 'characters',
      initialReport: 0,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    // The event timeline is not kept in real-time games, nor in the tutorial.
    hasEvents() {
      return this.$store.state.game.time.speed !== 'fast'
        && !this.$store.state.game.galaxy.tutorial_id;
    },
    panels() {
      return this.hasEvents ? ['characters', 'reports', 'events'] : ['characters', 'reports'];
    },
  },
  methods: {
    // { reportId } opens on that report, { tab } on that section.
    open(data) {
      if (data && data.reportId) {
        this.initialReport = data.reportId;
        this.activePanel = 'reports';
      } else if (data && this.panels.includes(data.tab)) {
        this.activePanel = data.tab;
      }
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Agents,
    Events,
    Reports,
  },
};
</script>
