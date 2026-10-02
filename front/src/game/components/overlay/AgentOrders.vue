<template>
  <!-- Agent orders list: every system ranked by travel time from the
       selected agent, with the orders it can be given there. A way to
       command agents without the galaxy map — built for screen-reader
       and keyboard play, and handy for anyone hunting a target in a big
       galaxy. Opened with G or the list button in the agent's panel. -->
  <div
    v-if="isOpen && character"
    class="agent-orders-backdrop"
    :class="`f-${theme}`"
    @click.self="close">
    <div
      ref="dialog"
      class="agent-orders"
      role="dialog"
      aria-modal="true"
      aria-labelledby="agent-orders-title"
      aria-describedby="agent-orders-position"
      @keydown.esc.stop.prevent="close"
      @keydown.tab="trapFocus">
      <header class="agent-orders-header">
        <div>
          <h2 id="agent-orders-title">{{ $t('a11y.orders.title', { agent: agentName }) }}</h2>
          <p
            id="agent-orders-position"
            class="agent-orders-position">{{ positionText }}</p>
        </div>
        <button
          type="button"
          class="agent-orders-close"
          :aria-label="$t('a11y.orders.close')"
          @click="close">
          <svgicon
            name="close"
            aria-hidden="true" />
        </button>
      </header>

      <div
        class="agent-orders-filters"
        role="search">
        <input
          ref="search"
          v-model="search"
          type="search"
          class="agent-orders-input"
          :aria-label="$t('a11y.orders.search_label')"
          :placeholder="$t('a11y.orders.search_placeholder')">

        <select
          v-model="relation"
          class="agent-orders-input"
          :aria-label="$t('a11y.orders.relation_label')">
          <option
            v-for="option in RELATIONS"
            :key="option"
            :value="option">{{ $t(`a11y.orders.relation.${option}`) }}</option>
        </select>

        <select
          v-model="orderFilter"
          class="agent-orders-input"
          :aria-label="$t('a11y.orders.order_label')">
          <option value="any">{{ $t('a11y.orders.order_any') }}</option>
          <option
            v-for="order in typeOrders"
            :key="order.key"
            :value="order.key">{{ $t(`galaxy.system.actions.${order.name}`) }}</option>
        </select>

        <select
          v-model="sectorFilter"
          class="agent-orders-input"
          :aria-label="$t('a11y.orders.sector_label')">
          <option value="all">{{ $t('a11y.orders.sector_all') }}</option>
          <option
            v-for="sector in sectors"
            :key="sector.id"
            :value="sector.id">{{ sector.name }}</option>
        </select>

        <select
          v-model="sortBy"
          class="agent-orders-input"
          :aria-label="$t('a11y.orders.sort_label')">
          <option value="travel">{{ $t('a11y.orders.sort_travel') }}</option>
          <option value="name">{{ $t('a11y.orders.sort_name') }}</option>
        </select>
      </div>

      <p
        class="agent-orders-count"
        role="status">{{ countText }}</p>

      <v-scrollbar class="agent-orders-scroll">
        <table class="agent-orders-table">
          <caption class="sr-only">{{ $t('a11y.orders.caption', { agent: agentName }) }}</caption>
          <thead>
            <tr>
              <th scope="col">{{ $t('a11y.orders.col_system') }}</th>
              <th scope="col">{{ $t('a11y.orders.col_owner') }}</th>
              <th scope="col">{{ $t('a11y.orders.col_travel') }}</th>
              <th scope="col">{{ $t('a11y.orders.col_orders') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="row in visibleRows"
              :key="row.id"
              :class="{ 'is-here': row.hops === 0 }">
              <th scope="row">
                <button
                  type="button"
                  class="bare-button agent-orders-system"
                  :aria-label="$t('a11y.orders.open_system', { system: row.name })"
                  @click="openSystem(row)">{{ row.name }}</button>
                <span class="agent-orders-sector">{{ row.sectorName }}</span>
              </th>
              <td>{{ row.ownerText }}</td>
              <td>{{ row.travelText }}</td>
              <td>
                <div class="agent-orders-actions">
                  <button
                    v-for="order in row.orders"
                    :key="order.key"
                    type="button"
                    class="agent-orders-action"
                    :aria-label="$t('a11y.orders.give', {
                      order: $t(`galaxy.system.actions.${order.name}`),
                      system: row.name,
                    })"
                    @click="give(order, row)">
                    {{ $t(`galaxy.system.actions.${order.name}`) }}
                  </button>
                  <span
                    v-if="!row.orders.length"
                    class="agent-orders-none">{{ $t('a11y.orders.none') }}</span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>

        <button
          v-if="filteredRows.length > limit"
          type="button"
          class="agent-orders-more"
          @click="limit += PAGE">
          {{ $t('a11y.orders.show_more', { n: Math.min(PAGE, filteredRows.length - limit) }) }}
        </button>
      </v-scrollbar>
    </div>
  </div>
