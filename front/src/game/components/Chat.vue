<template>
  <div
    v-show="!mapOverlay"
    class="chat-container"
    :class="{ 'is-pinned': pinned, 'is-compact': visibleLinesCount === 1 }"
    :style="{ '--chat-max': chatMaxHeight }"
    @mouseleave="onLeave">
    <div class="chat-input-box">
      <chat-composer
        ref="composer"
        :placeholder="composerPlaceholder"
        @submit="sendChatMessage" />
    </div>

    <!-- Tabs sit under the composer, on top of the list they filter: the
         chat's top-left corner lies under the top bar's logo block, which
         would swallow clicks on the first tabs. -->
    <div
      class="chat-tabs"
      role="tablist"
      :aria-label="$t('in_game_chat.tabs_label')">
      <button
        v-for="tab in tabs"
        :key="tab.key"
        type="button"
        role="tab"
        class="chat-tab"
        :class="{ 'is-active': tab.key === activeTab, 'has-unread': tab.unread > 0 }"
        :aria-selected="tab.key === activeTab ? 'true' : 'false'"
        v-tooltip.bottom="tab.hint"
        @click="selectTab(tab.key)">
        <span class="chat-tab-label">{{ tab.label }}</span>
        <span
          v-if="tab.unread > 0"
          class="chat-tab-unread">{{ tab.unread > 9 ? '9+' : tab.unread }}</span>
      </button>
    </div>

    <div
      ref="messages"
      class="chat-messages"
      :class="`show-${visibleLinesCount}-lines`">
      <!-- Deploy notice: not a chat line — a banner pinned above the
           list, rendered straight from the RC.Deploy flag so it can't
           sink into the scroll-back and disappears when the flag
           clears (deploy finished or /cleardeploy). -->
      <div
        v-if="deployOngoing"
        key="deploy-banner"
        class="chat-message is-system is-deploy">
        <strong>SYSTEM</strong>
        <span class="chat-message-body">{{ $t('in_game_chat.deploy_ongoing') }}</span>
      </div>
      <div
        v-for="row in rows"
        :key="row.key"
        :data-message-id="row.id"
        class="chat-message"
        :class="row.classes">
        <span
          v-if="row.tag !== null"
          class="chat-channel-tag"
          :class="`is-${row.channel}`"
          v-tooltip="$t(`in_game_chat.tabs.${row.channel}`)">{{ row.tag }}</span>
        <strong>{{ row.from }}</strong>
        <span
          v-if="row.age"
          class="chat-message-age"
          :title="row.date">{{ row.age }}</span>
        <span
          v-if="row.verb"
          class="chat-message-verb">{{ row.verb }}</span>
        <chat-message-body :raw="row.message" />
        <span
          v-if="row.note"
          class="chat-message-note">{{ row.note }}</span>
      </div>
      <div
        v-if="rows.length === 0 && !deployOngoing"
        class="chat-empty">
        {{ $t(`in_game_chat.empty.${activeTab}`) }}
      </div>
    </div>
  </div>
</template>

<script>
import ChatComposer from './chat/ChatComposer.vue';
import ChatMessageBody from './chat/ChatMessageBody.vue';
import {
  CHANNELS, DEFAULT_CHANNEL, CHANNEL_TAGS, channelOf, claimOf, latestClaimIds, isLiveClaim, voteCountOf,
} from './chat/channels';

// Which tab the player left the chat on, and up to which message they
// have read each channel. Per browser on purpose: unread marks are about
// what THIS screen has shown, and a wiped store only costs a few badges.
const TAB_KEY = 'tf-chat-tab';
const readKey = (instanceId, factionId) => `tf-chat-read:${instanceId}:${factionId}`;

function loadJson(key, fallback) {
  try {
    const value = JSON.parse(window.localStorage.getItem(key));
    return value && typeof value === 'object' ? value : fallback;
  } catch (e) {
    return fallback;
  }
}

function save(key, value) {
  try {
    window.localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
  } catch (e) {
    // private mode / quota: unread marks just won't survive a reload
  }
}

