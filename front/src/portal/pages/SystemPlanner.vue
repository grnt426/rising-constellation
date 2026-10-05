<template>
  <default-layout>
    <div
      class="fluid-panel system-planner"
      :class="`f-${theme}`">
      <div
        v-if="!plan || !speedData"
        class="planner-loading">
        {{ loadError || $t('page.system_planner.loading') }}
      </div>

      <template v-else>
        <!-- LEFT RAIL: what the system is made of besides its buildings -->
        <v-scrollbar class="panel-aside planner-setup">
          <div class="panel-aside-info">
            <h2>{{ $t('page.system_planner.setup') }}</h2>
            <p v-if="sourceLine">{{ sourceLine }}</p>
          </div>

          <div class="panel-aside-bloc planner-pair">
            <div class="default-input">
              <label for="planner-speed">{{ $t('page.system_planner.speed') }}</label>
              <select
                id="planner-speed"
                :value="plan.speed"
                @change="changeSpeed($event.target.value)">
                <option
                  v-for="speed in speeds"
                  :key="speed"
                  :value="speed">
                  {{ $t(`data.speed.${speed}.name`) }}
                </option>
              </select>
            </div>
            <div class="default-input">
              <label for="planner-faction">{{ $t('page.system_planner.faction') }}</label>
              <select
                id="planner-faction"
                :value="plan.faction"
                @change="edit((p) => { p.faction = $event.target.value; })">
                <option
                  v-for="faction in speedData.faction"
                  :key="faction.key"
                  :value="faction.key">
                  {{ $t(`data.faction.${faction.key}.name`) }}
                </option>
              </select>
            </div>
          </div>

          <div class="panel-aside-bloc planner-population">
            <div class="planner-label-row">
              <label for="planner-population">{{ $t('page.system_planner.population') }}</label>
              <button
                v-if="result"
                type="button"
                class="planner-link"
                v-tooltip="$t('page.system_planner.fill_housing_hint')"
                @click="setPopulation(result.system.habitation.value + 0.75)">
                {{ $t('page.system_planner.fill_housing') }}
              </button>
            </div>
            <div class="planner-population-input">
              <button
                type="button"
                :aria-label="$t('page.system_planner.population_down')"
                @click="setPopulation(Math.ceil(plan.population) - 1)">−</button>
              <input
                id="planner-population"
                type="number"
                min="0"
                :max="maxPopulation"
                step="1"
                :value="plan.population"
                @change="setPopulation(Number($event.target.value))">
              <button
                type="button"
                :aria-label="$t('page.system_planner.population_up')"
                @click="setPopulation(Math.floor(plan.population) + 1)">+</button>
            </div>
            <input
              class="planner-population-range"
              type="range"
              min="0"
              :max="populationRangeMax"
              step="0.1"
              :value="plan.population"
              :aria-label="$t('page.system_planner.population')"
              @input="setPopulation(Number($event.target.value))">
            <p class="planner-small">
              {{ $t('page.system_planner.population_hint') }}
            </p>

            <label class="planner-check">
              <input
                type="checkbox"
                :checked="plan.capital"
                @change="edit((p) => { p.capital = $event.target.checked; })">
              <span v-tooltip="$t('page.system_planner.capital_hint')">{{ $t('page.system_planner.capital') }}</span>
            </label>
          </div>

          <hr class="margin">

          <div class="panel-aside-info">
            <h2>{{ $t('page.system_planner.governor') }}</h2>
          </div>
          <div class="panel-aside-bloc">
            <planner-governor
              :governor="plan.governor"
              :data="speedData"
              @update="(governor) => edit((p) => { p.governor = governor; }, 'governor')" />
          </div>

          <hr class="margin">

          <div class="panel-aside-info">
            <h2>{{ $t('page.system_planner.research') }}</h2>
          </div>
          <div class="panel-aside-bloc planner-research">
            <label class="planner-check">
              <input
                type="checkbox"
                :checked="useResearch"
                @change="setUseResearch($event.target.checked)">
              <span>{{ $t('page.system_planner.limit_to_patents') }}</span>
            </label>
            <p class="planner-small">
              {{ useResearch ? $t('page.system_planner.limit_on_hint') : $t('page.system_planner.limit_off_hint') }}
            </p>

            <button
              type="button"
              class="planner-drawer-button"
              @click="drawer = 'patents'">
              <svgicon name="patent/root" />
              <span>{{ $t('page.system_planner.drawer_patents') }}</span>
              <strong>{{ (plan.patents || []).length }}/{{ speedData.patent.length }}</strong>
            </button>
            <button
              type="button"
              class="planner-drawer-button"
              @click="drawer = 'lexes'">
              <svgicon name="doctrine_stamp" />
              <span>{{ $t('page.system_planner.drawer_lexes') }}</span>
              <strong>{{ lexCountLabel }}</strong>
            </button>
          </div>
        </v-scrollbar>

        <!-- CENTER: the bodies, and the selected tile -->
        <div class="panel-content is-full-sized planner-main">
          <div class="panel-header">
            <h1>
              <strong>{{ $t('page.system_planner.title') }}</strong>
              <span
                v-if="plan.name"
                class="planner-system-name">{{ plan.name }}</span>
            </h1>

            <div class="planner-actions">
              <button
                type="button"
                class="planner-icon-button"
                :disabled="!history.length"
                v-tooltip="$t('page.system_planner.undo')"
                :aria-label="$t('page.system_planner.undo')"
                @click="undo">↶</button>
              <button
                type="button"
                class="planner-icon-button"
                :disabled="!future.length"
                v-tooltip="$t('page.system_planner.redo')"
                :aria-label="$t('page.system_planner.redo')"
                @click="redo">↷</button>
              <button
                type="button"
                class="default-button is-small"
                @click="importOpen = true">
                {{ $t('page.system_planner.import') }}
              </button>
              <button
                type="button"
                class="default-button is-small"
                v-tooltip.bottom="$t('page.system_planner.export_hint')"
                @click="exportPlan">
                {{ $t('page.system_planner.export') }}
              </button>
              <button
                type="button"
                class="default-button is-small"
                :disabled="!isChanged"
                v-tooltip.bottom="$t('page.system_planner.reset_hint')"
                @click="resetToBaseline">
                {{ $t('page.system_planner.reset') }}
              </button>
              <button
                type="button"
                class="default-button is-small"
                :disabled="!isChanged"
                v-tooltip.bottom="$t('page.system_planner.set_baseline_hint')"
                @click="setBaseline">
                {{ $t('page.system_planner.set_baseline') }}
              </button>
              <button
                type="button"
                class="default-button is-small"
                v-tooltip.bottom="$t('page.system_planner.new_plan_hint')"
                @click="newPlan">
                {{ $t('page.system_planner.new_plan') }}
              </button>
            </div>
          </div>

          <v-scrollbar class="content planner-content">
            <p
              v-if="!selected"
              class="planner-small planner-select-hint">
              {{ $t('page.system_planner.select_tile_hint') }}
            </p>

            <planner-bodies
              class="planner-bodies-block"
              :plan="plan"
              :data="speedData"
              :system="result ? result.system : null"
              :selected="selected"
              :patents="limitPatents"
              @select="selectTile"
              @level="setLevel"
              @remove="removeBuilding"
              @repair="(t) => setDamaged({ ...t, damaged: false })"
              @factor="setFactor">
              <!-- desktop: inline under the body; phones use the sheet -->
              <template
                v-if="!isMobileView"
                #editor>
                <planner-tile-panel
                  :plan="plan"
                  :data="speedData"
                  :system="result ? result.system : null"
                  :selected="selected"
                  :patents="limitPatents"
                  :theme="theme"
                  :placement-level.sync="placementLevel"
                  @place="placeBuilding"
                  @level="setLevel"
                  @remove="removeBuilding"
                  @damage="setDamaged" />
              </template>
            </planner-bodies>

            <p class="planner-small planner-scope-note">
              {{ $t('page.system_planner.scope_note') }}
            </p>
          </v-scrollbar>
        </div>

        <!-- RIGHT RAIL: the computed system -->
        <v-scrollbar class="panel-aside planner-results">
          <div class="panel-aside-info">
            <h2>{{ $t('page.system_planner.outputs') }}</h2>
            <p>{{ isChanged ? $t('page.system_planner.outputs_compared') : $t('page.system_planner.outputs_baseline') }}</p>
          </div>
          <div class="panel-aside-bloc">
            <p
              v-if="computeError"
              class="planner-error"
              role="alert">
              {{ computeError }}
            </p>
            <planner-outputs
              v-if="result"
              :class="{ 'is-stale': computing }"
              :system="result.system"
              :growth="result.growth"
              :baseline="baselineResult ? baselineResult.system : null"
              :baseline-growth="baselineResult ? baselineResult.growth : 0"
              :data="speedData" />
          </div>
        </v-scrollbar>
      </template>
    </div>

    <!-- phones: the tile editor is a bottom sheet over the bodies -->
    <div
      v-if="isMobileView && selected && plan"
      class="planner-sheet-root">
      <div
        class="planner-sheet-backdrop"
        @click="selected = null" />
      <div class="planner-sheet">
        <button
          type="button"
          class="planner-sheet-close"
          :aria-label="$t('page.system_planner.close')"
          @click="selected = null">
          <svgicon name="close" />
        </button>
        <planner-tile-panel
          :plan="plan"
          :data="speedData"
          :system="result ? result.system : null"
          :selected="selected"
          :patents="limitPatents"
          :theme="theme"
          :placement-level.sync="placementLevel"
          @place="placeBuilding"
          @level="setLevel"
          @remove="removeBuilding"
          @damage="setDamaged" />
      </div>
    </div>

    <!-- phones: the yields stay in view while editing far up the page -->
    <div
      v-if="isMobileView && result"
      class="planner-mobile-summary">
      <span
        v-for="key in summaryKeys"
        :key="key">
        <svgicon :name="`resource/${key}`" />
        {{ key === 'happiness' ? formatInteger(result.system[key].value) : formatIncome(result.system[key].value) }}
      </span>
    </div>

    <planner-tree-drawer
      v-if="drawer && plan"
      :kind="drawer"
      :data="speedData"
      :selected="drawer === 'patents' ? (plan.patents || []) : plan.active_lexes"
      :owned="plan.owned_lexes"
      :lex-slots="plan.lex_slots"
      :limiting="useResearch"
      :can-reset="drawerCanReset"
      :theme="theme"
      @toggle="toggleDrawerKey"
      @set="setDrawerKeys"
      @reset="resetDrawer"
      @close="drawer = null" />

    <planner-import-dialog
      v-if="importOpen"
      @import="importFromDialog"
      @close="importOpen = false" />
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import PlannerBodies from '@/portal/components/planner/PlannerBodies.vue';
import PlannerTilePanel from '@/portal/components/planner/PlannerTilePanel.vue';
import PlannerGovernor from '@/portal/components/planner/PlannerGovernor.vue';
import PlannerOutputs from '@/portal/components/planner/PlannerOutputs.vue';
import PlannerTreeDrawer from '@/portal/components/planner/PlannerTreeDrawer.vue';
import PlannerImportDialog from '@/portal/components/planner/PlannerImportDialog.vue';
import viewport from '@/utils/viewport';
import format, { setIncomeTicksPerHour } from '@/utils/format';
import { copyOrDownloadJson, planFilename } from '@/utils/json-export';
import {
  SPEEDS, MAX_POPULATION, PlanError, clone, bodyAt, emptyTile, planSpeed, normalizePlan,
  planFromTemplate, computePayload, withAncestors, withoutDescendants, takeStashedPlan,
  presetName, sessionAtRisk,
} from '@/portal/planner/plan';