</template>

<script>
import { searchKey } from '@/utils/search-key';
import { formatDuration } from '@/utils/format';
import { availableOrders, ORDERS_BY_TYPE } from '@/game/plan/orders';
import { routesFrom } from '@/game/plan/route';
import { agentTypeName, actionStatusName } from '@/game/a11y/describe';

const RELATIONS = ['all', 'own', 'enemy', 'neutral', 'uninhabited'];
const PAGE = 100;

const FOCUSABLE = 'button:not([disabled]), input, select, [tabindex]:not([tabindex="-1"])';

export default {
  name: 'agent-orders',
  inject: ['mapData'],
  data() {
    return {
      isOpen: false,
      // rows are rebuilt from the (non-reactive) map data on open and
      // whenever the agent's plan end moves; frozen, Vue needn't watch
      // thousands of them.
      rows: Object.freeze([]),
      search: '',
      relation: 'all',
      orderFilter: 'any',
      sectorFilter: 'all',
      sortBy: 'travel',
      limit: PAGE,
      returnFocus: null,
      RELATIONS,
      PAGE,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    player() { return this.$store.state.game.player; },
    character() { return this.$store.state.game.selectedCharacter; },
    // Orders queue after the current plan, so routes start where it ends.
    origin() {
      const c = this.character;
      if (!c) return null;
      return c.actions && c.actions.virtual_position != null ? c.actions.virtual_position : c.system;
    },
    agentName() {
      return this.character ? `${agentTypeName(this, this.character.type)} ${this.character.name}` : '';
    },
    sectors() {
      return (this.$store.state.game.galaxy.sectors || []).slice()
        .sort((a, b) => a.name.localeCompare(b.name));
    },
    typeOrders() {
      return this.character ? ORDERS_BY_TYPE[this.character.type] || [] : [];
    },
    positionText() {
      if (!this.character) return '';
      const here = this.mapData.systemsById.get(this.character.system);
      const end = this.mapData.systemsById.get(this.origin);
      const parts = [];
      if (here) parts.push(this.$t('a11y.orders.position', { system: here.name }));
      const status = actionStatusName(this, this.character.action_status);
      if (status) parts.push(status);
      const queue = this.character.actions && Array.isArray(this.character.actions.queue)
        ? this.character.actions.queue.length : 0;
      if (queue && end) parts.push(this.$tc('a11y.orders.plan_end', queue, { n: queue, system: end.name }));
      return parts.join('. ');
    },
    filteredRows() {
      const query = searchKey(this.search.trim());
      const sector = this.sectorFilter === 'all' ? null : Number(this.sectorFilter);

      const rows = this.rows.filter((row) => {
        if (query && !row.haystack.includes(query)) return false;
        if (sector !== null && row.sector_id !== sector) return false;
        if (this.relation !== 'all' && row.relation !== this.relation) return false;
        if (this.orderFilter !== 'any' && !row.orders.some((o) => o.key === this.orderFilter)) return false;
        return true;
      });

      if (this.sortBy === 'name') return rows.slice().sort((a, b) => a.name.localeCompare(b.name));
      return rows; // rows are built in travel order
    },
    visibleRows() {
      return this.filteredRows.slice(0, this.limit);
    },
    countText() {
      const n = this.filteredRows.length;
      const text = this.$tc('a11y.orders.count', n, { n });
      return n > this.limit ? `${text} ${this.$t('a11y.orders.showing', { n: this.limit })}` : text;
    },
  },
  watch: {
    // A queued order moves the plan's end: re-rank from there.
    origin() {
      if (this.isOpen) this.buildRows();
    },
    character(next) {
      if (!next && this.isOpen) this.close();
    },
    search() { this.limit = PAGE; },
    relation() { this.limit = PAGE; },
    orderFilter() { this.limit = PAGE; },
    sectorFilter() { this.limit = PAGE; },
    sortBy() { this.limit = PAGE; },
  },
  methods: {
    toggle() {
      if (this.isOpen) this.close();
      else this.open();
    },
    open() {
      if (!this.character) {
        this.$announce(this.$t('a11y.orders.no_agent'));
        return;
      }
      this.returnFocus = document.activeElement;
      this.isOpen = true;
      this.buildRows();
      this.$nextTick(() => {
        if (this.$refs.search) this.$refs.search.focus();
      });
    },
    close() {
      this.isOpen = false;
      const target = this.returnFocus;
      this.returnFocus = null;
      if (target && document.body.contains(target) && target.focus) target.focus();
    },
    buildRows() {
      const galaxy = this.$store.state.game.galaxy;
      const routes = routesFrom(galaxy, this.origin);
      const constant = (this.$store.state.game.data.constant || [])[0] || {};
      const movement = constant.character_movement_factor || 1;
      const tickToSecond = this.$store.getters['game/tickToSecondFactor'];
      const sectorById = new Map((galaxy.sectors || []).map((s) => [s.id, s]));
      const t = (key, params) => this.$t(key, params);

      const rows = [];
      this.mapData.systems.forEach((system) => {
        const route = routes.get(system.id);
        if (!route) return;

        const sector = sectorById.get(system.sector_id);
        const relation = this.relationOf(system);
        rows.push({
          id: system.id,
          name: system.name,
          sector_id: system.sector_id,
          sectorName: sector ? sector.name : '',
          relation,
          ownerText: this.ownerText(system, relation),
          hops: route.hops,
          travelText: route.hops === 0
            ? this.$t('a11y.orders.here')
            : this.$tc('a11y.orders.travel', route.hops, {
              n: route.hops,
              time: formatDuration(route.weight * movement * tickToSecond, t),
            }),
          weight: route.weight,
          orders: availableOrders(this.character, system, this.player),
          haystack: searchKey(`${system.name} ${system.owner || ''} ${sector ? sector.name : ''}`),
          system,
        });
      });
      rows.sort((a, b) => a.weight - b.weight || a.name.localeCompare(b.name));
      this.rows = Object.freeze(rows);
    },
    relationOf(system) {
      if (system.faction && system.faction === this.player.faction) return 'own';
      if (system.faction) return 'enemy';
      if (system.status === 'inhabited_neutral') return 'neutral';
      if (system.status === 'uninhabited') return 'uninhabited';
      return 'other';
    },
    ownerText(system, relation) {
      if (relation === 'own' || relation === 'enemy') {
        const faction = this.$te(`data.faction.${system.faction}.name`)
          ? this.$t(`data.faction.${system.faction}.name`) : system.faction;
        return system.owner ? `${system.owner} (${faction})` : faction;
      }
      if (relation === 'neutral') return this.$t('a11y.orders.relation.neutral');
      if (relation === 'uninhabited') return this.$t('a11y.orders.relation.uninhabited');
      return this.$t('galaxy.map.uninhabitable');
    },
    give(order, row) {
      this.$root.$emit('map:addAction', order.key, { system: row.system });
      this.$announce(this.$t('a11y.orders.sent', {
        order: this.$t(`galaxy.system.actions.${order.name}`),
        system: row.name,
      }));
    },
    openSystem(row) {
      this.close();
      this.$store.dispatch('game/openSystem', { vm: this, id: row.id });
    },
    // Keep Tab inside the dialog while it's open.
    trapFocus(event) {
      const focusable = Array.from(this.$refs.dialog.querySelectorAll(FOCUSABLE))
        .filter((el) => el.offsetParent !== null);
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    },
  },
  mounted() {
    this.$root.$on('toggleAgentOrders', this.toggle);
  },
  beforeDestroy() {
    this.$root.$off('toggleAgentOrders', this.toggle);
  },
};
</script>

<style lang="scss" scoped>
.agent-orders-backdrop {
  position: fixed;
  inset: 0;
  // modal: above everything in the game view, navbars included
  // ($z-navbar 600), below the splash screen
  z-index: 650;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.55);
}

