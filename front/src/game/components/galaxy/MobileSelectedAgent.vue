<template>
  <!-- Phone replacement for the desktop selection panel: the selected
       agent minimizes into a draggable floating bubble. Tap jumps the
       map to them, double-tap opens their card and fleet, the corner ✕
       deselects, and it can be dragged anywhere. Map actions come from
       long-pressing a target system (MapActionRadial), or — for a
       string of moves — from the card's multi-move button: the card
       closes and every tap on a system queues a move there (map.js),
       until a double-tap, "done", or the card coming back up. -->
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
        class="bubble-close"
        @pointerdown.stop
        @click.stop="unselect">
        <svgicon name="close" />
      </button>

      <div
        v-if="showHint"
        class="bubble-hint">
        {{ $t('galaxy.system.mobile.agent_bubble_hint') }}
      </div>
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
          <!-- orders as the editable plan, beside the card; above it,
               the orders that take more than one tap on the map -->
          <agent-detail-pair
            :character="character"
            :theme="theme"
            plan>
            <div
              v-if="canOrder"
              slot="top"
              class="mas-bulk">
              <button
                class="mas-bulk-button"
                data-bulk="multi-move"
                @click="startMultiMove">
                <svgicon name="action/jump_alt" />
                <span>{{ $t('galaxy.system.mobile.multi_move') }}</span>
              </button>
            </div>
          </agent-detail-pair>
        </div>
      </div>
    </div>

    <!-- Says which mode the map's taps are in, and how to leave it. Only
         the button takes touches: the map under the text stays tappable. -->
    <div
      v-if="multiMove"
      class="mobile-multi-move-banner"
      data-multi-move-banner>
      <svgicon name="action/jump_alt" />
      <span class="mmb-text">{{ $t('galaxy.system.mobile.multi_move_banner') }}</span>
      <button
        class="mmb-done"
        @click="stopMultiMove">
        {{ $t('galaxy.system.mobile.multi_move_done') }}
      </button>
    </div>
  </div>
</template>

<script>
import AgentDetailPair from '@/game/components/card/AgentDetailPair.vue';

const DRAG_SLOP_PX = 8;
// A second tap inside this window is a double-tap. The first tap has
// already jumped the map by then — centring twice is a no-op, so there
// is no reason to make the common gesture wait for the rare one.
const DOUBLE_TAP_MS = 320;
// Shown once per device, beside the first agent ever selected.
const HINT_KEY = 'rc:agent-bubble-hint';

export default {
  name: 'mobile-selected-agent',
  data() {
    return {
      x: 12,
      y: Math.max(80, window.innerHeight - 160),
      sheetOpen: false,
      showHint: false,
      lastTapAt: 0,
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
    multiMove() { return this.$store.state.game.multiMove; },
    // An agent of the player's, out on the map, takes orders.
    canOrder() {
      const { character } = this;
      return !!character.actions
        && character.status === 'on_board'
        && !character.on_sold
        && !character.on_strike
        && !!character.owner
        && character.owner.id === this.$store.state.game.player.id;
    },
  },
  watch: {
    // The card coming back up ends multi-move: its taps are for reading
    // and editing the plan again.
    sheetOpen(open) {
      if (open) this.stopMultiMove();
    },
    // Deselecting (or selecting someone else) must not leave the
    // previous agent's card sitting over the map.
    character(next, prev) {
      if (!next || !prev || next.id !== prev.id) {
        this.sheetOpen = false;
        this.lastTapAt = 0;
      }
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
      if (!wasTap || !this.character) return;

      this.dismissHint();

      // While the card is up the bubble is just the way back out.
      if (this.sheetOpen) {
        this.sheetOpen = false;
        this.lastTapAt = 0;
        return;
      }

      const now = Date.now();
      if (now - this.lastTapAt < DOUBLE_TAP_MS) {
        this.lastTapAt = 0;
        this.sheetOpen = true;
        return;
      }

      this.lastTapAt = now;
      this.center();
    },
    center() {
      this.$root.$emit('map:centerToCharacter', this.character);
    },
    unselect() {
      this.sheetOpen = false;
      this.$store.dispatch('game/unselectCharacter');
    },
    // Back to the galaxy map, where every tap on a system now queues a
    // move (see map.js onMultiMoveTap).
    startMultiMove() {
      this.sheetOpen = false;
      if (this.$store.state.game.selectedSystem) this.$store.dispatch('game/closeSystem', this);
      this.$store.commit('game/setMultiMove', true);
    },
    stopMultiMove() {
      if (this.multiMove) this.$store.commit('game/setMultiMove', false);
    },
    // Spent on the first showing, not on the first tap: a hint that
    // timed out unread would otherwise come back on every selection,
    // forever.
    maybeHint() {
      try {
        if (window.localStorage.getItem(HINT_KEY) === '1') return;
        window.localStorage.setItem(HINT_KEY, '1');
      } catch (e) {
        return; // private mode / blocked site data: skip the hint
      }
      this.showHint = true;
      this.hintTimer = setTimeout(() => { this.showHint = false; }, 6000);
    },
    // Any tap on the bubble proves the point.
    dismissHint() {
      if (!this.showHint) return;
      clearTimeout(this.hintTimer);
      this.showHint = false;
    },
  },
  created() {
    this.onPointerMoveBound = this.onPointerMove.bind(this);
    this.onPointerUpBound = this.onPointerUp.bind(this);
  },
  mounted() {
    this.maybeHint();
  },
  beforeDestroy() {
    this.stopMultiMove();
    clearTimeout(this.hintTimer);
    document.removeEventListener('pointermove', this.onPointerMoveBound, true);
    document.removeEventListener('pointerup', this.onPointerUpBound, true);
  },
  components: { AgentDetailPair },
};
</script>
