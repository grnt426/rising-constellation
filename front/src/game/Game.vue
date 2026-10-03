<template>
  <div class="game-context">
    <div
      :class="`theme-${theme}`"
      v-shortkey="shortkeys"
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
            <img src="~public/logo/large-v-white.png" alt="Tetrarchy Falls" />
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
        <quick-calc v-if="!isTutorial" />
        <help-overlay v-if="!isTutorial" />
        <tutorial v-if="isTutorial" />
        <opened-character />
        <opened-player />
        <agent-orders
          v-if="!isTutorial"
          ref="agentOrders" />

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
import viewport from '@/utils/viewport';

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
import QuickCalc from '@/game/components/calc/QuickCalc.vue';
import HelpOverlay from '@/game/components/HelpOverlay.vue';
import Tutorial from '@/game/components/Tutorial.vue';
import Settings from '@/game/components/Settings.vue';
import Topbar from '@/game/components/navbar/Topbar.vue';
import GalaxyContainer from '@/game/components/galaxy/Container.vue';
import Bottombar from '@/game/components/navbar/Bottombar.vue';
import OpenedCharacter from '@/game/components/overlay/opened-character.vue';
import OpenedPlayer from '@/game/components/overlay/opened-player.vue';
import AgentOrders from '@/game/components/overlay/AgentOrders.vue';
import { copyToClipboard } from '@/utils/clipboard';
import { copyResourcesForVm } from '@/game/resource-copy';
import { recordWork } from '@/game/debug/collector';
import { hasKeyboardFocus } from '@/plugins/a11y';
import { shortkeyMap } from '@/game/hotkeys/bindings';

const mapData = new MapData();