.agent-orders {
  display: flex;
  flex-direction: column;
  width: min(960px, calc(100vw - 32px));
  height: min(720px, calc(100vh - 140px));
  padding: 1em 1.2em;
  background: rgba(8, 12, 22, 0.97);
  border: 1px solid rgba(255, 255, 255, 0.2);
  box-shadow: 0 0 20px rgba(0, 0, 0, 0.6);
  color: #f1f3f6;
}

.agent-orders-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1em;

  h2 {
    margin: 0;
    font-size: 1.5em;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
}

.agent-orders-position {
  margin: 0.3em 0 0;
  opacity: 0.8;
}

.agent-orders-close {
  flex-shrink: 0;
  width: 2em;
  height: 2em;
  padding: 0.35em;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.25);
  color: inherit;
  cursor: pointer;

  .svg-icon { width: 100%; height: 100%; }
  &:hover { background: rgba(255, 255, 255, 0.1); }
}

.agent-orders-filters {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5em;
  margin-top: 0.8em;
}

.agent-orders-input {
  padding: 0.3em 0.5em;
  font: inherit;
  color: inherit;
  background: rgba(0, 0, 0, 0.45);
  border: 1px solid rgba(255, 255, 255, 0.25);

  &[type="search"] { flex: 1 1 14em; min-width: 10em; }
  &:focus { border-color: rgba(255, 255, 255, 0.6); }
}

