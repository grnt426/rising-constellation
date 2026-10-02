<template>
  <list-panel
    panel-key="agents"
    side="right"
    @search="search = $event">
    <template #toolbar>
      <div
        v-for="type in characterTypes"
        :key="`type-${type.key}`"
        class="list-panel-tool"
        :class="{ 'active': typeFilters[type.key] }"
        v-tooltip="$tc(`data.character.${type.key}.name`, 2)"
        @click="toggleTypeFilter(type.key)">
        <svgicon :name="`agent/${type.key}`" />
      </div>

      <span class="list-panel-divider"></span>

      <div
        v-for="status in statusList"
        :key="`status-${status.key}`"
        class="list-panel-tool"
        :class="{ 'active': statusFilters[status.key] }"
        v-tooltip="$t(`navbar.list_panel.status_${status.key}`)"
        @click="toggleStatusFilter(status.key)">
        <svgicon :name="status.icon" />
      </div>
    </template>

    <template v-if="groups.length">
      <div
        v-for="group in groups"
        :key="group.key">
        <div class="navbar-panel-header">
          <h1><span>{{ group.title }}</span></h1>
        </div>
        <closed-character-card
          v-for="character in group.characters"
          :key="character.id"
          :character="character"
          :theme="theme"
          @select="selectCharacter" />
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
import { searchKey } from '@/utils/search-key';
import ListPanel from '@/game/components/navbar/ListPanel.vue';
import ClosedCharacterCard from '@/game/components/card/ClosedCharacterCard.vue';

// action_status values that mean the agent is recovering rather than
// idle or on a mission: stuck in the docking bay, or in portal fatigue
// after a gateway jump.
const RESTING_STATUSES = ['docking', 'gateway_fatigue'];

export default {
  name: 'agents-list-panel',
  data() {
    return {
      search: '',
      // Within each facet the active toggles are OR'd (an agent matches
      // any selected type / any selected status); the two facets AND.
      typeFilters: {
        admiral: false,
        spy: false,
        speaker: false,
      },
      statusFilters: {
        idle: false,
        busy: false,
        resting: false,
        exposed: false,
      },
      statusList: [
        { key: 'idle', icon: 'disc' },
        { key: 'busy', icon: 'spinner' },
        { key: 'resting', icon: 'action/gateway_fatigue' },
        { key: 'exposed', icon: 'agent/discovered' },
      ],
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    player() { return this.$store.state.game.player; },
    characterTypes() { return this.$store.state.game.data.character; },
    onBoardCharacters() {
      // receivedAt is merged in (as the pre-redesign list did) so the
      // card re-renders on every player broadcast and its live action
      // countdowns stay honest.
      return this.player.characters
        .filter((c) => c.status === 'on_board')
        .map((c) => ({ ...c, receivedAt: this.player.receivedAt }));
    },
    filteredCharacters() {
      const query = searchKey(this.search);
      const activeTypes = Object.keys(this.typeFilters).filter((k) => this.typeFilters[k]);
      const activeStatuses = Object.keys(this.statusFilters).filter((k) => this.statusFilters[k]);

      return this.onBoardCharacters.filter((character) => {
        if (query && !searchKey(character.name).includes(query)) return false;
        if (activeTypes.length && !activeTypes.includes(character.type)) return false;
        if (activeStatuses.length
          && !activeStatuses.some((status) => this.hasStatus(character, status))) return false;
        return true;
      });
    },
    groups() {
      return this.characterTypes
        .map((type) => {
          const characters = this.filteredCharacters.filter((c) => c.type === type.key);
          return {
            key: type.key,
            title: `${characters.length} ${this.$tc(`data.character.${type.key}.name`, characters.length)}`,
            characters,
          };
        })
        .filter((group) => group.characters.length > 0);
    },
  },
  methods: {
    hasStatus(character, status) {
      if (status === 'exposed') {
        return character.type === 'spy' && character.is_discovered;
      }
      const resting = RESTING_STATUSES.includes(character.action_status);
      if (status === 'resting') return resting;
      const idle = !character.action_status || character.action_status === 'idle';
      if (status === 'idle') return idle;
      return !resting && !idle; // busy
    },
    toggleTypeFilter(key) {
      this.typeFilters[key] = !this.typeFilters[key];
    },
    toggleStatusFilter(key) {
      this.statusFilters[key] = !this.statusFilters[key];
    },
    selectCharacter(character) {
      this.$store.dispatch('game/selectCharacter', { vm: this, id: character.id });
    },
  },
  components: {
    ListPanel,
    ClosedCharacterCard,
  },
};
</script>