// Game data per speed, fetched once per page load (frozen: read-only and
// large, so Vue never walks it).
const dataCache = {};

// The working plan survives reloads in this browser (a convenience only:
// export is the way to keep or share one).
const SESSION_KEY = 'rc-planner-session';
const HISTORY_LIMIT = 100;
const COMPUTE_DELAY = 120;
const COALESCE_MS = 800;

function storage() {
  try {
    return window.localStorage;
  } catch (e) {
    return null;
  }
}

export default {
  name: 'system-planner',
  provide() {
    // BuildingCard / CardComplexBonus read the planner's data, not a game's
    return {
      cardContext: {
        data: () => this.speedData,
        patents: () => this.limitPatents,
      },
    };
  },
  data() {
    return {
      speeds: SPEEDS,
      maxPopulation: MAX_POPULATION,
      summaryKeys: ['production', 'credit', 'technology', 'ideology', 'happiness'],
      speedData: null,
      dataSpeed: null, // the speed speedData belongs to
      loadError: null,
      plan: null,
      baselinePlan: null,
      result: null,
      baselineResult: null,
      computing: false,
      computeError: null,
      useResearch: false,
      selected: null, // { path, tile }
      placementLevel: 1,
      drawer: null, // 'patents' | 'lexes'
      importOpen: false,
      history: [],
      future: [],
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    theme() {
      const faction = this.speedData && this.plan
        && this.speedData.faction.find((f) => f.key === this.plan.faction);
      return faction ? faction.theme : 'dark-blue';
    },
    limitPatents() {
      return this.useResearch && this.plan ? (this.plan.patents || []) : null;
    },
    planJson() { return this.plan ? JSON.stringify(this.plan) : ''; },
    isChanged() {
      return !!this.baselinePlan && JSON.stringify(this.baselinePlan) !== this.planJson;
    },
    lexCountLabel() {
      const n = this.plan.active_lexes.length;
      return this.plan.lex_slots === null ? `${n}` : `${n}/${this.plan.lex_slots}`;
    },
    populationRangeMax() {
      const housing = this.result ? this.result.system.habitation.value : 0;
      return Math.min(MAX_POPULATION, Math.max(60, Math.ceil((Math.max(housing, this.plan.population) + 10) / 10) * 10));
    },
    sourceLine() {
      const source = this.plan && this.plan.source;
      if (!source) return null;
      const where = source.sector
        ? this.$t('page.system_planner.source_sector', { name: this.plan.name || '?', sector: source.sector })
        : this.plan.name;
      const when = source.exported_at ? new Date(source.exported_at).toLocaleString() : null;
      return [this.$t('page.system_planner.source_imported', { where }), when].filter(Boolean).join(' · ');
    },
    drawerCanReset() {
      if (!this.baselinePlan) return false;
      const key = this.drawer === 'patents' ? 'patents' : 'active_lexes';
      return JSON.stringify(this.baselinePlan[key] || []) !== JSON.stringify(this.plan[key] || []);
    },
  },
  watch: {
    planJson() {
      this.scheduleCompute();
      this.saveSession();
    },
    baselinePlan() { this.computeBaseline(); },
    useResearch() { this.saveSession(); },
  },
  async created() {
    window.addEventListener('keydown', this.onKeydown);
    try {
      await this.start();
    } catch (err) {
      this.loadError = this.$t('page.system_planner.load_failed');
    }
  },
  beforeDestroy() {
    window.removeEventListener('keydown', this.onKeydown);
    clearTimeout(this.computeTimer);
    clearTimeout(this.saveTimer);
    // the portal formats plain per-tick figures outside a game
    setIncomeTicksPerHour(1);
  },
  methods: {
    // -- loading ------------------------------------------------------------
    async start() {
      const { import: key, preset } = this.$route.query;
      const store = storage();
      const stashed = key && store ? takeStashedPlan(store, String(key)) : null;
      // one-shot links: a reload must not import again over later edits
      if (key || preset) this.$router.replace({ query: {} }).catch(() => {});

      if (stashed) {
        try {
          await this.adopt(stashed, { fromGame: true });
          return;
        } catch (err) {
          this.$toasted.error(this.$t('page.system_planner.import_error.not_a_plan'));
        }
      }

      if (preset && await this.openPreset(String(preset))) return;
      if (await this.restoreSession()) return;
      await this.newPlan();
    },
    // A ready-made example opened by link (?preset=<name>, the help manual's
    // example systems). It becomes the plan and its baseline, so the results
    // show what the reader's own changes add to the example.
    async openPreset(value) {
      const name = presetName(value);
      const saved = this.savedSession();
      if (name && sessionAtRisk(saved) && !window.confirm(this.$t('page.system_planner.preset_confirm'))) {
        return false;
      }
      try {
        if (!name) throw new PlanError('not_a_plan');
        const { data } = await this.$axios.get(`/system-planner/preset/${name}`);
        await this.adopt(data);
        this.$toasted.success(this.$t('page.system_planner.preset_loaded', { name: this.plan.name }));
        return true;
      } catch (err) {
        this.$toasted.error(this.$t('page.system_planner.preset_missing'));
        return false;
      }
    },
    loadData(speed) {
      if (!dataCache[speed]) {
        dataCache[speed] = this.$axios.get('/data', { params: { speed } })
          .then(({ data }) => Object.freeze(data))
          .catch((err) => {
            delete dataCache[speed];
            throw err;
          });
      }
      return dataCache[speed];
    },
    useData(speed, data) {
      this.speedData = data;
      this.dataSpeed = speed;
      // Legacy ticks are 3 minutes: per-hour income needs the factor
      setIncomeTicksPerHour(speed === 'slow' ? 20 : 1);
    },
    // Make `raw` (an exported plan, or a saved session's) the working plan
    // and its baseline. Throws PlanError when raw isn't a plan.
    async adopt(raw, { fromGame = false, baseline = null, useResearch = null } = {}) {
      const speed = planSpeed(raw);
      const data = await this.loadData(speed);
      const { plan, warnings } = normalizePlan(raw, data);
      const base = baseline ? normalizePlan(baseline, data).plan : clone(plan);

      this.useData(speed, data);
      this.history = [];
      this.future = [];
      this.selected = null;
      this.baselineResult = null;
      this.result = null;
      this.plan = plan;
      this.baselinePlan = base;
      this.useResearch = useResearch === null ? plan.patents !== null : useResearch;
      if (fromGame) this.$toasted.success(this.$t('page.system_planner.imported_from_game'));
      this.reportWarnings(warnings);
    },
    async newPlan() {
      if (this.isChanged && !window.confirm(this.$t('page.system_planner.new_plan_confirm'))) return;
      const speed = (this.plan && this.plan.speed) || 'slow';
      const [data, { data: template }] = await Promise.all([
        this.loadData(speed),
        this.$axios.get('/system-planner/template', { params: { speed } }),
      ]);
      const faction = (this.plan && this.plan.faction) || data.faction[0].key;
      const plan = planFromTemplate(template, faction, data);
      await this.adopt(plan, { useResearch: false });
    },
    savedSession() {
      const store = storage();
      if (!store) return null;
      try {
        return JSON.parse(store.getItem(SESSION_KEY) || 'null');
      } catch (err) {
        return null;
      }
    },
    async restoreSession() {
      try {
        const saved = this.savedSession();
        if (!saved || !saved.plan) return false;
        await this.adopt(saved.plan, { baseline: saved.baseline, useResearch: !!saved.useResearch });
        return true;
      } catch (err) {
        return false;
      }
    },
    saveSession() {
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => {
        const store = storage();
        if (!store || !this.plan) return;
        try {
          store.setItem(SESSION_KEY, JSON.stringify({
            plan: this.plan, baseline: this.baselinePlan, useResearch: this.useResearch,
          }));
        } catch (err) {
          // storage full or blocked: the session just won't survive a reload
        }
      }, 400);
    },
    reportWarnings(warnings) {
      if (!warnings.length) return;
      const lines = warnings.map((w) => this.$t(`page.system_planner.warning.${w.code}`, {
        name: w.key ? this.dataName(w.key) : '',
      }));
      this.$toasted.info([...new Set(lines)].join(' '), { duration: 8000 });
    },
    dataName(key) {
      const path = `data.building.${key}.name`;
      return this.$te(path) ? this.$t(path) : key;
    },

    // -- computing ----------------------------------------------------------
    scheduleCompute() {
      clearTimeout(this.computeTimer);
      this.computing = true;
      this.computeTimer = setTimeout(() => this.compute(), COMPUTE_DELAY);
    },
    async post(plan) {
      const { data } = await this.$axios.post(
        '/system-planner/compute',
        computePayload(plan, this.$t('page.system_planner.governor_default')),
      );
      return data;
    },
    async compute() {
      this.seq = (this.seq || 0) + 1;
      const seq = this.seq;
      try {
        const result = await this.post(this.plan);
        if (seq !== this.seq) return;
        this.result = result;
        this.computeError = null;
        if (!this.isChanged) this.baselineResult = result;
      } catch (err) {
        if (seq !== this.seq) return;
        this.computeError = this.errorText(err);
      } finally {
        if (seq === this.seq) this.computing = false;
      }
    },
    async computeBaseline() {
      if (!this.baselinePlan) return;
      // the baseline is the current plan: compute() fills it in (now, or
      // when the pending computation lands)
      if (!this.isChanged) {
        if (!this.computing) this.baselineResult = this.result;
        return;
      }
      const plan = this.baselinePlan;
      try {
        const result = await this.post(plan);
        if (plan === this.baselinePlan) this.baselineResult = result;
      } catch (err) {
        this.baselineResult = null;
      }
    },
    errorText(err) {
      const reason = err && err.response && err.response.data && err.response.data.message;
      const key = `page.system_planner.compute_error.${reason}`;
      return reason && this.$te(key) ? this.$t(key) : this.$t('page.system_planner.compute_error.generic');
    },

    // -- editing ------------------------------------------------------------
    // Every change goes through here: one undo step per edit, except
    // consecutive edits of the same kind within COALESCE_MS (a dragged
    // slider, a run of skill clicks), which share one step.
    edit(mutate, coalesce = null) {
      const now = Date.now();
      const merge = coalesce && this.lastEdit
        && this.lastEdit.kind === coalesce && now - this.lastEdit.at < COALESCE_MS;
      if (!merge) {
        this.history.push(this.planJson);
        if (this.history.length > HISTORY_LIMIT) this.history.shift();
      }
      this.future = [];
      this.lastEdit = { kind: coalesce, at: now };

      const next = clone(this.plan);
      mutate(next);
      this.plan = next;
    },
    undo() {
      if (!this.history.length || this.restoring) return;
      this.future.push(this.planJson);
      this.restore(this.history.pop());
    },
    redo() {
      if (!this.future.length || this.restoring) return;
      this.history.push(this.planJson);
      this.restore(this.future.pop());
    },
    // An undo/redo step may cross a game mode switch: the plan must never
    // render against the other mode's data (a Legacy-only building has
    // no card in Flash data), so load the data first.
    async restore(json) {
      const plan = JSON.parse(json);
      this.lastEdit = null;
      if (plan.speed !== this.dataSpeed) {
        this.restoring = true;
        try {
          const data = await this.loadData(plan.speed);
          this.useData(plan.speed, data);
          this.baselinePlan = normalizePlan({ ...this.baselinePlan, speed: plan.speed }, data).plan;
        } finally {
          this.restoring = false;
        }
      }
      this.plan = plan;
      this.dropStaleSelection();
    },
    dropStaleSelection() {
      if (!this.selected) return;
      const body = bodyAt(this.plan, this.selected.path);
      if (!body || !body.tiles[this.selected.tile]) this.selected = null;
    },
    tileOf(plan, { path, tile }) {
      return bodyAt(plan, path).tiles[tile];
    },
    selectTile(target) {
      const same = this.selected && this.selected.tile === target.tile
        && this.selected.path.join() === target.path.join();
      this.selected = same ? null : target;
    },
    placeBuilding({
      path, tile, key, level,
    }) {
      this.edit((p) => {
        bodyAt(p, path).tiles[tile] = { building_key: key, building_level: level, building_status: 'built' };
      });
    },
    setLevel(target) {
      this.edit((p) => { this.tileOf(p, target).building_level = target.level; });
    },
    removeBuilding(target) {
      this.edit((p) => { bodyAt(p, target.path).tiles[target.tile] = emptyTile(); });
    },
    setDamaged(target) {
      this.edit((p) => { this.tileOf(p, target).building_status = target.damaged ? 'damaged' : 'built'; });
    },
    setFactor({ path, key, value }) {
      this.edit((p) => { bodyAt(p, path)[key] = value; }, `factor-${path.join()}-${key}`);
    },
    setPopulation(value) {
      if (!Number.isFinite(value)) return;
      const population = Math.round(Math.min(MAX_POPULATION, Math.max(0, value)) * 100) / 100;
      if (population === this.plan.population) return;
      this.edit((p) => { p.population = population; }, 'population');
    },
    setUseResearch(on) {
      this.useResearch = on;
      if (on && this.plan.patents === null) this.edit((p) => { p.patents = []; });
    },
    async changeSpeed(speed) {
      if (speed === this.plan.speed) return;
      try {
        const data = await this.loadData(speed);
        const { plan, warnings } = normalizePlan({ ...this.plan, speed }, data);
        const { plan: baseline } = normalizePlan({ ...this.baselinePlan, speed }, data);
        this.useData(speed, data);
        this.edit((p) => Object.assign(p, plan));
        this.baselinePlan = baseline;
        this.dropStaleSelection();
        this.reportWarnings(warnings);
      } catch (err) {
        this.$toasted.error(this.$t('page.system_planner.load_failed'));
      }
    },
    toggleDrawerKey(key) {
      if (this.drawer === 'patents') {
        const owned = this.plan.patents || [];
        const next = owned.includes(key)
          ? withoutDescendants(owned, this.speedData.patent, key)
          : withAncestors(owned, this.speedData.patent, key);
        this.edit((p) => { p.patents = next; });
      } else {
        this.edit((p) => {
          p.active_lexes = p.active_lexes.includes(key)
            ? p.active_lexes.filter((k) => k !== key)
            : [...p.active_lexes, key];
        });
      }
    },
    setDrawerKeys(keys) {
      this.edit((p) => {
        if (this.drawer === 'patents') p.patents = keys;
        else p.active_lexes = keys;
      });
    },
    resetDrawer() {
      const key = this.drawer === 'patents' ? 'patents' : 'active_lexes';
      const value = clone(this.baselinePlan[key]);
      this.edit((p) => { p[key] = value; });
    },
    resetToBaseline() {
      const baseline = clone(this.baselinePlan);
      this.edit((p) => Object.assign(p, baseline));
      this.dropStaleSelection();
    },
    setBaseline() {
      this.baselinePlan = clone(this.plan);
      this.$toasted.success(this.$t('page.system_planner.baseline_set'));
    },

    // -- import / export ----------------------------------------------------
    async importFromDialog(raw, fail) {
      try {
        await this.adopt(raw);
        this.importOpen = false;
      } catch (err) {
        fail(err instanceof PlanError ? err.code : 'not_a_plan');
      }
    },
    async exportPlan() {
      const outcome = await copyOrDownloadJson(JSON.stringify(this.plan, null, 2), planFilename(this.plan.name));
      if (outcome === 'copied') this.$toasted.success(this.$t('page.system_planner.export_copied'));
      else this.$toasted.info(this.$t('page.system_planner.export_downloaded'));
    },

    // -- keyboard -----------------------------------------------------------
    onKeydown(event) {
      const target = event.target || {};
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName) || this.importOpen) return;
      const mod = event.ctrlKey || event.metaKey;
      const key = String(event.key || '').toLowerCase();

      if (mod && key === 'z') {
        event.preventDefault();
        if (event.shiftKey) this.redo();
        else this.undo();
        return;
      }
      if (mod && key === 'y') {
        event.preventDefault();
        this.redo();
        return;
      }
      if (this.drawer || !this.selected || mod) return;

      const tile = this.tileOf(this.plan, this.selected);
      if (event.key === 'Escape') {
        this.selected = null;
      } else if (tile && tile.building_key && ['+', '='].includes(event.key)) {
        const building = this.speedData.building.find((b) => b.key === tile.building_key);
        const cap = building ? building.levels.length : 1;
        if (tile.building_level < cap) this.setLevel({ ...this.selected, level: tile.building_level + 1 });
      } else if (tile && tile.building_key && event.key === '-') {
        if (tile.building_level > 1) this.setLevel({ ...this.selected, level: tile.building_level - 1 });
      } else if (tile && tile.building_key && ['Delete', 'Backspace'].includes(event.key)) {
        const building = this.speedData.building.find((b) => b.key === tile.building_key);
        if (building && building.type !== 'infrastructure') this.removeBuilding(this.selected);
      }
    },
    formatIncome(value) { return format.income(value, 0); },
    formatInteger(value) { return format.integer(value); },
  },
  components: {
    DefaultLayout,
    PlannerBodies,
    PlannerTilePanel,
    PlannerGovernor,
    PlannerOutputs,
    PlannerTreeDrawer,
    PlannerImportDialog,
  },
};
</script>

