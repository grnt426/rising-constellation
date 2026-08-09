<template>
  <div class="navbar-container">
    <div class="navbar top">
      <div class="navbar-left">
        <div
          v-if="!isTutorial"
          class="navbar-main-button">
          <div class="navbar-main-button-toolbox">
            <div
              class="button"
              v-bind:class="{ 'active': isChatOpen }"
              @click="switchChat">
              <svgicon class="icon" name="chat" />
            </div>
          </div>

          <div
            @click="togglePanel('faction')"
            class="navbar-main-button-icon">
            <svgicon class="icon" :name="`faction/${faction.key}-small`" />
          </div>
        </div>

        <div
          v-if="!isTutorial"
          class="navbar-button-title"
          @click="toggleMiniPanel('victory')">
          {{ $t('navbar.topbar.victory_panel') }}
        </div>

        <div
          v-if="!isTutorial"
          class="navbar-button-title"
          @click="togglePanel('help')">
          {{ $t('navbar.topbar.help_panel') }}
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
      v-if="isDaily"
      v-tooltip.left="$t('navbar.topbar.daily_time_left')"
      class="daily-clock">
      <template v-if="dailyClock">
        <div><span class="num">{{ dailyClock.minutes }}</span> {{ $t('navbar.topbar.daily_minutes') }}</div>
        <div><span class="num">{{ dailyClock.seconds }}</span> {{ $t('navbar.topbar.daily_seconds') }}</div>
      </template>
      <div v-else>&mdash;</div>
    </div>

    <div
      class="victory-banner"
      v-if="victory.winner"
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

export default {
  name: 'topbar',
  data() {
    return {
      isChatOpen: false,
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
      this.isChatOpen = !this.isChatOpen;
      this.$root.$emit('changeChatState', this.isChatOpen);
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
          .to(this.$refs.miniPanelsContainer, { top: '52px', ease: Expo.easeOut, duration: 0.8 }, 0);
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
    this.$root.$on('openTopMiniPanel', (name) => { this.openMiniPanel(name); });
    this.$root.$on('closeTopMiniPanel', () => { this.closeMiniPanel(); });
    this.clockTimer = setInterval(() => { this.nowTick = Date.now(); }, 1000);
  },
  beforeDestroy() {
    if (this.clockTimer) { clearInterval(this.clockTimer); }
  },
  components: {
    Calendar,
    CharacterMarketMiniPanel,
    VictoryMiniPanel,
    MarketMiniPanel,
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
