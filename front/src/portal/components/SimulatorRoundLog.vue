<template>
  <div class="simulator-round-log">
    <div
      v-for="(action, k) in round"
      :key="`action-${k}`">
      <template v-if="action.type === 'transfer' && action.data.target === 'field'">
        <strong :class="`theme-${getShip(action.source).theme}`">
          {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
          [{{ action.source.tile }}]
        </strong>
        {{ $t('panel.operations.fight_arrival') }}
      </template>

      <template v-else-if="action.type === 'transfer' && action.data.target === 'army'">
        <strong :class="`theme-${getShip(action.source).theme}`">
          {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
          [{{ action.source.tile }}]
        </strong>
        {{ $t('panel.operations.fight_leave') }}
      </template>

      <template v-else-if="action.type === 'destroyed'">
        <strong :class="`theme-${getShip(action.source).theme}`">
          {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
          [{{ action.source.tile }}]
        </strong>
        {{ $t('panel.operations.fight_destroyed') }}
      </template>

      <template v-else-if="action.type === 'escaping'">
        <strong :class="`theme-${getShip(action.source).theme}`">
          {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
          [{{ action.source.tile }}]
        </strong>
        {{ $t('panel.operations.fight_fly') }}
      </template>

      <template v-else-if="action.type === 'attack'">
        <strong :class="`theme-${getShip(action.source).theme}`">
          {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
          [{{ action.source.tile }}]
        </strong>
        {{ $t('panel.operations.fight_attacks', {attack_count: action.data.actions.length}) }}
        <strong :class="`theme-${getShip(action.data.target).theme}`">
          {{ $t(`data.ship.${getShip(action.data.target).key}.name`) }}
          [{{ action.data.target.tile }}]
        </strong>
        <span v-html="computeStrikes(action.data.actions)"></span>
      </template>

      <template v-else>
      </template>
    </div>
  </div>
</template>

<script>
// Renders one round's action list. Both the full Log tab and the Debug View
// reuse this; the ref-resolution (getShip) and strike-summary (computeStrikes)
// helpers are passed in from FightSimulator (Vue 2 binds methods to the vm, so
// they keep the parent's `this`).
export default {
  name: 'simulator-round-log',
  props: {
    round: {
      type: Array,
      default: () => [],
    },
    getShip: {
      type: Function,
      required: true,
    },
    computeStrikes: {
      type: Function,
      required: true,
    },
  },
};
</script>
