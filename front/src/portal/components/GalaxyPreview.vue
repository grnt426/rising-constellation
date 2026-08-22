<template>
  <div
    class="galaxy-preview"
    ref="container">
    <svg
      v-if="containerSize > 0"
      :width="containerSize"
      :height="containerSize"
      version="1.1"
      xmlns="http://www.w3.org/2000/svg"
      class="map-container">
      <line
        v-for="i in gridLines"
        :key="`grid-v-${i}`"
        x1="0" :y1="resize(i * 12)"
        x2="100%" :y2="resize(i * 12)"
        class="map-grid" />
      <line
        v-for="i in gridLines"
        :key="`grid-h-${i}`"
        y1="0" :x1="resize(i * 12)"
        y2="100%" :x2="resize(i * 12)"
        class="map-grid" />

      <polygon
        v-for="s in sectors"
        :key="`sector-${s.key}`"
        :points="sectorPoints(s)"
        class="map-sector"
        :class="themeOf(s)" />

      <circle
        v-for="b in blackholes"
        :key="`blackhole-${b.key}`"
        :cx="resize(b.position.x)"
        :cy="resize(b.position.y)"
        :r="resize(b.radius)"
        class="map-blackhole" />

      <line
        v-for="(e, i) in edges"
        :key="`edge-${i}`"
        :x1="resize(e.s1.position.x)"
        :y1="resize(e.s1.position.y)"
        :x2="resize(e.s2.position.x)"
        :y2="resize(e.s2.position.y)"
        class="map-edges" />

      <circle
        v-for="s in systems"
        :key="`system-${s.key}`"
        :cx="resize(s.position.x)"
        :cy="resize(s.position.y)"
        :class="s.type"
        class="map-system" />

      <text
        v-for="s in namedSectors"
        :key="`sector-name-${s.key}`"
        :x="resize(s.centroid[0])"
        :y="resize(s.centroid[1])"
        class="map-sector-name"
        text-anchor="middle">
        {{ s.name }}
      </text>
    </svg>
  </div>
</template>

<script>
// Read-only galaxy render for the map/scenario detail pages. Same
// visual language as the wizard (identical CSS classes from
// editor.scss) minus every editing affordance. The warp lanes come
// from the same POST /maps/preview-edges endpoint the wizard uses, so
// the preview shows the connections a game from this design will have.
export default {
  name: 'galaxy-preview',
  props: {
    gameData: { type: Object, required: true },
    // Map size in game units (defines the coordinate space).
    size: { type: Number, required: true },
    // Optional { factionKey: 'theme-xxx' } map — colors scenario
    // sectors by assigned faction. Absent = neutral sector styling.
    factionThemes: { type: Object, default: null },
    showNames: { type: Boolean, default: false },
    showEdges: { type: Boolean, default: true },
  },
  data() {
    return {
      containerSize: 0,
      edges: Object.freeze([]),
    };
  },
  computed: {
    systems() { return this.gameData.systems || []; },
    sectors() { return this.gameData.sectors || []; },
    blackholes() { return this.gameData.blackholes || []; },
    gridLines() { return Math.max(0, Math.round(this.size / 12) - 1); },
    namedSectors() {
      if (!this.showNames) return [];
      return this.sectors.filter((s) => s.name && Array.isArray(s.centroid));
    },
  },
  methods: {
    resize(value) {
      return value * (this.containerSize / this.size);
    },
    sectorPoints(sector) {
      // points03 is the polygon inset by 0.3 game units, stored by the
      // wizard so adjacent sectors don't visually collide; older maps
      // may only have the raw points.
      const points = sector.points03 || sector.points || [];
      return points.map((p) => `${this.resize(p[0])},${this.resize(p[1])}`).join(' ');
    },
    themeOf(sector) {
      if (!this.factionThemes || !sector.faction) return '';
      return this.factionThemes[sector.faction] || '';
    },
    measure() {
      if (this.$refs.container) {
        this.containerSize = this.$refs.container.clientWidth;
      }
    },
    fetchEdges() {
      if (!this.showEdges || this.systems.length === 0) return;
      const systems = this.systems.map((s) => ({ key: s.key, position: s.position }));
      const blackholes = this.blackholes.map((b) => ({ radius: b.radius, position: b.position }));
      this.$axios.post('/maps/preview-edges', { systems, blackholes }).then(({ data }) => {
        // Deep-freeze before assigning — Vue 2 would otherwise walk and
        // reactify every edge, which at large system counts is the exact
        // dep-track blowup the wizard already works around.
        for (let i = 0; i < data.length; i += 1) {
          const e = data[i];
          if (e.s1 && e.s1.position) Object.freeze(e.s1.position);
          if (e.s1) Object.freeze(e.s1);
          if (e.s2 && e.s2.position) Object.freeze(e.s2.position);
          if (e.s2) Object.freeze(e.s2);
          Object.freeze(e);
        }
        this.edges = Object.freeze(data);
      }).catch(() => {
        // Lanes are decoration here — a rate-limited or failed call
        // just means the preview renders without them.
      });
    },
  },
  mounted() {
    this.$nextTick(this.measure);
    window.addEventListener('resize', this.measure);
    this.fetchEdges();
  },
  beforeDestroy() {
    window.removeEventListener('resize', this.measure);
  },
};
</script>
