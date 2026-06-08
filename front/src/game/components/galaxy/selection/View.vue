<template>
  <div
    :class="`f-${theme}`"
    ref="container"
    class="selection-view-container">
    <div class="selection-view">
      <div class="selection-view-content">
        <div class="selection-status">
          <div
            class="selection-status-info"
            v-html="$tmd('galaxy.selection.view.state', {state: $t(`data.character_action_status.${this.character.action_status}.name`)})" />
          <div class="selection-status-actions">
            <svgicon
              name="disc"
              v-tooltip="$t('galaxy.selection.view.action_center')"
              @click="centerToPosition" />
            <svgicon
              name="drag"
              v-if="isIdleAndAtHome && !character.on_sold"
              v-tooltip="$t('galaxy.selection.view.action_recall')"
              @click="deactivate" />
            <svgicon
              name="drag"
              class="disabled"
              v-else
              v-tooltip="$t('galaxy.selection.view.action_disabled')" />
          </div>
        </div>

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
            v-else-if="character.type === 'spy' && character.spy.cover.value <= constant.cover_threshold"
            class="action-toast">
            {{ $t('galaxy.selection.view.spy_discovered') }}
          </span>

          <template v-else>
            <div>
              <span
                v-for="(action, i) in queue"
                :key="i"
                :class="{
                  'faded': hoveredAction < i,
                  'clickable': i > 0,
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

            <template v-if="character.actions.queue.length === 0">
              <span
                v-if="character.type === 'admiral'
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

        <div class="selection-data">
          <army
            v-if="character.type === 'admiral'"
            :theme="theme"
            :context="'selection'"
            :character="character"
            :isIdleAndAtHome="isIdleAndAtHome" />

          <spy
            v-if="character.type === 'spy'"
            :character="character" />

          <speaker
            v-if="character.type === 'speaker'"
            :character="character" />
        </div>
      </div>

      <div class="selection-view-character">
        <character-card
          :closeable="true"
          :open="true"
          :character="character"
          :theme="theme"
          :lock="true" />
      </div>

      <div
        @click="close"
        class="selection-close">
        ×
      </div>
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import CharacterCard from '@/game/components/card/CharacterCard.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

export default {
  name: 'selection-view',
  data() {
    return {
      hoveredAction: undefined,
    };
  },
  computed: {
    constant() { return this.$store.state.game.data.constant[0]; },
    speed() { return this.$store.state.game.time.speed; },
    speedFactor() {
      return this.$store.state.game.data.speed.find((s) => s.key === this.speed).factor;
    },
    tickToMilisecondFactor() { return this.$store.getters['game/tickToMilisecondFactor']; },
    theme() { return this.$store.getters['game/theme']; },
    character() { return this.$store.state.game.selectedCharacter; },
    playerCharacters() { return this.$store.state.game.player.characters; },
    shipsData() { return this.$store.state.game.data.ship; },
    isAtHome() {
      return (!!this.$store.state.game.player.stellar_systems.find((s) => s.id === this.character.system)
        || !!this.$store.state.game.player.dominions.find((d) => d.id === this.character.system));
    },
    isIdleAndAtHome() {
      if (this.character.type === 'spy' && this.character.spy.cover.value <= this.constant.cover_threshold) {
        return false;
      }

      if (this.character.type === 'speaker' && this.character.speaker && this.character.speaker.cooldown.value > 0) {
        return false;
      }

      return ['idle', 'docking'].includes(this.character.action_status) && this.isAtHome;
    },
    isArmyFullLife() {
      if (this.character.type === 'admiral') {
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
  watch: {
    playerCharacters(characters) {
      const own = characters.find((c) => c.id === this.character.id);

      if (!own) {
        this.$store.dispatch('game/unselectCharacter');
      }
    },
  },
  methods: {
    // The server pushes :player_update only when an action starts or
    // finishes, so action.remaining_time in the player snapshot is
    // frozen between those events. action.started_at is reliable
    // (set once at start and never decremented), so derive remaining
    // time from elapsed monotonic time instead.
    //
    // Computed inline rather than via a Vuex getter because Date.now()
    // isn't a reactive dep: a getter would cache its first value and
    // never refresh (state.time only changes on global :start / :stop
    // broadcasts, which are rare).
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
    close() {
      this.$store.dispatch('game/unselectCharacter');
    },
    centerToPosition() {
      this.$root.$emit('map:centerToCharacter', this.character);
    },
    clearAfter(index) {
      if (index > 0) {
        this.$socket.player.push('clear_character_actions', {
          character_id: this.character.id,
          index,
        }).receive('ok', () => {
          this.leaveAction();
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
    deactivate() {
      if (this.isIdleAndAtHome) {
        const characterId = this.character.id;

        this.$store.dispatch('game/unselectCharacter');
        this.$socket.player.push('deactivate_character', {
          character_id: characterId,
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
    enterAction(index) {
      if (index > 0) {
        this.hoveredAction = index;
      }
    },
    leaveAction() {
      this.hoveredAction = undefined;
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { right: -500, opacity: 0 })
      .to(this.$refs.container, { right: 0, opacity: 1, ease: Expo.easeOut, duration: 1 }, 0);
  },
  components: {
    CharacterCard,
    CircleProgressValue,
    Army,
    Spy,
    Speaker,
  },
};
</script>
