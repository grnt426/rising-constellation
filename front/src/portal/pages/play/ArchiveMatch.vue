<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1>{{ match ? match.name : $t('page.play.archive.header').replace(/\*/g, '') }}</h1>

        <button
          v-if="match && isAdmin"
          class="default-button archive-header-button"
          @click="togglePublished">
          {{ match.published ? $t('page.play.archive.unpublish') : $t('page.play.archive.publish') }}
        </button>

        <router-link
          to="/play/slow/archive"
          class="default-button">
          <svgicon class="icon" name="caret-left" />
          {{ $t('page.play.archive.back_to_archive') }}
        </router-link>
      </div>

      <div
        v-if="match"
        class="archive-tabs">
        <button
          v-for="t in tabs"
          :key="`tab-${t}`"
          class="archive-tab"
          :class="{ 'is-active': tab === t }"
          @click="tab = t">
          {{ $t(`page.play.archive.tabs.${t}`) }}
        </button>
      </div>

      <v-scrollbar
        v-if="match"
        class="content archive-content">
        <div
          v-if="!match.published"
          class="archive-notice is-alert">
          {{ $t('page.play.archive.draft_notice') }}
        </div>
        <div
          v-if="missingDays.length && sampleDays.length"
          class="archive-notice">
          {{ $t('page.play.archive.missing_days_notice', { days: missingDays.join(', ') }) }}
        </div>
        <div
          v-if="!sampleDays.length"
          class="archive-notice">
          {{ $t('page.play.archive.no_snapshots_notice') }}
        </div>

        <!-- OVERVIEW ------------------------------------------------------ -->
        <template v-if="tab === 'overview'">
          <div
            class="archive-hero"
            :style="{ borderLeftColor: winner ? winner.color : null }">
            <svgicon
              class="archive-hero-icon"
              name="victory"
              :style="{ color: winner ? winner.color : null }" />
            <div>
              <div class="archive-hero-label">
                {{ match.victory_type ? $t(`page.play.archive.victory_type.${match.victory_type}`) : '' }}
              </div>
              <h2>
                {{ winner ? $t('page.play.archive.faction_won', { faction: winner.name }) : $t('page.play.archive.no_winner') }}
              </h2>
              <div class="archive-hero-meta">
                <span
                  v-if="match.map_name"
                  class="archive-chip">{{ match.map_name }}</span>
                <span class="archive-chip">{{ dateRange }}</span>
                <span class="archive-chip">{{ $t('page.play.archive.days_count', { n: days }) }}</span>
                <span class="archive-chip">{{ $t('page.play.archive.players_count', { n: match.player_count }) }}</span>
                <span class="archive-chip">{{ $t('page.play.archive.systems_count', { n: match.system_count }) }}</span>
              </div>
            </div>
          </div>

          <div class="archive-standings">
            <div
              v-for="f in factions"
              :key="`standing-${f.key}`"
              class="archive-standing"
              :style="{ borderTopColor: f.color }">
              <div class="archive-standing-head">
                <h3>{{ f.name }}</h3>
                <span>{{ $t('page.play.archive.standings.rank', { rank: f.rank || '—' }) }}</span>
              </div>
              <div class="archive-standing-vp">
                <strong>{{ f.victory_points === null || f.victory_points === undefined ? '—' : f.victory_points }}</strong>
                {{ $t('page.play.archive.standings.vp') }}
              </div>

              <div
                v-for="t in trackKeys"
                :key="`track-${f.key}-${t}`"
                class="archive-track">
                <div class="archive-track-label">
                  <span>{{ $t(`page.play.archive.tracks.${t}`) }}</span>
                  <span>{{ fmt(last(f.key, `track_${t}_points`)) }}</span>
                </div>
                <div class="archive-track-bar">
                  <div
                    class="archive-track-fill"
                    :style="{ width: `${trackRatio(f.key, t) * 100}%`, background: f.color }" />
                  <span
                    v-for="(m, i) in trackTicks(f.key, t)"
                    :key="`tick-${i}`"
                    class="archive-track-tick"
                    :style="{ left: `${m * 100}%` }" />
                </div>
              </div>

              <div class="archive-standing-stats">
                <div><strong>{{ fmt(f.systems) }}</strong>{{ $t('page.play.archive.standings.systems') }}</div>
                <div><strong>{{ fmt(f.dominions) }}</strong>{{ $t('page.play.archive.standings.dominions') }}</div>
                <div><strong>{{ fmt(f.sectors) }}</strong>{{ $t('page.play.archive.standings.sectors') }}</div>
                <div><strong>{{ f.players }}</strong>{{ $t('page.play.archive.standings.players') }}</div>
              </div>
            </div>
          </div>

          <div class="archive-grid">
            <section
              v-if="has('victory_points')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.victory_points') }}</h3>
              <p class="archive-hint">{{ $t('page.play.archive.charts.victory_points_hint') }}</p>
              <archive-line-chart
                :series="factionSeries('victory_points')"
                stepped />
            </section>

            <section
              v-if="has('sectors')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.sectors') }}</h3>
              <archive-bar-chart :series="factionSeries('sectors')" />
            </section>

            <section
              v-if="hasMap"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.map') }}</h3>
              <p class="archive-hint">{{ $t('page.play.archive.charts.map_hint') }}</p>
              <archive-map
                :map="match.map"
                :factions="factions" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.at_a_glance') }}</h3>
              <archive-hbars
                :rows="totalsRows(['battles', 'battles_won', 'raid', 'loot', 'conquest', 'make_dominion', 'colonization', 'infiltration'])" />
            </section>
          </div>
        </template>

        <!-- ECONOMY ------------------------------------------------------- -->
        <template v-if="tab === 'economy'">
          <div class="archive-filters">
            <button
              v-for="r in resources"
              :key="`res-${r}`"
              class="archive-filter"
              :class="{ 'is-active': resource === r }"
              @click="resource = r">
              <svgicon :name="`resource/${r}`" />
              {{ $t(`page.play.archive.resources.${r}`) }}
            </button>
          </div>

          <div class="archive-grid">
            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.net_income') }}</h3>
              <archive-line-chart
                :series="factionSeries(`${resource}_net`, perHour, `ps_${resource}_net`)" />
            </section>

            <section
              v-if="has(`${resource}_gross`)"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.gross_income') }}</h3>
              <archive-line-chart :series="factionSeries(`${resource}_gross`, perHour)" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.income_share') }}</h3>
              <archive-bar-chart
                mode="share"
                :series="factionSeries(`${resource}_net`, perHour, `ps_${resource}_net`, true)" />
            </section>

            <section
              v-if="has(`${resource}_expense`)"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.expenses') }}</h3>
              <archive-line-chart :series="factionSeries(`${resource}_expense`, -perHour)" />
            </section>

            <section
              v-if="has(`${resource}_stock`) || resource === 'credit'"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.stockpile') }}</h3>
              <archive-line-chart
                :series="factionSeries(`${resource}_stock`, 1, resource === 'credit' ? 'ps_credit_stock' : null)" />
            </section>

            <section
              v-if="has(`${resource}_gross`)"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.income_sources') }}</h3>
              <archive-hbars :rows="sourceRows" />
            </section>
          </div>
        </template>

        <!-- TERRITORY ----------------------------------------------------- -->
        <template v-if="tab === 'territory'">
          <div class="archive-grid">
            <section
              v-if="hasMap"
              class="archive-card is-wide">
              <h3>{{ $t('page.play.archive.charts.map') }}</h3>
              <p class="archive-hint">{{ $t('page.play.archive.charts.map_hint') }}</p>
              <archive-map
                :map="match.map"
                :factions="factions"
                :max-size="760" />
            </section>

            <section
              v-if="has('systems')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.systems') }}</h3>
              <archive-line-chart :series="factionSeries('systems')" />
            </section>

            <section
              v-if="has('dominions')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.dominions') }}</h3>
              <archive-line-chart :series="factionSeries('dominions')" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.conquests_per_day') }}</h3>
              <archive-bar-chart
                mode="grouped"
                :series="factionSeries('conquest_success')" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.dominions_per_day') }}</h3>
              <archive-bar-chart
                mode="grouped"
                :series="factionSeries('make_dominion_success')" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.colonizations_per_day') }}</h3>
              <archive-bar-chart
                mode="grouped"
                :series="factionSeries('colonization')" />
            </section>

            <section
              v-if="has('ps_population')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.population') }}</h3>
              <archive-line-chart
                :series="factionSeries('ps_population')"
                area />
            </section>

            <section
              v-if="has('track_population_points')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.population_track') }}</h3>
              <archive-line-chart :series="factionSeries('track_population_points')" />
            </section>
          </div>
        </template>

        <!-- WARFARE ------------------------------------------------------- -->
        <template v-if="tab === 'warfare'">
          <div class="archive-grid">
            <section class="archive-card is-wide">
              <h3>{{ $t('page.play.archive.charts.activity_heatmap') }}</h3>
              <p class="archive-hint">{{ $t('page.play.archive.charts.activity_heatmap_hint') }}</p>
              <archive-heatmap :rows="heatmapRows(['battles', 'raid_success', 'loot_success', 'conquest_success', 'make_dominion_success'])" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.combat_totals') }}</h3>
              <archive-hbars :rows="totalsRows(['battles', 'battles_won', 'raid', 'loot', 'conquest', 'make_dominion'])" />
            </section>

            <section
              v-if="hasMap"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.activity_map') }}</h3>
              <div class="archive-filters is-compact">
                <button
                  v-for="k in activityKinds"
                  :key="`act-${k}`"
                  class="archive-filter"
                  :class="{ 'is-active': activityKind === k }"
                  @click="activityKind = k">
                  {{ $t(`page.play.archive.activity.${k}`) }}
                </button>
              </div>
              <archive-map
                :map="match.map"
                :factions="factions"
                mode="activity"
                :activity="match.summary.activity || {}"
                :activity-kind="activityKind" />
            </section>

            <section
              v-if="has('ships_total')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.ships') }}</h3>
              <archive-line-chart :series="factionSeries('ships_total')" />
            </section>

            <section
              v-if="has('ships_total')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.fleet_composition') }}</h3>
              <archive-hbars :rows="compositionRows('ships', shipClasses)" />
            </section>

            <section
              v-if="has('ships_avg_xp')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.ship_xp') }}</h3>
              <archive-line-chart :series="factionSeries('ships_avg_xp')" />
            </section>

            <section
              v-if="has('fleet_maintenance')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.fleet_upkeep') }}</h3>
              <archive-line-chart :series="factionSeries('fleet_maintenance', perHour)" />
            </section>
          </div>
        </template>

        <!-- ESPIONAGE ----------------------------------------------------- -->
        <template v-if="tab === 'espionage'">
          <div class="archive-grid">
            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.ops_success') }}</h3>
              <archive-hbars :rows="totalsRows(['infiltration', 'sabotage', 'assassination', 'encourage_hate', 'conversion'])" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.ops_suffered') }}</h3>
              <archive-hbars :rows="totalsRows(['sabotage', 'assassination', 'encourage_hate', 'conversion'], 'suffered')" />
            </section>

            <section class="archive-card">
              <h3>{{ $t('page.play.archive.charts.infiltrations_per_day') }}</h3>
              <archive-bar-chart :series="factionSeries('infiltration_success')" />
            </section>

            <section
              v-if="has('malware_planted_enemy')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.malware_enemy') }}</h3>
              <archive-line-chart :series="factionSeries('malware_planted_enemy')" />
            </section>

            <section
              v-if="has('malware_suffered')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.malware_suffered') }}</h3>
              <archive-line-chart :series="factionSeries('malware_suffered')" />
            </section>

            <section
              v-if="has('malware_planted_neutral')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.malware_neutral') }}</h3>
              <archive-line-chart :series="factionSeries('malware_planted_neutral')" />
            </section>

            <section
              v-if="has('track_visibility_points')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.visibility_track') }}</h3>
              <archive-line-chart :series="factionSeries('track_visibility_points')" />
            </section>

            <section
              v-if="has('agents_spy')"
              class="archive-card">
              <h3>{{ $t('page.play.archive.charts.agents') }}</h3>
              <archive-hbars :rows="compositionRows('agents', agentTypes)" />
            </section>
          </div>
        </template>

        <!-- SYSTEMS ------------------------------------------------------- -->
        <template v-if="tab === 'systems'">
          <div class="archive-filters">
            <button
              v-for="s in ['sys', 'dom']"
              :key="`scope-${s}`"
              class="archive-filter"
              :class="{ 'is-active': scope === s }"
              @click="scope = s">
              {{ $t(`page.play.archive.scopes.${s}`) }}
            </button>
          </div>
          <p class="archive-hint">
            {{ $t('page.play.archive.charts.systems_hint', { scope: $t(`page.play.archive.scopes.${scope}`).toLowerCase() }) }}
          </p>
          <archive-legend :items="factionLegend" />

          <div class="archive-multiples">
            <section
              v-for="stat in systemStats"
              :key="`stat-${stat.key}`"
              class="archive-card is-small">
              <h3>
                <svgicon :name="stat.icon" />
                {{ $t(`page.play.archive.stats.${stat.key}`) }}
              </h3>
              <archive-line-chart
                :series="factionSeries(`${scope}_avg_${stat.key}`, stat.perHour ? perHour : 1)"
                :height="120"
                :legend="false" />
              <div class="archive-multiple-finals">
                <span
                  v-for="f in factions"
                  :key="`final-${stat.key}-${f.key}`">
                  <span
                    class="archive-dot"
                    :style="{ background: f.color }" />
                  {{ fmt(scaled(last(f.key, `${scope}_avg_${stat.key}`), stat.perHour ? perHour : 1)) }}
                </span>
              </div>
            </section>
          </div>
        </template>

        <!-- RESEARCH ------------------------------------------------------ -->
        <template v-if="tab === 'research'">
          <div class="archive-grid is-thirds">
            <section
              v-for="k in ['avg_lex_slots', 'avg_patents', 'avg_lex']"
              :key="`research-${k}`"
              class="archive-card">
              <h3>{{ $t(`page.play.archive.charts.${k.replace('avg_', '')}`) }}</h3>
              <archive-line-chart
                :series="factionSeries(k)"
                :height="160" />
            </section>
          </div>

          <section
            v-if="match.unlocks.length"
            class="archive-card">
            <h3>{{ $t('page.play.archive.charts.unlocks') }}</h3>
            <p class="archive-hint">{{ $t('page.play.archive.charts.unlocks_hint') }}</p>
            <div class="archive-filters is-compact">
              <button
                v-for="k in ['patent', 'lex']"
                :key="`kind-${k}`"
                class="archive-filter"
                :class="{ 'is-active': unlockKind === k }"
                @click="unlockKind = k">
                {{ $t(`page.play.archive.unlocks.${k}`) }}
              </button>
              <span class="archive-filter-sep" />
              <button
                v-for="s in ['most', 'least', 'earliest']"
                :key="`sort-${s}`"
                class="archive-filter"
                :class="{ 'is-active': unlockSort === s }"
                @click="unlockSort = s">
                {{ $t(`page.play.archive.unlocks.${s}`) }}
              </button>
            </div>
            <archive-hbars
              :rows="unlockRows"
              :max="match.player_count" />
          </section>
        </template>

        <!-- PLAYERS ------------------------------------------------------- -->
        <template v-if="tab === 'players'">
          <section
            v-if="match.players.some(p => p.series.length)"
            class="archive-card">
            <h3>{{ $t('page.play.archive.charts.points') }}</h3>
            <p class="archive-hint">{{ $t('page.play.archive.charts.points_hint') }}</p>
            <archive-legend :items="factionLegend" />
            <archive-line-chart
              :series="playerSeries"
              :legend="false"
              :height="260" />
          </section>

          <table class="default-table archive-players-table">
            <tr>
              <th>{{ $t('page.play.archive.players.name') }}</th>
              <th
                v-for="c in playerColumns"
                :key="`th-${c.key}`"
                class="is-sortable"
                :class="{ 'is-active': playerSort === c.key }"
                @click="playerSort = c.key">
                {{ $t(`page.play.archive.players.${c.label}`) }}
              </th>
            </tr>
            <tr
              v-for="p in sortedPlayers"
              :key="`player-${p.name}`"
              @mouseenter="highlightPlayer = p.name"
              @mouseleave="highlightPlayer = null">
              <td>
                <span
                  class="archive-dot"
                  :style="{ background: factionColor(p.faction) }" />
                <strong>{{ p.name }}</strong>
                <em>{{ $t(`data.faction.${p.faction}.name`) }}</em>
              </td>
              <td
                v-for="c in playerColumns"
                :key="`td-${p.name}-${c.key}`"
                class="is-number">
                {{ c.display ? c.display(p.metrics) : fmt(playerValue(p, c)) }}
              </td>
            </tr>
          </table>
        </template>
      </v-scrollbar>

      <div
        v-else-if="notFound"
        class="full-sized-text">
        {{ $t('page.play.archive.not_found') }}
      </div>

      <loading-mask v-else />
    </div>
  </div>