.agent-orders-count {
  margin: 0.6em 0 0.3em;
  font-size: 0.9em;
  opacity: 0.8;
}

.agent-orders-scroll {
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
}

.agent-orders-table {
  width: 100%;
  border-collapse: collapse;

  th,
  td {
    padding: 0.45em 0.5em;
    text-align: left;
    vertical-align: middle;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  }

  thead th {
    position: sticky;
    top: 0;
    z-index: 1;
    font-size: 0.8em;
    font-weight: normal;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    background: rgba(8, 12, 22, 0.98);
    opacity: 0.85;
  }

  tbody th { font-weight: normal; }

  tr.is-here { background: rgba(255, 255, 255, 0.05); }
}

.agent-orders-system {
  font-weight: bold;
  cursor: pointer;

  &:hover { text-decoration: underline; }
}

.agent-orders-sector {
  display: block;
  font-size: 0.75em;
  text-transform: uppercase;
  opacity: 0.7;
}

.agent-orders-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
}

.agent-orders-action,
.agent-orders-more {
  padding: 0.25em 0.6em;
  font: inherit;
  font-size: 0.9em;
  color: inherit;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.3);
  cursor: pointer;

  &:hover { background: rgba(255, 255, 255, 0.18); }
}

.agent-orders-more {
  display: block;
  margin: 0.8em auto;
}

.agent-orders-none { opacity: 0.6; }
</style>
