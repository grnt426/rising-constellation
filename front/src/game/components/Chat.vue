<template>
  <div
    v-show="visible"
    class="chat-container"
    :class="{
      'is-pinned': pinned,
      'is-compact': compact,
      'is-composing': composing,
      'is-resizing': resizing,
      'is-mention-pulse': pulsing,
    }"
    :style="boxStyle"
    @mouseenter="onEnter"
    @mouseleave="onLeave"
    @pointerdown="acknowledgeMentions">
    <!-- Oldest at the top, newest at the bottom, right above the composer.
         The box keeps the size the player gave it (corner grip); the list
         scrolls inside it and stays on the latest line unless the player
         scrolled back. -->
    <div class="chat-body">
      <div
        ref="messages"
        class="chat-messages"
        @scroll.passive="onScroll">
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
          v-if="rows.length === 0"
          class="chat-empty">
          {{ $t(`in_game_chat.empty.${activeTab}`) }}
        </div>
      </div>

      <!-- Lines that arrived while the player was reading further up. -->
      <button
        v-if="belowCount > 0"
        type="button"
        class="chat-jump"
        @click="jumpToLatest">
        {{ $t('in_game_chat.new_below', { n: belowCount }) }}
      </button>

      <!-- Deploy notice: not a chat line — a banner pinned under the
           list, rendered straight from the RC.Deploy flag so it can't
           sink into the scroll-back and disappears when the flag
           clears (deploy finished or /cleardeploy). -->
      <div
        v-if="deployOngoing"
        class="chat-message is-system is-deploy">
        <strong>SYSTEM</strong>
        <span class="chat-message-body">{{ $t('in_game_chat.deploy_ongoing') }}</span>
      </div>
    </div>

    <!-- Tabs sit right above the composer: the tab is also where a
         message typed now goes. (Not at the top of the box: its top-left
         corner lies under the top bar's logo block.) -->
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
        :class="{ 'is-active': tab.key === activeTab, 'has-unread': tab.unread > 0 || tab.mentioned }"
        :aria-selected="tab.key === activeTab ? 'true' : 'false'"
        v-tooltip.top="tab.hint"
        @click="selectTab(tab.key)">
        <span class="chat-tab-label">{{ tab.label }}</span>
        <span
          v-if="tab.mentioned"
          class="chat-tab-unread is-mention">@</span>
        <span
          v-else-if="tab.unread > 0"
          class="chat-tab-unread">{{ tab.unread > 9 ? '9+' : tab.unread }}</span>
      </button>
    </div>

    <div
      class="chat-input-box"
      @focusin="onComposerFocus"
      @focusout="composing = false">
      <chat-composer
        ref="composer"
        :placeholder="composerPlaceholder"
        :members="mentionable"
        @submit="sendChatMessage" />
    </div>

    <!-- Corner grip: drag to resize the box, arrow keys for the same,
         double-click for the default size. -->
    <div
      v-if="!isMobileView"
      class="chat-grip"
      role="separator"
      tabindex="0"
      aria-orientation="horizontal"
      :aria-label="$t('in_game_chat.resize_label')"
      :aria-valuenow="size.h"
      :aria-valuemin="minSize.h"
      :aria-valuetext="`${size.w} × ${size.h}`"
      v-tooltip="$t('in_game_chat.resize')"
      @pointerdown="onGripDown"
      @dblclick="resetSize"
      @keydown="onGripKey">
      <svgicon
        name="resize-grip"
        aria-hidden="true" />
    </div>
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import ChatComposer from './chat/ChatComposer.vue';
import ChatMessageBody from './chat/ChatMessageBody.vue';
import {
  CHANNELS, DEFAULT_CHANNEL, CHANNEL_TAGS, channelOf, claimOf, latestClaimIds, isLiveClaim,
} from './chat/channels';
import { mentionsPlayer } from './chat/mentions';

// Which tab the player left the chat on, and up to which message they
// have read each channel. Per browser on purpose: unread marks are about
// what THIS screen has shown, and a wiped store only costs a few badges.
const TAB_KEY = 'tf-chat-tab';
const readKey = (instanceId, factionId) => `tf-chat-read:${instanceId}:${factionId}`;
// Ids of the messages mentioning the player that they have already been
// shown (see acknowledgeMentions). Kept the same way, for the same reason.
const mentionKey = (instanceId, factionId) => `tf-chat-mentions:${instanceId}:${factionId}`;

// The size the player dragged the box to, in pixels. Per browser as
// well: a size picked on one screen is rarely the right one on another.
const SIZE_KEY = 'tf-chat-size';
const DEFAULT_SIZE = Object.freeze({ w: 300, h: 280 });
// Must mirror the min-width / min-height of .chat-container (chat.scss).
const MIN_SIZE = Object.freeze({ w: 260, h: 160 });
const MAX_WIDTH = 720;
// Must mirror $navbar-height in styles/game/variables.scss.
const NAVBAR_HEIGHT = 54;
// How far from the last line still counts as "reading the latest".
const STICK_SLACK = 24;

function loadSize() {
  const stored = loadJson(SIZE_KEY, {});
  const side = (value, fallback, min) => (Number.isFinite(value) ? Math.max(min, Math.round(value)) : fallback);

  return {
    w: Math.min(MAX_WIDTH, side(stored.w, DEFAULT_SIZE.w, MIN_SIZE.w)),
    h: side(stored.h, DEFAULT_SIZE.h, MIN_SIZE.h),
  };
}

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
  props: {
    // Whether the player has the chat open (the top bar's CHAT button).
    open: { type: Boolean, default: true },
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
      // Only matters with a system view open, where the chat rests as a
      // short strip: held open without the pointer over it, set when
      // something else (a claim flag on the map, a fresh sighting)
      // points at a message.
      pinned: false,
      // The composer has the keyboard: the strip stays open meanwhile.
      composing: false,
      flashId: null,
      // Ticks the relative ages ("3h") forward.
      now: Date.now(),
      size: loadSize(),
      minSize: MIN_SIZE,
      resizing: false,
      // Lines that came in under the fold while the player was scrolled up.
      belowCount: 0,
      // Ids of the mentions of the player they have acknowledged.
      ackedMentions: [],
      // One beat of the box's outline when a mention comes in.
      pulsing: false,
    };
  },
  computed: {
    mapOverlay() { return this.$store.state.game.mapOverlay; },
    isMobileView() { return viewport.isMobile; },
    // On screen: open, and not hidden behind a map overlay. Messages are
    // only ever counted as read while this holds.
    visible() { return this.open && !this.mapOverlay; },
    // With a system view open, the room under the top bar belongs to the
    // view's own panels: the chat rests as a strip of its latest lines
    // and opens to its full size under the pointer. (Phones keep the
    // chat in a drawer that the player opens on purpose.)
    compact() {
      return !this.isMobileView && !!this.$store.state.game.selectedSystem;
    },
    // Phones size the drawer from the stylesheet.
    boxStyle() {
      return this.isMobileView
        ? null
        : { width: `${this.size.w}px`, height: `${this.size.h}px` };
    },
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
    // Who the composer can mention: everyone else in the faction.
    mentionable() {
      return (this.faction.players || [])
        .filter((p) => p.id !== this.player.id)
        .map((p) => ({ id: p.id, name: p.name }));
    },
    // Somebody called on the player by name and the player has not been
    // shown it yet, oldest first. Unlike plain unread lines these are
    // flagged whether the chat is open or not: a line scrolling by in
    // an open chat is easy to miss, and this one was meant for them.
    pendingMentions() {
      return this.messages.filter((m) => m.id != null
        && mentionsPlayer(m, this.player.id)
        && !this.ackedMentions.includes(m.id));
    },
    pendingMentionIds() { return new Set(this.pendingMentions.map((m) => m.id)); },
    // The one claim post per system that a standing flag still backs.
    liveClaimIds() { return latestClaimIds(this.messages); },
    rows() {
      const inTab = this.activeTab === 'all'
        ? this.messages
        : this.messages.filter((m) => channelOf(m) === this.activeTab);

      return inTab.map((m, i) => this.toRow(m, i));
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
    totalUnread() {
      return CHANNELS.reduce((sum, c) => sum + this.unread[c], 0);
    },
    tabs() {
      return ['all', ...CHANNELS].map((key) => ({
        key,
        label: this.$t(`in_game_chat.tabs.${key}`),
        hint: this.$t(`in_game_chat.tabs_hint.${key}`),
        unread: key === 'all' ? this.totalUnread : this.unread[key],
        // a pending mention waits in this channel, and it is not the one on screen
        mentioned: key !== 'all' && key !== this.activeTab && this.activeTab !== 'all'
          && this.pendingMentions.some((m) => channelOf(m) === key),
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
  },
  watch: {
    // A new line: chime if it is someone else's, and count it read at
    // once if it landed in front of the player.
    newestId(id, previous) {
      const fresh = this.messages.filter((m) => m.id > previous);
      const others = fresh.filter((m) => m.from_id !== this.player.id);
      if (others.length > 0) this.$ambiance.sound('new-chat-message');
      if (others.some((m) => mentionsPlayer(m, this.player.id))) this.pulse();

      if (others.length < fresh.length) {
        // the player's own line: back to the latest, wherever they were
        this.stick = true;
      } else if (this.visible && !this.stick) {
        this.belowCount += others
          .filter((m) => this.activeTab === 'all' || channelOf(m) === this.activeTab)
          .length;
      }

      this.markSeen();
    },
    activeTab(tab) {
      save(TAB_KEY, tab);
      this.markSeen();
    },
    // Opening the chat (or coming back from a map overlay) shows the
    // latest lines, and what is on screen is read from then on.
    visible(visible) {
      if (!visible) {
        // a box that goes away under the pointer never says it left
        this.hovering = false;
        return;
      }
      this.stick = true;
      this.belowCount = 0;
      this.markSeen();
    },
    // The top bar's CHAT button wears this while the chat is closed.
    totalUnread: {
      immediate: true,
      handler(total) { this.$store.commit('game/updateChatUnread', total); },
    },
    // …and this, open or closed.
    pendingMentions: {
      immediate: true,
      handler(pending) { this.$store.commit('game/updateChatMentions', pending.length); },
    },
  },
  created() {
    // Where the list sits after a render (see syncScroll). Not reactive:
    // neither changes what is drawn.
    this.stick = true;
    this.focusId = null;

    // The pointer is over the chat: what is in view is being looked at.
    this.hovering = false;

    this.lastRead = loadJson(this.readStorageKey(), {});
    const acked = loadJson(this.mentionStorageKey(), []);
    this.ackedMentions = Array.isArray(acked) ? acked.filter(Number.isFinite) : [];
    this.markSeen();
  },
  mounted() {
    this.rootHandlers = {
      'chat:showMessage': (id) => { this.showMessage(id); },
      'chat:showClaim': (systemId) => { this.showClaim(systemId); },
      'chat:showMention': () => { this.showMention(); },
      // A reference dropped into the composer from elsewhere (a system,
      // a sighting): the composer has to be on screen to receive it.
      'chat:insertRef': () => { this.pinned = true; },
    };
    Object.keys(this.rootHandlers).forEach((name) => {
      this.$root.$on(name, this.rootHandlers[name]);
    });

    this.ageTimer = setInterval(() => { this.now = Date.now(); }, 30000);
    // The map swallows `mousedown` (pointerdown + preventDefault), so
    // listen to pointerdown, in capture phase, like the composer does.
    document.addEventListener('pointerdown', this.onDocumentPointerDown, true);

    // The list changes height without a render of ours (window resize,
    // the strip opening under the pointer): keep the latest line in view.
    if (typeof ResizeObserver !== 'undefined') {
      this.listObserver = new ResizeObserver(() => { this.syncScroll(); });
      this.listObserver.observe(this.$refs.messages);
    }

    this.syncScroll();
  },
  updated() {
    this.syncScroll();
    this.acknowledgeSeenMentions();
  },
  beforeDestroy() {
    Object.keys(this.rootHandlers).forEach((name) => {
      this.$root.$off(name, this.rootHandlers[name]);
    });
    clearInterval(this.ageTimer);
    clearTimeout(this.flashTimer);
    clearTimeout(this.showTimer);
    clearTimeout(this.sizeSaveTimer);
    clearTimeout(this.pulseTimer);
    this.teardownGripListeners();
    if (this.listObserver) this.listObserver.disconnect();
    document.removeEventListener('pointerdown', this.onDocumentPointerDown, true);
  },
  methods: {
    readStorageKey() {
      const { instance, faction } = this.$store.state.game.auth;
      return readKey(instance, faction);
    },

    mentionStorageKey() {
      const { instance, faction } = this.$store.state.game.auth;
      return mentionKey(instance, faction);
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

      // A claim stands while its author's flag does. Anything else — the
      // flag was removed, replaced, or claimed again since — is history.
      const liveClaim = claim !== null
        && this.liveClaimIds.has(message.id)
        && isLiveClaim(message, this.icons);

      let verb = null;
      if (claim !== null) verb = this.$t(`in_game_chat.auto.${liveClaim ? 'claim' : 'claim_past'}`);
      if (isSighting) verb = this.$t('in_game_chat.auto.sighting');

      return {
        // Rings restored from before message ids exist fall back to position.
        key: message.id != null ? `m-${message.id}` : `i-${index}`,
        id: message.id,
        from: message.from,
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
          // Calls on the player: marked for good, and lit until seen.
          'is-mention': mentionsPlayer(message, this.player.id),
          'is-mention-new': this.pendingMentionIds.has(message.id),
          'is-system': this.isSystemMessage(message),
          'is-auto': claim !== null || isSighting,
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
      this.jumpToLatest();
    },

    // What is in front of the player counts as read: the tab on screen,
    // or every channel on the All tab. Nothing is, while the chat is closed.
    markSeen() {
      if (!this.visible) return;
      this.markRead(this.activeTab === 'all' ? CHANNELS : [this.activeTab]);
    },

    // Runs after every render and every change of the list's height. The
    // list follows its last line (`stick`) until the player scrolls back,
    // and a message the chat was opened on (`focusId`) wins over both.
    syncScroll() {
      const list = this.$refs.messages;
      // hidden: positions mean nothing until it is back on screen
      if (!list || list.clientHeight === 0) return;

      if (this.focusId !== null) {
        const line = list.querySelector(`[data-message-id="${this.focusId}"]`);

        if (line) {
          list.scrollTop = Math.max(0, line.offsetTop - (list.clientHeight - line.offsetHeight) / 2);
          this.focusId = null;
          this.stick = this.isAtBottom(list);
          return;
        }
      }

      if (this.stick) list.scrollTop = list.scrollHeight;
    },

    isAtBottom(list) {
      return list.scrollHeight - list.scrollTop - list.clientHeight <= STICK_SLACK;
    },

    onScroll() {
      const list = this.$refs.messages;
      if (!list || list.clientHeight === 0) return;

      this.stick = this.isAtBottom(list);
      if (this.stick) this.belowCount = 0;
      this.acknowledgeSeenMentions();
    },

    // A mention just came in: one beat of the box's outline, and of the
    // top bar's bubble (which is all there is to see with the chat closed).
    pulse() {
      this.$root.$emit('chat:mentionPulse');

      clearTimeout(this.pulseTimer);
      this.pulsing = false;
      requestAnimationFrame(() => {
        this.pulsing = true;
        this.pulseTimer = setTimeout(() => { this.pulsing = false; }, 1500);
      });
    },

    // Mentions are acknowledged by id, in any order (the badge walks them
    // oldest first, scrolling can reach a newer one before). Ids that
    // have left the history are dropped: they can never come back.
    //
    // Called with nothing (a click or a tap anywhere in the chat, the
    // composer taking the keyboard), every pending mention is.
    acknowledgeMentions(ids) {
      const acknowledged = Array.isArray(ids) ? ids : this.pendingMentions.map((m) => m.id);
      if (acknowledged.length === 0) return;

      const oldest = this.messages.reduce((min, m) => (m.id != null && m.id < min ? m.id : min), Infinity);
      const next = [...new Set([...this.ackedMentions, ...acknowledged])].filter((id) => id >= oldest);

      this.ackedMentions = next;
      save(this.mentionStorageKey(), next);
    },

    // A pending mention whose line is in the list's viewable region,
    // while the pointer is over the chat. The pointer is what tells
    // "pulled into view and read" from "landed in view while the player
    // was looking at the map": with the list following its last line,
    // every mention lands in view.
    acknowledgeSeenMentions() {
      if (!this.hovering || !this.visible || this.pendingMentions.length === 0) return;

      const list = this.$refs.messages;
      if (!list || list.clientHeight === 0) return;
      const frame = list.getBoundingClientRect();

      const seen = this.pendingMentions.filter((m) => {
        const line = list.querySelector(`[data-message-id="${m.id}"]`);
        if (!line) return false;

        // at least one line of text of it, inside the frame
        const box = line.getBoundingClientRect();
        const shown = Math.min(box.bottom, frame.bottom) - Math.max(box.top, frame.top);
        return shown >= Math.min(box.height, 16);
      });

      if (seen.length > 0) this.acknowledgeMentions(seen.map((m) => m.id));
    },

    // From the top bar's bubble: to the oldest mention the player has
    // not seen, which that settles; the next click goes to the next one.
    showMention() {
      const [oldest] = this.pendingMentions;
      if (!oldest) return;

      this.showMessage(oldest.id, 0, true);
      this.acknowledgeMentions([oldest.id]);
    },

    onEnter() {
      this.hovering = true;
      this.acknowledgeSeenMentions();
    },

    onComposerFocus() {
      this.composing = true;
      this.acknowledgeMentions();
    },

    jumpToLatest() {
      this.stick = true;
      this.belowCount = 0;
      this.syncScroll();
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

    // The pointer left the chat. As a strip (system view open) it goes
    // back to showing its latest lines.
    onLeave() {
      this.hovering = false;
      this.pinned = false;
      if (this.compact) {
        this.stick = true;
        this.belowCount = 0;
      }
    },

    onDocumentPointerDown(e) {
      if (this.pinned && !this.$el.contains(e.target)) this.pinned = false;
    },

    // Keeps a size on screen: the stylesheet caps the box to the area
    // between the bars as well, so a stored size survives a small window.
    clampSize({ w, h }) {
      const maxW = Math.max(MIN_SIZE.w, Math.min(MAX_WIDTH, window.innerWidth - 10));
      const maxH = Math.max(MIN_SIZE.h, window.innerHeight - 2 * NAVBAR_HEIGHT - 10);

      return {
        w: Math.round(Math.min(maxW, Math.max(MIN_SIZE.w, w))),
        h: Math.round(Math.min(maxH, Math.max(MIN_SIZE.h, h))),
      };
    },

    onGripDown(event) {
      event.preventDefault();
      // Keep receiving pointer events when the drag leaves the window:
      // without capture, releasing outside strands the box mid-resize.
      if (event.target.setPointerCapture && event.pointerId != null) {
        event.target.setPointerCapture(event.pointerId);
      }
      clearTimeout(this.sizeSaveTimer);
      this.teardownGripListeners();

      // From the size on screen, which the stylesheet may have capped
      // below the stored one.
      const box = this.$el.getBoundingClientRect();
      const from = { x: event.clientX, y: event.clientY, w: box.width, h: box.height };
      this.resizing = true;

      this.onGripMove = (e) => {
        this.size = this.clampSize({
          w: from.w + (e.clientX - from.x),
          h: from.h + (e.clientY - from.y),
        });
      };
      this.onGripUp = () => {
        this.teardownGripListeners();
        this.resizing = false;
        save(SIZE_KEY, this.size);
      };

      window.addEventListener('pointermove', this.onGripMove);
      window.addEventListener('pointerup', this.onGripUp);
      window.addEventListener('pointercancel', this.onGripUp);
    },

    teardownGripListeners() {
      window.removeEventListener('pointermove', this.onGripMove);
      window.removeEventListener('pointerup', this.onGripUp);
      window.removeEventListener('pointercancel', this.onGripUp);
    },

    // Keyboard resize, 20px per press; saved after a pause so a held key
    // doesn't write on every repeat.
    onGripKey(event) {
      const step = {
        ArrowUp: { w: 0, h: -20 },
        ArrowDown: { w: 0, h: 20 },
        ArrowLeft: { w: -20, h: 0 },
        ArrowRight: { w: 20, h: 0 },
      }[event.key];
      if (!step) return;
      event.preventDefault();

      this.size = this.clampSize({ w: this.size.w + step.w, h: this.size.h + step.h });
      clearTimeout(this.sizeSaveTimer);
      this.sizeSaveTimer = setTimeout(() => { save(SIZE_KEY, this.size); }, 600);
    },

    resetSize() {
      this.size = { ...DEFAULT_SIZE };
      save(SIZE_KEY, this.size);
    },

    // Open the chat on a given message: its channel's tab, the list
    // scrolled to it, the line lit up for a moment.
    //
    // A report's reply names its message, and can land a beat before the
    // faction broadcast that carries the message itself: wait for it a
    // little before concluding it has left the history.
    //
    // `stayOnAll`: the All tab shows every channel, no need to leave it.
    showMessage(id, attempt = 0, stayOnAll = false) {
      const message = this.messages.find((m) => m.id === id);

      if (!message) {
        clearTimeout(this.showTimer);

        if (attempt < 10) {
          this.showTimer = setTimeout(() => { this.showMessage(id, attempt + 1, stayOnAll); }, 150);
        } else {
          this.$toasted.error(this.$t('in_game_chat.message_gone'));
        }

        return;
      }

      // it may be closed (the top bar's CHAT button, the drawer on phones)
      this.$root.$emit('changeChatState', true);

      if (!(stayOnAll && this.activeTab === 'all')) this.activeTab = channelOf(message);
      this.pinned = true;
      this.flashId = id;
      this.focusId = id;
      this.belowCount = 0;

      clearTimeout(this.flashTimer);
      this.flashTimer = setTimeout(() => { this.flashId = null; }, 2600);

      // in case none of the above changed anything that renders
      this.$nextTick(() => { this.syncScroll(); });
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