</template>

<script>
import LoadingMask from '@/portal/components/LoadingMask.vue';
import ArchiveLineChart from '@/portal/components/archive/ArchiveLineChart.vue';
import ArchiveBarChart from '@/portal/components/archive/ArchiveBarChart.vue';
import ArchiveHBars from '@/portal/components/archive/ArchiveHBars.vue';
import ArchiveHeatmap from '@/portal/components/archive/ArchiveHeatmap.vue';
import ArchiveMap from '@/portal/components/archive/ArchiveMap.vue';
import ArchiveLegend from '@/portal/components/archive/ArchiveLegend.vue';
import { compact, deepFreeze, lastValue } from '@/portal/components/archive/format';
import { NEUTRAL, seriesColor } from '@/portal/components/archive/palette';
import { factionColor } from '@/utils/factions';

const SYSTEM_STATS = [
  { key: 'defense', icon: 'resource/defense' },
  { key: 'intelligence', icon: 'resource/counter_intelligence' },
  { key: 'cybersecurity', icon: 'resource/remove_contact' },
  { key: 'stability', icon: 'resource/happiness' },
  { key: 'population', icon: 'resource/population' },
  { key: 'housing', icon: 'resource/habitation' },
  { key: 'production', icon: 'resource/production' },
  { key: 'credit', icon: 'resource/credit', perHour: true },
  { key: 'technology', icon: 'resource/technology', perHour: true },
  { key: 'ideology', icon: 'resource/ideology', perHour: true },
  { key: 'slsd', icon: 'resource/radar' },
  { key: 'mobility', icon: 'resource/mobility' },
  { key: 'malware', icon: 'eye' },
  { key: 'xp_fighter', icon: 'resource/fighter_lvl' },
  { key: 'xp_corvette', icon: 'resource/corvette_lvl' },
  { key: 'xp_frigate', icon: 'resource/frigate_lvl' },
  { key: 'xp_capital', icon: 'resource/capital_lvl' },
];

