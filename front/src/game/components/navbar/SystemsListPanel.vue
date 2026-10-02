<template>
  <list-panel
    panel-key="systems"
    side="left"
    @search="search = $event">
    <template #toolbar>
      <div
        class="list-panel-tool"
        :class="{ 'active': filters.enemyAgents }"
        v-tooltip="$t('navbar.list_panel.filter_enemy_agents')"
        @click="filters.enemyAgents = !filters.enemyAgents">
        <svgicon name="eye" />
      </div>
      <div
        class="list-panel-tool"
        :class="{ 'active': filters.underAttack }"
        v-tooltip="$t('navbar.list_panel.filter_under_attack')"
        @click="filters.underAttack = !filters.underAttack">
        <svgicon name="marker/attack" />
      </div>
      <div
        class="list-panel-tool"
        :class="{ 'active': filters.emptyQueue }"
        v-tooltip="$t('navbar.list_panel.filter_empty_queue')"
        @click="filters.emptyQueue = !filters.emptyQueue">
        <svgicon name="square" />
      </div>

      <span class="list-panel-divider"></span>

      <div
        class="list-panel-tool"
        :class="{ 'active': sortMode === 'name' }"
        v-tooltip="$t('navbar.list_panel.sort_name')"
        @click="toggleSort('name')">
        <svgicon name="sort" />
      </div>
      <div
        class="list-panel-tool"
        :class="{ 'active': sortMode === 'queue' }"
        v-tooltip="$t('navbar.list_panel.sort_queue')"
        @click="toggleSort('queue')">
        <svgicon name="production-queue" />
      </div>

      <span class="list-panel-divider"></span>

      <div
        class="list-panel-tool"
        :class="{ 'active': groupMode === 'sector' }"
        v-tooltip="groupMode === 'sector'
          ? $t('navbar.list_panel.group_kind')
          : $t('navbar.list_panel.group_sector')"
        @click="groupMode = groupMode === 'sector' ? 'kind' : 'sector'">
        <svgicon name="layers" />
      </div>
    </template>

    <template v-if="groups.length">
      <div
        v-for="group in groups"
        :key="group.key">
        <div class="navbar-panel-header">
          <h1><span>{{ group.title }}</span></h1>
        </div>
        <closed-system-card
          v-for="entry in group.entries"
          :key="entry.system.id"
          :system="entry.system"
          :theme="theme"
          @select="selectSystem" />
      </div>
    </template>
    <div
      v-else
      class="navbar-panel-empty">
      {{ $t('navbar.list_panel.no_match') }}
    </div>
  </list-panel>
</template>

<script>
import { foreignAgents } from '@/utils/foreign-agents';
import { searchKey } from '@/utils/search-key';
import ListPanel from '@/game/components/navbar/ListPanel.vue';
import ClosedSystemCard from '@/game/components/card/ClosedSystemCard.vue';

export default {
  name: 'systems-list-panel',
  data() {
    return {
      search: '',
      // Active filters combine with AND: each one narrows the list.
      filters: {
        enemyAgents: false,
        underAttack: false,
        emptyQueue: false,
      },
      // null keeps the server order (the pre-redesign behavior).
      sortMode: null, // null | 'name' | 'queue'
      groupMode: 'kind', // 'kind' (dominions/systems) | 'sector'
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    player() { return this.$store.state.game.player; },
    constants() { return (this.$store.state.game.data.constant || [])[0] || {}; },
    sectors() { return this.$store.state.game.galaxy.sectors || []; },
    entries() {
      return [
        ...this.player.dominions.map((system) => ({ system, isDominion: true })),
        ...this.player.stellar_systems.map((system) => ({ system, isDominion: false })),
      ];
    },
    filteredEntries() {
      const query = searchKey(this.search);
      const underAttackIds = this.player.dominions_under_attack;

      return this.entries.filter(({ system }) => {
        if (query && !searchKey(system.name).includes(query)) return false;
        if (this.filters.enemyAgents
          && foreignAgents(system, this.player, this.constants).length === 0) return false;
        if (this.filters.underAttack
          && !system.siege
          && !(Array.isArray(underAttackIds) && underAttackIds.includes(system.id))) return false;
        if (this.filters.emptyQueue && system.queue > 0) return false;
        return true;
      });
    },
    groups() {
      const groups = this.groupMode === 'sector'
        ? this.sectorGroups()
        : this.kindGroups();

      return groups
        .filter((group) => group.entries.length > 0)
        .map((group) => ({ ...group, entries: this.sorted(group.entries) }));
    },
  },
  methods: {
    kindGroups() {
      const dominions = this.filteredEntries.filter((e) => e.isDominion);
      const systems = this.filteredEntries.filter((e) => !e.isDominion);

      return [
        {
          key: 'dominions',
          title: `${dominions.length} ${this.$tc('system.dominion', dominions.length)}`,
          entries: dominions,
        },
        {
          key: 'systems',
          title: `${systems.length} ${this.$tc('system.system', systems.length)}`,
          entries: systems,
        },
      ];
    },
    sectorGroups() {
      const bySector = new Map();
      this.filteredEntries.forEach((entry) => {
        const id = entry.system.sector_id;
        if (!bySector.has(id)) bySector.set(id, []);
        bySector.get(id).push(entry);
      });

      return Array.from(bySector.entries())
        .map(([sectorId, entries]) => {
          const sector = this.sectors.find((s) => s.id === sectorId);
          const name = sector ? sector.name : this.$t('navbar.list_panel.sector_unknown');
          return { key: `sector-${sectorId}`, name, entries };
        })
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((group) => ({
          key: group.key,
          title: `${group.name} (${group.entries.length})`,
          entries: group.entries,
        }));
    },
    sorted(entries) {
      if (this.sortMode === 'name') {
        return entries.slice().sort((a, b) => a.system.name.localeCompare(b.system.name));
      }
      if (this.sortMode === 'queue') {
        return entries.slice().sort((a, b) => (b.system.queue - a.system.queue)
          || a.system.name.localeCompare(b.system.name));
      }
      // Default order inside sector groups: dominions above systems,
      // mirroring the split the kind grouping makes explicit.
      if (this.groupMode === 'sector') {
        return entries.slice().sort((a, b) => Number(b.isDominion) - Number(a.isDominion));
      }
      return entries;
    },
    toggleSort(mode) {
      this.sortMode = this.sortMode === mode ? null : mode;
    },
    selectSystem(system) {
      this.$store.dispatch('game/openSystem', { vm: this, id: system.id });
    },
  },
  components: {
    ListPanel,
    ClosedSystemCard,
  },
};
</script>
