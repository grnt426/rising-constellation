<template>
  <div class="game-context">
    <div
      :class="`theme-${theme}`"
      v-shortkey="{
        escape: ['esc'],
        firstSystem: ['home'],
        nextSystem: ['.'],
        nextAgent: [','],
        centerToCharacter: ['space'],
        copy: ['c'],
        patent: ['p'],
        doctrine: ['l'],
        'character-market': ['m'],
        ranking: ['r'],
        victory: ['v'],
        faction: ['o'],
        empire: ['s'],
        operations: ['a'],
        search: ['f'],
        help: ['h'],
        selectGroup1: ['1'],
        createGroup1: ['ctrl', '1'],
        selectGroup2: ['2'],
        createGroup2: ['ctrl', '2'],
        selectGroup3: ['3'],
        createGroup3: ['ctrl', '3'],
        selectGroup4: ['4'],
        createGroup4: ['ctrl', '4'],
        selectGroup5: ['5'],
        createGroup5: ['ctrl', '5'],
        selectGroup6: ['6'],
        createGroup6: ['ctrl', '6'],
        selectGroup7: ['7'],
        createGroup7: ['ctrl', '7'],
        selectGroup8: ['8'],
        createGroup8: ['ctrl', '8'],
        selectGroup9: ['9'],
        createGroup9: ['ctrl', '9'],
      }"
      @shortkey="onShortkey">
      <settings
        v-show="isSettingsOpen"
        @close="isSettingsOpen = !isSettingsOpen" />
      <div
        v-if="showSplash"
        ref="spsMain"
        class="splashscreen">
        <div class="container">
          <div ref="spsLogo" class="logo">
            <img src="~public/logo/large-v-white.png" alt="Rising Constellation" />
          </div>
          <div ref="spsQuote" class="content">
            <blockquote class="typing">
            </blockquote>
          </div>
        </div>
      </div>

      <div
        class="game-container"
        v-if="connected">
        <topbar ref="topbar" />

        <chat v-show="!isTutorial && isChatOpen" />
        <notification-center />
        <search-overlay v-if="!isTutorial" />
        <tutorial v-if="isTutorial" />
        <opened-character />
        <opened-player />

        <galaxy-container />
        <universe-map :data="mapData" />

        <div
          class="panels-container"
          ref="panelsContainer">
          <empire-panel
            v-show="activePanelName === 'empire'"
            ref="empire"
            @close="closePanel" />
          <operations-panel
            v-show="activePanelName === 'operations'"
            ref="operations"
            @close="closePanel" />
          <ranking-panel
            v-show="!isTutorial && activePanelName === 'ranking'"
            ref="ranking"
            @close="closePanel" />
          <faction-panel
            v-show="!isTutorial && activePanelName === 'faction'"
            ref="faction"
            @close="closePanel" />
          <help-panel
            v-show="activePanelName === 'help'"
            ref="help"
            @close="closePanel" />
          <messenger-panel
            v-show="!isTutorial && activePanelName === 'messenger'"
            ref="messenger"
            @close="closePanel" />
          <event-panel
            v-show="!isTutorial && activePanelName === 'event'"
            ref="event"
            @close="closePanel" />
        </div>

        <bottombar ref="bottombar" />
      </div>
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';
import Typed from 'typed.js';
import MapData from '@/game/map/map-data';
import eventBus from '@/plugins/event-bus';

