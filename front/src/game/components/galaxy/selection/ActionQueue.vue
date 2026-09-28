<template>
  <!-- An agent's orders, present and pending. Extracted from the desktop
       selection panel so the phone card surfaces (the chip's sheet and
       the system view's agent dock) show the same queue — that panel
       doesn't exist on a phone, which is why the orders had nowhere to
       appear. -->
  <div class="selection-actions">
    <div class="header">
      {{ $t('galaxy.selection.view.actions') }}
    </div>

    <span
      v-if="character.on_sold"
      class="action-toast">
      {{ $t('galaxy.selection.view.on_sold') }}
    </span>
    <span
      v-else-if="character.on_strike"
      class="action-toast">
      {{ $t('galaxy.selection.view.on_strike') }}
    </span>
    <span
      v-else-if="character.type === 'spy' && character.spy && character.spy.cover.value <= constant.cover_threshold"
      class="action-toast">
      {{ $t('galaxy.selection.view.spy_discovered') }}
    </span>

    <template v-else>
      <div>
        <span
          v-for="(action, i) in queue"
          :key="i"
          :class="{
            'faded': hoveredAction !== null && hoveredAction < i,
            'clickable': canClear && i > 0,
            'is-armed': armedIndex === i,
          }"
          class="action-item"
          v-tooltip="action.timestamp"
          @mouseenter="enterAction(i)"
          @mouseleave="leaveAction">
          <template v-if="i === 0 && action.remaining_time !== 'unknown_yet'">
            <circle-progress-value
              :current="action.total_time - liveRemaining(action)"
              :total="action.total_time"
              :increase="1"
              :size="20"
              :width="3"
              :theme="theme" />
            <svgicon :name="`action/${action.type}`" />
            <svgicon
              name="caret-right"
              class="action-caret" />
          </template>
          <template v-else>
            <svgicon
              :name="`action/${action.type}`"
              @click="clearAfter(i)" />
          </template>
        </span>
      </div>

      <div
        v-if="armedIndex !== null"
        class="action-cancel-hint">
        {{ $t('galaxy.selection.view.confirm_clear') }}
      </div>

      <template v-if="character.actions.queue.length === 0">
        <span
          v-if="character.type === 'admiral'
            && character.army
            && character.army.repair_coef.value > 0
            && !isArmyFullLife"
          class="action-toast">
          {{ $t('galaxy.selection.view.ongoing_repair_work') }}
        </span>
        <span
          v-else
          class="action-item">
        </span>
      </template>
    </template>
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

export default {
  name: 'agent-action-queue',
  props: {
    character: { type: Object, required: true },
    theme: { type: String, default: 'none' },
    // Only the owner may cancel; a foreign agent's queue is read-only
    // (and usually absent from the redacted payload entirely).
    canClear: { type: Boolean, default: false },
  },
  data() {
    return {
      hoveredAction: null,
      // Touch has no hover to preview what a click would drop, so
      // cancelling is a two-tap gesture there: the first tap arms the
      // entry (and fades everything it would remove), the second does it.
      armedIndex: null,
      armedTimer: null,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    constant() { return this.$store.state.game.data.constant[0]; },
    speed() { return this.$store.state.game.time.speed; },
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    tickToMilisecondFactor() { return this.$store.getters['game/tickToMilisecondFactor']; },
    shipsData() { return this.$store.state.game.data.ship; },
    isArmyFullLife() {
      if (this.character.type === 'admiral' && this.character.army) {
        return this.character.army.tiles.every((tile) => {
          if (tile.ship_status !== 'filled') {
            return true;
          }
          const shipData = this.shipsData.find((ship) => ship.key === tile.ship.key);
          const maxLife = shipData.unit_hull * shipData.unit_count;
          const currentLife = tile.ship.units.reduce((acc, unit) => unit.hull + acc, 0);

          return currentLife === maxLife;
        });
      }

      return false;
    },
    queue() {
      // ETAs are anchored to Date.now() (not character.receivedAt) so they
      // stay correct even when the player snapshot is stale — the server
      // only pushes :player_update on action :to_start / :to_finish, so
      // every other moment leaves a.remaining_time frozen at the value it
      // had when the snapshot was last refreshed.
      const now = Date.now();
      let cumulativeMs = 0;
      let unknown = false;

      return this.character.actions.queue.map((a) => {
        if (this.speed === 'fast') return a;

        if (a.remaining_time === 'unknown_yet') {
          a.timestamp = this.$t('galaxy.selection.view.unknown_action_time');
          unknown = true;
        } else if (unknown) {
          a.timestamp = this.$t('galaxy.selection.view.unknown_time');
        } else {
          cumulativeMs += this.liveRemaining(a) * this.tickToMilisecondFactor;
          const date = now + cumulativeMs;
          a.timestamp = this.$t('galaxy.selection.view.timestamp', { date: this.$options.filters['luxon-std'](date) });
        }

        return a;
      });
    },
  },
  methods: {
    // The server pushes :player_update only when an action starts or
    // finishes, so action.remaining_time in the player snapshot is
    // frozen between those events. action.started_at is reliable
    // (set once at start and never decremented), so derive remaining
    // time from elapsed monotonic time instead.
    liveRemaining(action) {
      if (typeof action.remaining_time !== 'number' || typeof action.total_time !== 'number') {
        return action.remaining_time;
      }
      const time = this.$store.state.game.time;
      if (action.started_at == null || time.now_monotonic == null || time.receivedAt == null) {
        return action.remaining_time;
      }
      const serverMonotonicNow = time.now_monotonic + (Date.now() - time.receivedAt);
      const elapsedUnits = ((serverMonotonicNow - action.started_at) * this.speedFactor) / 180000;
      return Math.max(0, action.total_time - elapsedUnits);
    },
    enterAction(i) {
      if (!this.canClear || this.isMobileView) return;
      this.hoveredAction = i;
    },
    leaveAction() {
      if (this.isMobileView) return;
      this.hoveredAction = null;
    },
    disarm() {
      clearTimeout(this.armedTimer);
      this.armedIndex = null;
      this.hoveredAction = null;
    },
    clearAfter(index) {
      if (!this.canClear || index <= 0) return;

      // Pointer: the hover preview already showed what goes, so one
      // click is enough, as it has always been on desktop.
      if (!this.isMobileView) {
        this.push(index);
        return;
      }

      if (this.armedIndex !== index) {
        this.armedIndex = index;
        this.hoveredAction = index - 1;
        clearTimeout(this.armedTimer);
        this.armedTimer = setTimeout(() => this.disarm(), 4000);
        return;
      }

      this.disarm();
      this.push(index);
    },
    push(index) {
      this.$socket.player.push('clear_character_actions', {
        character_id: this.character.id,
        index,
      }).receive('ok', () => {
        this.leaveAction();
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
  },
  beforeDestroy() {
    clearTimeout(this.armedTimer);
  },
  components: { CircleProgressValue },
};
</script>
