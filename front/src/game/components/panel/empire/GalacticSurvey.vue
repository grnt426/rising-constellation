<template>
  <div class="panel-content is-large gs-survey">
    <div class="gs-toolbar">
      <div class="gs-toolbar-row">
        <input
          v-model="search"
          type="text"
          class="gs-search"
          :placeholder="$t('panel.empire.survey_search_placeholder')">

        <select
          v-model="sectorFilter"
          class="gs-select">
          <option value="all">{{ $t('panel.empire.survey_sector_all') }}</option>
          <option
            v-for="sector in sectors"
            :key="sector.id"
            :value="sector.id">{{ sector.name }}</option>
        </select>

        <select
          v-model="ownerFilter"
          class="gs-select">
          <option value="all">{{ $t('panel.empire.survey_owner_all') }}</option>
          <option value="own">{{ $t('panel.empire.survey_owner_own') }}</option>
          <option value="other">{{ $t('panel.empire.survey_owner_other') }}</option>
          <option value="neutral">{{ $t('panel.empire.survey_owner_neutral') }}</option>
          <option value="unowned">{{ $t('panel.empire.survey_owner_unowned') }}</option>
        </select>

        <button
          class="gs-refresh"
          :disabled="loading"
          @click="refresh"
          v-tooltip.bottom="$t('panel.empire.survey_refresh')">
          &#x21bb;
        </button>
      </div>

      <div class="gs-toolbar-meta">
        <span v-if="loading">{{ $t('panel.empire.survey_loading') }}</span>
        <span v-else-if="lastError" class="gs-error">{{ lastError }}</span>
        <span v-else>{{ $tc('panel.empire.systems', filteredRows.length, { number: filteredRows.length }) }}</span>
      </div>
    </div>

    <v-scrollbar class="gs-scroll">
      <table class="gs-table">
        <colgroup>
          <col class="gs-c-icon">
          <col class="gs-c-name">
          <col class="gs-c-orbitals">
          <col class="gs-c-stat gs-c-stat-first">
          <col class="gs-c-stat">
          <col class="gs-c-stat">
          <col class="gs-c-sum">
          <col class="gs-c-income">
          <col class="gs-c-tiles">
        </colgroup>
        <thead>
          <tr class="gs-header">
            <th></th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'name' }"
                @click="setSort('name')">
                {{ $t('panel.empire.survey_col_name') }}
                <span v-if="sortBy === 'name'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'orbitals' }"
                @click="setSort('orbitals')">
                {{ $t('panel.empire.survey_col_orbitals') }}
                <span v-if="sortBy === 'orbitals'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'sum_prod' }"
                @click="setSort('sum_prod')"
                v-tooltip.bottom="$t('panel.empire.survey_col_prod_tt')">
                <svgicon name="stellar_body/industrial_factor" />
                <span v-if="sortBy === 'sum_prod'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'sum_sci' }"
                @click="setSort('sum_sci')"
                v-tooltip.bottom="$t('panel.empire.survey_col_sci_tt')">
                <svgicon name="stellar_body/technological_factor" />
                <span v-if="sortBy === 'sum_sci'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'sum_appeal' }"
                @click="setSort('sum_appeal')"
                v-tooltip.bottom="$t('panel.empire.survey_col_appeal_tt')">
                <svgicon name="stellar_body/activity_factor" />
                <span v-if="sortBy === 'sum_appeal'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>
              <button
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === 'sum_total' }"
                @click="setSort('sum_total')"
                v-tooltip.bottom="$t('panel.empire.survey_col_sum_tt')">
                Σ
                <span v-if="sortBy === 'sum_total'" class="gs-sort-arrow">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th>{{ $t('panel.empire.survey_col_income') }}</th>
            <th>{{ $t('panel.empire.survey_col_tiles') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="!filteredRows.length && !loading">
            <td colspan="9" class="gs-empty">{{ $t('panel.empire.survey_empty') }}</td>
          </tr>

          <tr
            class="gs-row"
            :class="rowThemeClass(row)"
            v-for="row in filteredRows"
            :key="row.id"
            @click="openSystem(row.id)">

            <td class="gs-cell-icon">
              <svgicon :name="`stellar_system/${row.type}`" />
            </td>

            <td class="gs-cell-name">
              <div class="gs-name-line">
                <strong class="gs-name">{{ row.name }}</strong>
                <span class="gs-sector">{{ sectorName(row.sector_id) }}</span>
              </div>
              <div class="gs-owner-line">
                <span class="gs-owner-label">{{ ownerLabel(row) }}</span>
                <span
                  v-if="row.has_eden"
                  class="gs-eden"
                  v-tooltip.bottom="$t('panel.empire.survey_eden')">
                  ★ EDEN
                </span>
              </div>
            </td>

            <td
              class="gs-cell-orbitals"
              v-tooltip.bottom="bodyBreakdownTooltip(row)">
              <div class="gs-orbitals-count">
                <strong>{{ row.orbitals }}</strong>
                <span class="gs-orbital-label">{{ $t('panel.empire.survey_orbitals') }}</span>
              </div>
              <div class="gs-body-breakdown">
                <span
                  v-for="kind in BODY_ORDER"
                  :key="kind"
                  v-if="(row.bodies_by_type || {})[kind]"
                  class="gs-body-item">
                  <span class="gs-body-count">{{ row.bodies_by_type[kind] }}</span>
                  <svgicon :name="`stellar_body/${kind}`" />
                </span>
              </div>
            </td>

            <td class="gs-cell-stat gs-cell-stat-first">
              <span v-if="row.sum_prod !== null" class="gs-stat-val">{{ row.sum_prod }}</span>
              <span v-else class="gs-unknown">?</span>
              <svgicon name="stellar_body/industrial_factor" />
            </td>

            <td class="gs-cell-stat">
              <span v-if="row.sum_sci !== null" class="gs-stat-val">{{ row.sum_sci }}</span>
              <span v-else class="gs-unknown">?</span>
              <svgicon name="stellar_body/technological_factor" />
            </td>

            <td class="gs-cell-stat">
              <span v-if="row.sum_appeal !== null" class="gs-stat-val">{{ row.sum_appeal }}</span>
              <span v-else class="gs-unknown">?</span>
              <svgicon name="stellar_body/activity_factor" />
            </td>

            <td class="gs-cell-sum">
              <span class="gs-sum-eq">=</span>
              <span v-if="row.sum_prod !== null" class="gs-stat-val">{{ sumResources(row) }}</span>
              <span v-else class="gs-unknown">?</span>
            </td>

            <td
              class="gs-cell-income"
              v-tooltip.bottom="$t('panel.empire.survey_income_tooltip')">
              <div class="gs-income-item">
                <span v-if="row.current_prod !== null" class="gs-stat-val">{{ row.current_prod | integer }}</span>
                <span v-else class="gs-unknown">?</span>
                <svgicon name="resource/production" />
              </div>
              <div class="gs-income-item">
                <span v-if="row.current_sci !== null" class="gs-stat-val">{{ row.current_sci | integer }}</span>
                <span v-else class="gs-unknown">?</span>
                <svgicon name="resource/technology" />
              </div>
              <div class="gs-income-item">
                <span v-if="row.current_appeal !== null" class="gs-stat-val">{{ row.current_appeal | integer }}</span>
                <span v-else class="gs-unknown">?</span>
                <svgicon name="resource/ideology" />
              </div>
            </td>

            <td class="gs-cell-tiles">
              <div
                class="gs-tiles-count"
                v-tooltip.bottom="tilesTooltip(row)">
                <template v-if="row.built_tile_count !== null">
                  <span class="gs-stat-val">{{ row.built_tile_count }}/{{ row.total_tile_count }}</span>
                </template>
                <span v-else class="gs-unknown">?</span>
                <svgicon name="resource/production" />
              </div>
              <div
                class="gs-megastructure"
                :class="{ 'has-megastructure': hasMegastructure(row) }"
                v-tooltip.bottom="megastructureTooltip(row)">
                <template v-if="row.megastructures_built === null">
                  <span class="gs-unknown">?</span>
                </template>
                <template v-else-if="hasMegastructure(row)">
                  <svgicon
                    v-for="key in row.megastructures_built"
                    :key="key"
                    :name="`building/${key}`"
                    class="gs-mega-icon" />
                </template>
                <template v-else>
                  <span class="gs-mega-empty">—</span>
                </template>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </v-scrollbar>
  </div>
</template>

<script>
const MEGASTRUCTURE_I18N = {
  monument_dome: 'data.building.monument_dome.name',
  high_factory_dome: 'data.building.high_factory_dome.name',
};

const BODY_ORDER = [
  'habitable_planet',
  'sterile_planet',
  'gaseous_giant',
  'moon',
  'asteroid_belt',
  'asteroid',
];

const DEFAULT_DIR = {
  name: 'asc',
  orbitals: 'desc',
  sum_prod: 'desc',
  sum_sci: 'desc',
  sum_appeal: 'desc',
  sum_total: 'desc',
};

export default {
  name: 'empire-galactic-survey-panel',
  data() {
    return {
      rows: [],
      loading: false,
      lastError: null,
      search: '',
      sectorFilter: 'all',
      ownerFilter: 'all',
      sortBy: 'orbitals',
      sortDir: 'desc',
      BODY_ORDER,
    };
  },
  computed: {
    player() { return this.$store.state.game.player; },
    ownFactionKey() { return this.player ? this.player.faction : null; },
    sectors() {
      const sectors = this.$store.state.game.galaxy && this.$store.state.game.galaxy.sectors;
      return sectors || [];
    },
    sectorById() {
      return this.sectors.reduce((acc, s) => {
        acc[s.id] = s;
        return acc;
      }, {});
    },
    filteredRows() {
      const search = this.search.trim().toLowerCase();
      let rows = this.rows;

      if (search) {
        rows = rows.filter((r) => r.name.toLowerCase().includes(search));
      }
      if (this.sectorFilter !== 'all') {
        const target = Number(this.sectorFilter);
        rows = rows.filter((r) => r.sector_id === target);
      }
      if (this.ownerFilter !== 'all') {
        rows = rows.filter((r) => this.ownerKind(r) === this.ownerFilter);
      }

      const sorted = rows.slice();
      const sign = this.sortDir === 'asc' ? 1 : -1;
      const key = this.sortBy;
      sorted.sort((a, b) => {
        if (key === 'name') return sign * a.name.localeCompare(b.name);
        if (key === 'sum_total') return sign * (this.sumResources(a) - this.sumResources(b));
        // null safe: unknown values sort to the end
        const av = a[key];
        const bv = b[key];
        if (av == null && bv == null) return 0;
        if (av == null) return 1;
        if (bv == null) return -1;
        return sign * (av - bv);
      });
      return sorted;
    },
  },
  methods: {
    sumResources(row) {
      return (row.sum_prod || 0) + (row.sum_sci || 0) + (row.sum_appeal || 0);
    },
    ownerKind(row) {
      if (row.faction != null) {
        return row.faction === this.ownFactionKey ? 'own' : 'other';
      }
      // No faction owner. Distinguish populated-neutral (a colonizable
      // population exists, but no player has claimed it) from completely
      // unowned (empty/uninhabitable rock).
      if (row.status === 'inhabited_neutral') return 'neutral';
      return 'unowned';
    },
    ownerLabel(row) {
      const kind = this.ownerKind(row);
      if (kind === 'own') return this.$t('panel.empire.survey_owner_own');
      if (kind === 'neutral') return this.$t('panel.empire.survey_owner_neutral');
      if (kind === 'unowned') return this.$t('panel.empire.survey_owner_unowned');
      return row.owner_name || this.$t('panel.empire.survey_unknown');
    },
    rowThemeClass(row) {
      const kind = this.ownerKind(row);
      if (kind === 'neutral') return 'gs-row-neutral';
      if (kind === 'unowned') return 'gs-row-unowned';
      const theme = this.$store.getters['game/themeByKey'](row.faction);
      if (!theme) return 'gs-row-unknown';
      return [`force-color-${theme}`, `gs-row-themed`, kind === 'own' ? 'gs-row-own' : 'gs-row-other'];
    },
    tilesTooltip(row) {
      if (row.built_tile_count === null) {
        return this.$t('panel.empire.survey_tiles_unknown');
      }
      return this.$t('panel.empire.survey_tiles_tooltip', {
        built: row.built_tile_count,
        total: row.total_tile_count,
      });
    },
    sectorName(sectorId) {
      const sector = this.sectorById[sectorId];
      return sector ? sector.name : '';
    },
    setSort(key) {
      if (this.sortBy === key) {
        this.sortDir = this.sortDir === 'asc' ? 'desc' : 'asc';
      } else {
        this.sortBy = key;
        this.sortDir = DEFAULT_DIR[key] || 'desc';
      }
    },
    bodyBreakdownTooltip(row) {
      const b = row.bodies_by_type || {};
      const keys = BODY_ORDER.filter((k) => b[k]);
      if (!keys.length) return this.$t('panel.empire.survey_no_bodies');
      return keys
        .map((k) => `${b[k]} × ${this.$t(`data.stellar_body.${k}.name`)}`)
        .join(', ');
    },
    hasMegastructure(row) {
      return Array.isArray(row.megastructures_built) && row.megastructures_built.length > 0;
    },
    megastructureName(key) {
      const path = MEGASTRUCTURE_I18N[key];
      return path ? this.$t(path) : key;
    },
    megastructureLabel(row) {
      if (!this.hasMegastructure(row)) return '';
      return row.megastructures_built.map((key) => this.megastructureName(key)).join(', ');
    },
    megastructureTooltip(row) {
      if (row.megastructures_built === null) {
        return this.$t('panel.empire.survey_megastructure_unknown');
      }
      if (this.hasMegastructure(row)) {
        return this.megastructureLabel(row);
      }
      return this.$t('panel.empire.survey_no_megastructure');
    },
    fetch() {
      if (!this.$socket || !this.$socket.faction) {
        this.lastError = 'no socket/faction channel';
        return;
      }
      this.loading = true;
      this.lastError = null;
      this.$socket.faction
        .push('get_galactic_survey', {})
        .receive('ok', (data) => {
          this.rows = Array.isArray(data.rows) ? data.rows : [];
          this.loading = false;
        })
        .receive('error', (data) => {
          this.lastError = (data && data.reason) || 'error';
          this.loading = false;
        })
        .receive('timeout', () => {
          this.lastError = 'timeout';
          this.loading = false;
        });
    },
    refresh() {
      this.fetch();
    },
    openSystem(id) {
      this.$emit('close');
      this.$store.dispatch('game/openSystem', { vm: this, id });
    },
  },
  mounted() {
    this.fetch();
  },
};
</script>

<style lang="scss" scoped>
.gs-survey {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.gs-toolbar {
  padding: 0.5em 1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  flex-shrink: 0;
}

.gs-toolbar-row {
  display: flex;
  gap: 0.5em;
  align-items: center;
  flex-wrap: wrap;
}

.gs-search {
  flex: 1 1 12em;
  min-width: 8em;
  padding: 0.25em 0.5em;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;

  &:focus {
    outline: none;
    border-color: rgba(255, 255, 255, 0.5);
  }
}

.gs-select {
  padding: 0.25em 0.5em;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
}

.gs-refresh {
  padding: 0.25em 0.6em;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
  cursor: pointer;
  font-size: 1.1em;

  &:hover:not(:disabled) { background: rgba(255, 255, 255, 0.1); }
  &:disabled { opacity: 0.5; cursor: default; }
}

.gs-toolbar-meta {
  margin-top: 0.4em;
  font-size: 0.85em;
  opacity: 0.7;
}

.gs-error { color: #e85a5a; }

/* ---- Table layout ----
 *
 * Native HTML table with `table-layout: fixed` + explicit <col> widths.
 * The table layout algorithm computes column widths once from the colgroup
 * and applies them to every row, so header and data cells are guaranteed
 * to line up. Tried CSS Grid first but ran into per-container width
 * differences (border-left on rows changing the content box, asymmetric
 * margins on stat cells, HMR-flaky scoped-style application of multiline
 * grid templates). Tables sidestep all of that.
 */
.gs-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  font-size: 1em;
}

.gs-c-icon         { width: 2.5em; }
.gs-c-name         { width: auto;  } /* flexes — gets all leftover space */
.gs-c-orbitals     { width: 9em;   }
.gs-c-stat         { width: 3.75em; }
.gs-c-sum          { width: 5em;   }
.gs-c-income       { width: 7em;   }
.gs-c-tiles        { width: 9em;   }

/* ---- Header row ---- */

.gs-table thead th {
  padding: 0.45em 0.4em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.15);
  background: rgba(8, 12, 22, 0.95);   /* opaque so sticky doesn't bleed */
  font-size: 0.8em;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  text-align: left;
  font-weight: normal;
  position: sticky;
  top: 0;
  z-index: 2;
}

/* Buttons sit flush inside their column cell so the header label starts at
 * the same x-coordinate as the corresponding data row content. Horizontal
 * padding here was throwing the header rightward relative to its data
 * column (especially visible on the orbitals header). */
.gs-sort-btn {
  background: none;
  border: none;
  color: inherit;
  padding: 0;
  cursor: pointer;
  font: inherit;
  text-transform: inherit;
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  opacity: 0.6;

  &:hover { opacity: 0.95; }
  &.is-active { opacity: 1; font-weight: bold; }

  .svg-icon { width: 1.1em; height: 1.1em; }
}

.gs-sort-arrow { font-size: 0.7em; }

/* ---- Per-cell content alignment ----
 * Column widths come from the colgroup above; here we only control how
 * each cell composes its inner content. Table cells default to
 * vertical-align: middle which is what we want.
 */
.gs-table td {
  padding: 0.5em 0.4em;
  vertical-align: middle;
}

.gs-cell-icon       { text-align: center; }
.gs-cell-orbitals   { text-align: left; }
.gs-cell-stat,
.gs-cell-sum,
.gs-cell-income,
.gs-cell-tiles { /* inner divs handle alignment */ }

/* Inner flex containers inside cells handle horizontal layout of icons +
 * numbers. Table cell itself just provides the box. */
.gs-cell-stat   > .gs-cell-inner,
.gs-cell-stat .gs-stat-val,
.gs-cell-stat .gs-unknown {
  /* no-op — we use display:flex on the cell content via class below */
}

/* Stat cells (prod/sci/appeal/sum) align their content right-bound for
 * numbers + icon, center-bound for the Σ summary. Tables align via
 * `text-align` for inline content, and the cell's flex children for
 * block content; we use both. */
.gs-cell-stat {
  text-align: right;
  white-space: nowrap;
  .svg-icon { vertical-align: middle; margin-left: 0.2em; }
}
.gs-cell-sum {
  text-align: center;
  white-space: nowrap;
  border-right: 1px solid rgba(255, 255, 255, 0.18);
}
.gs-cell-stat-first {
  border-left: 1px solid rgba(255, 255, 255, 0.18);
}
.gs-cell-income { text-align: center; white-space: nowrap; }

.gs-sum-eq {
  opacity: 0.45;
  margin-right: 0.15em;
}

.gs-income-item {
  display: inline-flex;
  align-items: center;
  gap: 0.15em;
  margin-right: 0.4em;
  font-size: 0.85em;

  &:last-child { margin-right: 0; }

  .svg-icon { width: 0.9em; height: 0.9em; opacity: 0.85; }
}

/* Mirror the same border treatment on the header so the vertical rules
 * extend the full table height. 4th col = prod (left edge of stat group),
 * 7th col = Σ (right edge of stat group). */
.gs-table thead th:nth-child(4) { border-left: 1px solid rgba(255, 255, 255, 0.18); }
.gs-table thead th:nth-child(7) { border-right: 1px solid rgba(255, 255, 255, 0.18); }

/* ---- Data rows ---- */

.gs-scroll { flex: 1 1 auto; min-height: 0; }

.gs-empty {
  padding: 2em 1em;
  text-align: center;
  opacity: 0.5;
}

.gs-row {
  cursor: pointer;
  transition: background 0.1s ease;

  &:hover > td { background: rgba(255, 255, 255, 0.05); }

  > td {
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  }

  .svg-icon { width: 1em; height: 1em; vertical-align: middle; }
}

/* Faction tinting: a colored left stripe via box-shadow inset on the first
 * cell of each row. We use box-shadow rather than border-left because a
 * border on a <td> would shift the cell content into the next column
 * track. box-shadow is purely visual and doesn't take space. */
.gs-row.gs-row-themed > td:first-child,
.gs-row.gs-row-neutral > td:first-child,
.gs-row.gs-row-unowned > td:first-child,
.gs-row.gs-row-unknown > td:first-child {
  box-shadow: inset 4px 0 0 var(--gs-faction-color, transparent);
}
.gs-row.gs-row-themed {
  background: rgba(255, 255, 255, 0.02);
}
.gs-row.force-color-dark-blue  > td:first-child { --gs-faction-color: #3a5ea5; }
.gs-row.force-color-red        > td:first-child { --gs-faction-color: #b94e4e; }
.gs-row.force-color-purple     > td:first-child { --gs-faction-color: #8e60bf; }
.gs-row.force-color-green      > td:first-child { --gs-faction-color: #a2cd44; }
.gs-row.force-color-yellow     > td:first-child { --gs-faction-color: #c9a115; }
/* Neutral = has population but no player owns it. Unowned = empty or
 * uninhabitable. Lift the unowned row's name lightness so it's visibly
 * distinct from the more "weighty" neutral row at a glance. */
.gs-row.gs-row-neutral > td:first-child  { --gs-faction-color: #707582; }
.gs-row.gs-row-neutral .gs-name          { color: #c9ced6; }
.gs-row.gs-row-unowned > td:first-child  { --gs-faction-color: #bcc3cc; }
.gs-row.gs-row-unowned .gs-name          { color: #f1f3f6; }
.gs-row.gs-row-unknown > td:first-child  { --gs-faction-color: #9ea4ad; }

/* ---- Name column ---- */

.gs-name-line { display: flex; align-items: baseline; gap: 0.5em; min-width: 0; }
.gs-name      { font-size: 1.05em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.gs-sector    { font-size: 0.75em; opacity: 0.6; text-transform: uppercase; flex-shrink: 0; }

.gs-owner-line {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.75em;
  opacity: 0.7;
  margin-top: 0.1em;
}
.gs-owner-label { text-transform: uppercase; letter-spacing: 0.04em; }
.gs-eden        { color: gold; font-weight: bold; font-size: 0.9em; }

/* ---- Orbitals column ---- */

.gs-orbitals-count {
  display: flex;
  align-items: baseline;
  gap: 0.35em;
  font-size: 0.95em;
}
.gs-orbital-label {
  font-size: 0.7em;
  text-transform: uppercase;
  opacity: 0.6;
}
.gs-body-breakdown {
  display: flex;
  gap: 0.5em;
  margin-top: 0.15em;
  flex-wrap: wrap;
}
.gs-body-item {
  display: inline-flex;
  align-items: center;
  gap: 0.15em;
  font-size: 0.85em;

  .svg-icon { width: 0.95em; height: 0.95em; opacity: 0.85; }
}
.gs-body-count { font-weight: bold; }

/* ---- Stat columns ---- */

.gs-stat-val   { font-weight: bold; }
.gs-unknown    {
  opacity: 0.4;
  font-weight: bold;
  font-size: 0.95em;
}

/* `.gs-income-item` styles live above near the cell content rules. */

/* ---- Tiles column ---- */

.gs-tiles-count {
  display: flex;
  align-items: center;
  gap: 0.3em;
  font-size: 0.9em;
}
.gs-megastructure {
  display: flex;
  align-items: center;
  gap: 0.35em;
  font-size: 0.9em;
  opacity: 0.7;
  min-height: 1.2em;

  &.has-megastructure { color: gold; opacity: 1; }

  .gs-mega-icon { width: 1.25em; height: 1.25em; }
}
.gs-mega-empty { opacity: 0.4; }
</style>
