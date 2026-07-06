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
          v-tooltip="{ content: queueTooltip }">
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
    // characters of other factions present on this system/dominion. The
    // backend already removes still-undercover enemy Erased and nulls the
    // cover field (Instance.Player.StellarSystem.visible_characters); the
    // numeric cover check below only still matters for player snapshots
    // taken before that filtering shipped, where undercover spies (with
    // their cover values) could linger until the next system update.
    foreignAgents() {
      const player = this.$store.state.game.player;
      const characters = Array.isArray(this.system.characters) ? this.system.characters : [];
      if (characters.length === 0 || !player || !player.faction_id) return [];

      const constants = (this.$store.state.game.data.constant || [])[0] || {};
      const factions = this.$store.state.game.data.faction || [];
      const coverThreshold = typeof constants.cover_threshold === 'number' ? constants.cover_threshold : 0;

      return characters
        .filter((c) => c && c.owner && c.owner.faction_id !== player.faction_id)
        .filter((c) => !(c.type === 'spy' && typeof c.cover === 'number' && c.cover >= coverThreshold))
        .map((c) => {
          const faction = factions.find((f) => f.key === c.owner.faction);
          return { ...c, color: faction ? faction.color : '#cccccc' };
        });
    },
    agentsTooltip() {
      const countByFaction = this.foreignAgents.reduce((acc, c) => {
        acc[c.owner.faction] = (acc[c.owner.faction] || 0) + 1;
        return acc;
      }, {});

      return Object.keys(countByFaction)
        .map((key) => this.$tc('card.closed_system.foreign_agents', countByFaction[key], {
          n: countByFaction[key],
          faction: this.$t(`data.faction.${key}.name`),
        }))
        .join('<br>');
    },
  },
  methods: {
    select() {
      this.$emit('select', this.system);
    },
    // async on purpose: v-tooltip evaluates plain content once and then
    // reuses the cached tooltip node, but thenable content is re-evaluated
    // on every show — so each hover recomputes the countdown.
    async queueTooltip() {
      const t = this.system.queue_remaining_time;
      if (typeof t !== 'number' || t <= 0) {
        return this.$t('card.closed_system.construction_queue');
      }

      // queue_remaining_time is a snapshot in game ticks, refreshed only
      // when the server re-broadcasts the player (queue events). Convert to
      // seconds and subtract the wall-clock time elapsed since the snapshot
      // arrived — while the game clock is running, game time tracks it 1:1.
      let seconds = t * this.tickToSecondFactor;
      const receivedAt = this.$store.state.game.player.receivedAt;
      if (typeof receivedAt === 'number' && this.$store.state.game.time.is_running) {
        seconds -= (Date.now() - receivedAt) / 1000;
      }

      if (seconds <= 0) {
        return this.$t('card.closed_system.construction_queue');
      }
      return formatDuration(seconds, (key, params) => this.$t(key, params));
    },
  },
};
</script>