export default {
  name: 'chat',
  components: {
    ChatComposer,
    ChatMessageBody,
  },
  data() {
    let activeTab = 'all';
    try {
      const stored = window.localStorage.getItem(TAB_KEY);
      if (stored === 'all' || CHANNELS.includes(stored)) activeTab = stored;
    } catch (e) {
      // keep the default
    }

    return {
      activeTab,
      // { channel: id of the newest message read there }
      lastRead: {},
      // Held open without the pointer over it: set when something else
      // (a claim flag on the map, a fresh sighting) points at a message.
      pinned: false,
      flashId: null,
      // Ticks the relative ages ("3h") forward.
      now: Date.now(),
    };
  },
  computed: {
    mapOverlay() { return this.$store.state.game.mapOverlay; },
    faction() { return this.$store.state.game.faction; },
    player() { return this.$store.state.game.player; },
    // Drop messages from muted senders first — the `from_id` field is
    // server-derived from the JWT-bound player_id (per ChatMessage.new)
    // so spoofing is not possible. A message with no `from_id` is a
    // server line and is never muted.
    isChatMuted() { return this.$store.getters['portal/isChatMuted']; },
    // RC.Deploy flag (portal:user:* join reply + broadcasts) — the same
    // state the Topbar headband and portal marquee render from.
    deployOngoing() { return this.$store.state.portal.deployOngoing === true; },
    // Oldest first, as the server keeps them.
    messages() {
      return (this.faction.chat || [])
        .filter((m) => !(m.from_id && this.isChatMuted(m.from_id)));
    },
    icons() { return this.faction.icons || []; },
    // The one claim post per system that a standing flag still backs.
    liveClaimIds() { return latestClaimIds(this.messages); },
    rows() {
      const inTab = this.activeTab === 'all'
        ? this.messages
        : this.messages.filter((m) => channelOf(m) === this.activeTab);

      // newest first: the composer sits above the list
      return inTab.slice(0).reverse().map((m, i) => this.toRow(m, i));
    },
    unread() {
      const counts = {};
      CHANNELS.forEach((c) => { counts[c] = 0; });

      this.messages.forEach((m) => {
        if (m.id == null || m.from_id === this.player.id) return;
        const channel = channelOf(m);
        if (m.id > (this.lastRead[channel] || 0)) counts[channel] += 1;
      });

      return counts;
    },
    tabs() {
      const total = CHANNELS.reduce((sum, c) => sum + this.unread[c], 0);

      return ['all', ...CHANNELS].map((key) => ({
        key,
        label: this.$t(`in_game_chat.tabs.${key}`),
        hint: this.$t(`in_game_chat.tabs_hint.${key}`),
        unread: key === 'all' ? total : this.unread[key],
      }));
    },
    // Where a message typed now goes. "All" is a view, not a channel.
    targetChannel() {
      return this.activeTab === 'all' ? DEFAULT_CHANNEL : this.activeTab;
    },
    composerPlaceholder() {
      return this.$t('in_game_chat.placeholder_channel', {
        channel: this.$t(`in_game_chat.tabs.${this.targetChannel}`),
      });
    },
    newestId() {
      return this.messages.reduce((max, m) => (m.id > max ? m.id : max), 0);
    },
    visibleLinesCount() {
      return this.$store.state.game.selectedSystem
        ? 1 : 5;
    },
    // Hover-expansion cap: the share of the between-navbars area the
    // systems list leaves free (its height cap is an account setting the
    // player drags on the list's grip), minus the tabs and the input box
    // above the messages. Floored at the 5-line rest height so an
    // aggressive list setting can never make hovering the chat shrink it.
    chatMaxHeight() {
      const systemsPct = this.$store.getters['portal/listHeightPct']('systems');
      const freeShare = (100 - systemsPct) / 100;
      return `max(110px, calc((100vh - 108px) * ${freeShare} - 86px))`;
    },
  },
  watch: {
    // A new line from someone else: chime, and count it read at once if
    // its channel is the one on screen.
    newestId(id, previous) {
      const fresh = this.messages.filter((m) => m.id > previous && m.from_id !== this.player.id);
      if (fresh.length > 0) this.$ambiance.sound('new-chat-message');
      if (this.activeTab !== 'all') this.markRead([this.activeTab]);
    },
    activeTab(tab) {
      save(TAB_KEY, tab);
      if (tab !== 'all') this.markRead([tab]);
    },
  },
  created() {
    this.lastRead = loadJson(this.readStorageKey(), {});
    if (this.activeTab !== 'all') this.markRead([this.activeTab]);
  },
  mounted() {
    this.rootHandlers = {
      'chat:showMessage': (id) => { this.showMessage(id); },
      'chat:showClaim': (systemId) => { this.showClaim(systemId); },
    };
    Object.keys(this.rootHandlers).forEach((name) => {
      this.$root.$on(name, this.rootHandlers[name]);
    });

    this.ageTimer = setInterval(() => { this.now = Date.now(); }, 30000);
    // The map swallows `mousedown` (pointerdown + preventDefault), so
    // listen to pointerdown, in capture phase, like the composer does.
    document.addEventListener('pointerdown', this.onDocumentPointerDown, true);
  },
  beforeDestroy() {
    Object.keys(this.rootHandlers).forEach((name) => {
      this.$root.$off(name, this.rootHandlers[name]);
    });
    clearInterval(this.ageTimer);
    clearTimeout(this.flashTimer);
    clearTimeout(this.showTimer);
    document.removeEventListener('pointerdown', this.onDocumentPointerDown, true);
  },
  methods: {
    readStorageKey() {
      const { instance, faction } = this.$store.state.game.auth;
      return readKey(instance, faction);
    },

    // Server-originated lines (cheat announcement, etc.): from_id is nil —
    // real senders always carry their JWT-bound profile id.
    isSystemMessage(message) {
      return !message.from_id && message.from === 'SYSTEM';
    },

    toRow(message, index) {
      const channel = channelOf(message);
      const claim = claimOf(message);
      const isSighting = !!(message.meta && message.meta.kind === 'sighting');
      const votes = voteCountOf(message);

      // A claim stands while its author's flag does. Anything else — the
      // flag was removed, replaced, or claimed again since — is history.
      const liveClaim = claim !== null
        && this.liveClaimIds.has(message.id)
        && isLiveClaim(message, this.icons);

      let verb = null;
      if (claim !== null) verb = this.$t(`in_game_chat.auto.${liveClaim ? 'claim' : 'claim_past'}`);
      if (isSighting) verb = this.$t('in_game_chat.auto.sighting');
      if (votes > 0) verb = this.$tc('in_game_chat.auto.vote', votes);

      return {
        // Rings restored from before message ids exist fall back to position.
        key: message.id != null ? `m-${message.id}` : `i-${index}`,
        id: message.id,
        // The game speaks for the government when a vote opens.
        from: votes > 0 ? this.$t('in_game_chat.government') : message.from,
        message: message.message,
        channel,
        // In the combined view every line keeps the tag column, empty
        // for General, so the names stay aligned.
        tag: this.activeTab === 'all' ? (CHANNEL_TAGS[channel] || '') : null,
        age: this.formatAge(message.timestamp),
        date: message.timestamp ? new Date(message.timestamp * 1000).toLocaleString() : '',
        verb,
        note: claim !== null && !liveClaim ? this.$t('in_game_chat.auto.claim_released') : null,
        classes: {
          // The amber SYSTEM look is for the game's own warnings (cheats,
          // deploys). A vote is faction business, in the faction's colour.
          'is-system': this.isSystemMessage(message) && votes === 0,
          'is-auto': claim !== null || isSighting || votes > 0,
          'is-stale': claim !== null && !liveClaim,
          'is-flash': message.id != null && message.id === this.flashId,
        },
      };
    },

    // Chat is read hours after it was written: every line says how old it is.
    formatAge(timestamp) {
      if (!timestamp) return '';
      const seconds = Math.max(0, Math.floor(this.now / 1000) - timestamp);
      if (seconds < 60) return this.$t('in_game_chat.age.now');
      if (seconds < 3600) return this.$t('in_game_chat.age.minutes', { n: Math.floor(seconds / 60) });
      if (seconds < 86400) return this.$t('in_game_chat.age.hours', { n: Math.floor(seconds / 3600) });
      return this.$t('in_game_chat.age.days', { n: Math.floor(seconds / 86400) });
    },

    selectTab(tab) {
      this.activeTab = tab;
      if (this.$refs.messages) this.$refs.messages.scrollTop = 0;
    },

    markRead(channels) {
      const next = { ...this.lastRead };
      let changed = false;

      this.messages.forEach((m) => {
        const channel = channelOf(m);
        if (m.id != null && channels.includes(channel) && m.id > (next[channel] || 0)) {
          next[channel] = m.id;
          changed = true;
        }
      });

      if (changed) {
        this.lastRead = next;
        save(this.readStorageKey(), next);
      }
    },

    // The pointer left the chat. On the All tab the whole feed was just
    // in front of the player, expanded: everything in it counts as read.
    onLeave() {
      this.pinned = false;
      if (this.activeTab === 'all') this.markRead(CHANNELS);
    },

    onDocumentPointerDown(e) {
      if (this.pinned && !this.$el.contains(e.target)) this.pinned = false;
    },

    // Open the chat on a given message: its channel's tab, the list held
    // open and scrolled to it, the line lit up for a moment.
    //
    // A report's reply names its message, and can land a beat before the
    // faction broadcast that carries the message itself: wait for it a
    // little before concluding it has left the history.
    showMessage(id, attempt = 0) {
      const message = this.messages.find((m) => m.id === id);

      if (!message) {
        clearTimeout(this.showTimer);

        if (attempt < 10) {
          this.showTimer = setTimeout(() => { this.showMessage(id, attempt + 1); }, 150);
        } else {
          this.$toasted.error(this.$t('in_game_chat.message_gone'));
        }

        return;
      }

      // phones keep the chat in a drawer
      this.$root.$emit('changeChatState', true);

      this.activeTab = channelOf(message);
      this.pinned = true;
      this.flashId = id;

      clearTimeout(this.flashTimer);
      this.flashTimer = setTimeout(() => { this.flashId = null; }, 2600);

      this.$nextTick(() => {
        const list = this.$refs.messages;
        const line = list && list.querySelector(`[data-message-id="${id}"]`);
        if (line) list.scrollTop = Math.max(0, line.offsetTop - list.clientHeight / 2);
      });
    },

    // From a claim flag on the map to the post that announced it.
    showClaim(systemId) {
      const claim = this.messages
        .slice(0)
        .reverse()
        .find((m) => claimOf(m) === systemId);

      if (claim) {
        this.showMessage(claim.id);
      } else {
        this.$toasted.error(this.$t('in_game_chat.claim_gone'));
      }
    },

    sendChatMessage(message) {
      if (!message || message.length === 0) return;
      this.$socket.faction.push('push_chat_message', {
        from: this.player.name,
        message,
        channel: this.targetChannel,
      }).receive('ok', () => {
        if (this.$refs.composer) this.$refs.composer.clear();
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
  },
};
</script>
