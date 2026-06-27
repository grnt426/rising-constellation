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

    <hotkeys v-show="activePanel === 'hotkeys'" />
    <legend-panel v-show="activePanel === 'legend'" />
    <stances v-show="activePanel === 'stances'" />
    <links v-show="activePanel === 'links'" />
  </div>
</template>

<script>
import Hotkeys from '@/game/components/panel/help/Hotkeys.vue';
import LegendPanel from '@/game/components/panel/help/Legend.vue';
import Stances from '@/game/components/panel/help/Stances.vue';
import Links from '@/game/components/panel/help/Links.vue';

export default {
  name: 'help-panel',
  data() {
    return {
      activePanel: 'hotkeys',
      panels: ['hotkeys', 'legend', 'stances', 'links'],
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
  },
  methods: {
    open(_data) {
      // no-op — sub-panel state persists between opens
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Hotkeys,
    LegendPanel,
    Stances,
    Links,
  },
};
</script>
