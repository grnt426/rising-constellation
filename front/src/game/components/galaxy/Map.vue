<template>
  <div>
    <div
      v-show="this.view === 'map'"
      class="map-options">
      <div class="map-options-group">
        <div
          class="map-options-item"
          v-tooltip="$t(`galaxy.map.modes.character-label`)"
          :class="{ 'is-active': mapOptions.showCharacterLabel }"
          @click="updateMapOptions('showCharacterLabel', !mapOptions.showCharacterLabel)">
          <svgicon name="bookmark" />
        </div>
        <div
          class="map-options-item"
          v-tooltip="$t(`galaxy.map.modes.system-icons`)"
          :class="{ 'is-active': mapOptions.showSystemIcons }"
          @click="updateMapOptions('showSystemIcons', !mapOptions.showSystemIcons)">
          <svgicon name="marker/flag" />
        </div>
      </div>
      <div class="map-options-group">
        <div
          class="map-options-item"
          v-for="mode in modes"
          v-tooltip="{ content: modeTooltip(mode.key), html: true }"
          :key="mode.key"
          :class="{ 'is-active': mode.key === mapOptions.mode }"
          @click="updateMapOptions('mode', mode.key)">
          <svgicon :name="mode.icon" />
        </div>
      </div>
      <div class="map-options-group">
        <div
          class="map-options-item"
          v-tooltip="$t('galaxy.map.modes.ruler', { hotkey: $store.getters['portal/hotkeyHint']('ruler') })"
          :class="{ 'is-active': ruler.active }"
          @click="toggleRuler">
          <svgicon name="ruler" />
        </div>
      </div>
      <div class="map-position-xy">
        {{ mapPosition.x }}:{{ mapPosition.y }}
      </div>
    </div>
    <div
      v-if="view === 'map' && ruler.active && rulerTravelTimeLabel"
      class="map-ruler-readout">
      {{ rulerTravelTimeLabel }}
    </div>
    <div class="map-cross">
      <crosshair-marks
        :crosshair="crosshair"
        :faction="playerFaction" />
    </div>
    <!-- the hovered sector's card: it lingers long enough to be
         reached, and holds still while the pointer is on it (the map
         stops picking under it) so its pager can be clicked -->
    <div
      v-if="shownSector"
      class="map-overlay"
      @mouseenter="hoverCardEnter"
      @mouseleave="onSectorCardLeave">
      <sector-card
        :sector="shownSector"
        :map-data="data"
        :page="sectorPage"
        :key="`sector-${shownSector.id}`"
        @page="sectorPage = $event" />
    </div>
    <system-icon-picker />
    <map-action-radial :data="data" />
    <div ref="mapcontainer"></div>
  </div>
</template>

<script>
import * as THREE from 'three';
import Map from '@/game/map/map';
import { registerMap, unregisterMap } from '@/game/debug/collector';

import SectorCard from '@/game/components/card/SectorCard.vue';
import CrosshairMarks from '@/game/components/galaxy/CrosshairMarks.vue';
import SystemIconPicker from '@/game/components/galaxy/system/SystemIconPicker.vue';
import MapActionRadial from '@/game/components/galaxy/MapActionRadial.vue';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';

// declare it outside of the component because we don't want it to be 'Observe'd by Vue,
// it would slow things down and potentially mess with the map object.
let map;

