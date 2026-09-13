<template>
  <div
    class="archive-map"
    ref="root">
    <div
      v-if="mode === 'ownership' && days.length > 1"
      class="archive-map-controls">
      <button
        class="archive-map-play"
        @click="togglePlay">
        {{ playing ? '❚❚' : '▶' }}
      </button>
      <input
        type="range"
        min="0"
        :max="days.length - 1"
        v-model.number="dayIndex">
      <span class="archive-map-day">{{ $t('page.play.archive.day') }} {{ currentDay.day }}</span>
    </div>

    <div
      class="archive-map-canvas"
      :style="{ height: `${px}px` }"
      @mouseleave="hover = null">
      <svg
        v-if="px > 0"
        :width="px"
        :height="px">
        <polygon
          v-for="s in sectors"
          :key="`sector-${s.id}`"
          :points="s.svgPoints"
          class="archive-map-sector"
          :style="sectorStyle(s)" />

        <text
          v-for="s in sectors"
          :key="`sector-name-${s.id}`"
          v-show="showNames"
          :x="s.cx"
          :y="s.cy"
          class="archive-map-sector-name"
          text-anchor="middle">{{ s.name }}</text>

        <template v-if="mode === 'ownership'">
          <circle
            v-for="(s, i) in systems"
            :key="`sys-${s.id}`"
            :cx="s.px"
            :cy="s.py"
            :r="systemRadius(codes[i])"
            :style="systemStyle(codes[i])" />
        </template>

        <template v-else>
          <circle
            v-for="s in systems"
            :key="`dot-${s.id}`"
            :cx="s.px"
            :cy="s.py"
            r="1.2"
            class="archive-map-faint" />
          <circle
            v-for="spot in hotspots"
            :key="`spot-${spot.id}`"
            :cx="spot.px"
            :cy="spot.py"
            :r="spot.r"
            class="archive-map-hotspot" />
        </template>

        <circle
          v-for="(s, i) in systems"
          :key="`hit-${s.id}`"
          :cx="s.px"
          :cy="s.py"
          r="7"
          class="archive-map-hit"
          @mousemove="onHover($event, s, i)" />
      </svg>

      <archive-tooltip
        v-if="hover"
        :x="hover.x"
        :y="hover.y"
        :container-width="px"
        :title="hover.title"
        :rows="hover.rows" />
    </div>

    <div class="archive-map-legend">
      <template v-if="mode === 'ownership'">
        <span
          v-for="f in factions"
          :key="`legend-${f.key}`"
          class="archive-map-legend-item">
          <span
            class="dot"
            :style="{ background: f.color }" />
          <span
            class="ring"
            :style="{ borderColor: f.color }" />
          {{ f.name }}
        </span>
        <span class="archive-map-legend-item is-muted">
          <span class="dot" /> {{ $t('page.play.archive.map.player_system') }}
          <span class="ring" /> {{ $t('page.play.archive.map.dominion') }}
          <span class="dot is-neutral" /> {{ $t('page.play.archive.map.neutral') }}
        </span>
      </template>
      <span
        v-else
        class="archive-map-legend-item is-muted">
        <span class="dot is-accent" />
        {{ $t('page.play.archive.map.hotspot_hint') }}
      </span>
      <label class="archive-map-names">
        <input
          type="checkbox"
          v-model="showNames">
        {{ $t('page.play.archive.map.sector_names') }}
      </label>
    </div>
  </div>
</template>

<script>
import ArchiveTooltip from './ArchiveTooltip.vue';
import { ACCENT } from './palette';

const ACTIVITY_KINDS = ['battles', 'raid', 'loot', 'conquest', 'make_dominion'];

