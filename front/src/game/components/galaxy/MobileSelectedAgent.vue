<template>
  <!-- Phone replacement for the desktop selection panel: the selected
       agent minimizes into a draggable floating bubble. Tap opens the
       agent's card and fleet; the flag button recenters the map on
       them; the corner ✕ deselects. Map actions come from long-pressing
       a target system (MapActionRadial). -->
  <div v-if="character">
    <div
      class="mobile-agent-bubble"
      :class="`f-${theme}`"
      :style="{ left: `${x}px`, top: `${y}px` }"
      @pointerdown="onPointerDown"
      @contextmenu.prevent>
      <div class="bubble-icon">
        <svgicon :name="`agent/${character.type}`" />
        <span class="number">{{ character.level }}</span>
      </div>
      <div class="bubble-name">{{ character.name }}</div>
      <button
        class="bubble-locate"
        v-tooltip="$t('galaxy.system.mobile.center_on_agent')"
        @pointerdown.stop
        @click.stop="center">
        <svgicon name="marker/flag" />
      </button>
      <button
        class="bubble-close"
        @pointerdown.stop
        @click.stop="unselect">
        <svgicon name="close" />
      </button>
    </div>

    <!-- Card sheet. `selectedCharacter` is already the full character
         (the store fetches it through get_character on select), so
         there is nothing to load here. -->
    <div
      v-if="sheetOpen"
      class="mobile-agent-sheet-backdrop"
      @click.self="sheetOpen = false">
      <div class="mobile-agent-sheet">
        <div class="mas-header">
          <span class="mas-title">{{ character.name }}</span>
          <span class="mas-sub">{{ $tc(`data.character.${character.type}.name`, 1) }}</span>
          <button
            class="mas-close"
            @click="sheetOpen = false">
            <svgicon name="close" />
          </button>
        </div>

        <div class="mas-body">
          <agent-detail-pair
            :character="character"
            :theme="theme" />
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import AgentDetailPair from '@/game/components/card/AgentDetailPair.vue';

const DRAG_SLOP_PX = 8;

export default {
  name: 'mobile-selected-agent',
  data() {
    return {
      x: 12,
      y: Math.max(80, window.innerHeight - 160),
      sheetOpen: false,
      dragging: false,
      moved: false,
      startX: 0,
      startY: 0,
      offsetX: 0,
      offsetY: 0,
    };
  },
  computed: {
    character() { return this.$store.state.game.selectedCharacter; },
    theme() {
      return this.character
        ? this.$store.getters['game/themeByKey'](this.character.owner.faction)
        : null;
    },
  },
  watch: {
    // Deselecting (or selecting someone else) must not leave the
    // previous agent's card sitting over the map.
    character(next, prev) {
      if (!next || !prev || next.id !== prev.id) this.sheetOpen = false;
    },
  },
  methods: {
    onPointerDown(event) {
      this.dragging = true;
      this.moved = false;
      this.startX = event.clientX;
      this.startY = event.clientY;
      this.offsetX = event.clientX - this.x;
      this.offsetY = event.clientY - this.y;
      document.addEventListener('pointermove', this.onPointerMoveBound, true);
      document.addEventListener('pointerup', this.onPointerUpBound, true);
    },
    onPointerMove(event) {
      if (!this.dragging) return;
      if (Math.abs(event.clientX - this.startX) > DRAG_SLOP_PX
        || Math.abs(event.clientY - this.startY) > DRAG_SLOP_PX) {
        this.moved = true;
      }
      if (this.moved) {
        this.x = Math.min(Math.max(0, event.clientX - this.offsetX), window.innerWidth - 56);
        this.y = Math.min(Math.max(44, event.clientY - this.offsetY), window.innerHeight - 100);
      }
    },
    onPointerUp() {
      const wasTap = this.dragging && !this.moved;
      this.dragging = false;
      document.removeEventListener('pointermove', this.onPointerMoveBound, true);
      document.removeEventListener('pointerup', this.onPointerUpBound, true);
      // A tap opens the card — recentring moved to its own button, since
      // "show me who this is" is what a player reaches for far more
      // often than "move the camera".
      if (wasTap && this.character) {
        this.sheetOpen = !this.sheetOpen;
      }
    },
    center() {
      this.sheetOpen = false;
      this.$root.$emit('map:centerToCharacter', this.character);
    },
    unselect() {
      this.sheetOpen = false;
      this.$store.dispatch('game/unselectCharacter');
    },
  },
  created() {
    this.onPointerMoveBound = this.onPointerMove.bind(this);
    this.onPointerUpBound = this.onPointerUp.bind(this);
  },
  beforeDestroy() {
    document.removeEventListener('pointermove', this.onPointerMoveBound, true);
    document.removeEventListener('pointerup', this.onPointerUpBound, true);
  },
  components: { AgentDetailPair },
};
</script>
