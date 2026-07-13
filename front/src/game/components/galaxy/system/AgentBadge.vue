<template>
  <div
    class="agent-badge"
    :class="`force-${theme}`">
    <div
      class="round-icon is-active has-hover"
      :class="{
        'has-border': isOwn,
        'has-circle': isSelected,
        'is-small': small,
        'is-big': isBesieger,
        'is-pulsing': isBesieger,
      }"
      @click="$emit('select', character)">
      <svgicon :name="`agent/${character.type}`" />
      <span class="number">
        {{ character.level }}
      </span>
    </div>

    <div
      class="agent-card"
      :class="{ 'is-flipped': flipped }">
      <div class="agent-card-name">{{ character.name }}</div>
      <div
        v-if="!isOwn"
        class="agent-card-owner"
        @click="openPlayer">
        {{ character.owner.name }}
      </div>
      <div
        v-if="!isOwn"
        class="agent-card-stats">
        <span v-tooltip="$t('card.character.determination')">
          <svgicon name="agent/determination" />
          {{ statValue(character.determination) }}
        </span>
        <span v-tooltip="$t('card.character.protection')">
          <svgicon name="agent/protection" />
          {{ statValue(character.protection) }}
        </span>
        <span
          v-if="character.cover !== null && character.cover !== undefined"
          v-tooltip="$t('galaxy.selection.view.undercover')">
          <svgicon name="agent/undercover" />
          {{ Math.round(character.cover) }}
        </span>
      </div>
    </div>

    <div
      v-if="actions.length > 0"
      class="toolbox-actions">
      <div
        v-for="action in actions"
        :key="`${character.id}-${action.name}-overview`"
        class="actions">
        <action-overview
          v-if="action.overview && hoveredAction === `${character.id}-${action.name}`"
          class="is-top-shifted"
          :theme="theme"
          :name="hoveredAction"
          :data="action.overview" />
      </div>
      <div
        v-for="action in actions"
        :key="`${character.id}-${action.name}-actions`"
        class="actions">
        <div
          v-if="action.status === 'available'"
          v-tooltip="action.tooltip"
          class="actions-item is-active has-hover"
          @click="doCharacterAction(action.icon)"
          @mouseover="hoveredAction = `${character.id}-${action.name}`"
          @mouseleave="hoveredAction = null">
          <svgicon :name="`action/${action.icon}_alt`" />
        </div>
        <div
          v-if="action.status === 'unavailable'"
          v-tooltip="action.reasons"
          class="actions-item is-disabled">
          <svgicon :name="`action/${action.icon}_alt`" />
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';

export default {
  name: 'agent-badge',
  props: {
    character: Object,
    actions: { type: Array, default: () => [] },
    theme: String,
    system: Object,
    isBesieger: Boolean,
    small: Boolean,
    flipped: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
    };
  },
  computed: {
    player() { return this.$store.state.game.player; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    isOwn() { return this.character.owner.id === this.player.id; },
    isSelected() { return this.selectedCharacter && this.selectedCharacter.id === this.character.id; },
  },
  methods: {
    statValue(value) {
      return value === null || value === undefined ? '?' : value;
    },
    doCharacterAction(action) {
      this.hoveredAction = null;
      this.$root.$emit('map:addAction', action, { character: this.character.id, system: this.system });
    },
    openPlayer() {
      this.$store.dispatch('game/openPlayer', { vm: this, id: this.character.owner.id });
    },
  },
  components: {
    ActionOverview,
  },
};
</script>
