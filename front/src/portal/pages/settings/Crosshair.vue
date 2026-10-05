<template>
  <default-layout>
    <div class="fluid-panel is-not-full-sized">
      <v-scrollbar class="panel-aside">
        <settings-nav />

        <div class="panel-aside-bloc">
          <div
            id="crosshair-marks"
            class="crosshair-heading">
            {{ $t('page.settings.crosshair.marks.title') }}
          </div>

          <div
            role="group"
            aria-labelledby="crosshair-marks">
            <div
              v-for="mark in marks"
              :key="mark.key"
              class="crosshair-mark-option">
              <div class="checkbox-input has-small-bm">
                <input
                  type="checkbox"
                  :id="`crosshair-${mark.key}`"
                  v-model="draft[mark.key]">
                <label :for="`crosshair-${mark.key}`">
                  {{ $t(`page.settings.crosshair.marks.${mark.key}`) }}
                </label>
              </div>

              <template v-if="draft[mark.key]">
                <div
                  v-for="size in mark.sizes"
                  :key="size"
                  class="default-input">
                  <label :id="`crosshair-${size}`">
                    {{ $t(`page.settings.crosshair.size.${size}`) }}
                    <strong>{{ $t('page.settings.crosshair.size.px', { size: draft[size] }) }}</strong>
                  </label>
                  <div class="input-slider">
                    <vue-slider
                      :min="limits[size].min"
                      :max="limits[size].max"
                      :interval="sizeStep"
                      :dotSize="16"
                      :height="8"
                      tooltip="none"
                      :dot-attrs="{ 'aria-labelledby': `crosshair-${size}` }"
                      v-model="draft[size]">
                    </vue-slider>
                  </div>
                </div>
              </template>
            </div>
          </div>

          <!-- aria-disabled, not disabled: the button keeps the keyboard
               focus once it has done its work. -->
          <button
            type="button"
            :class="['default-button', 'fullsized', { disabled: isHidden }]"
            :aria-disabled="isHidden ? 'true' : null"
            @click="removeMarks">
            {{ $t('page.settings.crosshair.marks.remove') }}
          </button>
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-small">
        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.settings.crosshair.title') }}</strong>
          </h1>
        </div>

        <v-scrollbar class="content">
          <p class="crosshair-intro">
            {{ $t('page.settings.crosshair.intro') }}
          </p>

          <!-- A stand-in for the galaxy map: the dark of space, a system
               at the center (the map centers on one) and a few around. -->
          <div
            ref="preview"
            class="crosshair-preview"
            role="img"
            :aria-label="previewLabel">
            <div
              v-for="(star, index) in stars"
              :key="index"
              class="crosshair-preview-star"
              :style="star">
            </div>
            <div
              class="crosshair-preview-center"
              :style="{ transform: `scale(${previewScale})` }">
              <crosshair-marks
                :crosshair="draft"
                :faction="previewFaction" />
            </div>
          </div>

          <p class="crosshair-note">
            <template v-if="isHidden">
              {{ $t('page.settings.crosshair.hidden') }}
            </template>
            <template v-else-if="previewScale < 1">
              {{ $t('page.settings.crosshair.scaled', { percent: Math.round(previewScale * 100) }) }}
            </template>
            <template v-else>
              {{ $t('page.settings.crosshair.actual_size') }}
            </template>
          </p>

          <button
            type="button"
            :class="['default-button', { disabled: isDefault }]"
            :aria-disabled="isDefault ? 'true' : null"
            @click="reset">
            {{ $t('page.settings.crosshair.reset') }}
          </button>

          <hr class="margin">
        </v-scrollbar>
      </div>

      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc">
          <div class="crosshair-heading">
            {{ $t('page.settings.crosshair.color.title') }}
          </div>

          <div class="checkbox-input">
            <input
              type="checkbox"
              id="crosshair-match-faction"
              v-model="draft.match_faction">
            <label for="crosshair-match-faction">
              {{ $t('page.settings.crosshair.color.match_faction') }}
            </label>
          </div>

          <template v-if="draft.match_faction">
            <p class="crosshair-hint">
              {{ $t('page.settings.crosshair.color.match_hint') }}
            </p>

            <div
              id="crosshair-preview-faction"
              class="crosshair-heading is-small">
              {{ $t('page.settings.crosshair.color.preview_faction') }}
            </div>
            <div
              class="crosshair-swatches"
              role="group"
              aria-labelledby="crosshair-preview-faction">
              <button
                v-for="faction in factions"
                :key="faction.key"
                type="button"
                :class="['crosshair-swatch', { 'is-active': previewFaction === faction.key }]"
                :style="{ background: faction.color }"
                v-tooltip="$t(`data.faction.${faction.key}.name`)"
                :aria-label="$t(`data.faction.${faction.key}.name`)"
                :aria-pressed="previewFaction === faction.key ? 'true' : 'false'"
                @click="previewFaction = faction.key">
              </button>
            </div>
          </template>

          <template v-else>
            <color-wheel v-model="draft.color" />

            <div class="default-input crosshair-hex">
              <label for="crosshair-hex">
                {{ $t('page.settings.crosshair.color.hex') }}
                <span
                  class="crosshair-hex-sample"
                  :style="{ background: draft.color }">
                </span>
              </label>
              <input
                id="crosshair-hex"
                type="text"
                maxlength="7"
                spellcheck="false"
                autocomplete="off"
                v-model="hexText"
                @input="onHexInput"
                @blur="hexText = draft.color">
            </div>

            <div
              id="crosshair-faction-colors"
              class="crosshair-heading is-small">
              {{ $t('page.settings.crosshair.color.factions') }}
            </div>
            <div
              class="crosshair-swatches"
              role="group"
              aria-labelledby="crosshair-faction-colors">
              <button
                v-for="faction in factions"
                :key="faction.key"
                type="button"
                :class="['crosshair-swatch', { 'is-active': draft.color === faction.color }]"
                :style="{ background: faction.color }"
                v-tooltip="$t(`data.faction.${faction.key}.name`)"
                :aria-label="$t(`data.faction.${faction.key}.name`)"
                :aria-pressed="draft.color === faction.color ? 'true' : 'false'"
                @click="draft.color = faction.color">
              </button>
            </div>
          </template>
        </div>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import { debounce } from 'lodash';