// Fixed color slot per source so a hue means the same thing on the income
// and the expense rows; rarely-used sources fold into "Other".
const SOURCES = ['system', 'dominion', 'doctrine', 'character_wages', 'fleet_maintenance'];
const OTHER_SOURCES = ['tradition', 'government', 'mutator'];

export default {
  name: 'play-archive-match',
  data() {
    return {
      match: null,
      notFound: false,
      tab: 'overview',
      tabs: ['overview', 'economy', 'territory', 'warfare', 'espionage', 'systems', 'research', 'players'],
      resources: ['credit', 'technology', 'ideology'],
      resource: 'credit',
      scope: 'sys',
      activityKinds: ['battles', 'raid', 'loot', 'conquest', 'make_dominion'],
      activityKind: 'battles',
      trackKeys: ['conquest', 'population', 'visibility'],
      shipClasses: ['fighter', 'corvette', 'frigate', 'capital', 'transport'],
      agentTypes: ['admiral', 'spy', 'speaker'],
      systemStats: SYSTEM_STATS,
      unlockKind: 'patent',
      unlockSort: 'most',
      playerSort: 'points',
      highlightPlayer: null,
    };
  },
  computed: {
    isAdmin() { return this.$store.state.portal.isAdmin; },
    days() { return (this.match && this.match.summary.days) || 0; },
    perHour() { return (this.match && this.match.summary.ut_per_hour) || 20; },
    sampleDays() { return (this.match && this.match.summary.sample_days) || []; },
    missingDays() {
      const sampled = new Set(this.sampleDays);
      const missing = [];
      for (let d = 1; d <= this.days; d += 1) if (!sampled.has(d)) missing.push(d);
      return missing;
    },
    hasMap() {
      return !!(this.match && this.match.map && this.match.map.systems && this.match.map.days && this.match.map.days.length);
    },
    factions() {
      if (!this.match) return [];
      return this.match.factions.map((f) => ({
        ...f,
        color: factionColor(f.key),
        name: this.$t(`data.faction.${f.key}.name`),
      }));
    },
    winner() {
      return this.factions.find((f) => f.key === this.match.winner_faction) || null;
    },
    factionLegend() {
      return this.factions.map((f) => ({ label: f.name, color: f.color, kind: 'rect' }));
    },
    dateRange() {
      const opts = { year: 'numeric', month: 'short', day: 'numeric' };
      const start = new Date(this.match.started_at).toLocaleDateString(this.$i18n.locale, opts);
      const end = new Date(this.match.ended_at).toLocaleDateString(this.$i18n.locale, opts);
      return `${start} – ${end}`;
    },
    sourceRows() {
      const rows = [];
      const res = this.resource;
      this.factions.forEach((f) => {
        const segments = (sign) => {
          const part = (s) => Math.max(0, sign * (this.last(f.key, `${res}_src_${s}`) || 0)) * this.perHour;
          return SOURCES.map((s, i) => ({
            label: this.$t(`page.play.archive.sources.${s}`),
            color: seriesColor(i),
            value: part(s),
          })).concat([{
            label: this.$t('page.play.archive.sources.other'),
            color: NEUTRAL,
            value: OTHER_SOURCES.reduce((acc, s) => acc + part(s), 0),
          }]);
        };
        const income = segments(1);
        const expenses = segments(-1);
        rows.push({ key: `${f.key}-in`, label: this.$t('page.play.archive.charts.income_label', { faction: f.name }), segments: income });
        rows.push({ key: `${f.key}-out`, label: this.$t('page.play.archive.charts.expense_label', { faction: f.name }), segments: expenses });
      });
      // Drop sources nobody used so the legend only lists what's drawn.
      const used = new Set();
      rows.forEach((r) => r.segments.forEach((s) => { if (s.value > 0) used.add(s.label); }));
      return rows.map((r) => ({ ...r, segments: r.segments.filter((s) => used.has(s.label)) }));
    },
    unlockRows() {
      const byKey = {};
      this.match.unlocks
        .filter((u) => u.kind === this.unlockKind)
        .forEach((u) => {
          if (!byKey[u.key]) byKey[u.key] = { key: u.key, counts: {}, firstDay: null };
          byKey[u.key].counts[u.faction] = u.player_count;
          if (u.first_day && (byKey[u.key].firstDay === null || u.first_day < byKey[u.key].firstDay)) {
            byKey[u.key].firstDay = u.first_day;
          }
        });
      const dataKey = this.unlockKind === 'patent' ? 'patent' : 'doctrine';
      const rows = Object.values(byKey).map((u) => {
        const i18nKey = `data.${dataKey}.${u.key}.name`;
        return {
          key: u.key,
          label: this.$te(i18nKey) ? this.$t(i18nKey) : u.key,
          sublabel: u.firstDay ? `D${u.firstDay}` : '',
          firstDay: u.firstDay || 999,
          total: Object.values(u.counts).reduce((a, b) => a + b, 0),
          segments: this.factions.map((f) => ({ label: f.name, color: f.color, value: u.counts[f.key] || 0 })),
        };
      });
      const sorters = {
        most: (a, b) => b.total - a.total || a.firstDay - b.firstDay,
        least: (a, b) => a.total - b.total || a.label.localeCompare(b.label),
        earliest: (a, b) => a.firstDay - b.firstDay || b.total - a.total,
      };
      return rows.sort(sorters[this.unlockSort]);
    },
    playerColumns() {
      return [
        { key: 'points', label: 'points', metric: 'final_points' },
        { key: 'systems', label: 'systems', metric: 'final_systems' },
        {
          key: 'battles',
          label: 'battles',
          metric: 'battles_won',
          display: (m) => `${m.battles_won || 0} / ${m.battles || 0}`,
        },
        { key: 'raids', label: 'raids', metric: 'raid_success' },
        { key: 'loots', label: 'loots', metric: 'loot_success' },
        { key: 'captures', label: 'captures', value: (m) => (m.conquest_success || 0) + (m.make_dominion_success || 0) },
        { key: 'infiltrations', label: 'infiltrations', metric: 'infiltration_success' },
        { key: 'patents', label: 'patents', metric: 'patents' },
        { key: 'lex', label: 'lex', metric: 'lex' },
      ];
    },
    sortedPlayers() {
      const col = this.playerColumns.find((c) => c.key === this.playerSort) || this.playerColumns[0];
      return [...this.match.players].sort((a, b) => (this.playerValue(b, col) || 0) - (this.playerValue(a, col) || 0));
    },
    playerSeries() {
      return this.match.players.map((p) => {
        const values = new Array(this.days).fill(null);
        p.series.forEach((row) => { values[row[0] - 1] = row[1]; });
        return {
          key: p.name,
          label: p.name,
          color: factionColor(p.faction),
          values,
          muted: this.highlightPlayer !== null && this.highlightPlayer !== p.name,
          highlightInTooltip: true,
        };
      });
    },
  },
  methods: {
    factionColor,
    fmt(v) { return compact(v); },
    scaled(v, scale) { return v === null || v === undefined ? null : v * scale; },
    values(faction, key) {
      const s = this.match.series[faction];
      return (s && s[key]) || new Array(this.days).fill(null);
    },
    has(key) {
      return this.factions.some((f) => this.values(f.key, key).some((v) => v !== null && v !== undefined));
    },
    last(faction, key) {
      return lastValue(this.values(faction, key));
    },
    // One series per faction for `key`, scaled; `fallback` fills days the
    // primary metric wasn't sampled (e.g. snapshot income ← player_stats).
    factionSeries(key, scale = 1, fallback = null, clampPositive = false) {
      return this.factions.map((f) => {
        const primary = this.values(f.key, key);
        const backup = fallback ? this.values(f.key, fallback) : null;
        const values = primary.map((v, i) => {
          let out = v;
          if ((out === null || out === undefined) && backup) out = backup[i];
          if (out === null || out === undefined) return null;
          out *= scale;
          return clampPositive ? Math.max(0, out) : out;
        });
        return { key: f.key, label: f.name, color: f.color, values };
      });
    },
    totalsRows(actions, suffix = null) {
      return actions.map((a) => {
        let metric = a;
        if (suffix) metric = `${a}_${suffix}`;
        else if (!['battles', 'battles_won', 'colonization'].includes(a)) metric = `${a}_success`;
        return {
          key: metric,
          total: a === 'battles' && !suffix ? this.match.summary.battle_count : null,
          label: this.$t(`page.play.archive.actions.${a}`),
          segments: this.factions.map((f) => ({
            label: f.name,
            color: f.color,
            value: ((this.match.summary.totals || {})[f.key] || {})[metric] || 0,
          })),
        };
      });
    },
    heatmapRows(metrics) {
      const rows = [];
      metrics.forEach((m) => {
        const action = m.replace('_success', '');
        this.factions.forEach((f, i) => {
          rows.push({
            label: `${this.$t(`page.play.archive.actions.${action}`)} · ${f.name}`,
            color: f.color,
            values: this.values(f.key, m).map((v) => v || 0),
            scaleGroup: m,
            groupStart: i === 0,
          });
        });
      });
      return rows;
    },
    compositionRows(prefix, kinds) {
      return this.factions.map((f) => ({
        key: f.key,
        label: f.name,
        segments: kinds.map((k, i) => ({
          label: this.$t(`page.play.archive.${prefix === 'ships' ? 'ships' : 'agents'}.${k}`),
          color: seriesColor(i),
          value: this.last(f.key, `${prefix}_${k}`) || 0,
        })),
      }));
    },
    trackRatio(faction, track) {
      const milestones = this.last(faction, `track_${track}_milestones`) || [];
      const top = milestones[milestones.length - 1];
      const points = this.last(faction, `track_${track}_points`) || 0;
      return top ? Math.min(1, points / top) : 0;
    },
    trackTicks(faction, track) {
      const milestones = this.last(faction, `track_${track}_milestones`) || [];
      const top = milestones[milestones.length - 1];
      if (!top) return [];
      return milestones.slice(1, -1).map((m) => m / top);
    },
    playerValue(p, col) {
      if (col.value) return col.value(p.metrics);
      return p.metrics[col.metric] || 0;
    },
    togglePublished() {
      const published = !this.match.published;
      this.$axios.put(`/archive/matches/${this.match.id}/publish`, { published }).then(() => {
        this.match = deepFreeze({ ...this.match, published });
      });
    },
    fetch() {
      this.$axios.get(`/archive/matches/${this.$route.params.id}`).then(({ data }) => {
        this.match = deepFreeze(data);
      }).catch(() => {
        this.notFound = true;
      });
    },
  },
  mounted() {
    this.fetch();
  },
  components: {
    LoadingMask,
    ArchiveLineChart,
    ArchiveBarChart,
    ArchiveHbars: ArchiveHBars,
    ArchiveHeatmap,
    ArchiveMap,
    ArchiveLegend,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-header-button {
  margin-right: 10px;
}

.archive-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  padding: 0 25px;
  background: rgba(0, 0, 0, .1);
  border-bottom: solid 1px $grey-default;
}

.archive-tab {
  padding: 10px 14px;
  background: none;
  border: none;
  border-bottom: solid 2px transparent;
  color: inherit;
  font-size: 1.3rem;
  text-transform: uppercase;
  opacity: .6;
  cursor: pointer;

  &:hover { opacity: .85; }

  &.is-active {
    opacity: 1;
    border-bottom-color: $primary;
    font-weight: bold;
  }
}

.archive-content {
  position: relative;
}

.archive-notice {
  margin-bottom: 14px;
  padding: 8px 12px;
  border-left: solid 3px $grey-dark;
  background: rgba(0, 0, 0, .15);
  color: $white-alt-1;

  &.is-alert { border-left-color: $color-alert; }
}

.archive-hero {
  display: flex;
  align-items: center;
  gap: 20px;
  margin-bottom: 20px;
  padding: 18px 22px;
  background: rgba(0, 0, 0, .15);
  border-left: solid 4px $primary;

  h2 {
    margin: 2px 0 8px;
    font-family: $title-font;
    font-size: 2.4rem;
    text-transform: uppercase;
  }
}

.archive-hero-icon {
  flex-shrink: 0;
  width: 54px;
  height: 54px;
}

.archive-hero-label {
  color: $white-alt-1;
  text-transform: uppercase;
  font-size: 1.2rem;
  letter-spacing: 1px;
}

.archive-hero-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.archive-chip {
  display: inline-block;
  padding: 0 8px;
  border-radius: 3px;
  background: $grey-default;
  white-space: nowrap;
}

.archive-standings {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 16px;
  margin-bottom: 20px;
}

.archive-standing {
  padding: 14px 16px;
  background: rgba(0, 0, 0, .12);
  border: solid 1px rgba(0, 0, 0, .2);
  border-top: solid 3px $grey-dark;
}

.archive-standing-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;

  h3 {
    font-size: 1.8rem;
    text-transform: uppercase;
  }

  span { color: $white-alt-2; }
}

