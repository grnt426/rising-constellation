<template>
  <div
    class="mobile-gauge mobile-tri-gauge"
    v-tooltip="tooltip">
    <svg viewBox="0 0 40 40">
      <g
        v-for="(seg, i) in arcs"
        :key="seg.letter">
        <circle
          class="mg-track"
          cx="20" cy="20" r="16"
          pathLength="100"
          :stroke-dasharray="`${segLength} ${100 - segLength}`"
          :stroke-dashoffset="-(i * segWindow + segGap / 2)"
          transform="rotate(-90 20 20)" />
        <circle
          v-if="seg.fillLength > 0"
          class="mg-fill"
          :class="{ 'is-seg-full': seg.value >= seg.max && seg.max > 0 }"
          cx="20" cy="20" r="16"
          pathLength="100"
          :stroke-dasharray="`${seg.fillLength} ${100 - seg.fillLength}`"
          :stroke-dashoffset="-(i * segWindow + segGap / 2)"
          transform="rotate(-90 20 20)" />
        <text
          class="mg-seg-letter"
          :x="seg.x" :y="seg.y"
          text-anchor="middle">{{ seg.letter }}</text>
      </g>
    </svg>
  </div>
</template>

<script>
// One ring, three independent thirds — each third fills with its own
// usage ratio. Segment 0 starts at 12 o'clock and they run clockwise.
const SEG_WINDOW = 100 / 3;
const SEG_GAP = 4;

export default {
  name: 'mobile-tri-gauge',
  props: {
    // [{ letter, value, max }] — exactly three entries.
    segments: { type: Array, required: true },
    tooltip: { type: String, default: null },
  },
  computed: {
    segWindow() { return SEG_WINDOW; },
    segGap() { return SEG_GAP; },
    segLength() { return SEG_WINDOW - SEG_GAP; },
    arcs() {
      return this.segments.map((seg, i) => {
        const ratio = seg.max > 0 ? Math.max(0, Math.min(1, seg.value / seg.max)) : 0;
        const midDeg = i * 120 + 60 - 90;
        const rad = (midDeg * Math.PI) / 180;
        return {
          ...seg,
          fillLength: +(ratio * this.segLength).toFixed(2),
          x: +(20 + 10 * Math.cos(rad)).toFixed(2),
          y: +(20 + 10 * Math.sin(rad) + 2.2).toFixed(2),
        };
      });
    },
  },
};
</script>