// A control the keyboard is on (mouse focus left on a clicked button
// doesn't count: Space still centers the map for that player).
function isControl(el) {
  return hasKeyboardFocus()
    && !!el.closest('button, a[href], select, [role="button"], [role="separator"], [tabindex]:not([tabindex="-1"])');
}

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
  // Deliberately NOT in data(): mapData holds every system on the map and
  // rebuilds entries on every galaxy broadcast — inside data() Vue would
  // deep-observe it and re-install reactivity on each rebuilt system
  // (the map reads it imperatively per frame and never needed reactivity;
  // same reason Map.vue keeps the three.js `map` module-scoped). A plain
  // instance property assigned in beforeCreate is invisible to the
  // observer but still available to provide(), the template, and methods.
  beforeCreate() {
    this.mapData = mapData;
  },
  data() {
    return {
      showSplash: true,
      activePanel: {},
      somePanelIsOpen: false,
      // Phones: chat starts hidden (it overlays the whole top of the
      // screen there) and lives behind the topbar chat toggle as a
      // pull-out drawer. Desktop keeps it always-on.
      isChatOpen: !viewport.isMobile,
      isSettingsOpen: false,
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
  watch: {
    // Fetch the help bundle as soon as the instance speed is known (and
    // whenever it changes), so HelpButton can tell which pages exist.
    helpBundleKey: {
      immediate: true,
      handler(key) {
        if (key) this.$store.dispatch('help/load');
      },
    },
  },
  computed: {
    helpBundleKey() {
      const speed = this.$store.state.game.time && this.$store.state.game.time.speed;
      return this.$store.getters['help/enabled'] && speed ? speed : null;
    },
    connected() { return this.$store.state.game.connected; },
    // { action id: keys } for v-shortkey: the defaults from
    // game/hotkeys/bindings.js with the player's own bindings on top
    // (Help → Keyboard shortcuts). onShortkey gets the action id as srcKey.
    shortkeys() { return shortkeyMap(this.$store.getters['portal/hotkeys']); },
    theme() { return this.$store.getters['game/theme']; },
    activePanelName() { return this.activePanel.name; },
    onBoardCharacters() { return this.$store.state.game.player.characters.filter((p) => p.status === 'on_board'); },
    isTutorial() { return this.$store.state.game.galaxy.tutorial_id; },
  },
  methods: {
    onShortkey(event) {
      // Space belongs to a keyboard-focused control (it presses buttons);
      // don't also run a map hotkey on the same keystroke.
      if (event.srcKey === 'center_character' && isControl(document.activeElement)) {
        return;
      }

      // Esc never reaches the overlays' own handlers (vue-shortkey
      // swallows it first), so it closes the topmost one from here.
      if (event.srcKey === 'settings') {
        if (this.$refs.agentOrders && this.$refs.agentOrders.isOpen) {
          this.$refs.agentOrders.close();
        } else if (this.$store.state.game.openedCharacter) {
          this.$store.dispatch('game/closeCharacter');
        } else if (this.$store.state.game.selectedSystem) {
          this.$store.dispatch('game/closeSystem', this);
        } else {
          this.isSettingsOpen = !this.isSettingsOpen;
        }
      }

      if (event.srcKey === 'first_system') {
        this.$root.$emit('switchSystem', 'first');
      }

      if (event.srcKey === 'next_system') {
        this.$root.$emit('switchSystem', 'next');
      }

      if (event.srcKey.startsWith('select_group_')) {
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

        if (event.srcKey === 'next_agent') {
          const i = selectedCharacter
            ? this.onBoardCharacters.findIndex((c) => c.id === selectedCharacter.id)
            : -1;

          const nextCharacterId = this.onBoardCharacters[(i + 1) % this.onBoardCharacters.length].id;
          this.$store.dispatch('game/selectCharacter', { vm: this, id: nextCharacterId });
        }

        if (event.srcKey === 'center_character') {
          this.$root.$emit('map:centerToCharacter', selectedCharacter);
        }

        if (event.srcKey.startsWith('create_group_')) {
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

      if (event.srcKey === 'calc') {
        this.$root.$emit('toggleCalc');
      }

      if (event.srcKey === 'agent_orders') {
        this.$root.$emit('toggleAgentOrders');
      }

      if (event.srcKey === 'system_briefing') {
        if (this.$store.state.game.selectedSystem) {
          this.$root.$emit('focusSystemBriefing');
        } else {
          this.$announce(this.$t('a11y.system.no_system'));
        }
      }

      if (event.srcKey === 'ruler') {
        this.$store.commit('game/setRulerActive', !this.$store.state.game.ruler.active);
      }

      if (event.srcKey === 'copy') {
        this.handleCopy();
      }

      if (['patent', 'doctrine'].includes(event.srcKey)) {
        this.$root.$emit('openBottomMiniPanel', event.srcKey);
      }

      if (event.srcKey === 'character_market') {
        this.$root.$emit('openTopMiniPanel', 'character-market');
      }

      if (event.srcKey === 'victory') {
        this.$root.$emit('openTopMiniPanel', 'victory');
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
      await copyResourcesForVm(this);
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
    // Handlers are kept as bound refs so beforeDestroy can $off them.
    // eventBus and $root both outlive this route component; without the
    // teardown, every portal→game re-entry stacked another set of
    // listeners — N× MapData.update per broadcast after N re-entries,
    // and the closures retained the whole previous game's mapData.
    this.busHandlers = {
      'map/update': (data) => {
        // Walks every system on the map per broadcast: its distribution
        // goes in the Debug report.
        const start = performance.now();
        this.mapData.update(data);
        recordWork('mapData.update', performance.now() - start);
      },
    };
    this.rootHandlers = {
      togglePanel: (name, data) => { this.togglePanel(name, data); },
      closePanel: () => { this.closePanel(); },
      changeChatState: (state) => { this.isChatOpen = state; },
      hoveredResource: (name) => { this.hoveredResource = name; },
    };

    eventBus.$on('map/update', this.busHandlers['map/update']);
    this.$socket.joinGame();
    this.$store.dispatch('portal/initConversations', this.$store.state.game.auth.instance);

    if (this.$config.MODE === 'production') {
      await this.animateSplash();
    } else {
      this.showSplash = false;
    }

    Object.keys(this.rootHandlers).forEach((event) => {
      this.$root.$on(event, this.rootHandlers[event]);
    });

    // Deep link: /game?help=<slug> opens that manual page in the help modal.
    const helpSlug = this.$route && this.$route.query && this.$route.query.help;
    if (helpSlug) {
      this.$nextTick(() => this.$root.$emit('openHelp', { page: helpSlug }));
    }
  },
  beforeDestroy() {
    eventBus.$off('map/update', this.busHandlers['map/update']);
    Object.keys(this.rootHandlers).forEach((event) => {
      this.$root.$off(event, this.rootHandlers[event]);
    });
  },
  components: {
    Settings,
    Chat,
    NotificationCenter,
    SearchOverlay,
    QuickCalc,
    HelpOverlay,
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
    AgentOrders,
    UniverseMap,
  },
};
</script>
