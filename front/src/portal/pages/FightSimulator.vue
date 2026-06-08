<template>
  <default-layout>
    <div class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-info">
          <h2>{{ $t('page.fight_simulator.player', {number: 1}) }}</h2>
          <p>{{ $t('page.fight_simulator.attacker') }}</p>
        </div>

        <div class="panel-aside-bloc">
          <div class="default-input">
            <label for="attacker_initial_xp">
              {{ $t('page.fight_simulator.initial_xp') }}
            </label>
            <input
              type="number"
              id="attacker_initial_xp"
              v-model.number="attacker.initial_xp" />
          </div>
        </div>

        <div class="panel-aside-bloc simulator-army-bloc">
          <simulator-army
            mode="edit"
            :theme="attackerTheme"
            :tiles="editTiles(attacker.tiles)"
            :activeIdx="activeIdxFor('attacker')"
            @pick-tile="onPickTile('attacker', $event)"
            @clear-tile="onClearTile('attacker', $event)"
            @bump-up="onBump('attacker', $event, 'next')"
            @bump-down="onBump('attacker', $event, 'prev')" />
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-full-sized">
        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.fight_simulator.title') }}</strong>
          </h1>

          <button
            @click="fight"
            class="default-button">
            {{ $t('page.fight_simulator.launch') }}
          </button>
        </div>

        <v-scrollbar class="content">
          <simulator-ship-picker
            v-if="activePicker"
            :theme="activePicker.side === 'attacker' ? attackerTheme : defenderTheme"
            @pick="onPickShip" />

          <div
            v-else-if="logs"
            class="simulator-results">
            <div
              v-for="side in ['attackers', 'defenders']"
              :key="`results-${side}`"
              class="simulator-results-side">
              <h2>
                {{ $t(`page.fight_simulator.results_${side}`) }}
              </h2>
              <div
                v-for="character in initialCharacters[side]"
                :key="`char-${side}-${character.id}`"
                class="simulator-results-army">
                <simulator-army
                  mode="display"
                  :theme="theme(character.owner.faction)"
                  :tiles="displayTilesFor(character)"
                  :diff="displayTilesFor(finalCharacterFor(side, character.id))" />
              </div>
            </div>

            <div class="fight-report">
              <div class="title">
                {{ $t('panel.operations.fight_course') }}
              </div>
              <div
                class="round"
                v-for="(round, j) in logs"
                :key="`round-${j}`">
                <div class="round-title">
                  {{ j + 1 }}
                </div>
                <div class="round-content">
                  <div
                    v-for="(action, k) in round"
                    :key="`action-${k}`">
                    <template v-if="action.type === 'transfer' && action.data.target === 'field'">
                      <strong :class="`theme-${getShip(action.source).theme}`">
                        {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
                        [{{ action.source.tile }}]
                      </strong>
                      {{ $t('panel.operations.fight_arrival') }}
                    </template>

                    <template v-else-if="action.type === 'transfer' && action.data.target === 'army'">
                      <strong :class="`theme-${getShip(action.source).theme}`">
                        {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
                        [{{ action.source.tile }}]
                      </strong>
                      {{ $t('panel.operations.fight_leave') }}
                    </template>

                    <template v-else-if="action.type === 'destroyed'">
                      <strong :class="`theme-${getShip(action.source).theme}`">
                        {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
                        [{{ action.source.tile }}]
                      </strong>
                      {{ $t('panel.operations.fight_destroyed') }}
                    </template>

                    <template v-else-if="action.type === 'escaping'">
                      <strong :class="`theme-${getShip(action.source).theme}`">
                        {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
                        [{{ action.source.tile }}]
                      </strong>
                      {{ $t('panel.operations.fight_fly') }}
                    </template>

                    <template v-else-if="action.type === 'attack'">
                      <strong :class="`theme-${getShip(action.source).theme}`">
                        {{ $t(`data.ship.${getShip(action.source).key}.name`) }}
                        [{{ action.source.tile }}]
                      </strong>
                      {{ $t('panel.operations.fight_attacks', {attack_count: action.data.actions.length}) }}
                      <strong :class="`theme-${getShip(action.data.target).theme}`">
                        {{ $t(`data.ship.${getShip(action.data.target).key}.name`) }}
                        [{{ action.data.target.tile }}]
                      </strong>
                      <span v-html="computeStrikes(action.data.actions)"></span>
                    </template>

                    <template v-else>
                    </template>
                  </div>
                </div>
              </div>
            </div>

            <hr class="margin">
          </div>

          <div
            v-else
            class="simulator-empty-hint">
            {{ $t('page.fight_simulator.empty_hint') }}
          </div>
        </v-scrollbar>
      </div>

      <v-scrollbar class="panel-aside">
        <div class="panel-aside-info">
          <h2>{{ $t('page.fight_simulator.player', {number: 2}) }}</h2>
          <p>{{ $t('page.fight_simulator.defender') }}</p>
        </div>

        <div class="panel-aside-bloc">
          <div class="default-input">
            <label for="defender_initial_xp">
              {{ $t('page.fight_simulator.initial_xp') }}
            </label>
            <input
              type="number"
              id="defender_initial_xp"
              v-model.number="defender.initial_xp" />
          </div>
        </div>

        <div class="panel-aside-bloc simulator-army-bloc">
          <simulator-army
            mode="edit"
            :theme="defenderTheme"
            :tiles="editTiles(defender.tiles)"
            :activeIdx="activeIdxFor('defender')"
            @pick-tile="onPickTile('defender', $event)"
            @clear-tile="onClearTile('defender', $event)"
            @bump-up="onBump('defender', $event, 'next')"
            @bump-down="onBump('defender', $event, 'prev')" />
        </div>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import SimulatorArmy from '@/portal/components/SimulatorArmy.vue';
import SimulatorShipPicker from '@/portal/components/SimulatorShipPicker.vue';

const TILE_COUNT = 18;

export default {
  name: 'fight-simulator',
  data() {
    return {
      attacker: { initial_xp: 0, tiles: Array(TILE_COUNT).fill(null) },
      defender: { initial_xp: 0, tiles: Array(TILE_COUNT).fill(null) },
      activePicker: null, // { side: 'attacker'|'defender', idx: number }
      logs: null,
      initialCharacters: { attackers: [], defenders: [] },
      finalCharacters: { attackers: [], defenders: [] },
    };
  },
  computed: {
    data() { return this.$store.state.portal.data; },
    shipsData() { return this.$store.state.portal.data.ship || []; },
    attackerTheme() { return this.themeOf('myrmezir'); },
    defenderTheme() { return this.themeOf('tetrarchy'); },
  },
  methods: {
    editTiles(rawTiles) {
      // Edit mode wants Array<null|{ship_key}>. Internal storage keeps the
      // ship_key strings (matches the wire format the backend expects).
      return rawTiles.map((k) => (k ? { ship_key: k } : null));
    },
    displayTilesFor(character) {
      if (!character || !character.army) return Array(TILE_COUNT).fill(null);
      return character.army.tiles.map((t) => (
        t.ship_status === 'filled' && t.ship
          ? { ship_key: t.ship.key, level: t.ship.level, units: t.ship.units }
          : null
      ));
    },
    finalCharacterFor(side, id) {
      return (this.finalCharacters[side] || []).find((c) => c.id === id);
    },
    activeIdxFor(side) {
      return this.activePicker && this.activePicker.side === side
        ? this.activePicker.idx
        : -1;
    },
    onPickTile(side, idx) {
      this.activePicker = { side, idx };
    },
    onClearTile(side, idx) {
      this.$set(this[side].tiles, idx, null);
      if (this.activePicker
          && this.activePicker.side === side
          && this.activePicker.idx === idx) {
        this.activePicker = null;
      }
    },
    onBump(side, idx, direction) {
      const current = this[side].tiles[idx];
      if (!current) return;
      const ship = this.shipsData.find((s) => s.key === current);
      if (!ship) return;
      const variants = this.shipsData
        .filter((s) => s.model === ship.model)
        .sort((a, b) => a.unit_count - b.unit_count);
      const i = variants.findIndex((s) => s.key === current);
      const next = direction === 'next' ? variants[i + 1] : variants[i - 1];
      if (next) this.$set(this[side].tiles, idx, next.key);
    },
    onPickShip(shipKey) {
      if (!this.activePicker) return;
      const { side, idx } = this.activePicker;
      this.$set(this[side].tiles, idx, shipKey);

      // Advance to the next empty slot on the same side. Mirrors the
      // in-game production picker's nextTile() flow — closes the picker
      // if every slot is filled.
      const tiles = this[side].tiles;
      let nextIdx = -1;
      for (let i = idx + 1; i < tiles.length; i += 1) {
        if (tiles[i] === null) { nextIdx = i; break; }
      }
      if (nextIdx === -1) {
        for (let i = 0; i < idx; i += 1) {
          if (tiles[i] === null) { nextIdx = i; break; }
        }
      }
      this.activePicker = nextIdx === -1 ? null : { side, idx: nextIdx };
    },
    async fight() {
      try {
        const { data } = await this.$axios.post(
          '/run-fight',
          { attacker: this.attacker, defender: this.defender },
        );
        const { initial, final, logs } = data;

        this.logs = logs;
        this.initialCharacters = initial;
        this.finalCharacters = final;
        this.activePicker = null;
      } catch (err) {
        this.$toastChangesetError(err);
      }
    },
    getShip(ref) {
      const characters = this.initialCharacters.attackers.concat(this.initialCharacters.defenders);
      const character = characters.find((c) => c.id === ref.character);
      const tile = character.army.tiles.find((t) => t.id === ref.tile);
      return {
        theme: this.theme(character.owner.faction),
        ...tile.ship,
      };
    },
    computeStrikes(actions) {
      const strikes = actions.reduce((acc1, action) => action.strikes.reduce((acc2, strike) => {
        if (strike.action === 'missed') {
          acc2.missed += 1;
        } else if (strike.action === 'hit') {
          acc2.hit += 1;
        } else if (strike.action === 'hit_and_crashed') {
          acc2.hit_and_crashed += 1;
        }
        acc2.damages += strike.damages;
        return acc2;
      }, acc1), { missed: 0, hit: 0, hit_and_crashed: 0, damages: 0 });

      return this.$tmd('panel.operations.fight_strike', {
        damages: Math.round(strikes.damages),
        hit_count: strikes.hit + strikes.hit_and_crashed,
        missed_count: strikes.missed,
        crashed_count: strikes.hit_and_crashed,
      });
    },
    theme(faction) {
      return this.themeOf(faction);
    },
    themeOf(factionKey) {
      const factions = this.$store.state.portal.data.faction || [];
      const f = factions.find((x) => x.key === factionKey);
      return f ? f.theme : 'dark-blue';
    },
  },
  components: {
    DefaultLayout,
    SimulatorArmy,
    SimulatorShipPicker,
  },
};
</script>

<style lang="scss" scoped>
.simulator-army-bloc {
  display: flex;
  justify-content: center;
}

.simulator-empty-hint {
  padding: 40px 20px;
  text-align: center;
  opacity: 0.6;
}

.simulator-results {
  padding: 20px;
}

.simulator-results-side {
  margin-bottom: 24px;

  h2 {
    margin: 0 0 8px 0;
  }
}

.simulator-results-army {
  margin-bottom: 12px;
}
</style>
