<template>
  <div
    class="crosshair-marks"
    :style="{ color }"
    aria-hidden="true">
    <div
      v-for="(mark, index) in marks"
      :key="index"
      :class="['crosshair-mark', `is-${mark.type}`]"
      :style="mark.style">
    </div>
  </div>
</template>

<script>
import { crosshairColor, crosshairMarks, THICKNESS } from '@/utils/crosshair';
import { FACTIONS, BOT_FACTIONS } from '@/utils/factions';

// The galaxy map's crosshair, drawn around the top-left corner of whatever
// positioned element holds it: the center of the map in a match, the center
// of the preview on the settings screen.
export default {
  name: 'crosshair-marks',
  props: {
    // A complete crosshair (utils/crosshair normalizeCrosshair).
    crosshair: { type: Object, required: true },
    // Key of the faction being played, when there is one.
    faction: { type: String, default: null },
  },
  computed: {
    marks() {
      return crosshairMarks(this.crosshair).map((mark) => ({
        type: mark.type,
        style: {
          left: `${mark.left}px`,
          top: `${mark.top}px`,
          width: `${mark.width}px`,
          height: `${mark.height}px`,
          borderWidth: mark.type === 'circle' ? `${THICKNESS}px` : null,
        },
      }));
    },
    color() {
      const faction = [...FACTIONS, ...BOT_FACTIONS].find((f) => f.key === this.faction);
      return crosshairColor(this.crosshair, faction ? faction.color : null);
    },
  },
};
</script>

<style lang="scss" scoped>
.crosshair-marks {
  position: absolute;
  top: 0; left: 0;
  width: 0; height: 0;
}

.crosshair-mark {
  position: absolute;
  box-sizing: border-box;
  background: currentColor;

  &.is-circle, &.is-dot {
    border-radius: 50%;
  }

  &.is-circle {
    background: none;
    border: solid 0 currentColor;
  }
}
</style>
