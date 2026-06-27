<template>
  <default-layout>
    <div class="fluid-panel is-not-full-sized">
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc">
          <div class="radio-input is-horizontal">
            <div class="label">
              {{ $t('page.settings.language_choice') }}
            </div>
            <div class="content">
              <div
                v-for="(language, languageCode) in languages"
                :key="languageCode"
                class="content-item">
                <input
                  type="radio"
                  :id="`size-${languageCode}`"
                  :value="languageCode"
                  v-model="selectedLanguage"
                  @change="setLanguage">
                <label :for="`size-${languageCode}`">
                  <strong>
                    {{ language }}
                  </strong>
                </label>
              </div>
            </div>
          </div>

          <div class="radio-input is-horizontal">
            <div class="label">
              {{ $t('page.settings.number_format') }}
            </div>
            <div class="content">
              <div
                v-for="formatCode in numberFormats"
                :key="formatCode"
                class="content-item">
                <input
                  type="radio"
                  :id="`numfmt-${formatCode}`"
                  :value="formatCode"
                  v-model="selectedNumberFormat"
                  @change="setNumberFormat">
                <label :for="`numfmt-${formatCode}`">
                  <strong>{{ formatCode.toUpperCase() }}</strong>
                  &mdash; {{ exampleFor(formatCode) }}
                </label>
              </div>
            </div>
          </div>
        </div>

        <div
          v-if="mode === 'development'"
          class="panel-aside-bloc">
          <div class="radio-input">
            <div class="label">
              Test son
            </div>
            <div class="content">
              <button
                @click="testSound('click')"
                class="default-button">
                1
              </button>
              <button
                @click="testSound('panel-open')"
                class="default-button">
                2
              </button>
              <button
                @click="testSound('panel-close')"
                class="default-button">
                3
              </button>
              <button
                @click="testSound('system-open')"
                class="default-button">
                4
              </button>
              <button
                @click="testSound('system-close')"
                class="default-button">
                5
              </button>
              <button
                @click="testSound('mini-panel-open')"
                class="default-button">
                6
              </button>
              <button
                @click="testSound('error')"
                class="default-button">
                7
              </button>
            </div>
          </div>
        </div>

        <div class="panel-aside-bloc">
          <div class="label">
            {{ $t('page.settings.mutes.title') }}
          </div>
          <p
            v-if="mutedEntries.length === 0"
            class="mute-empty">
            {{ $t('page.settings.mutes.empty') }}
          </p>
          <div
            v-for="entry in mutedEntries"
            :key="`mute-${entry.id}`"
            class="mute-row">
            <strong class="mute-name">{{ entry.name }}</strong>
            <div class="mute-toggles">
              <button
                @click="toggleMute('chat', entry.id)"
                v-tooltip="entry.chat
                  ? $t('page.settings.mutes.tooltip.unmute_chat')
                  : $t('page.settings.mutes.tooltip.mute_chat')"
                :class="['mute-toggle', { 'is-muted': entry.chat }]"
                :aria-label="entry.chat
                  ? $t('page.settings.mutes.tooltip.unmute_chat')
                  : $t('page.settings.mutes.tooltip.mute_chat')"
                :aria-pressed="entry.chat">
                <svgicon name="chat" />
              </button>
              <button
                @click="toggleMute('icons', entry.id)"
                v-tooltip="entry.icons
                  ? $t('page.settings.mutes.tooltip.unmute_icons')
                  : $t('page.settings.mutes.tooltip.mute_icons')"
                :class="['mute-toggle', { 'is-muted': entry.icons }]"
                :aria-label="entry.icons
                  ? $t('page.settings.mutes.tooltip.unmute_icons')
                  : $t('page.settings.mutes.tooltip.mute_icons')"
                :aria-pressed="entry.icons">
                <svgicon name="smiley" />
              </button>
            </div>
          </div>
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-small">
        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.settings.title') }}</strong>
          </h1>
        </div>

        <v-scrollbar class="content">
          <div
            class="default-input">
            <label for="name">{{ $t('page.settings.master_volume') }}</label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="0"
                :max="1"
                :interval="0.01"
                :dotSize="16"
                :height="8"
                tooltip="none"
                v-model="ambiance.master"
                @change="updateAmbiance">
              </vue-slider>
            </div>
          </div>

          <hr class="separator">

          <div
            class="default-input">
            <label for="name">{{ $t('page.settings.music_volume') }}</label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="0"
                :max="1"
                :interval="0.01"
                :dotSize="16"
                :height="8"
                tooltip="none"
                v-model="ambiance.music"
                @change="updateAmbiance">
              </vue-slider>
            </div>
          </div>

          <div
            class="default-input">
            <label for="name">{{ $t('page.settings.sound_volume') }}</label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="0"
                :max="1"
                :interval="0.01"
                :dotSize="16"
                :height="8"
                tooltip="none"
                v-model="ambiance.sound"
                @change="updateAmbiance">
              </vue-slider>
            </div>
          </div>

          <div
            class="default-input">
            <label for="name">{{ $t('page.settings.voice_volume') }}</label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="0"
                :max="1"
                :interval="0.01"
                :dotSize="16"
                :height="8"
                tooltip="none"
                v-model="ambiance.voice"
                @change="updateAmbiance">
              </vue-slider>
            </div>
          </div>

          <hr class="margin">
        </v-scrollbar>
      </div>

      <v-scrollbar class="panel-aside">
        <div
          v-show="isSteam"
          class="panel-aside-bloc">
          <div class="checkbox-input">
            <input
              type="checkbox"
              id="windowed"
              v-model="windowed">
            <label for="windowed">{{ $t('page.settings.windowed') }}</label>
          </div>

          <div class="default-input">
            <label for="name">
              {{ $t('page.settings.resolution') }}
              <strong>
                {{ Math.round(Math.pow(1.2, uiScale) * 20) * 5 }}%
              </strong>
            </label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="-3"
                :max="3"
                :interval="0.5"
                :marks="true"
                :hideLabel="true"
                :dotSize="16"
                :height="8"
                tooltip="none"
                v-model="uiScale"
                @change="updateUIScale">
              </vue-slider>
            </div>
          </div>
        </div>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import VueSlider from 'vue-slider-component';