import VueSlider from 'vue-slider-component';

import DefaultLayout from '@/portal/layouts/Default.vue';
import SettingsNav from '@/portal/components/SettingsNav.vue';
import ColorWheel from '@/portal/components/ColorWheel.vue';
import CrosshairMarks from '@/game/components/galaxy/CrosshairMarks.vue';
import { FACTIONS } from '@/utils/factions';
import {
  DEFAULT_CROSSHAIR, MARKS, SIZE_LIMITS, SIZE_STEP,
  crosshairExtent, isDefaultCrosshair, normalizeHex,
} from '@/utils/crosshair';

// The sliders each mark comes with.
const MARK_SIZES = {
  cross: ['width', 'height'],
  circle: ['circle_size'],
  dot: ['dot_size'],
};

// Clear space kept between the marks and the edge of the preview, px.
const PREVIEW_MARGIN = 16;

// Systems scattered over the preview, in % of its box. The one at the
// center is drawn by .crosshair-preview-center itself.
const STARS = [
  [12, 22, 5], [24, 71, 4], [33, 38, 3], [41, 84, 5], [58, 14, 4],
  [67, 63, 3], [76, 31, 5], [86, 78, 4], [91, 18, 3], [8, 52, 3],
].map(([left, top, size]) => ({
  left: `${left}%`, top: `${top}%`, width: `${size}px`, height: `${size}px`,
}));