// Galaxy map of an archived match: sector + system ownership on any sampled
// day (with a play-through slider), or per-system activity hotspots.
// Y is flipped like InstanceMap so it matches the lobby preview.
export default {
  name: 'archive-map',
  props: {
    // match.map: { size, sectors, systems, faction_keys, days: [{ day, sectors, systems }] }
    map: { type: Object, required: true },
    // [{ key, name, color }]
    factions: { type: Array, required: true },
    mode: { type: String, default: 'ownership' }, // ownership | activity
    // match.summary.activity: { systemId: { battles, raid, loot, ... } }
    activity: { type: Object, default: () => ({}) },
    activityKind: { type: String, default: 'battles' },
    maxSize: { type: Number, default: 640 },
  },
  data() {
    return {
      px: 0,
      dayIndex: Math.max(0, (this.map.days || []).length - 1),
      playing: false,
      showNames: false,
      hover: null,
    };
  },
  computed: {
    days() { return this.map.days || []; },
    currentDay() { return this.days[this.dayIndex] || { day: 0, systems: [], sectors: {} }; },
    codes() { return this.currentDay.systems || []; },
    scale() { return this.px / (this.map.size || 1); },
    colorByKey() {
      const m = {};
      this.factions.forEach((f) => { m[f.key] = f.color; });
      return m;
    },
    systems() {
      return (this.map.systems || []).map((s) => ({
        ...s,
        px: s.x * this.scale,
        py: (this.map.size - s.y) * this.scale,
      }));
    },
    sectors() {
      return (this.map.sectors || []).map((s) => ({
        ...s,
        svgPoints: (s.points || []).map((p) => `${p[0] * this.scale},${(this.map.size - p[1]) * this.scale}`).join(' '),
        cx: s.centroid ? s.centroid[0] * this.scale : 0,
        cy: s.centroid ? (this.map.size - s.centroid[1]) * this.scale : 0,
      }));
    },
    hotspots() {
      const kind = ACTIVITY_KINDS.includes(this.activityKind) ? this.activityKind : 'battles';
      return this.systems
        .map((s) => {
          const counts = this.activity[s.id] || this.activity[`${s.id}`] || {};
          const n = counts[kind] || 0;
          return { id: s.id, px: s.px, py: s.py, r: n > 0 ? (2 + Math.sqrt(n) * 2.2) * Math.max(0.6, this.px / 500) : 0 };
        })
        .filter((s) => s.r > 0)
        .sort((a, b) => b.r - a.r);
    },
  },
  methods: {
    factionOfCode(code) {
      if (code < 2) return null;
      return this.map.faction_keys[Math.floor((code - 2) / 2)];
    },
    systemRadius(code) {
      if (!code) return 1;
      if (code === 1) return 1.8;
      return code % 2 === 0 ? 3.2 : 2.6;
    },
    systemStyle(code) {
      if (!code) return { fill: 'rgba(255,255,255,.14)' };
      if (code === 1) return { fill: '#8a8f99', fillOpacity: 0.7 };
      const color = this.colorByKey[this.factionOfCode(code)] || '#e6e6e6';
      return code % 2 === 0
        ? { fill: color, stroke: '#31363f', strokeWidth: 1 }
        : { fill: 'none', stroke: color, strokeWidth: 1.5 };
    },
    sectorStyle(sector) {
      const owners = this.currentDay.sectors || {};
      const owner = owners[sector.id] !== undefined ? owners[sector.id] : owners[`${sector.id}`];
      const color = this.colorByKey[owner];
      return color
        ? { fill: color, fillOpacity: 0.16, stroke: color, strokeOpacity: 0.45 }
        : { fill: 'transparent', stroke: 'rgba(255,255,255,.1)' };
    },
    onHover(e, system, i) {
      const rect = this.$refs.root.querySelector('.archive-map-canvas').getBoundingClientRect();
      const rows = [];
      if (this.mode === 'ownership') {
        const code = this.codes[i];
        const faction = this.factions.find((f) => f.key === this.factionOfCode(code));
        let status = this.$t('page.play.archive.map.uninhabited');
        if (code === 1) status = this.$t('page.play.archive.map.neutral');
        else if (code >= 2) {
          status = code % 2 === 0
            ? this.$t('page.play.archive.map.player_system')
            : this.$t('page.play.archive.map.dominion');
        }
        rows.push({ color: faction ? faction.color : null, label: faction ? faction.name : '', value: status });
      } else {
        const counts = this.activity[system.id] || this.activity[`${system.id}`] || {};
        ACTIVITY_KINDS.forEach((k) => {
          if (counts[k]) {
            rows.push({
              color: k === this.activityKind ? ACCENT : null,
              label: this.$t(`page.play.archive.activity.${k}`),
              value: counts[k],
            });
          }
        });
        if (rows.length === 0) rows.push({ label: this.$t('page.play.archive.map.quiet'), value: '—' });
      }
      this.hover = { x: e.clientX - rect.left, y: e.clientY - rect.top, title: system.name, rows };
    },
    togglePlay() {
      if (this.playing) {
        this.stop();
        return;
      }
      if (this.dayIndex >= this.days.length - 1) this.dayIndex = 0;
      this.playing = true;
      this.timer = setInterval(() => {
        if (this.dayIndex >= this.days.length - 1) this.stop();
        else this.dayIndex += 1;
      }, 700);
    },
    stop() {
      this.playing = false;
      clearInterval(this.timer);
    },
    measure() {
      if (this.$refs.root) this.px = Math.min(this.maxSize, this.$refs.root.clientWidth);
    },
  },
  mounted() {
    this.$nextTick(this.measure);
    window.addEventListener('resize', this.measure);
  },
  beforeDestroy() {
    this.stop();
    window.removeEventListener('resize', this.measure);
  },
  components: {
    ArchiveTooltip,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-map {
  width: 100%;
}

.archive-map-controls {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;

  input[type=range] {
    flex: 1 1 auto;
    max-width: 520px;
    accent-color: $primary;
  }
}

.archive-map-play {
  width: 30px;
  height: 26px;
  border: solid 1px rgba(255, 255, 255, .15);
  border-radius: 3px;
  background: $grey-dark;
  color: $white;
  cursor: pointer;
}

.archive-map-day {
  min-width: 60px;
  font-variant-numeric: tabular-nums;
  color: $white-alt-1;
}

.archive-map-canvas {
  position: relative;

  svg {
    display: block;
    background: rgba(0, 0, 0, .15);
    border-radius: 3px;
  }
}

.archive-map-sector {
  stroke-width: 1;
}

.archive-map-sector-name {
  fill: $white-alt-1;
  font-size: 10px;
  text-transform: uppercase;
  pointer-events: none;
}

.archive-map-faint {
  fill: rgba(255, 255, 255, .18);
}

.archive-map-hotspot {
  fill: $primary;
  fill-opacity: .4;
  stroke: $primary;
  stroke-width: 1;
  pointer-events: none;
}

.archive-map-hit {
  fill: transparent;
}

.archive-map-legend {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 16px;
  margin-top: 8px;
  font-size: 1.2rem;
  color: $white-alt-1;

  .is-muted { color: $white-alt-2; }

  .dot, .ring {
    display: inline-block;
    width: 8px;
    height: 8px;
    margin: 0 2px 0 6px;
    border-radius: 50%;
    vertical-align: middle;
  }

  .dot {
    background: $white-alt-1;

    &.is-neutral { background: #8a8f99; }
    &.is-accent { background: $primary; }
  }

  .ring {
    border: solid 2px $white-alt-1;
  }
}

.archive-map-legend-item {
  display: inline-flex;
  align-items: center;
}

.archive-map-names {
  margin-left: auto;
  cursor: pointer;
}
</style>