<style lang="scss">
// In-game styles the planner reuses, scoped to the page: the system
// view's body rows and the mini panels' trees (the portal context only
// carries the tile grid, see main.scss).
@import '~@/styles/shared/variables';

.portal-context .system-planner,
.portal-context .planner-drawer-root {
  @import '~@/styles/game/variables';
  @import '~@/styles/game/mixins/default-button';
  @import '~@/styles/game/components/galaxy/system/content';
  @import '~@/styles/game/components/mini-panels/main';
  @import '~@/styles/game/components/mini-panels/tree-node';
}
</style>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-loading {
  padding: 60px 20px;
  text-align: center;
  opacity: .7;
}

.planner-pair {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;

  .default-input {
    margin-bottom: 0;
  }

  select {
    width: 100%;
  }
}

.planner-label-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 6px;
  font-size: 1.3rem;
  text-transform: uppercase;
}

.planner-link {
  padding: 0;
  border: none;
  background: none;
  color: $primary;
  font: inherit;
  font-size: 1.2rem;
  text-decoration: underline;
  cursor: pointer;
}

.planner-population-input {
  display: flex;
  align-items: stretch;
  gap: 4px;

  input {
    flex: 1 1 auto;
    min-width: 0;
    padding: 4px 8px;
    border: solid 1px rgba(255, 255, 255, .2);
    background: rgba(0, 0, 0, .3);
    color: $white;
    font: inherit;
    font-size: 1.5rem;
    font-variant-numeric: tabular-nums;
    text-align: center;
  }

  button {
    width: 32px;
    border: solid 1px rgba(255, 255, 255, .2);
    background: rgba(0, 0, 0, .3);
    color: $white;
    font-size: 1.7rem;
    cursor: pointer;

    &:hover { border-color: $white; }
  }
}

