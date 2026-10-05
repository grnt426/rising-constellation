<template>
  <div class="color-wheel">
    <!-- Hue around the disc, saturation from its center out; the slider
         below is the third axis. A slider to assistive tech: its value is
         the hue, its text gives both. -->
    <div
      ref="disc"
      class="color-wheel-disc"
      role="slider"
      aria-valuemin="0"
      aria-valuemax="360"
      :aria-valuenow="hue"
      :aria-valuetext="$t('page.settings.crosshair.color.wheel_value', { hue, saturation })"
      :aria-label="$t('page.settings.crosshair.color.wheel')"
      tabindex="0"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="onPointerUp"
      @pointercancel="onPointerUp"
      @keydown="onKeydown">
      <div
        class="color-wheel-shade"
        :style="{ opacity: (1 - hsv.v) * 0.8 }">
      </div>
      <div
        class="color-wheel-marker"
        :style="markerStyle">
      </div>
    </div>

    <div class="default-input">
      <label :id="`${uid}-brightness`">
        {{ $t('page.settings.crosshair.color.brightness') }}
        <strong>{{ brightness }}%</strong>
      </label>
      <div class="input-slider">
        <vue-slider
          :min="0"
          :max="100"
          :interval="1"
          :dotSize="16"
          :height="8"
          tooltip="none"
          :dot-attrs="{ 'aria-labelledby': `${uid}-brightness` }"
          v-model="brightness">
        </vue-slider>
      </div>
    </div>
  </div>
</template>

<script>
import VueSlider from 'vue-slider-component';
import { hexToHsv, hsvToHex, normalizeHex } from '@/utils/crosshair';

const HUE_STEP = 5;
const SATURATION_STEP = 0.05;

let instances = 0;

export default {
  name: 'color-wheel',
  props: {
    // '#rrggbb'
    value: { type: String, required: true },
  },
  data() {
    instances += 1;

    return {
      uid: `color-wheel-${instances}`,
      // Kept here, not derived from `value` on every render: black and the
      // greys have no hue of their own, and the marker must not jump back
      // to red each time the color passes through one.
      hsv: hexToHsv(this.value),
      dragging: false,
    };
  },
  computed: {
    hue() { return Math.round(this.hsv.h) % 360; },
    saturation() { return Math.round(this.hsv.s * 100); },
    brightness: {
      get() { return Math.round(this.hsv.v * 100); },
      set(percent) { this.pick({ v: percent / 100 }); },
    },
    markerStyle() {
      // conic-gradient angles: 0 at the top, clockwise.
      const angle = (this.hsv.h * Math.PI) / 180;

      return {
        left: `${50 + Math.sin(angle) * this.hsv.s * 50}%`,
        top: `${50 - Math.cos(angle) * this.hsv.s * 50}%`,
        background: hsvToHex(this.hsv),
      };
    },
  },
  watch: {
    // A color set from outside (a quick pick, the hex field, a reset).
    value(value) {
      const hex = normalizeHex(value);
      if (!hex || hex === hsvToHex(this.hsv)) return;

      const next = hexToHsv(hex);
      if (next.v === 0) next.s = this.hsv.s;
      if (next.v === 0 || next.s === 0) next.h = this.hsv.h;
      this.hsv = next;
    },
  },
  methods: {
    pick(change) {
      this.hsv = { ...this.hsv, ...change };
      this.$emit('input', hsvToHex(this.hsv));
    },
    // Hue and saturation from the wheel. At zero brightness every point of
    // it is black, so a pick there would seem to do nothing: it also turns
    // the brightness all the way up.
    pickOnDisc(change) {
      this.pick(this.hsv.v === 0 ? { ...change, v: 1 } : change);
    },
    pickAt(event) {
      const rect = this.$refs.disc.getBoundingClientRect();
      const radius = rect.width / 2;
      const dx = event.clientX - (rect.left + radius);
      const dy = event.clientY - (rect.top + radius);

      this.pickOnDisc({
        h: ((Math.atan2(dx, -dy) * 180) / Math.PI + 360) % 360,
        s: Math.min(1, Math.hypot(dx, dy) / radius),
      });
    },
    onPointerDown(event) {
      if (event.button > 0) return;

      this.dragging = true;
      this.$refs.disc.setPointerCapture(event.pointerId);
      this.pickAt(event);
    },
    onPointerMove(event) {
      if (this.dragging) this.pickAt(event);
    },
    onPointerUp() {
      this.dragging = false;
    },
    onKeydown(event) {
      const { h, s } = this.hsv;
      const change = {
        ArrowRight: { h: (h + HUE_STEP) % 360 },
        ArrowLeft: { h: (h - HUE_STEP + 360) % 360 },
        ArrowUp: { s: Math.min(1, s + SATURATION_STEP) },
        ArrowDown: { s: Math.max(0, s - SATURATION_STEP) },
      }[event.key];

      if (!change) return;

      event.preventDefault();
      this.pickOnDisc(change);
    },
  },
  components: {
    VueSlider,
  },
};
</script>

<style lang="scss" scoped>
.color-wheel .default-input {
  margin-bottom: 0;
}

.color-wheel-disc {
  position: relative;
  width: 180px;
  max-width: 100%;
  aspect-ratio: 1;
  margin: 0 auto 20px auto;
  border-radius: 50%;
  // The hue ring at full saturation, fading to white at the center.
  background:
    radial-gradient(closest-side, #ffffff, rgba(255, 255, 255, 0)),
    conic-gradient(#ff0000, #ffff00, #00ff00, #00ffff, #0000ff, #ff00ff, #ff0000);
  box-shadow: 0 0 0 1px rgba(0, 0, 0, .5), 0 0 0 4px rgba(0, 0, 0, .2);
  // A drag on the wheel picks a color: it must not scroll the page.
  touch-action: none;
}

// Darkens the wheel with the brightness slider. Never fully black, so the
// hues stay readable at zero brightness.
.color-wheel-shade {
  position: absolute;
  top: 0; left: 0; right: 0; bottom: 0;
  border-radius: 50%;
  background: #000000;
  pointer-events: none;
}

.color-wheel-marker {
  position: absolute;
  width: 16px; height: 16px;
  margin: -8px 0 0 -8px;
  border-radius: 50%;
  border: solid 2px #ffffff;
  box-shadow: 0 0 0 1px rgba(0, 0, 0, .8), 0 0 4px rgba(0, 0, 0, .6);
  pointer-events: none;
}
</style>
