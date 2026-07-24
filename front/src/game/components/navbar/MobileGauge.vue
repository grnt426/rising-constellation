<template>
  <div
    class="mobile-gauge"
    :class="[
      theme ? `is-color-${theme}` : '',
      { 'is-full': max > 0 && value >= max },
    ]"
    v-tooltip="tooltip">
    <svg viewBox="0 0 40 40">
      <circle
        class="mg-track"
        cx="20" cy="20" r="16" />
      <circle
        v-if="ratio > 0"
        class="mg-fill"
        cx="20" cy="20" r="16"
        pathLength="100"
        :stroke-dasharray="`${ratio} 100`"
        transform="rotate(-90 20 20)" />

      <!-- Identity glyphs: a system is "yours at the center" (filled
           core, neutral satellites); a dominion is "yours on the edge"
           (hollow core, faction satellites). -->
      <g v-if="glyph === 'system'">
        <circle class="mg-glyph-core" cx="8" cy="7" r="2.2" />
        <circle
          v-for="(p, i) in ringDots(6, 8, 7, 5)"
          :key="`s-${i}`"
          class="mg-glyph-dot"
          :cx="p.x" :cy="p.y" r=".9" />
      </g>
      <g v-else-if="glyph === 'dominion'">
        <circle class="mg-glyph-hollow" cx="8" cy="7" r="2" />
        <circle
          v-for="(p, i) in ringDots(3, 8, 7, 5)"
          :key="`d-${i}`"
          class="mg-glyph-core"
          :cx="p.x" :cy="p.y" r="1.3" />
      </g>

      <template v-if="letter">
        <text
          class="mg-letter"
          x="20" y="25.5"
          text-anchor="middle">{{ letter }}</text>
      </template>
      <template v-else>
        <text
          class="mg-value"
          x="19" y="24.5"
          text-anchor="middle">{{ value }}</text>
        <text
          class="mg-max"
          x="30.5" y="36"
          text-anchor="middle">/{{ max }}</text>
      </template>
    </svg>
  </div>
</template>

<script>
export default {
  name: 'mobile-gauge',
  props: {
    value: { type: Number, required: true },
    max: { type: Number, required: true },
    letter: { type: String, default: null },
    glyph: { type: String, default: null },
    theme: { type: String, default: null },
    tooltip: { type: String, default: null },
  },
  computed: {
    ratio() {
      if (!this.max || this.max <= 0) return 0;
      return Math.max(0, Math.min(100, Math.round((this.value / this.max) * 100)));
    },
  },
  methods: {
    ringDots(n, cx, cy, r) {
      return Array.from({ length: n }, (_, i) => {
        const angle = -Math.PI / 2 + (i * 2 * Math.PI) / n;
        return {
          x: +(cx + r * Math.cos(angle)).toFixed(2),
          y: +(cy + r * Math.sin(angle)).toFixed(2),
        };
      });
    },
  },
};
</script>
