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
          class="msv-dock-dismiss"
          @click="$emit('close')">
          <svgicon name="close" />
        </button>
      </div>

      <div
        v-if="detail"
        class="msv-agent-dock-body">
        <div class="msv-agent-dock-card">
          <character-card
            :key="`dock-${detail.id}`"
            :character="detail"
            :theme="theme"
            noAction />
        </div>

        <!-- A Navarch's fleet is the thing you actually want to read
             before ordering anything; spies and speakers get their own
             equivalents. -->
        <div
          v-if="detail.status === 'on_board'"
          class="msv-agent-dock-aside">
          <army
            v-if="detail.type === 'admiral' && detail.army"
            :theme="theme"
            valign="top"
            halign="right"
            context="display"
            :character="detail" />
          <spy
            v-else-if="detail.type === 'spy'"
            :character="detail" />
          <speaker
            v-else-if="detail.type === 'speaker'"
            :character="detail" />
        </div>
      </div>

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
import CharacterCard from '@/game/components/card/CharacterCard.vue';
import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

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
  },
  watch: {
    summary: {
      immediate: true,
      handler() { this.fetch(); },
    },
  },
  methods: {
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
  components: { CharacterCard, Army, Spy, Speaker },
};
</script>