.archive-standing-vp {
  margin: 6px 0 12px;
  color: $white-alt-1;

  strong {
    margin-right: 4px;
    font-size: 3.6rem;
    color: $white;
  }
}

.archive-track {
  margin-bottom: 8px;
}

.archive-track-label {
  display: flex;
  justify-content: space-between;
  font-size: 1.2rem;
  color: $white-alt-1;
}

.archive-track-bar {
  position: relative;
  height: 6px;
  margin-top: 3px;
  border-radius: 3px;
  background: rgba(255, 255, 255, .08);
}

.archive-track-fill {
  height: 100%;
  border-radius: 3px;
}

.archive-track-tick {
  position: absolute;
  top: -2px;
  width: 2px;
  height: 10px;
  margin-left: -1px;
  background: $grey-lighter;
}

.archive-standing-stats {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 6px;
  margin-top: 12px;
  font-size: 1.1rem;
  color: $white-alt-2;
  text-transform: uppercase;

  strong {
    display: block;
    font-size: 1.8rem;
    color: $white;
  }
}

.archive-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(420px, 1fr));
  gap: 16px;
  margin-bottom: 16px;

  &.is-thirds {
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  }
}

.archive-card {
  min-width: 0;
  padding: 14px 16px;
  background: rgba(0, 0, 0, .1);
  border: solid 1px rgba(0, 0, 0, .2);

  &.is-wide { grid-column: 1 / -1; }

  h3 {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 8px;
    font-size: 1.4rem;
    text-transform: uppercase;
    letter-spacing: .5px;

    .svg-icon {
      width: 16px;
      height: 16px;
    }
  }

  &.is-small {
    padding: 10px 12px;

    h3 { font-size: 1.2rem; }
  }
}

