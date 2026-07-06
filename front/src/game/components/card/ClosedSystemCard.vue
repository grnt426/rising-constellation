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
          <span
            v-if="foreignAgents.length > 0"
            class="agent-dots"
            v-tooltip="{ content: agentsTooltip }">
            <span
              v-for="agent in foreignAgents"
              :key="`agent-${agent.id}`"
              class="agent-dot"
              :style="{ backgroundColor: agent.color, color: agent.color }">
            </span>
          </span>
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
import { formatDuration } from '@/utils/format';

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
    tickToSecondFactor() { return this.$store.getters['game/tickToSecondFactor']; },
    queueTooltip() {
      const base = this.$t('card.closed_system.construction_queue');
      const t = this.system.queue_remaining_time;
      if (typeof t !== 'number' || t <= 0) {
        return base;
      }
      // queue_remaining_time is in game ticks, not seconds
      const seconds = t * this.tickToSecondFactor;
      const duration = formatDuration(seconds, (key, params) => this.$t(key, params));
      return `${base} — ${this.$t('card.closed_system.queue_eta', { duration })}`;
    },
    // characters of other factions present on this system/dominion;
    // still-undercover enemy Erased are filtered out, mirroring the
    // backend's visibility rule (Instance.Character.Spy.undercover?)
    foreignAgents() {
      const player = this.$store.state.game.player;
      const characters = Array.isArray(this.system.characters) ? this.system.characters : [];
      if (characters.length === 0 || !player || !player.faction_id) return [];

      const constants = (this.$store.state.game.data.constant || [])[0] || {};
      const factions = this.$store.state.game.data.faction || [];
      // fail closed: without a known threshold treat every foreign Erased
      // as undercover rather than revealing one that should be hidden
      const coverThreshold = typeof constants.cover_threshold === 'number' ? constants.cover_threshold : 0;

      return characters
        .filter((c) => c && c.owner && c.owner.faction_id !== player.faction_id)
        .filter((c) => c.type !== 'spy' || (typeof c.cover === 'number' && c.cover < coverThreshold))
        .map((c) => {
          const faction = factions.find((f) => f.key === c.owner.faction);
          return { ...c, color: faction ? faction.color : '#cccccc' };
        });
    },
    agentsTooltip() {
      return this.foreignAgents
        .map((c) => {
          const type = this.$tc(`data.character.${c.type}.name`, 1);
          const faction = this.$t(`data.faction.${c.owner.faction}.name`);
          return `${this.$escape(c.name)} — ${type} (${faction})`;
        })
        .join('<br>');
    },
  },
  methods: {
    select() {
      this.$emit('select', this.system);
    },
  },
};
</script>
