<template>
  <div class="panel-content is-large gs-survey">
    <div class="gs-toolbar">
      <div
        class="gs-toolbar-row"
        role="search">
        <input
          v-model="search"
          type="search"
          class="gs-search"
          :aria-label="$t('panel.empire.survey_search_label')"
          :placeholder="$t('panel.empire.survey_search_placeholder')">

        <select
          v-model="sectorFilter"
          class="gs-select"
          :aria-label="$t('panel.empire.survey_sector_label')">
          <option value="all">{{ $t('panel.empire.survey_sector_all') }}</option>
          <option
            v-for="sector in sectors"
            :key="sector.id"
            :value="sector.id">{{ sector.name }}</option>
        </select>

        <select
          v-model="ownerFilter"
          class="gs-select"
          :aria-label="$t('panel.empire.survey_owner_label')">
          <option value="all">{{ $t('panel.empire.survey_owner_all') }}</option>
          <option value="own">{{ $t('panel.empire.survey_owner_own') }}</option>
          <option value="other">{{ $t('panel.empire.survey_owner_other') }}</option>
          <option value="neutral">{{ $t('panel.empire.survey_owner_neutral') }}</option>
          <option value="unowned">{{ $t('panel.empire.survey_owner_unowned') }}</option>
        </select>

        <select
          v-model="agentFilter"
          class="gs-select"
          :aria-label="$t('panel.empire.survey_agents_label')">
          <option value="all">{{ $t('panel.empire.survey_agents_all') }}</option>
          <option value="foreign">{{ $t('panel.empire.survey_agents_foreign') }}</option>
          <option value="own">{{ $t('panel.empire.survey_agents_own') }}</option>
          <option value="any">{{ $t('panel.empire.survey_agents_any') }}</option>
          <option value="none">{{ $t('panel.empire.survey_agents_none') }}</option>
        </select>

        <button
          type="button"
          class="gs-refresh"
          :disabled="loading"
          :aria-label="$t('panel.empire.survey_refresh')"
          @click="refresh"
          v-tooltip.bottom="$t('panel.empire.survey_refresh')">
          <span aria-hidden="true">&#x21bb;</span>
        </button>
      </div>

      <!-- Polite live region: a screen reader hears the new count after
           each filter change without losing its place in the toolbar. -->
      <div
        class="gs-toolbar-meta"
        role="status">
        <span v-if="loading">{{ $t('panel.empire.survey_loading') }}</span>
        <span v-else-if="lastError" class="gs-error">{{ lastError }}</span>
        <span v-else>{{ $tc('panel.empire.systems', filteredRows.length, { number: filteredRows.length }) }}</span>
      </div>
    </div>

    <v-scrollbar class="gs-scroll">
      <table class="gs-table">
        <caption class="sr-only">{{ $t('panel.empire.survey_caption') }}</caption>
        <colgroup>
          <col class="gs-c-icon">
          <col class="gs-c-name">
          <col class="gs-c-orbitals">
          <col class="gs-c-agents">
          <col class="gs-c-stat gs-c-stat-first">
          <col class="gs-c-stat">
          <col class="gs-c-stat">
          <col class="gs-c-sum">
          <col class="gs-c-income">
          <col class="gs-c-tiles">
        </colgroup>
        <thead>
          <tr class="gs-header">
            <th scope="col">
              <span class="sr-only">{{ $t('panel.empire.survey_col_star') }}</span>
            </th>
            <th
              v-for="col in SORTABLE_COLUMNS"
              :key="col.key"
              scope="col"
              :class="col.thClass"
              :aria-sort="ariaSort(col.key)">
              <button
                type="button"
                class="gs-sort-btn"
                :class="{ 'is-active': sortBy === col.key }"
                @click="setSort(col.key)"
                v-tooltip.bottom="col.tooltip ? $t(col.tooltip) : null">
                <svgicon
                  v-if="col.icon"
                  :name="col.icon"
                  aria-hidden="true" />
                <span
                  v-if="col.symbol"
                  aria-hidden="true">{{ col.symbol }}</span>
                <span :class="{ 'sr-only': col.icon || col.symbol }">{{ $t(col.label) }}</span>
                <span
                  v-if="sortBy === col.key"
                  class="gs-sort-arrow"
                  aria-hidden="true">{{ sortDir === 'asc' ? '▲' : '▼' }}</span>
              </button>
            </th>
            <th scope="col">{{ $t('panel.empire.survey_col_income') }}</th>
            <th scope="col">{{ $t('panel.empire.survey_col_tiles') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="!filteredRows.length && !loading">
            <td colspan="10" class="gs-empty">{{ $t('panel.empire.survey_empty') }}</td>
          </tr>

          <tr
            class="gs-row"
            :class="rowThemeClass(row)"
            v-for="row in filteredRows"
            :key="row.id"
            @click="openSystem(row.id)">

            <td class="gs-cell-icon">
              <svgicon
                :name="`stellar_system/${row.type}`"
                aria-hidden="true" />
              <span class="sr-only">{{ $t(`data.stellar_system.${row.type}.name`) }}</span>
            </td>

            <!-- Row header: screen readers announce the system name when
                 moving across a row's cells. -->
            <th
              scope="row"
              class="gs-cell-name">
              <div class="gs-name-cell-inner">
                <div class="gs-name-info">
                  <div class="gs-name-line">
                    <!-- The keyboard way into the system (the row click is
                         mouse-only); styled to look like the plain name. -->
                    <button
                      type="button"
                      class="bare-button gs-name"
                      @click.stop="openSystem(row.id)">{{ row.name }}</button>
                    <span class="gs-sector">{{ sectorName(row.sector_id) }}</span>
                  </div>
                  <div class="gs-owner-line">
                    <span class="gs-owner-label">{{ ownerLabel(row) }}</span>
                    <span
                      v-if="row.has_eden"
                      class="gs-eden"
                      v-tooltip.bottom="$t('panel.empire.survey_eden')">
                      <span aria-hidden="true">★ EDEN</span>
                      <span class="sr-only">{{ $t('panel.empire.survey_eden') }}</span>
                    </span>
                  </div>
                </div>

                <!-- Buttons stop propagation so they don't also fire the
                     row-level click handler. -->
                <div class="gs-row-actions" @click.stop>
                  <button
                    type="button"
                    class="gs-row-action"
                    :aria-label="`${$t('panel.empire.survey_action_system_view')}: ${row.name}`"
                    @click.stop="enterSystemView(row.id)"
                    v-tooltip.bottom="$t('panel.empire.survey_action_system_view')">
                    <span aria-hidden="true">⊙</span>
                  </button>
                  <button
                    type="button"
                    class="gs-row-action"
                    :aria-label="`${$t('panel.empire.survey_action_copy_basic')}: ${row.name}`"
                    @click.stop="copyBasic(row)"
                    v-tooltip.bottom="$t('panel.empire.survey_action_copy_basic')">
                    <span aria-hidden="true">⧉</span>
                  </button>
                  <button
                    type="button"
                    class="gs-row-action"
                    :aria-label="`${$t('panel.empire.survey_action_copy_summary')}: ${row.name}`"
                    @click.stop="copySummary(row)"
                    v-tooltip.bottom="$t('panel.empire.survey_action_copy_summary')">
                    <span aria-hidden="true">⧉+</span>
                  </button>
                </div>
              </div>
            </th>

            <td
              class="gs-cell-orbitals"
              v-tooltip.bottom="bodyBreakdownTooltip(row)">
              <div
                class="gs-orbitals-line"
                aria-hidden="true">
                <strong class="gs-orbitals-total">{{ row.bodyCounts.total }}</strong>
                <span
                  v-for="group in BODY_GROUPS"
                  :key="group.key"
                  class="gs-body-item"
                  :class="{ 'is-zero': !row.bodyCounts[group.key] }">
                  <span class="gs-body-count">{{ row.bodyCounts[group.key] }}</span>
                  <svgicon :name="group.icon" />
                </span>
              </div>
              <span class="sr-only">{{ bodySummary(row) }}</span>
            </td>

            <td
              class="gs-cell-agents"
              v-tooltip.bottom="agentsTooltip(row)">
              <template v-if="row.agentGroups === null">
                <span
                  class="gs-unknown"
                  aria-hidden="true">?</span>
                <span class="sr-only">{{ $t('panel.empire.survey_agents_unknown') }}</span>
              </template>
              <template v-else-if="!row.agentGroups.length">
                <span
                  class="gs-mega-empty"
                  aria-hidden="true">—</span>
                <span class="sr-only">{{ $t('panel.empire.survey_agents_empty') }}</span>
              </template>
              <template v-else>
                <div
                  class="gs-agent-groups"
                  aria-hidden="true">
                  <span
                    v-for="group in row.agentGroups"
                    :key="group.faction"
                    class="gs-agent-group"
                    :class="[`force-color-${group.theme}`, { 'is-own': group.own }]">
                    <span
                      v-for="type in group.types"
                      :key="type.key"
                      class="gs-agent-count">
                      {{ type.count }}<svgicon :name="`agent/${type.key}`" />
                    </span>
                  </span>
                </div>
                <span class="sr-only">{{ agentsSummary(row) }}</span>
              </template>
            </td>

            <td class="gs-cell-stat gs-cell-stat-first">
              <span v-if="row.sum_prod !== null" class="gs-stat-val">{{ row.sum_prod }}</span>
              <template v-else>
                <span class="gs-unknown" aria-hidden="true">?</span>
                <span class="sr-only">{{ $t('panel.empire.survey_unknown') }}</span>
              </template>
              <svgicon name="stellar_body/industrial_factor" aria-hidden="true" />
            </td>

            <td class="gs-cell-stat">
              <span v-if="row.sum_sci !== null" class="gs-stat-val">{{ row.sum_sci }}</span>
              <template v-else>
                <span class="gs-unknown" aria-hidden="true">?</span>
                <span class="sr-only">{{ $t('panel.empire.survey_unknown') }}</span>
              </template>
              <svgicon name="stellar_body/technological_factor" aria-hidden="true" />
            </td>

            <td class="gs-cell-stat">
              <span v-if="row.sum_appeal !== null" class="gs-stat-val">{{ row.sum_appeal }}</span>
              <template v-else>
                <span class="gs-unknown" aria-hidden="true">?</span>
                <span class="sr-only">{{ $t('panel.empire.survey_unknown') }}</span>
              </template>
              <svgicon name="stellar_body/activity_factor" aria-hidden="true" />
            </td>

            <td class="gs-cell-sum">
              <span class="gs-sum-eq" aria-hidden="true">=</span>
              <span v-if="row.sum_prod !== null" class="gs-stat-val">{{ row.sumTotal }}</span>
              <template v-else>
                <span class="gs-unknown" aria-hidden="true">?</span>
                <span class="sr-only">{{ $t('panel.empire.survey_unknown') }}</span>
              </template>
            </td>

            <td
              class="gs-cell-income"
              v-tooltip.bottom="$t('panel.empire.survey_income_tooltip')">
              <div
                v-for="res in INCOME_COLUMNS"
                :key="res.field"
                class="gs-income-item">
                <span class="sr-only">{{ $t(res.label) }}</span>
                <span v-if="row[res.field] !== null" class="gs-stat-val">{{ row[res.field] | income(0) }}</span>
                <template v-else>
                  <span class="gs-unknown" aria-hidden="true">?</span>
                  <span class="sr-only">{{ $t('panel.empire.survey_unknown') }}</span>
                </template>
                <svgicon :name="res.icon" aria-hidden="true" />
              </div>
            </td>

            <td class="gs-cell-tiles">
              <div
                class="gs-tiles-count"
                v-tooltip.bottom="tilesTooltip(row)">
                <template v-if="row.built_tile_count !== null">
                  <span class="gs-stat-val" aria-hidden="true">{{ row.built_tile_count }}/{{ row.total_tile_count }}</span>
                </template>
                <span v-else class="gs-unknown" aria-hidden="true">?</span>
                <span class="sr-only">{{ tilesTooltip(row) }}</span>
                <svgicon name="resource/production" aria-hidden="true" />
              </div>
              <div
                class="gs-megastructure"
                :class="{ 'has-megastructure': hasMegastructure(row) }"
                v-tooltip.bottom="megastructureTooltip(row)">
                <template v-if="row.megastructures_built === null">
                  <span class="gs-unknown" aria-hidden="true">?</span>
                </template>
                <template v-else-if="hasMegastructure(row)">
                  <svgicon
                    v-for="key in row.megastructures_built"
                    :key="key"
                    :name="`building/${key}`"
                    class="gs-mega-icon"
                    aria-hidden="true" />
                </template>
                <template v-else>
                  <span class="gs-mega-empty" aria-hidden="true">—</span>
                </template>
                <span class="sr-only">{{ megastructureTooltip(row) }}</span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </v-scrollbar>
  </div>
</template>

<script>
import { copyToClipboard } from '@/utils/clipboard';
import { searchKey } from '@/utils/search-key';

const MEGASTRUCTURE_I18N = {
  monument_dome: 'data.building.monument_dome.name',
  high_factory_dome: 'data.building.high_factory_dome.name',
};

// The body column counts what can be built on, grouped by biome. Moons
// and asteroids share the orbital biome (same tiles, same buildings, the
// patent tree's "Moons and Asteroids" class), so they are one count. Gas
// giants and asteroid belts have no tiles and no factors — they only
// host those moons and asteroids — so they appear in the tooltip only.
const BODY_GROUPS = [
  { key: 'open', types: ['habitable_planet'], icon: 'stellar_body/habitable_planet' },
  { key: 'dome', types: ['sterile_planet'], icon: 'stellar_body/sterile_planet' },
  { key: 'orbital', types: ['moon', 'asteroid'], icon: 'stellar_body/moon' },
];
const HOST_BODY_TYPES = ['gaseous_giant', 'asteroid_belt'];

const AGENT_TYPES = ['admiral', 'spy', 'speaker'];

const SORTABLE_COLUMNS = [
  { key: 'name', label: 'panel.empire.survey_col_name' },
  {
    key: 'orbitals',
    label: 'panel.empire.survey_col_bodies',
    tooltip: 'panel.empire.survey_col_bodies_tt',
  },
  {
    key: 'agents',
    label: 'panel.empire.survey_col_agents',
    tooltip: 'panel.empire.survey_col_agents_tt',
  },
  {
    key: 'sum_prod',
    label: 'panel.empire.survey_col_prod',
    icon: 'stellar_body/industrial_factor',
    tooltip: 'panel.empire.survey_col_prod_tt',
    thClass: 'gs-th-stat-first',
  },
  {
    key: 'sum_sci',
    label: 'panel.empire.survey_col_sci',
    icon: 'stellar_body/technological_factor',
    tooltip: 'panel.empire.survey_col_sci_tt',
  },
  {
    key: 'sum_appeal',
    label: 'panel.empire.survey_col_appeal',
    icon: 'stellar_body/activity_factor',
    tooltip: 'panel.empire.survey_col_appeal_tt',
  },
  {
    key: 'sum_total',
    label: 'panel.empire.survey_col_sum',
    symbol: 'Σ',
    tooltip: 'panel.empire.survey_col_sum_tt',
    thClass: 'gs-th-sum',
  },
];

const INCOME_COLUMNS = [
  { field: 'current_prod', icon: 'resource/production', label: 'panel.empire.survey_income_prod' },
  { field: 'current_sci', icon: 'resource/technology', label: 'panel.empire.survey_income_sci' },
  { field: 'current_appeal', icon: 'resource/ideology', label: 'panel.empire.survey_income_appeal' },
];

const DEFAULT_DIR = {
  name: 'asc',
  orbitals: 'desc',
  agents: 'desc',
  sum_prod: 'desc',
  sum_sci: 'desc',
  sum_appeal: 'desc',
  sum_total: 'desc',
};

// Sort values per column; null (not visible yet) always sorts last.
const SORT_VALUE = {
  orbitals: (row) => row.bodyCounts.total,
  agents: (row) => (row.agentGroups === null ? null : (row.agents || []).length),
  sum_total: (row) => row.sumTotal,
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
      agentFilter: 'all',
      sortBy: 'orbitals',
      sortDir: 'desc',
      BODY_GROUPS,
      SORTABLE_COLUMNS,
      INCOME_COLUMNS,
    };
  },
  computed: {
    // playerFaction, not state.player: this table is always mounted
    // (v-show) and a state.player dependency re-rendered every row on
    // every player replacement — per construction click, per tick.
    ownFactionKey() { return this.$store.state.game.playerFaction; },
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
    // Derived per-row data, computed once per fetch rather than per
    // render / per sort comparison.
    decoratedRows() {
      return this.rows.map((row) => ({
        ...row,
        bodyCounts: this.countBodies(row),
        sumTotal: row.sum_prod === null ? null : this.sumResources(row),
        agentGroups: this.groupAgents(row),
        haystack: searchKey([
          row.name,
          row.owner_name,
          ...(row.agents || []).map((a) => a.name),
        ].join(' ')),
      }));
    },
    filteredRows() {
      const search = searchKey(this.search.trim());
      let rows = this.decoratedRows;

      if (search) {
        rows = rows.filter((r) => r.haystack.includes(search));
      }
      if (this.sectorFilter !== 'all') {
        const target = Number(this.sectorFilter);
        rows = rows.filter((r) => r.sector_id === target);
      }
      if (this.ownerFilter !== 'all') {
        rows = rows.filter((r) => this.ownerKind(r) === this.ownerFilter);
      }
      if (this.agentFilter !== 'all') {
        rows = rows.filter((r) => this.matchesAgentFilter(r));
      }

      const sorted = rows.slice();
      const sign = this.sortDir === 'asc' ? 1 : -1;
      const key = this.sortBy;
      const value = SORT_VALUE[key] || ((row) => row[key]);
      sorted.sort((a, b) => {
        if (key === 'name') return sign * a.name.localeCompare(b.name);
        // null safe: unknown values sort to the end
        const av = value(a);
        const bv = value(b);
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
    countBodies(row) {
      const byType = row.bodies_by_type || {};
      const counts = { total: 0 };
      BODY_GROUPS.forEach((group) => {
        counts[group.key] = group.types.reduce((acc, type) => acc + (byType[type] || 0), 0);
        counts.total += counts[group.key];
      });
      return counts;
    },
    // Visible agents grouped by faction, own faction first. null when the
    // system is below the visibility that reveals agents (shown as ?).
    groupAgents(row) {
      if (!Array.isArray(row.agents)) return null;

      const byFaction = new Map();
      row.agents.forEach((agent) => {
        if (!byFaction.has(agent.faction)) byFaction.set(agent.faction, []);
        byFaction.get(agent.faction).push(agent);
      });

      return Array.from(byFaction.entries())
        .map(([faction, agents]) => ({
          faction,
          own: faction === this.ownFactionKey,
          theme: this.$store.getters['game/themeByKey'](faction) || 'unknown',
          agents,
          types: AGENT_TYPES
            .map((key) => ({ key, count: agents.filter((a) => a.type === key).length }))
            .filter((type) => type.count > 0),
        }))
        .sort((a, b) => Number(b.own) - Number(a.own)
          || String(a.faction).localeCompare(String(b.faction)));
    },
    matchesAgentFilter(row) {
      const groups = row.agentGroups;
      if (groups === null) return false;
      switch (this.agentFilter) {
        case 'foreign': return groups.some((g) => !g.own);
        case 'own': return groups.some((g) => g.own);
        case 'any': return groups.length > 0;
        case 'none': return groups.length === 0;
        default: return true;
      }
    },
    factionName(key) {
      return this.$te(`data.faction.${key}.name`) ? this.$t(`data.faction.${key}.name`) : String(key);
    },
    agentsSummary(row) {
      return row.agentGroups
        .map((group) => {
          const faction = group.own
            ? this.$t('panel.empire.survey_agents_own_faction', { faction: this.factionName(group.faction) })
            : this.factionName(group.faction);
          const list = group.types
            .map((type) => `${type.count} ${this.$tc(`data.character.${type.key}.name`, type.count)}`)
            .join(', ');
          return `${faction}: ${list}`;
        })
        .join('. ');
    },
    agentsTooltip(row) {
      if (row.agentGroups === null) return this.$t('panel.empire.survey_agents_unknown');
      if (!row.agentGroups.length) return this.$t('panel.empire.survey_agents_empty');
      // Plain text only: agent and player names are player-controlled.
      return row.agentGroups
        .flatMap((group) => group.agents.map((agent) => this.$t('panel.empire.survey_agent_line', {
          name: agent.name,
          type: this.$tc(`data.character.${agent.type}.name`, 1),
          level: agent.level,
          owner: agent.owner_name || this.factionName(group.faction),
        })))
        .join(' · ');
    },
    bodySummary(row) {
      const counts = row.bodyCounts;
      const parts = BODY_GROUPS
        .map((group) => this.$tc(`panel.empire.survey_bodies_${group.key}`, counts[group.key], { n: counts[group.key] }))
        .join(', ');
      return `${this.$tc('panel.empire.survey_bodies_total', counts.total, { n: counts.total })}: ${parts}`;
    },
    ariaSort(key) {
      if (this.sortBy !== key) return null;
      return this.sortDir === 'asc' ? 'ascending' : 'descending';
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
      if (!row.bodyCounts.total) return this.$t('panel.empire.survey_no_bodies');
      const b = row.bodies_by_type || {};
      const hosts = HOST_BODY_TYPES
        .filter((k) => b[k])
        .map((k) => `${b[k]} × ${this.$t(`data.stellar_body.${k}.name`)}`);
      const summary = this.bodySummary(row);
      return hosts.length
        ? `${summary} ${this.$t('panel.empire.survey_bodies_hosts', { hosts: hosts.join(', ') })}`
        : summary;
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
    // Explicit "open this system's detail view" — same store action the row
    // click uses; the button just makes that affordance discoverable.
    enterSystemView(id) {
      this.openSystem(id);
    },
    rowLocation(row) {
      const x = Math.round(row.position?.x ?? 0);
      const y = Math.round(row.position?.y ?? 0);
      const sector = this.sectorName(row.sector_id) || '?';
      return { x, y, sector };
    },
    // Matches the format used by Game.vue's `copySystem` (the C-key shortcut)
    // so pasting from either source yields the same text.
    async copyBasic(row) {
      const { x, y, sector } = this.rowLocation(row);
      const text = `${row.name} (${x}, ${y}) in ${sector}`;
      const ok = await copyToClipboard(text);
      if (ok) this.$toasted.success(this.$t('clipboard.copied', { text }));
      else this.$toasted.error(this.$t('clipboard.failed'));
    },
    async copySummary(row) {
      const text = this.buildSummaryText(row);
      const ok = await copyToClipboard(text);
      if (ok) {
        this.$toasted.success(this.$t('panel.empire.survey_summary_copied', { name: row.name }));
      } else {
        this.$toasted.error(this.$t('clipboard.failed'));
      }
    },
    buildSummaryText(row) {
      const { x, y, sector } = this.rowLocation(row);
      const owner = this.ownerLabel(row);
      const lines = [`${row.name} (${x}, ${y}) — ${sector} — ${owner}`];
      if (row.has_eden) lines.push('★ EDEN');

      const num = (v) => (v == null ? '?' : v);
      const round = (v) => (v == null ? '?' : Math.round(v));

      lines.push(this.bodySummary(row));

      lines.push(
        `Body factors: prod=${num(row.sum_prod)}, sci=${num(row.sum_sci)}, ` +
        `appeal=${num(row.sum_appeal)}, total=${num(row.sumTotal)}`
      );

      if (row.agentGroups !== null) {
        lines.push(`Agents: ${row.agentGroups.length ? this.agentsSummary(row) : '—'}`);
      }

      lines.push(
        `Income: prod=${round(row.current_prod)}, sci=${round(row.current_sci)}, ` +
        `ideology=${round(row.current_appeal)}`
      );

      if (row.built_tile_count !== null) {
        lines.push(`Tiles: ${row.built_tile_count}/${row.total_tile_count} built`);
      } else {
        lines.push('Tiles: ?');
      }

      if (this.hasMegastructure(row)) {
        lines.push(`Megastructures: ${this.megastructureLabel(row)}`);
      }

      return lines.join('\n');
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
.gs-c-orbitals     { width: 8.5em; }
.gs-c-agents       { width: 7em;   }
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
.gs-table td,
.gs-table tbody th {
  padding: 0.5em 0.4em;
  vertical-align: middle;
}
/* The name cell is a row header (<th scope="row">) for screen readers;
 * undo the header look so it reads like the other cells. */
.gs-table tbody th {
  font-weight: normal;
  text-align: left;
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
 * extend the full table height: prod is the left edge of the stat group,
 * Σ the right edge. */
.gs-table thead th.gs-th-stat-first { border-left: 1px solid rgba(255, 255, 255, 0.18); }
.gs-table thead th.gs-th-sum        { border-right: 1px solid rgba(255, 255, 255, 0.18); }

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

  &:hover > td,
  &:hover > th { background: rgba(255, 255, 255, 0.05); }

  > td,
  > th {
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

/* ---- Name column ----
 *
 * The cell is split into a left "info" block (name + sector + owner) and a
 * right "actions" block (per-row buttons). The flex container lives INSIDE
 * the <td> rather than on it — putting `display: flex` directly on a table
 * cell drops it out of the table layout. The info side flexes so a long
 * system name ellipsizes instead of pushing the buttons off-cell.
 */
.gs-name-cell-inner {
  display: flex;
  align-items: center;
  gap: 0.75em;
}
.gs-name-info { flex: 1 1 auto; min-width: 0; }

.gs-name-line { display: flex; align-items: baseline; gap: 0.5em; min-width: 0; }
.gs-name      {
  min-width: 0;
  font-size: 1.05em;
  font-weight: bold;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
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

/* Per-row action buttons. Sit at the right edge of the name cell so they
 * read as "buttons between the name and the orbital summary column".
 * Subdued by default — opacity comes up on row hover so a quiet table at
 * rest still pops a clear affordance once the user moves the mouse. */
.gs-row-actions {
  display: flex;
  align-items: center;
  gap: 0.25em;
  flex-shrink: 0;
  opacity: 0.55;
}
.gs-row:hover .gs-row-actions { opacity: 1; }

.gs-row-action {
  background: rgba(0, 0, 0, 0.35);
  border: 1px solid rgba(255, 255, 255, 0.18);
  color: inherit;
  font: inherit;
  font-size: 0.9em;
  line-height: 1;
  padding: 0.25em 0.5em;
  cursor: pointer;
  min-width: 1.8em;
  text-align: center;

  &:hover { background: rgba(255, 255, 255, 0.12); border-color: rgba(255, 255, 255, 0.4); }
  &:active { background: rgba(255, 255, 255, 0.18); }
}

/* ---- Bodies column ----
 * Total, then habitable / barren / moons & asteroids. A zero count stays
 * in place (dimmed) so each icon sits in the same spot on every row. */

.gs-orbitals-line {
  display: flex;
  align-items: center;
  gap: 0.5em;
}
.gs-orbitals-total {
  min-width: 1.4em;
  font-size: 1.05em;
}
.gs-body-item {
  display: inline-flex;
  align-items: center;
  gap: 0.15em;
  font-size: 0.85em;

  .svg-icon { width: 0.95em; height: 0.95em; opacity: 0.85; }

  &.is-zero { opacity: 0.3; }
}
.gs-body-count { font-weight: bold; }

/* ---- Agents column ----
 * One chip per faction, tinted with the faction color (own faction
 * first), holding a count per agent type. */

.gs-agent-groups {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
}
.gs-agent-group {
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  padding: 0.1em 0.35em;
  font-size: 0.85em;
  font-weight: bold;
  border-left: 3px solid var(--gs-agent-color, #9ea4ad);
  background: rgba(255, 255, 255, 0.06);

  &.is-own { background: rgba(255, 255, 255, 0.12); }

  &.force-color-dark-blue { --gs-agent-color: #3a5ea5; }
  &.force-color-red       { --gs-agent-color: #b94e4e; }
  &.force-color-purple    { --gs-agent-color: #8e60bf; }
  &.force-color-green     { --gs-agent-color: #a2cd44; }
  &.force-color-yellow    { --gs-agent-color: #c9a115; }
}
.gs-agent-count {
  display: inline-flex;
  align-items: center;
  gap: 0.1em;

  .svg-icon { width: 0.95em; height: 0.95em; }
}

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