.planner-population-range {
  width: 100%;
  margin: 10px 0 4px;
}

.planner-small {
  margin: 4px 0 10px;
  font-size: 1.2rem;
  line-height: 1.45;
  opacity: .65;
}

.planner-check {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
  font-size: 1.3rem;

  input {
    width: 16px;
    height: 16px;
  }
}

.planner-drawer-button {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  margin-top: 6px;
  padding: 8px 10px;
  border: solid 1px rgba(255, 255, 255, .15);
  background: rgba(0, 0, 0, .25);
  color: $white;
  font: inherit;
  font-size: 1.3rem;
  text-transform: uppercase;
  cursor: pointer;

  .svg-icon {
    width: 22px;
    height: 22px;
  }

  strong {
    margin-left: auto;
    font-variant-numeric: tabular-nums;
  }

  &:hover {
    border-color: rgba(255, 255, 255, .5);
  }
}

.panel-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px 16px;

  h1 {
    display: flex;
    align-items: baseline;
    gap: 12px;
    min-width: 0;
  }
}

.planner-system-name {
  font-size: 1.5rem;
  font-weight: normal;
  opacity: .7;
}

.planner-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin-left: auto;
}

.planner-icon-button {
  width: 30px;
  height: 30px;
  border: solid 1px rgba(255, 255, 255, .2);
  border-radius: 3px;
  background: rgba(0, 0, 0, .3);
  color: $white;
  font-size: 1.7rem;
  line-height: 1;
  cursor: pointer;

  &:disabled { opacity: .3; cursor: default; }
  &:hover:not(:disabled) { border-color: $white; }
}