export default {
  name: 'settings-crosshair',
  data() {
    const draft = { ...this.$store.getters['portal/crosshair'] };

    return {
      // What the preview shows. Saved a moment after the last change: a
      // drag on a slider or the wheel changes it many times a second, and
      // every save posts the whole settings object.
      draft,
      hexText: draft.color,
      // Whose color the preview takes while the crosshair matches the
      // faction: there is no match, and so no faction, on this screen.
      previewFaction: FACTIONS[0].key,
      previewSize: { width: 0, height: 0 },
      marks: MARKS.map((key) => ({ key, sizes: MARK_SIZES[key] })),
      limits: SIZE_LIMITS,
      sizeStep: SIZE_STEP,
      factions: FACTIONS,
      stars: STARS,
    };
  },
  computed: {
    isHidden() { return MARKS.every((mark) => !this.draft[mark]); },
    isDefault() { return isDefaultCrosshair(this.draft); },
    // Under 1 when the crosshair is larger than the preview: it is shrunk
    // to fit, and the note under it says so.
    previewScale() {
      const { x, y } = crosshairExtent(this.draft);
      const { width, height } = this.previewSize;
      if (!width || !height || (!x && !y)) return 1;

      return Math.min(
        1,
        (width / 2 - PREVIEW_MARGIN) / Math.max(x, 1),
        (height / 2 - PREVIEW_MARGIN) / Math.max(y, 1),
      );
    },
    previewLabel() {
      if (this.isHidden) return this.$t('page.settings.crosshair.hidden');

      const marks = MARKS
        .filter((mark) => this.draft[mark])
        .map((mark) => this.$t(`page.settings.crosshair.marks.${mark}`))
        .join(', ');

      return this.$t('page.settings.crosshair.preview', { marks });
    },
  },
  watch: {
    draft: {
      deep: true,
      handler() {
        // The field keeps what is being typed until it is left.
        if (normalizeHex(this.hexText) !== this.draft.color) this.hexText = this.draft.color;
        this.save();
      },
    },
  },
  methods: {
    removeMarks() {
      if (this.isHidden) return;

      MARKS.forEach((mark) => { this.draft[mark] = false; });
      this.$announce(this.$t('page.settings.crosshair.hidden'));
    },
    reset() {
      if (this.isDefault) return;

      this.draft = { ...DEFAULT_CROSSHAIR };
      this.$announce(this.$t('page.settings.crosshair.reset_done'));
    },
    onHexInput() {
      const hex = normalizeHex(this.hexText);
      if (hex) this.draft.color = hex;
    },
    measurePreview() {
      const { preview } = this.$refs;
      if (preview) this.previewSize = { width: preview.clientWidth, height: preview.clientHeight };
    },
  },
  created() {
    this.save = debounce(() => {
      this.$store.dispatch('portal/setCrosshair', this.draft);
    }, 400);
  },
  mounted() {
    this.measurePreview();
    window.addEventListener('resize', this.measurePreview);
  },
  beforeDestroy() {
    window.removeEventListener('resize', this.measurePreview);
    // Leaving right after a change must not lose it.
    this.save.flush();
  },
  components: {
    ColorWheel,
    CrosshairMarks,
    DefaultLayout,
    SettingsNav,
    VueSlider,
  },
};
</script>

<style lang="scss" scoped>
.crosshair-heading {
  margin-bottom: 10px;
  font-size: 1.4rem;
  font-weight: bold;
  text-transform: uppercase;

  &.is-small {
    margin-top: 20px;
    font-size: 1.2rem;
    font-weight: normal;
    opacity: .8;
  }
}

.crosshair-mark-option {
  margin-bottom: 15px;

  .default-input {
    margin: 0 0 10px 0;
  }
}

.crosshair-intro {
  margin-bottom: 20px;
}

.crosshair-preview {
  position: relative;
  height: 300px;
  overflow: hidden;
  // The galaxy map's backdrop, near enough: the crosshair has to be
  // judged against the dark it will sit on.
  background: radial-gradient(circle at 50% 40%, #121722, #0a0c12 75%);
  border: solid 1px rgba(0, 0, 0, .5);
  box-shadow: inset 0 0 40px rgba(0, 0, 0, .6);
}

.crosshair-preview-star {
  position: absolute;
  border-radius: 50%;
  background: #c9ced8;
  opacity: .7;
}

.crosshair-preview-center {
  position: absolute;
  top: 50%; left: 50%;
  width: 0; height: 0;

  // The system the map is centered on.
  &:before {
    content: '';
    position: absolute;
    top: -3px; left: -3px;
    width: 6px; height: 6px;
    border-radius: 50%;
    background: #e6e6e6;
    box-shadow: 0 0 8px rgba(230, 230, 230, .6);
  }
}

.crosshair-note {
  margin: 10px 0 20px 0;
  font-size: 1.3rem;
  opacity: .7;
}

.crosshair-hint {
  margin-bottom: 5px;
  font-size: 1.3rem;
  opacity: .8;
}

// .default-input twice over: the portal's own rule for it is as specific
// as a single scoped class.
.default-input.crosshair-hex {
  margin: 20px 0 0 0;

  input {
    font-family: monospace;
    text-transform: lowercase;
  }
}

.crosshair-hex-sample {
  width: 20px; height: 20px;
  border-radius: 3px;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, .3);
}

.crosshair-swatches {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}

.crosshair-swatch {
  width: 34px; height: 34px;
  padding: 0;
  border: solid 2px rgba(0, 0, 0, .6);
  border-radius: 50%;
  cursor: pointer;
  transition: transform linear 100ms;

  &:hover {
    transform: scale(1.1);
  }

  &.is-active {
    border-color: #e6e6e6;
    box-shadow: 0 0 0 2px rgba(0, 0, 0, .6);
  }
}
</style>
