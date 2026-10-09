<template>
  <div class="sector-summary">
    <div class="ss-header">
      <svgicon
        v-if="emblem"
        class="ss-emblem"
        :name="emblem" />
      <div class="ss-heading">
        <div class="ss-name">
          {{ sector.name }}
        </div>
        <div class="ss-holder">
          {{ sector.owner
            ? $t('card.sector.held_by', { faction: factionName(sector.owner) })
            : $t('card.sector.unclaimed') }}
        </div>
      </div>
      <div class="ss-value">
        <strong>{{ sector.victory_points }}</strong>
        <span>{{ $tc('card.sector.conquest_points', sector.victory_points) }}</span>
      </div>
    </div>

    <!-- who holds how many systems, and how far the holder is from losing -->
    <div class="ss-section">
      <h2>
        {{ $t('card.sector.control') }}
        <span>{{ $tc('card.sector.inhabited_systems', bar.total, { count: bar.total }) }}</span>
      </h2>

      <div
        v-if="bar.total > 0"
        class="ss-bar">
        <span
          v-for="segment in bar.segments"
          class="ss-segment"
          :class="[colorClass(segment.faction), `is-${segment.role}`]"
          :style="{ width: `${segment.share * 100}%` }"
          :key="`segment-${segment.faction}`"></span>
        <span
          v-if="bar.line !== null"
          class="ss-line"
          :style="{ left: `${bar.line * 100}%` }"></span>
      </div>

      <div
        v-if="contest"
        class="ss-contest">
        {{ contest }}
      </div>

      <div class="ss-legend">
        <div
          v-for="segment in legend"
          class="ss-legend-item"
          :key="`legend-${segment.faction}`">
          <span
            class="ss-dot"
            :class="colorClass(segment.faction)"></span>
          <span class="ss-legend-name">{{ factionName(segment.faction) }}</span>
          <strong>{{ segment.points }}</strong>
        </div>
      </div>
    </div>

    <!-- one faction at a time: the viewer's own, then the others there -->
    <div class="ss-section">
      <h2>
        {{ $t('card.sector.faction_title', { faction: factionName(faction) }) }}
        <span
          v-if="factions.length > 1"
          class="ss-pager">
          <i
            v-for="key in factions"
            class="ss-dot"
            :class="[colorClass(key), { 'is-current': key === faction }]"
            :key="`page-${key}`"></i>
        </span>
      </h2>

      <div
        v-if="empty"
        class="ss-note">
        {{ stats.own ? $t('card.sector.nothing_own') : $t('card.sector.nothing_known') }}
      </div>

      <div class="ss-stats">
        <div
          v-if="stats.systems > 0"
          class="ss-stat">
          <span class="ss-stat-label">{{ $t('card.sector.population_points') }}</span>
          <span class="ss-stat-value">
            {{ stats.population.systems > 0 ? stats.population.points : '?' }}
            <small v-if="stats.population.systems < stats.systems">
              {{ partial(stats.population.systems) }}
            </small>
          </span>
        </div>
        <div
          v-if="stats.visibility"
          class="ss-stat">
          <span class="ss-stat-label">
            {{ stats.own ? $t('card.sector.visibility_points') : $t('card.sector.visibility_on_them') }}
          </span>
          <span class="ss-stat-value">
            {{ stats.visibility.points }}<small> / {{ stats.visibility.max }}</small>
          </span>
        </div>
        <div
          v-if="intel && (stats.own || stats.fleets.count > 0)"
          class="ss-stat">
          <span class="ss-stat-label">
            {{ stats.own ? $t('card.sector.fleets') : $t('card.sector.fleets_in_sight') }}
          </span>
          <span class="ss-stat-value">
            {{ stats.fleets.count }}
            <small v-if="stats.fleets.count > stats.fleets.unread">
              {{ $t('card.sector.fleet_upkeep', { upkeep: fleetUpkeep }) }}
            </small>
          </span>
        </div>
        <div
          v-if="intel && stats.own"
          class="ss-stat">
          <span class="ss-stat-label">{{ $t('card.sector.foreign_fleets') }}</span>
          <span class="ss-stat-value">{{ stats.foreignFleets }}</span>
        </div>
      </div>

      <div
        v-if="stats.economy"
        class="ss-row">
        <span class="ss-stat-label">
          {{ $t('card.sector.output') }}
          <template v-if="!stats.own && stats.economy.systems < stats.systems">
            · {{ partial(stats.economy.systems) }}
          </template>
        </span>
        <span class="ss-output">
          <span
            v-for="resource in outputs"
            class="ss-output-item"
            :key="`output-${resource}`">
            <svgicon :name="`resource/${resource}`" />
            {{ stats.economy[resource] | income(0) }}
          </span>
        </span>
      </div>

      <div
        v-if="stats.own && census"
        class="ss-row">
        <span class="ss-stat-label">{{ $t('card.sector.census') }}</span>
        <span class="ss-stat-value">
          {{ $tc('card.sector.census_count', census.count, { count: census.count }) }}
          <small v-if="!census.powered">{{ $t('card.sector.census_offline') }}</small>
        </span>
      </div>

      <div
        v-if="factions.length > 1"
        class="ss-hint">
        {{ $t('card.sector.next_faction') }}
      </div>
    </div>
  </div>
