<template>
  <default-layout>
    <div class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <section
          v-if="mode === 'new'"
          class="panel-aside-info">
          <h2>{{ $t('page.create.common.step') }} {{ step.number }} — {{ stepLabel }}</h2>
          <p class="is-large">
            {{ $t(`page.create.scenario_editor.step_descriptions.${currentStep}`) }}
          </p>
        </section>

        <div class="panel-aside-bloc">
          <div class="default-input">
            <label for="name">{{ $t('page.create.common.name') }}</label>
            <input
              id="name"
              type="text"
              autocomplete="off"
              placeholder="___"
              v-model="scenario.game_metadata.name" />
          </div>

          <div class="default-input">
            <label for="description">{{ $t('page.create.common.description') }}</label>
            <textarea
              id="description"
              v-model="scenario.game_metadata.description">
            </textarea>
          </div>

        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-square">
        <router-link
          class="close-button"
          to="/create/scenarios">
          {{ $t('page.create.common.back') }}
        </router-link>

        <div
          class="content"
          ref="container">
          <svg
            :width="containerSize"
            :height="containerSize"
            version="1.1"
            xmlns="http://www.w3.org/2000/svg"
            class="map-container">
            <line
              v-for="i in Math.round(scenario.game_metadata.size / 12)"
              :key="`v-${i}`"
              x1="0" :y1="resize(i * 12)"
              x2="100%" :y2="resize(i * 12)"
              class="map-grid" />
            <line
              v-for="i in Math.round(scenario.game_metadata.size / 12)"
              :key="`h-${i}`"
              y1="0" :x1="resize(i * 12)"
              y2="100%" :x2="resize(i * 12)"
              class="map-grid" />

            <circle
              v-for="s in scenario.game_data.systems"
              :key="`system-${s.key}`"
              :cx="resize(s.position.x)"
              :cy="resize(s.position.y)"
              :class="s.type"
              class="map-system" />

            <circle
              v-for="b in scenario.game_data.blackholes"
              :key="`map-blackhole-${b.key}`"
              :cx="resize(b.position.x)"
              :cy="resize(b.position.y)"
              :r="resize(b.radius)"
              class="map-blackhole" />

            <polygon
              v-for="s in scenario.game_data.sectors"
              :key="`sector-${s.key}`"
              :points="offsetPolygon(s.points, 0.5).flat().map(p => resize(p)).join()"
              class="map-sector"
              :class="getTheme(s.faction)"
              @click="toggleSectorToFaction(s.key)" />

            <text
              v-for="s in scenario.game_data.sectors"
              :key="`sector-name-${s.key}`"
              :x="resize(s.centroid[0])"
              :y="resize(s.centroid[1])"
              class="map-sector-name"
              text-anchor="middle"
              :class="getTheme(s.faction)"
              @click="toggleSectorToFaction(s.key)">
              [{{ s.victory_points }}] {{ s.name }} ({{ s.systems.length }})
            </text>
          </svg>

          <hr class="margin">
        </div>
      </div>

      <v-scrollbar class="panel-aside">
        <template v-if="currentStep === 0">
          <div class="panel-aside-bloc">
            <div class="radio-input is-horizontal">
              <div
                class="label"
                v-tooltip="$t('page.create.scenario_editor.scenario_speed_tooltip')">
                {{ $t('page.create.scenario_editor.scenario_speed') }}
              </div>
              <div class="content">
                <div
                  v-for="{ key } in data.speed"
                  :key="`speed-${key}`"
                  class="content-item">
                  <input
                    type="radio"
                    :id="`speed-${key}`"
                    :value="key"
                    v-model="step.speed">
                  <label :for="`speed-${key}`">
                    <strong>{{ $t(`data.speed.${key}.name`) }}</strong>
                    {{ $t(`data.speed.${key}.description`) }}
                  </label>
                </div>
              </div>
            </div>

            <!-- Dev/Prod scenario-mode picker removed: all scenarios are
                 production by default. The field still lives in game_data
                 (set to "prod" in toStep1) so downstream code that
                 branches on it stays happy. -->

            <!--
            <div class="default-input">
              <label>TODO: Resources Starter</label>
            </div>
            -->

            <div class="default-input">
              <label
                for="date"
                v-tooltip="$t('page.create.scenario_editor.starting_year_tooltip')">
                {{ $t('page.create.scenario_editor.starting_year') }}
              </label>
              <input
                id="date"
                type="number"
                v-model.number="scenario.game_data.date" />
            </div>

            <div class="default-input">
              <label for="seed">{{ $t('page.create.common.seed') }}</label>
              <input
                id="seed"
                type="text"
                disabled
                v-model="scenario.game_data.seed" />
              <button
                @click="scenario.game_data.seed = newSeed()"
                class="default-button action">
                ↺
              </button>
            </div>
          </div>

          <section class="panel-aside-info">
            <h2>{{ $t('page.create.scenario_editor.neutral_heading') }}</h2>
            <p>{{ $t('page.create.scenario_editor.neutral_info') }}</p>
          </section>

          <div class="panel-aside-bloc">
            <div class="radio-input is-horizontal">
              <div class="content">
                <div class="content-item">
                  <input
                    type="radio"
                    id="neutral-default"
                    value="default"
                    :checked="scenarioNeutralMode() === 'default'"
                    @change="setScenarioNeutralMode('default')" />
                  <label
                    for="neutral-default"
                    v-tooltip="$t('page.create.scenario_editor.neutral_mode_rng_desc')">
                    <strong>{{ $t('page.create.scenario_editor.neutral_mode_rng') }}</strong>
                  </label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="neutral-fixed"
                    value="fixed"
                    :checked="scenarioNeutralMode() === 'fixed'"
                    @change="setScenarioNeutralMode('fixed')" />
                  <label
                    for="neutral-fixed"
                    v-tooltip="$t('page.create.scenario_editor.neutral_mode_fixed_desc')">
                    <strong>{{ $t('page.create.scenario_editor.neutral_mode_fixed') }}</strong>
                  </label>
                </div>
              </div>
            </div>

            <div
              v-if="scenarioNeutralMode() === 'fixed'"
              class="default-input">
              <label for="neutral-ratio">
                {{ $t('page.create.scenario_editor.neutral_ratio_label') }}
                <strong>{{ Math.round((scenario.game_data.neutralDistribution.ratio || 0) * 100) }}%</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  id="neutral-ratio"
                  :min="0" :max="1" :interval="0.05"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  :value="scenario.game_data.neutralDistribution.ratio || 0"
                  @change="setScenarioNeutralRatio($event)">
                </vue-slider>
              </div>
            </div>
          </div>

          <section class="panel-aside-info">
            <h2>{{ $t('page.create.scenario_editor.mutators_heading') }}</h2>
            <p>{{ $t('page.create.scenario_editor.mutators_info') }}</p>
          </section>

          <div class="panel-aside-bloc">
            <div
              v-for="m in mutatorCatalog"
              :key="m.key"
              class="checkbox-input has-small-bm"
              :class="{ 'is-disabled': !m.implemented }">
              <input
                type="checkbox"
                :id="`mut-${m.key}`"
                :disabled="!m.implemented"
                :checked="isMutatorActive(m.key)"
                @change="toggleMutator(m.key, $event.target.checked)" />
              <label :for="`mut-${m.key}`">
                <strong>{{ $t(`data.mutator.${m.key}.name`) }}</strong>
                <em v-if="!m.implemented">
                  ({{ $t('page.create.scenario_editor.mutator_coming_soon') }})
                </em>
                {{ $t(`data.mutator.${m.key}.description`) }}
              </label>
            </div>
            <div
              v-if="mutatorCatalog.length === 0"
              class="default-input">
              {{ $t('page.create.scenario_editor.mutator_loading') }}
            </div>
          </div>

          <div class="panel-aside-bloc">
            <button
              @click="toStep1"
              class="default-button">
              {{ $t('page.create.scenario_editor.next_step') }}
            </button>
          </div>
        </template>

        <template v-if="currentStep === 1">
          <section class="panel-aside-info">
            <h2>{{ $t('page.create.scenario_editor.factions') }}</h2>
            <p v-html="$t('page.create.scenario_editor.factions_info_minimum')"></p>
            <p>{{ $t('page.create.scenario_editor.factions_info_no_sector_removed') }}</p>
          </section>

          <div class="panel-aside-bloc">
            <div
              v-for="f in step.factions"
              :key="`faction-${f.key}`"
              :class="[
                { 'active': step.selected === f.key },
                `theme-${f.theme}`,
              ]"
              @click="selectFaction(f.key)"
              class="selectable-item">
              <div class="selectable-item-select"></div>
              <div class="selectable-item-faction">
                <strong>{{ f.key }}</strong>
                <em>{{f.sectors.length }} {{ $t('page.create.scenario_editor.sectors') }}</em>
              </div>
            </div>
          </div>

          <div class="panel-aside-bloc">
            <button
              @click="toStep2"
              class="default-button">
              {{ $t('page.create.scenario_editor.next_step') }}
            </button>
          </div>
        </template>

        <template v-if="currentStep === 2">
          <div class="panel-aside-bloc">
            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.scenario_editor.max_duration_tooltip')">
                {{ $t('page.create.scenario_editor.max_duration') }}
                <strong>{{ minutesToTime(scenario.game_data.time_limit) }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[2].timeLimits[scenario.game_metadata.speed].min"
                  :max="steps[2].timeLimits[scenario.game_metadata.speed].max"
                  :interval="steps[2].timeLimits[scenario.game_metadata.speed].interval"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  v-model.number="scenario.game_data.time_limit">
                </vue-slider>
              </div>
            </div>
          </div>

          <hr class="separator">

          <section class="panel-aside-info">
            <h2>{{ $t('page.create.scenario_editor.conquest_heading') }}</h2>
            <p>{{ $t('page.create.scenario_editor.conquest_info') }}</p>
          </section>

          <div class="panel-aside-bloc">
            <div class="default-input">
              <label v-tooltip="$t('page.create.scenario_editor.conquest_total_tooltip')">
                {{ $t('page.create.scenario_editor.conquest_total_label') }}
                <strong>{{ totalSectorPoints }} {{ $t('page.create.scenario_editor.points') }}</strong>
              </label>
            </div>

            <div class="radio-input is-horizontal">
              <div class="content">
                <div class="content-item">
                  <input
                    type="radio"
                    id="ct-auto"
                    :checked="conquestMode() === 'default'"
                    @change="setConquestMode('default')" />
                  <label
                    for="ct-auto"
                    v-tooltip="$t('page.create.scenario_editor.conquest_mode_auto_desc')">
                    <strong>{{ $t('page.create.scenario_editor.conquest_mode_auto') }}</strong>
                  </label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="ct-custom"
                    :checked="conquestMode() === 'custom'"
                    @change="setConquestMode('custom')" />
                  <label
                    for="ct-custom"
                    v-tooltip="$t('page.create.scenario_editor.conquest_mode_custom_desc')">
                    <strong>{{ $t('page.create.scenario_editor.conquest_mode_custom') }}</strong>
                  </label>
                </div>
              </div>
            </div>

            <div
              v-if="conquestMode() === 'default'"
              class="default-input">
              <label v-tooltip="$t('page.create.scenario_editor.conquest_preview_tooltip')">
                {{ $t('page.create.scenario_editor.conquest_preview_label') }}
                <strong>{{ defaultConquestThresholds.join(' / ') }}</strong>
              </label>
            </div>

            <template v-else>
              <div
                v-for="(vp, i) in [2, 5, 10]"
                :key="`ct-tier-${i}`"
                class="default-input">
                <label :for="`ct-tier-${i}`">
                  {{ $t('page.create.scenario_editor.conquest_tier_label', { n: i + 1, vp }) }}
                </label>
                <input
                  :id="`ct-tier-${i}`"
                  type="number"
                  min="1"
                  :value="scenario.game_data.conquest_thresholds[i]"
                  @input="setConquestTier(i, $event.target.value)" />
              </div>

              <section
                v-if="!conquestThresholdsValid"
                class="panel-aside-info">
                <p><strong>{{ $t('page.create.scenario_editor.conquest_invalid') }}</strong></p>
              </section>
              <section
                v-else-if="conquestThresholdsUnreachable"
                class="panel-aside-info">
                <p><strong>{{ $t('page.create.scenario_editor.conquest_unreachable') }}</strong></p>
              </section>
            </template>
          </div>

          <hr class="separator">

          <div class="panel-aside-bloc">
            <div
              v-for="(s, i) in scenario.game_data.sectors"
              :key="`s-${s.key}`"
              :class="s.color"
              class="sectors-points">
              <div class="default-input">
                <label
                  :for="`s-${s.key}`"
                  v-tooltip="$t('page.create.scenario_editor.victory_points_tooltip')">
                  {{ s.name }} <em>({{ s.systems.length }} {{ $t('page.create.scenario_editor.summary_systems') }})</em>
                  <strong>{{ s.victory_points }} {{ $t('page.create.scenario_editor.points') }}</strong>
                </label>
                <div class="input-slider">
                  <vue-slider
                    :id="`s-${s.key}`"
                    :min="0" :max="10" :interval="1"
                    :dotSize="16" :height="8"
                    :hideLabel="true" tooltip="none"
                    v-model.number="scenario.game_data.sectors[i].victory_points">
                  </vue-slider>
                </div>
              </div>

              <!-- Stage 6 #1.5 — per-sector neutral distribution. Slider
                   above the radios so the ratio sits next to the preview
                   count it's driving, not on the far side of the mode
                   picker. The slider only renders when the sector is on
                   an override mode (Default inherits the scenario-wide
                   value and has no per-sector ratio to drag). -->
              <div class="default-input">
                <label v-tooltip="$t('page.create.scenario_editor.sector_neutral_tooltip')">
                  {{ $t('page.create.scenario_editor.sector_neutral_label') }}
                  <strong>
                    <template v-if="sectorNeutralPreview(s).exact">
                      = {{ sectorNeutralPreview(s).count }} / {{ s.systems.length }}
                    </template>
                    <template v-else>
                      ≈ {{ sectorNeutralPreview(s).count }} / {{ s.systems.length }} (RNG)
                    </template>
                  </strong>
                </label>
                <div
                  v-if="sectorNeutralMode(s) !== 'default'"
                  class="input-slider">
                  <vue-slider
                    :id="`sn-ratio-${s.key}`"
                    :min="0" :max="1" :interval="0.05"
                    :dotSize="16" :height="8"
                    :hideLabel="true" tooltip="none"
                    :value="(s.neutral && s.neutral.ratio) || 0"
                    @change="setSectorNeutralRatio(s, $event)">
                  </vue-slider>
                </div>
                <div class="radio-input is-horizontal">
                  <div class="content">
                    <div class="content-item">
                      <input
                        type="radio"
                        :id="`sn-default-${s.key}`"
                        :checked="sectorNeutralMode(s) === 'default'"
                        @change="setSectorNeutralMode(s, 'default')" />
                      <label :for="`sn-default-${s.key}`">
                        {{ $t('page.create.scenario_editor.sector_neutral_default') }}
                      </label>
                    </div>
                    <div class="content-item">
                      <input
                        type="radio"
                        :id="`sn-rng-${s.key}`"
                        :checked="sectorNeutralMode(s) === 'rng'"
                        @change="setSectorNeutralMode(s, 'rng')" />
                      <label :for="`sn-rng-${s.key}`">
                        {{ $t('page.create.scenario_editor.sector_neutral_rng') }}
                      </label>
                    </div>
                    <div class="content-item">
                      <input
                        type="radio"
                        :id="`sn-fixed-${s.key}`"
                        :checked="sectorNeutralMode(s) === 'fixed'"
                        @change="setSectorNeutralMode(s, 'fixed')" />
                      <label :for="`sn-fixed-${s.key}`">
                        {{ $t('page.create.scenario_editor.sector_neutral_fixed') }}
                      </label>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="panel-aside-bloc">
            <button
              @click="toStep3"
              class="default-button">
              {{ $t('page.create.scenario_editor.next_step') }}
            </button>
          </div>
        </template>

        <template v-if="currentStep === 3">
          <div class="panel-aside-bloc">
            <button
              v-if="mode === 'new'"
              @click="create"
              :disabled="!isValid"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.create.scenario_editor.save_scenario') }}</template>
            </button>
            <button
              v-else
              @click="update"
              :disabled="!isValid"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.create.scenario_editor.save_changes') }}</template>
            </button>
            <button
              v-if="mode === 'edit' && !scenario.published_at"
              @click="publish"
              :disabled="waiting"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.create.common.publish') }}</template>
            </button>
            <!-- Edit mode lands directly on this step; without this hop the
                 victory tab (duration, sector points, conquest milestones)
                 is unreachable for saved scenarios. -->
            <button
              v-if="mode === 'edit'"
              @click="currentStep = 2"
              class="default-button">
              {{ $t('page.create.scenario_editor.edit_victories') }}
            </button>
          </div>

          <div
            v-if="mode === 'edit' && scenario.author"
            class="panel-aside-info">
            <p>
              {{ $t('page.create.common.by') }} <strong>{{ scenario.author.name }}</strong>
            </p>
            <p v-if="scenario.published_at">
              {{ $t('page.create.common.published_on', { date: formatDate(scenario.published_at) }) }}
            </p>
            <p v-else>
              <strong>{{ $t('page.create.common.draft') }}</strong>
            </p>
            <div class="reactions editor-reactions">
              <button
                class="reaction-button"
                v-tooltip="$t('page.create.common.like')"
                @click="react('likes')">
                <svgicon name="check" />
                <span>{{ scenario.likes || 0 }}</span>
              </button>
              <button
                class="reaction-button"
                v-tooltip="$t('page.create.common.dislike')"
                @click="react('dislikes')">
                <svgicon name="close" />
                <span>{{ scenario.dislikes || 0 }}</span>
              </button>
              <button
                class="reaction-button"
                v-tooltip="$t('page.create.common.favorite')"
                @click="react('favorites')">
                <svgicon name="bookmark" />
                <span>{{ scenario.favorites || 0 }}</span>
              </button>
            </div>
          </div>

          <div class="panel-aside-info">
            <p>
              {{ $t('page.create.scenario_editor.size_label') }}
              <strong>{{ $t(`map.size.${scenario.game_metadata.size}.toast`) }}</strong>
            </p>
            <p>
              {{ $t('page.create.scenario_editor.mode_label') }}
              <strong>{{ scenario.game_data.mode }}</strong>
            </p>
            <p>
              {{ $t('page.create.scenario_editor.speed_label') }}
              <strong>{{ $t(`data.speed.${scenario.game_metadata.speed}.name`) }}</strong>
            </p>
            <p>
              {{ $t('page.create.scenario_editor.start_year_label') }}
              <strong>{{ scenario.game_data.date }}</strong>
            </p>
            <p>
              {{ $t('page.create.scenario_editor.time_limit_label') }}
              <strong>{{ minutesToTime(scenario.game_data.time_limit) }}</strong>
            </p>
            <p>
              {{ $t('page.create.scenario_editor.conquest_summary_label') }}
              <strong>
                <template v-if="conquestMode() === 'custom'">
                  {{ scenario.game_data.conquest_thresholds.join(' / ') }}
                </template>
                <template v-else>
                  {{ $t('page.create.scenario_editor.conquest_summary_auto') }}
                </template>
              </strong>
            </p>
            <p><strong>{{ scenario.game_data.sectors.length }}</strong> {{ $t('page.create.scenario_editor.summary_sectors') }}</p>
            <p><strong>{{ scenario.game_data.systems.length }}</strong> {{ $t('page.create.scenario_editor.summary_systems') }}</p>
            <p><strong>{{ scenario.game_data.factions.length }}</strong> {{ $t('page.create.scenario_editor.summary_factions') }}</p>
          </div>

          <div
            v-if="mode === 'edit'"
            class="panel-aside-bloc">
            <button
              @click="destroy"
              :disabled="!isValid"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.create.scenario_editor.delete_scenario') }}</template>
            </button>
          </div>
        </template>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import Offset from 'polygon-offset';

import DefaultLayout from '@/portal/layouts/Default.vue';
import VueSlider from 'vue-slider-component';

import newSeed from '@/portal/utils';

export default {
  name: 'create-scenario',
  data() {
    return {
      mode: 'new',
      waiting: false,
      currentStep: 0,
      containerSize: 0,
      steps: [
        {
          number: 'I',
          speed: undefined,
          mode: {
            value: 'prod',
            choices: ['dev', 'prod'],
          },
        },
        {
          number: 'II',
          factions: [],
          selected: undefined,
        },
        {
          number: 'III',
          timeLimits: {
            fast: { default: 120, min: 60, max: 180, interval: 5 },
            medium: { default: 600, min: 300, max: 720, interval: 30 },
            slow: { default: 43200, min: 10080, max: 129600, interval: 1440 },
          },
        },
        {
          number: 'IV',
        },
      ],
      // Stage 5 — fetched from GET /api/data/mutators in mounted().
      mutatorCatalog: [],
      // Stage 6 #1.5 — per-speed defaults for the neutral-ratio constant
      // (mirrors lib/data/game/content/constant-{fast,medium,slow}.ex).
      // Editor-side only; the backend re-reads c.system_neutral_ratio
      // at game start. If the backend value changes, update here too.
      SPEED_NEUTRAL_DEFAULT: {
        fast: 0.2,
        medium: 0.2,
        slow: 0.35,
      },
      scenario: {
        is_map: false,
        is_official: false,
        game_data: {
          systems: [],
          sectors: [],
          factions: [],
          // Active mutator entries. Stored as a list of {key} maps so
          // future per-mutator params can land in the same struct
          // without a migration. Empty list = vanilla scenario.
          mutators: [],
          // Stage 6 #1.5 — scenario-wide neutral distribution default.
          // null = inherit the speed constant (current behaviour).
          // {mode: "fixed", ratio: 0..1} = exactly floor(N*ratio) per sector.
          // Per-sector overrides on sector.neutral take precedence.
          neutralDistribution: null,
          // Conquest-track milestone override: null = the engine's
          // player-count-weighted formula; [t1, t2, t3] = fixed tier 1/2/3
          // thresholds (worth 2/5/10 VP), same for every faction.
          conquest_thresholds: null,
          speed: undefined,
          size: 0,
          mode: undefined,
          seed: undefined,
          date: undefined,
          time_limit: undefined,
          victory_points: 0,
        },
        game_metadata: {
          name: '',
          description: '',
          size: 0,
          system_number: undefined,
          sector_number: undefined,
          factions: [],
          speed: undefined,
          mode: undefined,
        },
        thumbnail: undefined,
      },
    };
  },
  computed: {
    data() { return this.$store.state.portal.data; },
    step() { return this.steps[this.currentStep]; },
    stepLabel() { return this.$t(`page.create.scenario_editor.step_labels.${this.currentStep}`); },
    isValid() { return !this.waiting; },
    totalSectorPoints() {
      return this.scenario.game_data.sectors.reduce((sum, s) => sum + (s.victory_points || 0), 0);
    },
    // What the engine's formula lands on when factions have balanced player
    // counts (weighting = 1): coeff × total × 2 / faction_count, with the
    // same rounding, floors and 95% final-tier cap as update_tracks/1 in
    // lib/game/instance/victory/victory.ex. Uneven faction headcounts shift
    // these by ×0.5–1.5 at runtime, hence "estimated" in the UI copy.
    defaultConquestThresholds() {
      const total = this.totalSectorPoints;
      const factionCount = Math.max((this.scenario.game_data.factions || []).length, 1);
      const factor = 2 / factionCount;

      const t1 = Math.min(Math.max(Math.round(0.25 * total * factor), 1), total);
      const t2 = Math.min(Math.max(Math.round(0.6 * total * factor), 2), total);
      const cap = Math.max(Math.min(Math.floor(0.95 * total), total - 1), 1);
      const t3 = Math.min(Math.max(Math.floor(0.95 * total * factor), 3), cap);

      return [t1, t2, t3];
    },
    conquestThresholdsValid() {
      const tiers = this.scenario.game_data.conquest_thresholds;
      if (!Array.isArray(tiers)) return true;

      return tiers.length === 3
        && tiers.every((t) => Number.isInteger(t) && t >= 1)
        && tiers[0] <= tiers[1] && tiers[1] <= tiers[2];
    },
    // Valid but pointless: the final tier asks for more points than the map
    // holds. The backend takes it verbatim (maybe the designer wants an
    // unreachable tier 3), so this only warns.
    conquestThresholdsUnreachable() {
      const tiers = this.scenario.game_data.conquest_thresholds;
      return Array.isArray(tiers) && this.conquestThresholdsValid && tiers[2] > this.totalSectorPoints;
    },
  },
  methods: {
    async create() {
      if (this.isValid) {
        this.waiting = true;

        try {
          await this.$axios.post('/scenarios', { scenario: this.scenario });
          // Server renders the thumbnail from persisted game_data.
          this.$toasted.success(this.$t('page.create.scenario_editor.toast_created'));
          this.$router.push('/create/scenarios');
        } catch (err) {
          this.$toastError(this.$t('page.create.common.error_generic'));
        }

        this.waiting = false;
      }
    },
    async update() {
      if (this.isValid) {
        this.waiting = true;

        try {
          await this.$axios.put(`/scenarios/${this.scenario.id}`, { scenario: this.scenario });
          this.$toasted.success(this.$t('page.create.scenario_editor.toast_saved'));
          this.$router.push('/create/scenarios');
        } catch (err) {
          this.$toastError(this.$t('page.create.common.error_generic'));
        }

        this.waiting = false;
      }
    },
    async publish() {
      // See Map.vue publish/3 — same flow on the scenario side.
      if (!window.confirm(this.$t('page.create.common.publish_confirm'))) return;

      this.waiting = true;
      try {
        const { data } = await this.$axios.put(`/scenarios/${this.scenario.id}/publish`);
        this.scenario = data;
        this.$toasted.success(this.$t('page.create.scenario_editor.toast_saved'));
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
      this.waiting = false;
    },
    formatDate(iso) {
      if (!iso) return '';
      return new Date(iso).toLocaleDateString();
    },
    async react(kind) {
      try {
        await this.$axios.post(`/scenarios/${this.scenario.id}/folders/${kind}`);
        this.$set(this.scenario, kind, (this.scenario[kind] || 0) + 1);
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    // --- Stage 5 mutators ---
    isMutatorActive(key) {
      const mutators = (this.scenario.game_data && this.scenario.game_data.mutators) || [];
      return mutators.some((m) => m.key === key);
    },
    toggleMutator(key, on) {
      // Defensive: edit-mode loads scenarios saved before mutators
      // existed, where game_data has no `mutators` key. Materialize
      // it via $set so Vue notices the new property.
      if (!this.scenario.game_data.mutators) {
        this.$set(this.scenario.game_data, 'mutators', []);
      }
      const current = this.scenario.game_data.mutators;
      if (on) {
        if (!current.some((m) => m.key === key)) {
          this.scenario.game_data.mutators = [...current, { key }];
        }
      } else {
        this.scenario.game_data.mutators = current.filter((m) => m.key !== key);
      }
    },
    async destroy() {
      if (this.isValid) {
        this.waiting = true;

        try {
          await this.$axios.delete(`/scenarios/${this.scenario.id}`);
          this.$toasted.success(this.$t('page.create.scenario_editor.toast_deleted'));
          this.$router.push('/create/scenarios');
        } catch (err) {
          this.$toastError(this.$t('page.create.common.error_generic'));
        }

        this.waiting = false;
      }
    },
    toStep1() {
      if (this.step.speed && this.step.mode.value) {
        this.scenario.game_data.speed = this.step.speed;
        this.scenario.game_data.mode = this.step.mode.value;
        this.scenario.game_metadata.speed = this.step.speed;
        this.scenario.game_metadata.mode = this.step.mode.value;
        this.scenario.game_data.time_limit = this.steps[2].timeLimits[this.step.speed].default;
        this.steps[1].factions = this.data.faction.map((f) => ({ key: f.key, theme: f.theme, sectors: [] }));
        this.currentStep = 1;
      }
    },
    toStep2() {
      const validFactioNumber = this.step.factions
        .filter((f) => f.sectors.length > 0).length;

      if (validFactioNumber >= 2) {
        const factions = this.step.factions
          .filter((f) => f.sectors.length > 0)
          .map((f) => ({ key: f.key, sector_number: f.sectors.length }));

        this.scenario.game_data.factions = factions;
        this.scenario.game_metadata.factions = factions;

        this.currentStep = 2;
      }
    },
    toStep3() {
      const sectorsPoints = this.scenario.game_data.sectors.reduce((sum, s) => sum + s.victory_points, 0);

      if (sectorsPoints >= this.scenario.game_data.victory_points && this.conquestThresholdsValid) {
        this.currentStep = 3;
      }
    },

    // --- Conquest-track milestone override ---

    conquestMode() {
      return Array.isArray(this.scenario.game_data.conquest_thresholds) ? 'custom' : 'default';
    },
    setConquestMode(mode) {
      if (mode === 'default') {
        // $set: edit-mode loads scenarios saved before this key existed.
        this.$set(this.scenario.game_data, 'conquest_thresholds', null);
      } else if (this.conquestMode() !== 'custom') {
        // Seed from the formula's numbers so Custom starts from the values
        // the game would have used anyway.
        this.$set(this.scenario.game_data, 'conquest_thresholds', [...this.defaultConquestThresholds]);
      }
    },
    setConquestTier(index, raw) {
      // parseInt over Number: an emptied input yields NaN either way, but
      // partial entries like "12x" should still land on 12 while typing.
      const value = parseInt(raw, 10);
      // Direct index assignment is invisible to Vue 2's reactivity.
      this.$set(this.scenario.game_data.conquest_thresholds, index, Number.isNaN(value) ? null : value);
    },
    selectFaction(key) {
      this.step.selected = this.step.selected === key
        ? undefined : key;
    },
    getFaction(key) {
      return this.step.factions.find((f) => f.key === key);
    },
    toggleSectorToFaction(key) {
      if (this.step.selected) {
        const faction = this.getFaction(this.step.selected);
        const sector = this.scenario.game_data.sectors.find((s) => s.key === key);

        if (sector.faction) {
          if (this._.includes(faction.sectors, sector)) {
            sector.faction = null;
            this._.remove(faction.sectors, (s) => s.key === sector.key);
          } else {
            this.step.factions.forEach((f) => {
              this._.remove(f.sectors, (s) => s.key === sector.key);
            });

            sector.faction = faction.key;
            faction.sectors.push(sector);
          }
        } else {
          sector.faction = faction.key;
          faction.sectors.push(sector);
        }
      }
    },
    getTheme(key) {
      return key
        ? `theme-${this.data.faction.find((f) => f.key === key).theme}`
        : '';
    },
    getSector(key) {
      return this.scenario.game_data.sectors.find((s) => s.key === key);
    },
    offsetPolygon(points, size = 0.2) {
      const offset = new Offset();
      const p = offset.data(points).padding(0);

      return offset.data(p).padding(size)[0];
    },
    minutesToTime(minutes) {
      const d = Math.floor(minutes / 1440);
      const h = Math.floor((minutes - (d * 1440)) / 60);
      const m = `${Math.round(minutes % 60)}`.padStart(2, '0');

      if (d > 0) { return `${d}${this.$t('page.create.scenario_editor.duration_day_short')} ${h}h${m}`; }
      if (h > 0) { return `${h}h${m}`; }
      return `${m} ${this.$t('page.create.scenario_editor.duration_minutes')}`;
    },
    resize(value) {
      return value * (this.containerSize / this.scenario.game_metadata.size);
    },
    newSeed() {
      return newSeed();
    },

    // --- Stage 6 #1.5 — neutral distribution helpers ---

    // Per-speed RNG default neutral ratio (mirrors backend constants).
    speedNeutralRatio() {
      const speed = this.scenario.game_data.speed;
      return this.SPEED_NEUTRAL_DEFAULT[speed] || this.SPEED_NEUTRAL_DEFAULT.medium;
    },

    // Scenario-level: pick "default" (null), "fixed at X%", etc.
    // Stored as null | {mode, ratio}.
    scenarioNeutralMode() {
      const nd = this.scenario.game_data.neutralDistribution;
      if (!nd) return 'default';
      return nd.mode === 'fixed' ? 'fixed' : 'default';
    },
    setScenarioNeutralMode(mode) {
      if (mode === 'default') {
        this.scenario.game_data.neutralDistribution = null;
      } else if (mode === 'fixed') {
        const cur = this.scenario.game_data.neutralDistribution;
        const ratio = (cur && cur.ratio != null) ? cur.ratio : this.speedNeutralRatio();
        this.scenario.game_data.neutralDistribution = { mode: 'fixed', ratio };
      }
    },
    setScenarioNeutralRatio(ratio) {
      this.scenario.game_data.neutralDistribution = { mode: 'fixed', ratio };
    },

    // Per-sector: "default" (inherit scenario), "rng" (per-system roll
    // at custom ratio), "fixed" (exact floor(N×ratio) for this sector).
    sectorNeutralMode(sector) {
      const n = sector && sector.neutral;
      if (!n) return 'default';
      return n.mode === 'fixed' ? 'fixed' : 'rng';
    },
    setSectorNeutralMode(sector, mode) {
      if (mode === 'default') {
        // Use $set so the deletion is reactive on a possibly-pre-existing key.
        this.$set(sector, 'neutral', null);
      } else {
        const cur = sector.neutral;
        const ratio = (cur && cur.ratio != null) ? cur.ratio : this.speedNeutralRatio();
        this.$set(sector, 'neutral', { mode, ratio });
      }
    },
    setSectorNeutralRatio(sector, ratio) {
      const mode = (sector.neutral && sector.neutral.mode) || 'fixed';
      this.$set(sector, 'neutral', { mode, ratio });
    },

    // Live preview: returns { count, exact, label, ratio } for the sector.
    // `count` is the number to show; `exact` is true when the floor math
    // gives a guaranteed value, false when RNG variance applies.
    sectorNeutralPreview(sector) {
      const total = (sector.systems || []).length;
      const sectorOverride = sector.neutral;
      const scenarioDefault = this.scenario.game_data.neutralDistribution;

      // Per-sector wins, then scenario, then speed constant (RNG).
      const effective = sectorOverride || scenarioDefault;

      if (!effective) {
        const ratio = this.speedNeutralRatio();
        return { count: Math.round(total * ratio), exact: false, ratio, label: 'rng' };
      }

      if (effective.mode === 'fixed') {
        const ratio = effective.ratio || 0;
        return { count: Math.floor(total * ratio), exact: true, ratio, label: 'fixed' };
      }

      // mode: "rng" (with custom ratio)
      const ratio = effective.ratio != null ? effective.ratio : this.speedNeutralRatio();
      return { count: Math.round(total * ratio), exact: false, ratio, label: 'rng' };
    },
  },
  async mounted() {
    // Same race as Map.vue: clientWidth is 0 on the first synchronous
    // mounted() read, so the SVG renders at containerSize=-50 and the
    // map looks blank. Re-measure after $nextTick once data has landed
    // and the parent layout is settled.
    this.containerSize = this.$refs.container.clientWidth - (25 * 2);
    const mode = this.$route.params.mode;

    // Stage 5 — load the mutator catalog. Best-effort; if the
    // endpoint is unreachable the picker just shows the loading
    // copy and the scenario can still be saved without mutators.
    this.$axios.get('/data/mutators').then(({ data }) => {
      this.mutatorCatalog = data;
    }).catch(() => {});

    try {
      if (mode === 'new') {
        const { data } = await this.$axios.get(`/maps/${this.$route.params.id}`);

        this.mode = 'new';

        this.scenario.game_data.size = data.game_data.size;
        this.scenario.game_data.seed = this.newSeed();
        this.scenario.game_data.date = 4000;
        this.scenario.game_data.time_limit = 60;
        this.scenario.game_data.victory_points = 2;
        this.scenario.game_data.systems = data.game_data.systems;
        this.scenario.game_data.blackholes = data.game_data.blackholes;
        this.scenario.game_data.sectors = data.game_data.sectors
          .map((s) => Object.assign(s, { faction: null, victory_points: 1, neutral: null }));

        this.scenario.game_metadata.name = data.game_metadata.name;
        this.scenario.game_metadata.description = data.game_metadata.description;
        this.scenario.game_metadata.size = data.game_metadata.size;
        this.scenario.game_metadata.system_number = data.game_metadata.system_number;
        this.scenario.game_metadata.sector_number = data.game_metadata.sector_number;
      } else if (mode === 'edit') {
        const { data } = await this.$axios.get(`/scenarios/${this.$route.params.id}`);

        this.mode = 'edit';
        this.currentStep = 3;
        this.scenario = data;
      } else {
        throw new Error('Error');
      }

      await this.$nextTick();
      this.containerSize = this.$refs.container.clientWidth - (25 * 2);
    } catch (err) {
      this.$router.push('/create/scenarios');
      this.$toastError(this.$t('page.create.scenario_editor.toast_unknown'));
    }
  },
  components: {
    DefaultLayout,
    VueSlider,
  },
};
</script>
