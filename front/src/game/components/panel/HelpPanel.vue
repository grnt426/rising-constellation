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
    <links v-show="activePanel === 'links'" />
  </div>
</template>

<script>
import Hotkeys from '@/game/components/panel/help/Hotkeys.vue';
import Links from '@/game/components/panel/help/Links.vue';

export default {
  name: 'help-panel',
  data() {
    return {
      activePanel: 'hotkeys',
      panels: ['hotkeys', 'links'],
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
    Links,
  },
};
</script>