.archive-hint {
  margin: -4px 0 10px;
  font-size: 1.2rem;
  color: $white-alt-2;
}

.archive-filters {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  margin-bottom: 14px;

  &.is-compact { margin-bottom: 10px; }
}

.archive-filter {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 12px;
  border: solid 1px rgba(255, 255, 255, .12);
  border-radius: 3px;
  background: transparent;
  color: $white-alt-1;
  cursor: pointer;

  .svg-icon {
    width: 14px;
    height: 14px;
  }

  &:hover { background: rgba(255, 255, 255, .05); }

  &.is-active {
    border-color: $primary;
    background: rgba(0, 184, 154, .12);
    color: $white;
  }
}

.archive-filter-sep {
  width: 1px;
  height: 20px;
  margin: 0 6px;
  background: rgba(255, 255, 255, .12);
}

.archive-multiples {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 12px;
}

.archive-multiple-finals {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 12px;
  margin-top: 4px;
  font-size: 1.2rem;
  font-variant-numeric: tabular-nums;
}

.archive-dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  margin-right: 4px;
  border-radius: 50%;
}

.archive-players-table {
  margin-top: 16px;

  th {
    padding: 8px 10px;
    text-align: right;
    font-size: 1.2rem;
    text-transform: uppercase;
    color: $white-alt-2;
    white-space: nowrap;

    &:first-child { text-align: left; }
    &.is-sortable { cursor: pointer; }
    &.is-active { color: $white; }
  }

  td em { margin-left: 8px; }

  .is-number {
    text-align: right;
    font-variant-numeric: tabular-nums;
  }
}
</style>
