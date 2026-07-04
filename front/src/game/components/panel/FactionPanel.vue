<template>
  <div
    class="panel-container is-left"
    :class="theme"
    @click.self="close">
    <div class="panel-navbar">
      <button
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.faction.${panel}`)"
        :key="panel"
        :class="{ 'is-active': activePanel === panel }"
        @click="activePanel = panel">
      </button>
    </div>

    <overall v-show="activePanel === 'overall'" />
    <player v-show="activePanel === 'player'" />
    <government v-show="activePanel === 'government'" />
    <about v-show="activePanel === 'about'" />
  </div>
</template>

<script>
import About from '@/game/components/panel/faction/About.vue';
import Government from '@/game/components/panel/faction/Government.vue';
import Overall from '@/game/components/panel/faction/Overall.vue';
import Player from '@/game/components/panel/faction/Player.vue';

export default {
  name: 'faction-panel',
  data() {
    return {
      activePanel: 'overall',
      panels: ['overall', 'player', 'government'],
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
  },
  methods: {
    open(_data) {
      // ...
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    About,
    Government,
    Overall,
    Player,
  },
};
</script>
