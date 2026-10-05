<template>
  <!-- The agent screen's fixed top third: the card of whichever agent
       the player last tapped, plus its fleet/network. The list below
       keeps only quick actions, so a tap that isn't a quick action
       always has somewhere useful to land. -->
  <div
    class="msv-dock msv-agent-dock"
    :class="{ 'is-active': !!summary }">
    <template v-if="summary">
      <div class="msv-dock-head">
        <span class="msv-dock-title">{{ summary.name }}</span>
        <span class="msv-dock-sub">{{ summary.owner.name }}</span>
        <button
          v-if="canReport"
          type="button"
          class="chat-report-button"
          @click="report">
          {{ $t('in_game_chat.sighting.report_agent') }}
        </button>
        <button
          class="msv-dock-dismiss"
          @click="$emit('close')">
          <svgicon name="close" />
        </button>
      </div>

      <agent-detail-pair
        v-if="detail"
        class="msv-agent-dock-body"
        :character="detail"
        :theme="theme"
        noAction />

      <div
        v-else
        class="msv-dock-hint">
        {{ $t('galaxy.system.mobile.agent_loading') }}
      </div>
    </template>

    <template v-else>
      <div class="msv-dock-head">
        <span class="msv-dock-title">{{ $t('navbar.bottombar.agents') }}</span>
      </div>
      <div class="msv-dock-hint">
        {{ $t('galaxy.system.mobile.agent_hint') }}
      </div>
    </template>
  </div>
</template>

<script>
import AgentDetailPair from '@/game/components/card/AgentDetailPair.vue';
import { canReportAgent, reportAgent } from '@/game/components/chat/reportSighting';

export default {
  name: 'mobile-agent-dock',
  props: {
    // The roster entry that was tapped. system.characters holds
    // SUMMARIES — no skills, no army, no bonus pipelines — so the card
    // is drawn from a fetched full character, not from this.
    summary: { type: Object, default: null },
  },
  data() {
    return {
      detail: null,
      // guards a reply that lands after the player tapped someone else
      pendingId: null,
    };
  },
  computed: {
    theme() {
      return this.summary
        ? this.$store.getters['game/themeByKey'](this.summary.owner.faction)
        : 'none';
    },
    isOwn() {
      return !!this.summary
        && this.summary.owner.id === this.$store.state.game.player.id;
    },
    // Another faction's agent in the open system: reportable to the
    // faction's Spotted chat channel (phones have no Shift+click).
    canReport() {
      return canReportAgent(this, this.summary) && !!this.$store.state.game.selectedSystem;
    },
  },
  watch: {
    summary: {
      immediate: true,
      handler() { this.fetch(); },
    },
  },
  methods: {
    report() {
      reportAgent(this, this.$store.state.game.selectedSystem.id, this.summary.id);
    },
    // Own agents come off the player channel (full detail); everyone
    // else off the faction channel, which returns the redacted view the
    // player is entitled to — the same split clickCharacter uses.
    fetch() {
      this.detail = null;
      if (!this.summary) {
        this.pendingId = null;
        return;
      }

      const id = this.summary.id;
      this.pendingId = id;

      const channel = this.isOwn ? this.$socket.player : this.$socket.faction;
      channel.push('get_character', { character_id: id })
        .receive('ok', ({ character }) => {
          if (this.pendingId !== id) return;
          this.detail = typeof character === 'object' ? character : null;
        })
        .receive('error', (data) => {
          if (this.pendingId !== id) return;
          this.$toastError(data.reason);
          this.$emit('close');
        });
    },
  },
  components: { AgentDetailPair },
};
</script>