.planner-bodies-block {
  border-bottom: solid 1px rgba(255, 255, 255, .08);
}

.planner-scope-note {
  padding: 12px 20px 20px;
}

.planner-select-hint {
  margin: 0;
  padding: 12px 20px 0;
}

.planner-error {
  margin: 0 0 10px;
  padding-left: 10px;
  border-left: solid 3px $color-alert;
}

.is-stale {
  opacity: .6;
  transition: opacity 150ms ease 150ms;
}

/* --- phone --- */

.planner-sheet-root {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  z-index: 300;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  pointer-events: none;
}

.planner-sheet-backdrop {
  flex: 1 1 auto;
  pointer-events: auto;
  background: rgba(0, 0, 0, .35);
}

.planner-sheet {
  position: relative;
  pointer-events: auto;
  max-height: 62vh;
  overflow-y: auto;
  overscroll-behavior: contain;
  background: $grey-darker;
  border-top: solid 1px rgba(255, 255, 255, .2);
  box-shadow: 0 -8px 20px rgba(0, 0, 0, .55);
}

.planner-sheet-close {
  position: absolute;
  top: 8px;
  right: 8px;
  width: 30px;
  height: 30px;
  border: none;
  background: none;
  color: $white;

  .svg-icon {
    width: 13px;
    height: 13px;
  }
}

.planner-mobile-summary {
  position: fixed;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 250;
  display: flex;
  justify-content: space-around;
  padding: 6px 8px calc(6px + env(safe-area-inset-bottom));
  background: rgba(0, 0, 0, .85);
  border-top: solid 1px rgba(255, 255, 255, .15);
  font-size: 1.3rem;
  font-weight: bold;
  font-variant-numeric: tabular-nums;

  .svg-icon {
    width: 14px;
    height: 14px;
    vertical-align: -2px;
  }
}

@media screen and (max-width: $mobile-breakpoint) {
  // bodies, then setup, then the numbers
  .planner-main { order: -1; }

  .planner-results {
    padding-bottom: 40px; // clear of the summary bar
  }

  .planner-actions {
    margin-left: 0;
  }

}
</style>
