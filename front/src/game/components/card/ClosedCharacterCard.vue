<template>
  <!-- Selectable agents are buttons for the keyboard; one spoken line
       (agentListLabel) stands in for the icons. -->
  <div
    class="card-container closed"
    :class="`f-${theme}`"
    :role="selectable ? 'button' : 'group'"
    :tabindex="selectable ? 0 : null"
    :aria-label="ariaLabel"
    @click="select"
    @keydown.enter.self.prevent="select"
    @keydown.space.self.prevent="select">
    <div
      class="card-header"
      aria-hidden="true">
      <div
        v-if="character.status === 'on_board' && character.type === 'admiral'"
        class="card-header-army">
        <div
          v-if="character.army_size"
          class="card-header-army-item is-faded"
          :style="{ height: `${character.army_size.planned / army_tile_count * 100}%` }"></div>
        <div
          v-if="character.army_size"
          class="card-header-army-item"
          :style="{ height: `${character.army_size.filled / army_tile_count * 100}%` }"></div>
      </div>
      <div
        v-if="character.status === 'on_board'
          && character.type === 'spy'
          && character.is_discovered"
        class="card-header-cover">
        <svgicon name="agent/discovered" />
      </div>
      <div class="card-header-icon">
        <svgicon :name="`agent/${character.type}`" />
        <span class="level">
          {{ character.level }}
        </span>
        <span
          v-show="group"
          class="group">
          {{ group }}
        </span>
        <span
          v-if="armadaSize"
          class="armada">
          <svgicon name="layers" />
        </span>
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          {{ character.name }}
        </div>
        <div
          v-if="actions.length"
          class="title-actions">
          <counter
            class="counter"
            v-if="character.actions && character.actions.queue[0].remaining_time !== 'unknown_yet'"
            :current="liveRemaining(character.actions.queue[0])" />
          <div
            v-for="(action, i) in actions"
            :key="`c${character.id}-a${i}`"
            :class="{
              'is-action': action !== 'jump',
              'is-big': action === 'jump' && i === 0
            }"
            class="title-actions-item is-jump"></div>
        </div>
        <div
          v-else-if="character.action_status === 'docking'"
          class="title-small">
          {{ $t(`data.character_action_status.${character.action_status}.name`) }}
        </div>
        <!-- in a school: where it stands, and the time left to settle in -->
        <div
          v-else-if="isStudent"
          class="title-small nowrap is-training">
          <counter
            v-if="settle"
            class="counter"
            :current="settle.remaining" />
          {{ trainingText }}
        </div>
      </div>
      <div
        v-if="isStudent"
        v-tooltip.left="trainingTooltip"
        class="card-header-toast is-training">
        <svgicon :name="`building/${school}`" />
      </div>
      <div
        v-if="character.status === 'on_board' && character.actions
          && character.actions.queue.length
          && character.actions.queue[0].type !== 'jump'"
        v-tooltip.left="$t(`data.character_action_status.${character.action_status}.name`)"
        class="card-header-toast active">
        <svgicon :name="`action/${character.actions.queue[0].type}`" />
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import Counter from '@/game/components/generic/Counter.vue';
import { liveRemaining } from '@/game/clock';
import { agentListLabel } from '@/game/a11y/describe';
import { schoolBuilding, settling, trainingStatus } from '@/game/training';

export default {
  name: 'closed-character-card',
  mixins: [CardMixin],
  props: {
    character: Object,
  },
  computed: {
    // On-board agents, governors and students open something when clicked.
    selectable() {
      return ['governor', 'on_board', 'student'].includes(this.character.status);
    },
    // Agent training (docs/agent-training.md)
    isStudent() { return this.character.status === 'student' && !!this.character.training; },
    school() { return schoolBuilding(this.character); },
    // settling in: recomputed with every copy of the roster or of the
    // clock; the counter runs by itself in between
    settle() {
      if (!this.isStudent) return null;
      const constant = this.$store.state.game.data.constant[0];
      return settling(this.character.training, constant, this.$store.state.game.time, this.speedFactor);
    },
    trainingText() { return trainingStatus(this, this.character); },
    trainingTooltip() {
      const building = this.$t(`data.building.${this.school}.name`);
      const hint = this.settle ? `. ${this.$t('galaxy.school.settling_hint')}` : '';
      return `${building}: ${this.trainingText}${hint}`;
    },
    ariaLabel() {
      return agentListLabel(this, this.character, { group: this.group, armadaSize: this.armadaSize });
    },
    army_tile_count() { return this.$store.state.game.data.constant[0].army_tile_count; },
    speedFactor() {
      return this.$store.getters['game/effectiveSpeedFactor'];
    },
    actions() {
      if (!this.character.actions) {
        return [];
      }

      const actions = this.character.actions.queue.map((action) => action.type);
      return actions.slice(0, 10);
    },
    group() {
      return Object.keys(this.$store.state.game.charactersGroup)
        .find((key) => this.$store.state.game.charactersGroup[key] === this.character.id);
    },
    armadaSize() {
      return this.character.armada && Array.isArray(this.character.armada.member_ids)
        ? this.character.armada.member_ids.length
        : 0;
    },
  },
  methods: {
    // The server only refreshes the player-snapshot remaining_time at
    // action :to_start / :to_finish — derive it from the server clock.
    liveRemaining(action) {
      return liveRemaining(action, this.$store.state.game.time, this.speedFactor);
    },
    select() {
      if (this.selectable) {
        this.$emit('select', this.character);
      }
    },
  },
  components: {
    Counter,
  },
};
</script>