import DefaultLayout from '@/portal/layouts/Default.vue';
import { availableLanguages } from '@/plugins/i18n';
import { exampleForLang } from '@/utils/format';
import config from '@/config';

// eslint-disable-next-line prefer-const
let nwin = {
  isFullscreen: false,
  leaveFullscreen() {},
  enterFullscreen() {},
  zoomLevel: 0,
};

// const ngui = require('nw.gui');
// nwin = ngui.Window.get();

export default {
  name: 'settings',
  data() {
    return {
      mode: config.MODE,
      languages: {
        en: 'English',
        fr: 'Français',
        de: 'Deutsch (Umlaufbestand)',
      },
      selectedLanguage: this.$store.state.portal.settings.lang,
      selectedNumberFormat:
        this.$store.state.portal.settings.numberFormat
        || this.$store.state.portal.settings.lang
        || 'en',
      numberFormats: ['en', 'fr', 'de'],
      ambiance: this.$store.state.portal.settings.ambiance,
      windowed: !nwin.isFullscreen,
      isSteam: config.IS_STEAM,
      uiScale: this.$store.state.portal.settings.uiScale || 0,
      // profileId → name. Filled lazily on mount by hitting
      // GET /profiles/:pid for each id in either mute list. The
      // setting only stores ids (cross-game stable, smaller payload),
      // so we need this lookup just to render readable names on the
      // manage screen. A missing entry falls back to a numeric id.
      mutedNames: {},
      // Ids that appeared muted (in either list) at any point during
      // this session. Keeps a row visible after the user toggles both
      // mutes off, so the toggle remains discoverable and reversible
      // without leaving the page. Reset on next mount.
      sessionMutedIds: [],
    };
  },
  computed: {
    availableLanguages() { return availableLanguages; },
    mutedChatIds() { return this.$store.getters['portal/mutedChatIds']; },
    mutedIconIds() { return this.$store.getters['portal/mutedIconIds']; },
    // Rows for every id that was muted when the page loaded plus
    // anything muted since. `chat` / `icons` reflect *current* state
    // from the store, so the toggle icons update live as the user
    // clicks. Sorted by name (id fallback) for render stability.
    mutedEntries() {
      return this.sessionMutedIds
        .map((id) => ({
          id,
          name: this.mutedNames[id] || `#${id}`,
          chat: this.mutedChatIds.includes(id),
          icons: this.mutedIconIds.includes(id),
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
    },
  },
  watch: {
    windowed(isWindowed) {
      if (isWindowed) {
        nwin.leaveFullscreen();
      } else {
        nwin.enterFullscreen();
      }
    },
    // Backfill names when the user unmutes/mutes (rare here, but free).
    // Also pin any freshly-muted id to sessionMutedIds so the row stays
    // visible if they toggle it back off later in the same session.
    mutedChatIds(ids) {
      ids.forEach((id) => this.rememberMuted(id));
      this.loadMutedNames();
    },
    mutedIconIds(ids) {
      ids.forEach((id) => this.rememberMuted(id));
      this.loadMutedNames();
    },
  },
  methods: {
    testSound(key) {
      this.$ambiance.sound(key);
    },
    async setLanguage() {
      const language = this.selectedLanguage;
      await this.$store.dispatch('portal/setLanguage', language);
      // setLanguage re-syncs number format to the language's customary
      // format (see portal/store.js). Mirror that locally so the radio
      // ticks over without the user having to click.
      this.selectedNumberFormat = language;
    },
    async setNumberFormat() {
      await this.$store.dispatch('portal/setNumberFormat', this.selectedNumberFormat);
    },
    exampleFor(lang) {
      return exampleForLang(lang);
    },
    async updateAmbiance() {
      await this.$store.dispatch('portal/updateAmbiance', this.ambiance);
    },
    updateUIScale() {
      nwin.zoomLevel = this.uiScale;
      this.$store.commit('portal/updateSettings', { uiScale: this.uiScale });
    },
    toggleMute(kind, profileId) {
      this.$store.commit('portal/toggleMute', { kind, profileId });
    },
    // Add `id` to the session row-keep set if it isn't already there.
    // Called on mount (for the initial mute lists) and from the watcher
    // (for anyone newly muted while the page is open).
    rememberMuted(id) {
      if (!this.sessionMutedIds.includes(id)) {
        this.sessionMutedIds = [...this.sessionMutedIds, id];
      }
    },
    async loadMutedNames() {
      // Fan out one GET per muted id. Typical mute lists are tiny
      // (<10) so this is fine; if a user racks up hundreds we'd
      // want a batch endpoint, but that's a v2 problem.
      const ids = Array.from(new Set([...this.mutedChatIds, ...this.mutedIconIds]));
      const lookups = ids.map(async (id) => {
        if (this.mutedNames[id]) return null;
        try {
          const r = await this.$axios.get(`/profiles/${id}`);
          return [id, r.data && r.data.name];
        } catch (e) {
          return null;
        }
      });
      const results = await Promise.all(lookups);
      const fresh = { ...this.mutedNames };
      results.forEach((entry) => {
        if (entry && entry[1]) {
          [, fresh[entry[0]]] = entry;
        }
      });
      this.mutedNames = fresh;
    },
  },
  async mounted() {
    this.sessionMutedIds = Array.from(new Set([
      ...this.mutedChatIds,
      ...this.mutedIconIds,
    ]));
    await this.loadMutedNames();
  },
  components: {
    DefaultLayout,
    VueSlider,
  },
};
</script>

<style lang="scss" scoped>
.mute-empty {
  margin: 0.5rem 0;
  opacity: 0.6;
  font-style: italic;
}

.mute-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.4rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
}

.mute-name {
  flex: 1 1 auto;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.mute-toggles {
  display: flex;
  gap: 0.25rem;
  flex: 0 0 auto;
}

.mute-toggle {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1.85rem;
  height: 1.85rem;
  padding: 0;
  background: transparent;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 4px;
  color: inherit;
  cursor: pointer;
  opacity: 0.55;
  transition: opacity 0.15s ease, border-color 0.15s ease, background-color 0.15s ease;

  ::v-deep svg {
    width: 1.05rem;
    height: 1.05rem;
    fill: currentColor;
  }

  &:hover,
  &:focus-visible {
    opacity: 1;
    border-color: rgba(255, 255, 255, 0.4);
    background-color: rgba(255, 255, 255, 0.05);
  }

  // Muted state — overlay a diagonal strike from bottom-left to top-right.
  // currentColor keeps it themable; the line sits above the icon via z-index.
  &.is-muted {
    opacity: 0.95;

    &::after {
      content: '';
      position: absolute;
      left: 12%;
      right: 12%;
      top: 50%;
      height: 2px;
      background: currentColor;
      transform: rotate(-45deg);
      transform-origin: center;
      pointer-events: none;
    }
  }
}
</style>