import UniverseMap from '@/game/components/galaxy/Map.vue';
import EmpirePanel from '@/game/components/panel/EmpirePanel.vue';
import OperationsPanel from '@/game/components/panel/OperationsPanel.vue';
import RankingPanel from '@/game/components/panel/RankingPanel.vue';
import FactionPanel from '@/game/components/panel/FactionPanel.vue';
import HelpPanel from '@/game/components/panel/HelpPanel.vue';
import MessengerPanel from '@/game/components/panel/MessengerPanel.vue';
import EventPanel from '@/game/components/panel/EventPanel.vue';
import Chat from '@/game/components/Chat.vue';
import NotificationCenter from '@/game/components/NotificationCenter.vue';
import SearchOverlay from '@/game/components/SearchOverlay.vue';
import Tutorial from '@/game/components/Tutorial.vue';
import Settings from '@/game/components/Settings.vue';
import Topbar from '@/game/components/navbar/Topbar.vue';
import GalaxyContainer from '@/game/components/galaxy/Container.vue';
import Bottombar from '@/game/components/navbar/Bottombar.vue';
import OpenedCharacter from '@/game/components/overlay/opened-character.vue';
import OpenedPlayer from '@/game/components/overlay/opened-player.vue';
import { copyToClipboard } from '@/utils/clipboard';

const mapData = new MapData();

