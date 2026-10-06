<template>
  <div class="navbar-container">
    <div class="navbar top">
      <div class="navbar-left">
        <div
          v-if="!isTutorial"
          class="navbar-main-button">
          <div
            @click="togglePanel('faction')"
            class="navbar-main-button-icon">
            <svgicon class="icon" :name="`faction/${faction.key}-small`" />
          </div>
        </div>

        <div
          v-if="!isTutorial"
          class="navbar-button-title"
          :class="{ 'is-icon-button': isMobileView }"
          v-tooltip="isMobileView ? $t('navbar.topbar.victory_panel') : ''"
          @click="toggleMiniPanel('victory')">
          <svgicon
            v-if="isMobileView"
            class="icon"
            name="victory" />
          <template v-else>
            {{ $t('navbar.topbar.victory_panel') }}
          </template>
        </div>

        <!-- Opens and closes the faction chat. While it is closed, the
             bubble counts what was said since; open, the chat's own tabs
             do the counting. A mention of the player (`@Name`) is flagged
             either way, and the button then leads to it first. -->
        <div
          v-if="!isTutorial"
          class="navbar-button-title has-bubble"
          :class="{ 'is-icon-button': isMobileView }"
          v-tooltip="isMobileView ? $t('navbar.topbar.chat_panel') : ''"
          @click="switchChat">
          <svgicon
            v-if="isMobileView"
            class="icon"
            name="chat" />
          <template v-else>
            {{ $t('navbar.topbar.chat_panel') }}
          </template>
          <span
            v-if="chatBubble"
            class="navbar-button-bubble"
            :class="{ 'is-mention': chatBubble.mention, 'is-pulsing': chatPulse }"
            :aria-label="chatBubble.title">
            {{ chatBubble.label }}
          </span>
        </div>

        <div
          v-if="!isTutorial"
          class="navbar-button-title"
          :class="{ 'is-icon-button': isMobileView }"
          v-tooltip="isMobileView ? $t('navbar.topbar.help_panel') : ''"
          @click="togglePanel('help')">
          <svgicon
            v-if="isMobileView"
            class="icon"
            name="marker/question" />
          <template v-else>
            {{ $t('navbar.topbar.help_panel') }}
          </template>
        </div>
      </div>

      <div class="navbar-center">
        <calendar @click.native="togglePanel('event')" />

        <div
          class="headband"
          v-if="player.is_bankrupt"
          v-tooltip.bottom="$t('navbar.topbar.bankrupt_tooltip')">
          {{ $t('navbar.topbar.bankrupt') }}
        </div>
        <div
          class="headband headband-deploy"
          v-if="$config.MODE && !time.is_running && deployOngoing">
          {{ $t('navbar.topbar.deploy_interruption') }}
        </div>
        <div
          class="headband"
          v-else-if="$config.MODE && !time.is_running">
          {{ $t('navbar.topbar.supervisor_paused') }}
        </div>
        <div
          class="headband"
          v-if="isDead">
          {{ $t('navbar.topbar.defeat') }}
        </div>
      </div>

      <div class="navbar-right">
        <!-- Phone: one consolidated market button (the panels cross-link
             to each other); desktop keeps the two labeled buttons. -->
        <div
          v-if="isMobileView"
          class="navbar-button-title is-icon-button"
          v-tooltip="$t('navbar.topbar.market_panel')"
          @click="toggleMiniPanel(isTutorial ? 'character-market' : 'market')">
          <svgicon class="icon" name="resource/credit" />
        </div>
        <template v-else>
          <div
            v-if="!isTutorial"
            class="navbar-button-title"
            @click="toggleMiniPanel('market')">
            {{ $t('navbar.topbar.market_panel') }}
          </div>
          <div
            class="navbar-button-title"
            @click="toggleMiniPanel('character-market')">
            {{ $t('navbar.topbar.character_market_panel') }}
          </div>
        </template>

        <div
          v-if="!isTutorial"
          class="navbar-main-button">
          <div
            @click="togglePanel('ranking')"
            class="navbar-main-button-icon">
            <svgicon class="icon" name="ranking" />
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="isDaily && !victory.winner && !dailyResult"
      v-tooltip.left="$t('navbar.topbar.daily_time_left')"
      class="daily-clock">
      <template v-if="dailyClock">
        <div><span class="num">{{ dailyClock.minutes }}</span> {{ $t('navbar.topbar.daily_minutes') }}</div>
        <div><span class="num">{{ dailyClock.seconds }}</span> {{ $t('navbar.topbar.daily_seconds') }}</div>
      </template>
      <div v-else>&mdash;</div>
    </div>

    <daily-result-banner v-if="isDaily && dailyResult" />

    <div
      class="victory-banner"
      v-if="victory.winner && !isDaily"
      :class="[
        {'open': victory.winner},
        theme(victory.winner),
      ]">
      <div class="victory-banner-background"></div>
      <div class="victory-banner-content">
        <svgicon class="icon" :name="`faction/${victory.winner}`" />
        <div class="name">
          {{ $t('navbar.topbar.victory_of') }}
        </div>
        <div class="name">
          {{ $t(`data.faction.${victory.winner}.name`) }}
        </div>
        <div class="action">
          <template v-if="victory.winner === faction.key">
            {{ $t('navbar.topbar.you_won') }}
          </template>
          <template v-else>
            {{ $t('navbar.topbar.you_lost') }}
          </template>
        </div>
        <!-- Rebel Defense: say which way the players-vs-AI match went. -->
        <div
          v-if="waveBotFaction"
          class="info">
          <template v-if="victory.winner === waveBotFaction">
            {{ $t('navbar.topbar.wave_rebellion_won') }}
          </template>
          <template v-else>
            {{ $t('navbar.topbar.wave_players_won') }}
          </template>
        </div>
      </div>
    </div>

    <div
      class="mini-panels-container"
      ref="miniPanelsContainer"
      @click.self="closeMiniPanel">
      <victory-mini-panel
        v-if="!isTutorial && activeMiniPanel.name === 'victory'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
      <market-mini-panel
        v-if="!isTutorial && activeMiniPanel.name === 'market'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
      <character-market-mini-panel
        v-if="activeMiniPanel.name === 'character-market'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import viewport from '@/utils/viewport';