export default {
  name: 'universe-map',
  mixins: [HoverCardMixin],
  props: {
    data: Object,
  },
  data() {
    return {
      modes: [
        { key: 'population', icon: 'layers' },
        { key: 'visibility', icon: 'eye' },
        { key: 'radar', icon: 'disc' },
        { key: 'overview', icon: 'overview' },
      ],
      intelTimer: null,
      // which faction the sector card shows: its pager, or a click on
      // the hovered sector's name
      sectorPage: 0,
      // the sector whose card is up: follows the hovered one through
      // the hover-intent timers (HoverCardMixin), so the card survives
      // the trip from the sector to the corner it sits in
      shownSectorId: null,
      // the card sits in a corner, far from most sectors: crossing other
      // sectors on the way there must not swap it
      hoverCardSwapDwell: 400,
      // ...and the way there often crosses empty space past the
      // galaxy's edge, which clears the hover
      hoverCardCloseGrace: 1000,
    };
  },
  computed: {
    view() { return this.$store.state.game.view; },
    mapOptions() { return this.$store.state.game.mapOptions; },
    mapPosition() { return this.$store.state.game.mapPosition; },
    // The player's own crosshair (portal Settings → Galaxy crosshair).
    crosshair() { return this.$store.getters['portal/crosshair']; },
    playerFaction() { return this.$store.state.game.playerFaction; },
    ruler() { return this.$store.state.game.ruler; },
    rulerTravelTimeLabel() {
      const ticks = this.ruler.travelTimeTicks;
      if (ticks == null || ticks <= 0) return null;

      // ticks → wall-clock seconds. tickToSecondFactor encodes the
      // current speed (slow/medium/fast), so the readout updates if the
      // speed changes mid-measurement.
      const seconds = ticks * this.$store.getters['game/tickToSecondFactor'];
      const h = Math.floor(seconds / 3600);
      const m = Math.floor((seconds % 3600) / 60);
      const s = Math.round(seconds % 60);

      if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`;
      if (m > 0) return `${m}m ${String(s).padStart(2, '0')}s`;
      return `${s}s`;
    },
    // the sector under the pointer (the map's hover)
    hoveredSector() {
      if (this.$store.state.game.mapOverlay) {
        if (this.$store.state.game.mapOverlay.type === 'sector') {
          return this.$store.state.game.galaxy.sectors
            .find((s) => s.id === this.$store.state.game.mapOverlay.data);
        }
      }

      return null;
    },
    shownSector() {
      if (this.shownSectorId === null) return null;
      return this.$store.state.game.galaxy.sectors.find((s) => s.id === this.shownSectorId) || null;
    },
  },
  watch: {
    // entering overview mode: fetch at once rather than at the next poll
    'mapOptions.mode': 'pollMapIntel',
    // another sector's card starts on the viewer's own faction
    shownSectorId() { this.sectorPage = 0; },
    hoveredSector(sector) {
      // the pointer is on the card: the map does not pick under it, but
      // anything else that clears the hover must not take the card away
      if (this.cardPinned) return;
      if (sector) this.hoverCardShow(sector.id);
      else this.hoverCardHide();
    },
  },
  methods: {
    hoverCardApply(sectorId) { this.shownSectorId = sectorId; },
    hoverCardVisible() { return this.shownSectorId !== null; },
    // Off the card: back onto a sector (the same one, or another after
    // the dwell), or into empty space and closed after the grace. The
    // map's hover is still the one from before the card was entered,
    // and the next move on the map corrects it through the watcher.
    onSectorCardLeave() {
      this.cardPinned = false;
      if (this.hoveredSector) this.hoverCardShow(this.hoveredSector.id);
      else this.hoverCardHide();
    },
    // The overview mode explains its glyph in its tooltip: the fixed line
    // every mode has, then one line per part of the glyph.
    modeTooltip(key) {
      const title = this.$t(`galaxy.map.modes.${key}`);
      if (key !== 'overview') return title;
      return [title, ...['fleets', 'agents', 'stats', 'siege']
        .map((part) => this.$t(`galaxy.map.glyph.legend.${part}`))].join('<br>');
    },
    // Overview mode draws from the faction's map intel, which is only
    // sent when asked for. Asked for while the mode is on and the map is
    // what the player is looking at; the server rebuilds it every ~30 s
    // at most, whatever the number of members asking.
    pollMapIntel() {
      if (this.mapOptions.mode !== 'overview' || this.view !== 'map' || document.hidden) return;
      this.$store.dispatch('game/refreshMapIntel', { socket: this.$socket, maxAge: 40000 });
    },
    updateMapOptions(key, value) {
      if (this.mapOptions[key] === value) {
        return;
      }
      this.$store.commit('game/updateMapOptions', { key, value });
      // Only a mode change can alter the radar overlay's geometry (it is
      // only drawn in 'radar' mode). The label/icon switches are read
      // per-frame by their blocks and must NOT force a radar rebuild:
      // that rebuild re-unions every radar disk with paper.js and froze
      // the game for seconds on big factions.
      if (key === 'mode') {
        this.data.forceRedrawRadars();
      }
    },
    toggleRuler() {
      this.$store.commit('game/setRulerActive', !this.ruler.active);
    },
  },
  async mounted() {
    if (this.$store.state.game.time.speed === 'fast') {
      this.updateMapOptions('mode', 'radar');
    }

    const { mapcontainer } = this.$refs;

    const fov = 30;
    const camera = new THREE.PerspectiveCamera(fov, mapcontainer.clientWidth / mapcontainer.clientHeight, 1, 1500);
    const scene = new THREE.Scene();
    const renderer = new THREE.WebGLRenderer({ antialias: true });

    renderer.setSize(mapcontainer.clientWidth, mapcontainer.clientHeight);
    mapcontainer.appendChild(renderer.domElement);

    map = new Map({
      scene,
      camera,
      renderer,
      fov,
      $root: this.$root,
      vm: this,
      data: this.data,
      $socket: this.$socket,
      $toasted: this.$toasted,
    });
    // Before init: a map stuck loading (fonts never arrive) is exactly
    // what the Debug report needs to see.
    registerMap(map);

    await map.init();
    map.onZ(camera.position.z);
    map.bindEvents();

    // Dev-only escape hatch for driving the map from the console /
    // automated smoke tests (the `map` binding above is module-scoped
    // and otherwise unreachable from devtools).
    if (process.env.NODE_ENV !== 'production') {
      window.__rcMap = map;
    }

    // background color
    renderer.setClearColor(0x000000, 1);

    this.intelTimer = setInterval(() => this.pollMapIntel(), 15000);
    this.pollMapIntel();

    this.onSectorClick = () => { this.sectorPage += 1; };
    this.$root.$on('map:sectorClick', this.onSectorClick);
  },
  beforeDestroy() {
    this.$root.$off('map:sectorClick', this.onSectorClick);
    clearInterval(this.intelTimer);
    unregisterMap(map);
    map.destroy();
  },
  components: {
    CrosshairMarks,
    SectorCard,
    SystemIconPicker,
    MapActionRadial,
  },
};
</script>
