<template>
  <div
    class="card-container closed"
    :class="[`f-${theme}`, { 'is-under-attack': isUnderAttack }]"
    role="button"
    tabindex="0"
    :aria-label="ariaLabel"
    @click="select"
    @keydown.enter.self.prevent="select"
    @keydown.space.self.prevent="select">
    <div
      class="card-header"
      aria-hidden="true">
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
          <span
            v-if="etaLabel"
            class="counter">
            {{ etaLabel }}
          </span>
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
import { foreignAgents } from '@/utils/foreign-agents';
import { formatDuration } from '@/utils/format';
import { formatWallTime } from '@/utils/wall-time';
import { queueEta } from '@/game/queue-eta';

export default {
  name: 'closed-system-card',
  mixins: [CardMixin],
  props: {
    system: Object,
  },
  data() {
    return {
      // Shown next to the queue pips: "4h 51min · 14:05" (time left, and
      // when the queue will be empty), kept current by refreshEta.
      etaLabel: '',
      etaFinish: '',
      etaPulse: undefined,
    };
  },
  computed: {
    isUnderAttack() {
      const list = this.$store.state.game.player.dominions_under_attack;
      return Array.isArray(list) && list.includes(this.system.id);
    },
    msPerUnit() { return this.$store.getters['game/tickToMilisecondFactor']; },
    // characters of other factions present on this system/dominion —
    // detection rules live in utils/foreign-agents.js, shared with the
    // systems list's "enemy agents detected" filter.
    foreignAgents() {
      const player = this.$store.state.game.player;
      const constants = (this.$store.state.game.data.constant || [])[0] || {};
      const factions = this.$store.state.game.data.faction || [];

      return foreignAgents(this.system, player, constants)
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
    // The card's icons and dots as one spoken line.
    ariaLabel() {
      const parts = [this.system.name];
      if (this.system.queue > 0) {
        parts.push(this.$tc('a11y.system.queue', this.system.queue, { n: this.system.queue }));
        // the finish time only: it holds still, where the time left would
        // rewrite the label every second
        if (this.etaFinish) {
          parts.push(this.$t('a11y.system.queue_done_at', { time: this.etaFinish }));
        }
      }
      if (this.system.siege) {
        parts.push(this.$t(`data.character_action_status.${this.system.siege.type}.name`));
      } else if (this.isUnderAttack) {
        parts.push(this.$t('a11y.system.under_attack'));
      }
      if (this.foreignAgents.length) {
        parts.push(this.agentsTooltip.split('<br>').join(', '));
      }
      return parts.join(', ');
    },
  },
  methods: {
    select() {
      this.$emit('select', this.system);
    },
    eta(now) {
      return queueEta(this.system, this.$store.state.game.time, this.msPerUnit, now);
    },
    duration(ms) {
      return formatDuration(ms / 1000, (key, params) => this.$t(key, params));
    },
    // Assigns only what changed, so the 1 s pulse re-renders a card when its
    // text moves (once a minute for most queues), not every second.
    refreshEta() {
      const now = Date.now();
      const eta = this.eta(now);
      let label = '';
      let finish = '';

      if (eta.state === 'running') {
        finish = formatWallTime(eta.finishAt, now, this.$i18n.locale);
        label = `${this.duration(eta.remainingMs)} · ${finish}`;
      } else if (eta.state === 'stalled') {
        label = this.$t('card.closed_system.queue_stalled');
      }

      if (label !== this.etaLabel) this.etaLabel = label;
      if (finish !== this.etaFinish) this.etaFinish = finish;
    },
    // async on purpose: v-tooltip evaluates plain content once and then
    // reuses the cached tooltip node, but thenable content is re-evaluated
    // on every show — so each hover recomputes the countdown.
    async queueTooltip() {
      const now = Date.now();
      const eta = this.eta(now);
      const count = this.$tc('a11y.system.queue', this.system.queue, { n: this.system.queue });

      if (eta.state === 'running') {
        const line = this.$t('card.closed_system.queue_eta', {
          duration: this.duration(eta.remainingMs),
          time: formatWallTime(eta.finishAt, now, this.$i18n.locale),
        });
        return `${line}<br>${count}`;
      }
      if (eta.state === 'stalled') {
        return `${this.$t('card.closed_system.queue_stalled_hint')}<br>${count}`;
      }
      return this.$t('card.closed_system.construction_queue');
    },
  },
  watch: {
    system: 'refreshEta',
    msPerUnit: 'refreshEta',
  },
  created() {
    this.refreshEta();
  },
  mounted() {
    this.etaPulse = setInterval(() => this.refreshEta(), 1000);
  },
  beforeDestroy() {
    clearInterval(this.etaPulse);
  },
};
</script>