</template>

<script>
import formatNumber from '@/utils/format';
import {
  controlBar, factionStats, sectorCensus, sectorFactions,
} from '@/game/map/sector-summary';

const EMBLEMS = ['ark', 'cardan', 'myrmezir', 'rebellion', 'synelle', 'tetrarchy'];

export default {
  name: 'sector-card',
  props: {
    sector: {
      type: Object,
      required: true,
    },
    // The map's own copy of the galaxy (MapData): the only one patched
    // by every system and contact push. Not reactive, and it need not
    // be: the card is built anew each time a sector is hovered.
    mapData: {
      type: Object,
      default: null,
    },
    // Which faction's figures are up: a count of clicks on the sector's
    // name (the card itself never takes the pointer), wrapped over the
    // factions there.
    page: {
      type: Number,
      default: 0,
    },
  },
  computed: {
    playerFaction() { return this.$store.state.game.playerFaction; },
    intel() { return this.$store.state.game.mapIntel; },
    government() {
      const { faction } = this.$store.state.game;
      return (faction && faction.government) || null;
    },
    emblem() {
      return EMBLEMS.includes(this.sector.owner) ? `faction/${this.sector.owner}-small` : null;
    },
    bar() { return controlBar(this.sector); },
    // the holder is listed even after its last system there is gone
    legend() {
      return this.bar.segments.filter((s) => s.points > 0 || (s.role === 'holder' && s.faction));
    },
    contest() {
      const { challenger, holder, lead, total, segments } = this.bar;
      if (total === 0) return this.$t('card.sector.empty');
      if (!challenger) {
        if (!this.sector.owner) return null;
        // more neutral systems than the holder has, and still held: say why
        const neutral = segments.find((s) => s.faction === null);
        return neutral && neutral.points >= holder.points
          ? this.$t('card.sector.home_sector')
          : this.$t('card.sector.unopposed');
      }

      const name = this.factionName(challenger.faction);
      if (lead < 0) return this.$t('card.sector.flipping', { faction: name });
      return this.$tc('card.sector.needs', lead + 1, { faction: name, count: lead + 1 });
    },
    factions() { return sectorFactions(this.sector, this.playerFaction); },
    faction() { return this.factions[this.page % this.factions.length]; },
    stats() {
      const classes = this.$store.state.game.data.population_class || [];
      return factionStats({
        sectorId: this.sector.id,
        systems: this.mapData ? this.mapData.systems : [],
        faction: this.faction,
        ownFaction: this.playerFaction,
        pointsByClass: classes.reduce((acc, c) => {
          acc[c.key] = c.points;
          return acc;
        }, {}),
        intel: this.intel,
      });
    },
    census() { return sectorCensus(this.government, this.sector.id); },
    // nothing to say about this faction here
    empty() {
      const { stats } = this;
      return stats.systems === 0 && !stats.visibility && stats.fleets.count === 0
        && !stats.foreignFleets && !(stats.own && this.census);
    },
    // "3,400", or "3,400+" when some of the fleets could not be read
    fleetUpkeep() {
      const { upkeep, unread } = this.stats.fleets;
      return `${formatNumber.compact(upkeep)}${unread > 0 ? '+' : ''}`;
    },
    // production is left out: it is spent system by system, a sum of it
    // says nothing
    outputs() { return ['credit', 'technology', 'ideology']; },
  },
  methods: {
    factionName(faction) {
      return this.$t(`data.faction.${faction || 'neutral'}.name`);
    },
    // a class per faction theme; the neutral systems are grey
    colorClass(faction) {
      const theme = faction ? this.$store.getters['game/themeByKey'](faction) : '';
      return theme ? `ss-color-${theme}` : 'ss-color-neutral';
    },
    // "2 of 5 systems": how much of the faction a figure covers
    partial(count) {
      return this.$t('card.sector.partial', { count, total: this.stats.systems });
    },
  },
  mounted() {
    // fleets and income come from the faction's map intel: make sure the
    // copy on hand is a recent one (shown as soon as it lands)
    this.$store.dispatch('game/refreshMapIntel', { socket: this.$socket, maxAge: 45000 });
  },
};
</script>
