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
import Reports from '@/game/components/panel/operation/Reports.vue';

export default {
  name: 'operations-panel',
  data() {
    return {
      activePanel: 'characters',
      panels: ['characters', 'reports'],
      initialReport: 0,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
  },
  methods: {
    open(data) {
      if (data && data.reportId) {
        this.initialReport = data.reportId;
        this.activePanel = 'reports';
      }
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Agents,
    Reports,
  },
};
</script>
