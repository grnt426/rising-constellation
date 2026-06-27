<template>
  <div
    class="card-container closed"
    :class="[`f-${theme}`, { 'is-under-attack': isUnderAttack }]"
    @click="select">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon :name="`stellar_system/${system.type}`" />
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          {{ system.name }}
        </div>
        <div
          v-if="system.queue > 0"
          class="title-actions"
          v-tooltip="queueTooltip">
          <div
            v-for="i in system.queue"
            :key="`build-${i}`"
            class="title-actions-item is-jump">
          </div>
        </div>
      </div>
      <div
        v-if="system.siege"
        v-tooltip.left="$t(`data.character_action_status.${system.siege.type}.name`)"
        class="card-header-toast active colored">
        <svgicon :name="`action/${system.siege.type}`" />
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';

export default {
  name: 'closed-system-card',
  mixins: [CardMixin],
  props: {
    system: Object,
  },
  computed: {
    isUnderAttack() {
      const list = this.$store.state.game.player.dominions_under_attack;
      return Array.isArray(list) && list.includes(this.system.id);
    },
    queueTooltip() {
      const base = this.$t('card.closed_system.construction_queue');
      const t = this.system.queue_remaining_time;
      if (typeof t !== 'number' || t <= 0) {
        return base;
      }
      return `${base} — ${this.$options.filters.counter(t)}`;
    },
  },
  methods: {
    select() {
      this.$emit('select', this.system);
    },
  },
};
</script>
