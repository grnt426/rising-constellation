<template>
  <!-- Long-press action wheel: with an agent selected, holding a
       system on the galaxy map fans out that agent's possible orders
       around the press point. It opens while the finger is still down
       (map.js onLongPress): sliding to an order and lifting picks it,
       lifting in place leaves the wheel up for a separate tap, and a
       tap anywhere else closes it. Availability here is coarse (class +
       system status); the server remains the real validator and
       rejections surface as the usual error toast. -->
  <div
    v-if="visible"
    class="map-action-radial"
    :class="{ 'is-held': held }"
    :style="{ left: `${screen.x}px`, top: `${screen.y}px` }">
    <div class="map-action-radial-origin" />
    <div
      v-for="(action, i) in actions"
      :key="action.key"
      class="map-action-radial-item"
      :class="{ 'is-hot': hot === action.key }"
      :data-action="action.key"
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
      // the finger that opened the wheel is still down…
      held: false,
      // …and over this order
      hot: null,
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
    // `held`: the press that asked for the wheel is still down.
    show({ systemId, screen, held = false }) {
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
      this.hot = null;
      this.held = held;
      if (held) this.trackPress();
      eventBus.$emit('map:action-radial:opened');
    },
    // `dismissedBy`: the pointerdown that closed the wheel, if one did.
    hide(dismissedBy) {
      if (!this.visible) return;
      this.visible = false;
      this.system = null;
      this.releasePress();
      eventBus.$emit('map:action-radial:closed', { dismissedBy });
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

    // ---- the opening press, while it lasts -------------------------------
    // A touch stays captured by the element it went down on (the map's
    // canvas), so the wheel's items see none of its events: follow it
    // from the document and hit-test by position.
    trackPress() {
      document.addEventListener('pointermove', this.onPressMoveBound, true);
      document.addEventListener('pointerup', this.onPressEndBound, true);
      document.addEventListener('pointercancel', this.onPressCancelBound, true);
    },
    releasePress() {
      this.held = false;
      this.hot = null;
      document.removeEventListener('pointermove', this.onPressMoveBound, true);
      document.removeEventListener('pointerup', this.onPressEndBound, true);
      document.removeEventListener('pointercancel', this.onPressCancelBound, true);
    },
    actionAt(x, y) {
      const el = document.elementFromPoint(x, y);
      const item = el && el.closest ? el.closest('.map-action-radial-item') : null;
      if (!item || !this.$el.contains(item)) return null;
      return this.actions.find((a) => a.key === item.dataset.action) || null;
    },
    onPressMove(event) {
      const action = this.actionAt(event.clientX, event.clientY);
      this.hot = action ? action.key : null;
    },
    // Lifted over an order: that order. Anywhere else (in place, or
    // after wandering off): the wheel stays for a tap.
    onPressEnd(event) {
      const action = this.actionAt(event.clientX, event.clientY);
      this.releasePress();
      if (action) this.pick(action);
    },
    onPressCancel() {
      this.releasePress();
    },

    onDocumentPointerDown(event) {
      if (!this.visible) return;
      if (this.$el && this.$el.contains && this.$el.contains(event.target)) return;
      this.hide(event);
    },
  },
  watch: {
    // the wheel is one agent's: it goes with the selection
    character(next, prev) {
      if (!next || !prev || next.id !== prev.id) this.hide();
    },
  },
  created() {
    this.onPressMoveBound = this.onPressMove.bind(this);
    this.onPressEndBound = this.onPressEnd.bind(this);
    this.onPressCancelBound = this.onPressCancel.bind(this);
    this.onDocumentPointerDownBound = this.onDocumentPointerDown.bind(this);
  },
  mounted() {
    eventBus.$on('map:action-radial:show', this.show);
    document.addEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
  beforeDestroy() {
    this.hide();
    eventBus.$off('map:action-radial:show', this.show);
    document.removeEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
};
</script>