import Calendar from '@/game/components/navbar/Calendar.vue';

import CharacterMarketMiniPanel from '@/game/components/mini-panel/CharacterMarketMiniPanel.vue';
import VictoryMiniPanel from '@/game/components/mini-panel/VictoryMiniPanel.vue';
import MarketMiniPanel from '@/game/components/mini-panel/MarketMiniPanel.vue';
import DailyResultBanner from '@/game/components/navbar/DailyResultBanner.vue';

export default {
  name: 'topbar',
  data() {
    return {
      // Same starting state as the chat itself (Game.vue): open on
      // desktop, a closed drawer on phones.
      isChatOpen: !viewport.isMobile,
      chatPulse: false,
      nowTick: Date.now(),

      activeMiniPanel: { name: '' },
      isMiniPanelOpen: false,
      miniPanels: [
        { name: 'character-market', height: 490 },
        { name: 'market', height: 468 },
        { name: 'victory', height: 440 },
      ],
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    time() { return this.$store.state.game.time; },
    // Deploy-related pause: the portal socket flips this before the game
    // socket drops, so the "Paused" headband can name the real cause.
    deployOngoing() { return this.$store.state.portal.deployOngoing; },
    isDead() { return this.$store.state.game.isDead; },
    faction() { return this.$store.state.game.faction; },
    victory() { return this.$store.state.game.victory; },
    player() { return this.$store.state.game.player; },
    isTutorial() { return this.$store.state.game.galaxy.tutorial_id; },
    isDaily() { return this.time.speed === 'daily'; },
    // Rebel Defense: the bot-run faction's key, null in other modes.
    waveBotFaction() { return this.$store.state.game.instanceInfo.wave_bot_faction || null; },
    dailyResult() { return this.$store.state.game.dailyResult; },
    // Lines of the faction chat nobody has put in front of the player
    // yet (counted by Chat.vue). Only shown while the chat is closed.
    chatUnread() { return this.$store.state.game.chatUnread; },
    // Messages calling on the player by name that they have not seen.
    // Shown whether the chat is open or not, and ahead of the plain count.
    chatMentions() { return this.$store.state.game.chatMentions; },
    chatBubble() {
      const cap = (n, max) => (n > max ? `${max}+` : String(n));

      if (this.chatMentions > 0) {
        return {
          mention: true,
          label: this.chatMentions > 1 ? `@${cap(this.chatMentions, 9)}` : '@',
          title: this.$t('navbar.topbar.chat_mentions', { n: this.chatMentions }),
        };
      }
      if (!this.isChatOpen && this.chatUnread > 0) {
        return {
          mention: false,
          label: cap(this.chatUnread, 99),
          title: this.$t('navbar.topbar.chat_unread', { n: this.chatUnread }),
        };
      }
      return null;
    },
    dailyClock() {
      const v = this.victory;
      if (!v || typeof v.ut_time_left !== 'number' || !v.receivedAt) { return null; }

      // :daily runs at factor 240 (Data.Game.Speed.Content). Game-time (unit-
      // time) advances at factor/180000 per ms, so 1 unit-time = 180000/240 =
      // 750 ms of real time. The victory broadcast (~every 15s) refreshes
      // ut_time_left; we count down to the derived deadline locally.
      const deadline = v.receivedAt + v.ut_time_left * 750;
      const remainingMs = Math.max(0, deadline - this.nowTick);
      const totalSec = Math.floor(remainingMs / 1000);

      return {
        minutes: Math.floor(totalSec / 60),
        seconds: (totalSec % 60).toString().padStart(2, '0'),
      };
    },
  },
  methods: {
    switchChat() {
      // A mention is waiting: the button goes to it (opening the chat if
      // need be) instead of toggling. Chat.vue settles it on the way.
      if (this.chatMentions > 0) {
        this.$root.$emit('chat:showMention');
        return;
      }

      this.isChatOpen = !this.isChatOpen;
      this.$root.$emit('changeChatState', this.isChatOpen);
    },
    // The chat can also be opened from elsewhere (a claim flag, a fresh
    // sighting): keep the button in step.
    onChatState(state) {
      this.isChatOpen = state;
    },
    // A mention just came in: one beat of the bubble.
    onMentionPulse() {
      clearTimeout(this.chatPulseTimer);
      this.chatPulse = false;
      requestAnimationFrame(() => {
        this.chatPulse = true;
        this.chatPulseTimer = setTimeout(() => { this.chatPulse = false; }, 1500);
      });
    },
    togglePanel(name) {
      this.$root.$emit('togglePanel', name);
    },
    toggleMiniPanel(name) {
      if (this.isMiniPanelOpen && this.activeMiniPanel.name === name) {
        this.closeMiniPanel();
      } else {
        this.openMiniPanel(name);
      }
    },
    openMiniPanel(name) {
      this.$root.$emit('closePanel');
      this.$root.$emit('closeBottomMiniPanel');

      this.animateCloseMiniPanelContainer().then(() => {
        this.animateOpenMiniPanelContainer(name);
      });
    },
    closeMiniPanel() {
      this.animateCloseMiniPanelContainer().then(() => {
        this.isMiniPanelOpen = false;
        this.activeMiniPanel = { name: '' };
      });
    },
    animateOpenMiniPanelContainer(name) {
      return new Promise((resolve) => {
        this.$ambiance.sound('mini-panel-open');

        this.$refs.miniPanelsContainer.style.display = 'flex';
        this.activeMiniPanel = this.miniPanels.find((p) => p.name === name);
        this.isMiniPanelOpen = true;

        new TimelineLite({
          onComplete() { resolve(); },
        }).set(this.$refs.miniPanelsContainer, { top: `-${this.activeMiniPanel.height}px` })
          .to(this.$refs.miniPanelsContainer, {
            // the mobile top bar is 40px tall, the desktop one 52px
            top: this.isMobileView ? '40px' : '52px',
            ease: Expo.easeOut,
            duration: 0.8,
          }, 0);
      });
    },
    animateCloseMiniPanelContainer() {
      if (!this.isMiniPanelOpen) {
        return Promise.resolve();
      }

      return new Promise((resolve) => {
        this.$ambiance.sound('mini-panel-close');

        const self = this;

        if (!this.isMiniPanelOpen) {
          resolve();
        } else {
          const position = `-${this.activeMiniPanel.height}px`;

          new TimelineLite({
            onComplete() {
              self.$refs.miniPanelsContainer.style.display = 'none';
              resolve();
            },
          }).to(this.$refs.miniPanelsContainer, { top: position, ease: Expo.linear, duration: 0.4 }, 0);
        }
      });
    },
    theme(factionKey) {
      return factionKey
        ? `f-${this.$store.getters['game/themeByKey'](factionKey)}`
        : 'null';
    },
  },
  mounted() {
    // Bound refs so beforeDestroy can $off — $root outlives this
    // component, so anonymous closures stack across game re-entries.
    this.onOpenMiniPanel = (name) => { this.openMiniPanel(name); };
    this.onCloseMiniPanel = () => { this.closeMiniPanel(); };
    this.$root.$on('openTopMiniPanel', this.onOpenMiniPanel);
    this.$root.$on('closeTopMiniPanel', this.onCloseMiniPanel);
    this.$root.$on('changeChatState', this.onChatState);
    this.$root.$on('chat:mentionPulse', this.onMentionPulse);
    this.clockTimer = setInterval(() => { this.nowTick = Date.now(); }, 1000);
  },
  beforeDestroy() {
    if (this.clockTimer) { clearInterval(this.clockTimer); }
    this.$root.$off('openTopMiniPanel', this.onOpenMiniPanel);
    this.$root.$off('closeTopMiniPanel', this.onCloseMiniPanel);
    this.$root.$off('changeChatState', this.onChatState);
    this.$root.$off('chat:mentionPulse', this.onMentionPulse);
    clearTimeout(this.chatPulseTimer);
  },
  components: {
    Calendar,
    CharacterMarketMiniPanel,
    VictoryMiniPanel,
    MarketMiniPanel,
    DailyResultBanner,
  },
};
</script>

<style scoped>
.daily-clock {
  position: fixed;
  top: 92px;
  right: 16px;
  z-index: 5;
  text-align: right;
  color: rgba(255, 255, 255, 0.85);
  font-size: 1rem;
  line-height: 1.25;
  letter-spacing: 0.04em;
  text-shadow: 0 0 6px rgba(0, 0, 0, 0.6);
  pointer-events: none;
}
.daily-clock .num {
  font-size: 1.5rem;
  font-variant-numeric: tabular-nums;
}
</style>