export default {
  name: 'game',
  // Expose the MapData singleton to descendants (notably chat ref
  // components) so they can look up systems/positions without going
  // through Vuex. mapData isn't in the store — it's a module-level
  // instance updated by `map/update` event-bus messages.
  provide() {
    return {
      mapData: this.mapData,
    };
  },
  data() {
    return {
      showSplash: true,
      activePanel: {},
      somePanelIsOpen: false,
      isChatOpen: true,
      isSettingsOpen: false,
      mapData,
      // 'credit' | 'technology' | 'ideology' | null — set by Bottombar
      // mouseenter/leave and consumed by the C-key copy handler.
      hoveredResource: null,
      panels: [
        {
          name: 'empire',
          side: 'left',
        }, {
          name: 'operations',
          side: 'right',
        }, {
          name: 'ranking',
          side: 'right',
        }, {
          name: 'faction',
          side: 'left',
        }, {
          name: 'help',
          side: 'left',
        }, {
          name: 'messenger',
          side: 'left',
        }, {
          name: 'event',
          side: 'right',
          excludeSpeeds: ['fast'],
        },
      ],
    };
  },
  computed: {
    connected() { return this.$store.state.game.connected; },
    theme() { return this.$store.getters['game/theme']; },
    activePanelName() { return this.activePanel.name; },
    onBoardCharacters() { return this.$store.state.game.player.characters.filter((p) => p.status === 'on_board'); },
    isTutorial() { return this.$store.state.game.galaxy.tutorial_id; },
  },
  methods: {
    onShortkey(event) {
      if (event.srcKey === 'escape') {
        if (this.$store.state.game.selectedSystem) {
          this.$store.dispatch('game/closeSystem', this);
        } else {
          this.isSettingsOpen = !this.isSettingsOpen;
        }
      }

      if (event.srcKey === 'firstSystem') {
        this.$root.$emit('switchSystem', 'first');
      }

      if (event.srcKey === 'nextSystem') {
        this.$root.$emit('switchSystem', 'next');
      }

      if (event.srcKey.startsWith('selectGroup')) {
        const key = event.srcKey.slice(-1);

        if (this.$store.state.game.charactersGroup[key]) {
          const characterId = this.$store.state.game.charactersGroup[key];

          if (this.onBoardCharacters.find((c) => c.id === characterId)) {
            this.$store.dispatch('game/selectCharacter', { vm: this, id: characterId });
          }
        }
      }

      if (this.$store.state.game.selectedCharacter) {
        const selectedCharacter = this.$store.state.game.selectedCharacter;

        if (event.srcKey === 'nextAgent') {
          const i = selectedCharacter
            ? this.onBoardCharacters.findIndex((c) => c.id === selectedCharacter.id)
            : -1;

          const nextCharacterId = this.onBoardCharacters[(i + 1) % this.onBoardCharacters.length].id;
          this.$store.dispatch('game/selectCharacter', { vm: this, id: nextCharacterId });
        }

        if (event.srcKey === 'centerToCharacter') {
          this.$root.$emit('map:centerToCharacter', selectedCharacter);
        }

        if (event.srcKey.startsWith('createGroup')) {
          const key = event.srcKey.slice(-1);
          this.$store.commit('game/updateCharactersGroup', { key, characterId: selectedCharacter.id });
        }
      }

      if (['ranking', 'faction', 'empire', 'operations', 'help'].includes(event.srcKey)) {
        this.$root.$emit('togglePanel', event.srcKey);
      }

      if (event.srcKey === 'search') {
        this.$root.$emit('toggleSearch');
      }

      if (event.srcKey === 'copy') {
        this.handleCopy();
      }

      if (['patent', 'doctrine'].includes(event.srcKey)) {
        this.$root.$emit('openBottomMiniPanel', event.srcKey);
      }

      if (['character-market', 'victory'].includes(event.srcKey)) {
        this.$root.$emit('openTopMiniPanel', event.srcKey);
      }
    },
    // C-key handler. Priority order:
    //   1. Hovered bottom-bar resource → copy 2x3 totals/income block
    //      (clipboard-friendly for paste into a spreadsheet)
    //   2. Hovered system on the galaxy map → copy "NAME (X, Y) in SECTOR"
    //   3. Currently-open system view → same format for the open system
    // Silent no-op if none of the above is active.
    async handleCopy() {
      if (this.hoveredResource) {
        await this.copyResourceBlock();
        return;
      }
      const hoveredId = this.mapData?.hoveredSystemId;
      if (hoveredId) {
        const sys = this.mapData.systems.find((s) => s.id === hoveredId);
        if (sys) await this.copySystem(sys);
        return;
      }
      const selected = this.$store.state.game.selectedSystem;
      if (selected) await this.copySystem(selected);
    },
    async copySystem(system) {
      if (!system || !system.name) return;
      const x = Math.round(system.position?.x ?? 0);
      const y = Math.round(system.position?.y ?? 0);
      const sectors = this.$store.state.game.galaxy.sectors || [];
      const sector = sectors.find((s) => s.id === system.sector_id);
      const sectorName = sector ? sector.name : '?';
      const text = `${system.name} (${x}, ${y}) in ${sectorName}`;
      const ok = await copyToClipboard(text);
      if (ok) this.$toasted.success(this.$t('clipboard.copied', { text }));
      else this.$toasted.error(this.$t('clipboard.failed'));
    },
    async copyResourceBlock() {
      const p = this.$store.state.game.player;
      if (!p || !p.credit || !p.technology || !p.ideology) return;
      const round = (v) => Math.round(v ?? 0);
      // Tab-separated 3 columns × 2 rows for Excel paste:
      //   row 1: credit total, technology total, ideology total
      //   row 2: credit income/UT, technology income/UT, ideology income/UT
      const text = [
        [round(p.credit.value), round(p.technology.value), round(p.ideology.value)].join('\t'),
        [round(p.credit.change), round(p.technology.change), round(p.ideology.change)].join('\t'),
      ].join('\n');
      const ok = await copyToClipboard(text);
      if (ok) this.$toasted.success(this.$t('clipboard.resources_copied'));
      else this.$toasted.error(this.$t('clipboard.failed'));
    },
    async togglePanel(name, data) {
      const panel = this.panels.find((p) => p.name === name);

      if (panel.excludeSpeeds && panel.excludeSpeeds.includes(this.$store.state.game.time.speed)) {
        return;
      }

      if (this.somePanelIsOpen && this.activePanel.name === name) {
        await this.closePanel();
      } else {
        await this.openPanel(name, data);
      }
    },
    async openPanel(name, data) {
      await this.animateClosePanelContainer();
      this.$root.$emit('closeTopMiniPanel');
      this.$root.$emit('closeBottomMiniPanel');
      this.$store.commit('game/addOverlay', 'panel');
      this.animateOpenPanelContainer(name, data);
    },
    async closePanel() {
      await this.animateClosePanelContainer();
      this.$store.commit('game/removeOverlay');
    },
    animateOpenPanelContainer(name, data) {
      return new Promise((resolve) => {
        this.$ambiance.sound('panel-open');
        this.activePanel = this.panels.find((p) => p.name === name);
        this.somePanelIsOpen = true;
        this.$refs[name].open(data);

        const reset = this.activePanel.side === 'left'
          ? { left: '-100vw', right: 'auto' } : { left: 'auto', right: '-100vw' };
        const to = this.activePanel.side === 'left' ? { left: 0 } : { right: 0 };

        new TimelineLite({
          onComplete() { resolve(); },
        }).set(this.$refs.panelsContainer, reset)
          .to(this.$refs.panelsContainer, { ...to, ease: Expo.easeOut, duration: 0.8 }, 0);
      });
    },
    animateClosePanelContainer() {
      if (!this.somePanelIsOpen) {
        return Promise.resolve();
      }

      return new Promise((resolve) => {
        this.$ambiance.sound('panel-close');
        const from = this.activePanel.side === 'left' ? { left: '-100vw' } : { right: '-100vw' };

        new TimelineLite({
          onComplete: () => {
            this.somePanelIsOpen = false;
            this.activePanel = {};
            resolve();
          },
        }).to(this.$refs.panelsContainer, { ...from, ease: Expo.linear, duration: 0.4 }, 0);
      });
    },
    async animateSplash() {
      const languageHasQuotes = 'quotes' in this.$i18n.messages[this.$i18n.locale];
      let quote = '';
      if (languageHasQuotes) {
        const quoteCount = Object.keys(this.$i18n.messages[this.$i18n.locale].quotes).length;
        const quoteNumber = Math.floor(Math.random() * quoteCount);
        quote = `
          <p>${this.$t(`quotes[${quoteNumber}].content`)}</p>
          <footer>
            ${this.$t(`quotes[${quoteNumber}].author`)}<br/>
            ${this.$t(`quotes[${quoteNumber}].reference`)}
          </footer>
        `;
      } else {
        quote = '<p>Welcome</p>';
      }

      // Race the cinematic against the socket: kick off typing and the
      // connected-poll in parallel, fade out the moment BOTH are done.
      const typingDone = new Promise((resolve) => {
        new Typed('.typing', { // eslint-disable-line no-new
          strings: [quote],
          typeSpeed: 4,
          showCursor: false,
          autoInsertCss: false,
          loop: false,
          onComplete: resolve,
        });
      });

      const connectionReady = new Promise((resolve) => {
        if (this.connected) { resolve(); return; }
        const interval = setInterval(() => {
          if (this.connected) {
            clearInterval(interval);
            resolve();
          }
        }, 50);
      });

      await Promise.all([typingDone, connectionReady]);
      this.hideSplash();
    },
    async hideSplash() {
      await new TimelineLite()
        .to(this.$refs.spsLogo, { opacity: 0, duration: 0.5 }, 0)
        .to(this.$refs.spsQuote, { opacity: 0, duration: 0.5 }, 0)
        .to(this.$refs.spsMain, { opacity: 0, duration: 0.5 }, 0);
      this.showSplash = false;
    },
  },
  async mounted() {
    eventBus.$on('map/update', (data) => { this.mapData.update(data); });
    this.$socket.joinGame();
    this.$store.dispatch('portal/initConversations', this.$store.state.game.auth.instance);

    if (this.$config.MODE === 'production') {
      await this.animateSplash();
    } else {
      this.showSplash = false;
    }

    this.$root.$on('togglePanel', (name, data) => { this.togglePanel(name, data); });
    this.$root.$on('closePanel', () => { this.closePanel(); });
    this.$root.$on('changeChatState', (state) => { this.isChatOpen = state; });
    this.$root.$on('hoveredResource', (name) => { this.hoveredResource = name; });
  },
  components: {
    Settings,
    Chat,
    NotificationCenter,
    SearchOverlay,
    Tutorial,
    Topbar,
    GalaxyContainer,
    Bottombar,
    EmpirePanel,
    OperationsPanel,
    RankingPanel,
    FactionPanel,
    HelpPanel,
    MessengerPanel,
    EventPanel,
    OpenedCharacter,
    OpenedPlayer,
    UniverseMap,
  },
};
</script>
