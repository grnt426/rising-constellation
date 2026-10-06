<template>
  <button
    type="button"
    class="chat-ref chat-ref-mention"
    :class="{ 'is-me': isMe, 'is-unknown': !member }"
    v-tooltip="tooltip"
    @click.stop="onClick">
    <span class="chat-ref-label">@{{ displayLabel }}</span>
  </button>
</template>

<script>
import { navigateRef } from '../refNavigation';

/**
 * Renders a `[[at:42|Name]]` mention in a chat message body.
 *
 * The name shown is the member's own, looked up by id: the label in the
 * token is only what the sender's client wrote, and is used when the id
 * no longer belongs to anyone in the faction. A mention of the reader
 * stands out (`is-me`). Click opens the player's card.
 */
export default {
  name: 'chat-ref-mention',
  props: {
    id: { type: String, required: true },
    label: { type: String, default: null },
  },
  computed: {
    playerId() {
      const n = parseInt(this.id, 10);
      return Number.isFinite(n) ? n : null;
    },
    member() {
      const players = this.$store.state.game.faction.players || [];
      return players.find((p) => p.id === this.playerId) || null;
    },
    isMe() {
      return this.playerId !== null && this.playerId === this.$store.state.game.player.id;
    },
    displayLabel() {
      if (this.member && this.member.name) return this.member.name;
      return this.label || '?';
    },
    tooltip() {
      if (!this.member) return this.$t('in_game_chat.ref.unknown_player');
      return this.isMe ? this.$t('in_game_chat.ref.mention_you') : '';
    },
  },
  methods: {
    onClick() {
      if (this.member) navigateRef(this, 'at', this.id);
    },
  },
};
</script>
