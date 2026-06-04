<template>
  <div
    v-show="!mapOverlay"
    class="chat-container">
    <div class="chat-input-box">
      <chat-composer
        ref="composer"
        :placeholder="$t('in_game_chat.placeholder')"
        @submit="sendChatMessage" />
    </div>

    <div
      class="chat-messages"
      :class="`show-${visibleLinesCount}-lines`">
      <div
        v-for="(message, i) in reversedChat"
        :key="i"
        class="chat-message">
        <strong>{{ message.from }}</strong>
        <chat-message-body :raw="message.message" />
      </div>
    </div>
  </div>
</template>

<script>
import ChatComposer from './chat/ChatComposer.vue';
import ChatMessageBody from './chat/ChatMessageBody.vue';

export default {
  name: 'chat',
  components: {
    ChatComposer,
    ChatMessageBody,
  },
  computed: {
    mapOverlay() { return this.$store.state.game.mapOverlay; },
    faction() { return this.$store.state.game.faction; },
    player() { return this.$store.state.game.player; },
    // Drop messages from muted senders BEFORE reversing — the
    // `from_id` field is server-derived from the JWT-bound player_id
    // (per ChatMessage.new) so spoofing is not possible. Old messages
    // missing `from_id` fall through to the unmuted path; chat is
    // in-memory only and rebuilds on agent boot, so any such rows are
    // ephemeral.
    isChatMuted() { return this.$store.getters['portal/isChatMuted']; },
    reversedChat() {
      return this.faction.chat
        .filter((m) => !(m.from_id && this.isChatMuted(m.from_id)))
        .slice(0)
        .reverse();
    },
    visibleLinesCount() {
      return this.$store.state.game.selectedSystem
        ? 1 : 5;
    },
  },
  watch: {
    reversedChat() {
      this.$ambiance.sound('new-chat-message');
    },
  },
  methods: {
    sendChatMessage(message) {
      if (!message || message.length === 0) return;
      this.$socket.faction.push('push_chat_message', {
        from: this.player.name,
        message,
      }).receive('ok', () => {
        if (this.$refs.composer) this.$refs.composer.clear();
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
  },
};
</script>
