<template>
  <div
    class="panel-container is-left"
    :class="theme"
    @click.self="close">
    <div class="panel-navbar">
      <button
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.help.${panel}`)"
        :key="panel"
        :class="{ 'is-active': activePanel === panel }"
        @click="activePanel = panel">
      </button>
    </div>

    <manual
      v-if="manualEnabled"
      v-show="activePanel === 'manual'"
      ref="manual" />
    <hotkeys v-show="activePanel === 'hotkeys'" />
    <legend-panel v-show="activePanel === 'legend'" />
    <stances v-show="activePanel === 'stances'" />
    <links v-show="activePanel === 'links'" />
  </div>
</template>

<script>
import Manual from '@/game/components/panel/help/Manual.vue';
import Hotkeys from '@/game/components/panel/help/Hotkeys.vue';
import LegendPanel from '@/game/components/panel/help/Legend.vue';
import Stances from '@/game/components/panel/help/Stances.vue';
import Links from '@/game/components/panel/help/Links.vue';

export default {
  name: 'help-panel',
  data() {
    return {
      activePanel: this.$store.getters['help/enabled'] ? 'manual' : 'hotkeys',
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    // The Manual tab rides the help_manual beta; the other tabs are for everyone.
    manualEnabled() { return this.$store.getters['help/enabled']; },
    panels() {
      const base = ['hotkeys', 'legend', 'stances', 'links'];
      return this.manualEnabled ? ['manual', ...base] : base;
    },
  },
  watch: {
    manualEnabled(enabled) {
      if (!enabled && this.activePanel === 'manual') this.activePanel = 'hotkeys';
    },
  },
  methods: {
    // Deep links (`?help=slug`, the modal's Expand button) land here via
    // Game.vue's togglePanel('help', { page }); sub-panel state otherwise
    // persists between opens.
    open(data) {
      if (data && data.page && this.manualEnabled) {
        this.activePanel = 'manual';
        this.$nextTick(() => { if (this.$refs.manual) this.$refs.manual.show(data.page); });
      }
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Manual,
    Hotkeys,
    LegendPanel,
    Stances,
    Links,
  },
};
</script>
