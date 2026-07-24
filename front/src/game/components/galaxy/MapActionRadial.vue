<template>
  <!-- Long-press action wheel: with an agent selected, holding a
       system on the galaxy map fans out that agent's possible orders
       around the press point. Availability here is coarse (class +
       system status); the server remains the real validator and
       rejections surface as the usual error toast. -->
  <div
    v-if="visible"
    class="map-action-radial"
    :style="{ left: `${screen.x}px`, top: `${screen.y}px` }">
    <div
      v-for="(action, i) in actions"
      :key="action.key"
      class="map-action-radial-item"
      :style="fanPosition(i, actions.length)"
      @click="pick(action)">
      <div class="radial-icon">
        <svgicon :name="`action/${action.key}_alt`" />
      </div>
      <div class="radial-label">{{ $t(`galaxy.system.actions.${action.name}`) }}</div>
    </div>
  </div>
</template>

<script>
import eventBus from '@/plugins/event-bus';

const INHABITED = ['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'];

export default {
  name: 'map-action-radial',
  props: {
    data: Object, // MapData — systems carry id/status/owner/position
  },
  data() {
    return {
      visible: false,
      screen: { x: 0, y: 0 },
      system: null,
    };
  },
  computed: {
    character() { return this.$store.state.game.selectedCharacter; },
    player() { return this.$store.state.game.player; },
    actions() {
      const character = this.character;
      const system = this.system;
      if (!character || !system) return [];

      const list = [];
      const own = system.owner && system.owner.id === this.player.id;
      const inhabited = INHABITED.includes(system.status);

      if (character.actions && character.actions.virtual_position !== system.id) {
        list.push({ key: 'jump', name: 'move' });
      }

      if (!own) {
        if (character.type === 'admiral') {
          if (system.status === 'uninhabited' && !system.owner) {
            list.push({ key: 'colonization', name: 'colonize' });
          }
          if (inhabited) {
            list.push({ key: 'conquest', name: 'conquer' });
            list.push({ key: 'raid', name: 'raid' });
            list.push({ key: 'loot', name: 'loot' });
          }
        }

        if (character.type === 'spy' && inhabited) {
          list.push({ key: 'infiltrate', name: 'infiltrate' });
        }

        if (character.type === 'speaker') {
          if (['inhabited_neutral', 'inhabited_dominion'].includes(system.status)) {
            list.push({ key: 'make_dominion', name: 'make_dominion' });
          }
          if (inhabited) {
            list.push({ key: 'encourage_hate', name: 'encourage_hate' });
          }
        }
      }

      return list;
    },
  },
  methods: {
    show({ systemId, screen }) {
      const system = this.data && this.data.systems
        ? this.data.systems.find((s) => s.id === systemId)
        : null;
      if (!system || !this.character) return;
      this.system = system;
      if (this.actions.length === 0) {
        this.system = null;
        return;
      }
      this.screen = {
        x: Math.min(Math.max(80, screen.x), window.innerWidth - 80),
        y: Math.min(Math.max(140, screen.y), window.innerHeight - 120),
      };
      this.visible = true;
    },
    hide() {
      this.visible = false;
      this.system = null;
    },
    // Fan the items over the upper semi-circle around the press point.
    fanPosition(i, count) {
      const radius = 84;
      const angle = count === 1
        ? Math.PI / 2
        : (Math.PI / 6) + (i * ((Math.PI * 4) / 6) / (count - 1));
      const x = Math.round(radius * Math.cos(Math.PI - angle));
      const y = -Math.round(radius * Math.sin(angle));
      return { transform: `translate(${x}px, ${y}px)` };
    },
    pick(action) {
      const system = this.system;
      this.hide();
      this.$root.$emit('map:addAction', action.key, { system });
    },
    onDocumentPointerDown(event) {
      if (!this.visible) return;
      if (this.$el && this.$el.contains && this.$el.contains(event.target)) return;
      this.hide();
    },
  },
  mounted() {
    eventBus.$on('map:action-radial:show', this.show);
    this.onDocumentPointerDownBound = this.onDocumentPointerDown.bind(this);
    document.addEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
  beforeDestroy() {
    eventBus.$off('map:action-radial:show', this.show);
    document.removeEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
};
</script>
