<template>
  <default-layout>
    <div class="fluid-panel">
      <!-- LEFT RAIL: both fleets, stacked -->
      <v-scrollbar class="panel-aside">
        <div
          v-for="s in sides"
          :key="`edit-${s.name}`">
          <div class="panel-aside-info">
            <h2>{{ $t('page.fight_simulator.player', {number: s.number}) }}</h2>
            <p>{{ $t(`page.fight_simulator.${s.name}`) }}</p>
          </div>

          <div class="panel-aside-bloc simulator-fleet-actions">
            <button
              class="default-button is-small"
              @click="clearAll(s.name)">
              {{ $t('page.fight_simulator.clear_all') }}
            </button>
          </div>

          <div class="panel-aside-bloc simulator-army-bloc">
            <simulator-army
              mode="edit"
              :theme="s.theme"
              :tiles="s.data.tiles"
              :activeIdx="activeIdxFor(s.name)"
              @pick-tile="onPickTile(s.name, $event)"
              @clear-tile="onClearTile(s.name, $event)"
              @bump-up="onBump(s.name, $event, 'next')"
              @bump-down="onBump(s.name, $event, 'prev')"
              @hover="onHoverShip" />
          </div>

          <hr class="margin">
        </div>
      </v-scrollbar>

      <div class="panel-content is-full-sized">
        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.fight_simulator.title') }}</strong>
          </h1>

          <div class="simulator-balance default-input">
            <label for="balance_preset">{{ $t('page.fight_simulator.balance') }}</label>
            <select id="balance_preset" v-model="balance">
              <option value="baseline">{{ $t('page.fight_simulator.balance_baseline') }}</option>
              <option value="hard_counter_rps">{{ $t('page.fight_simulator.balance_hard_counter_rps') }}</option>
            </select>
          </div>

          <button
            @click="fight"
            class="default-button simulator-launch">
            {{ $t('page.fight_simulator.launch') }}
          </button>
        </div>

        <v-scrollbar class="content">
          <simulator-ship-picker
            v-if="activePicker"
            :theme="activePicker.side === 'attacker' ? attackerTheme : defenderTheme"
            :level="placementLevel"
            :stack-by-class="stackByClass"
            @update:level="placementLevel = $event"
            @update:stack="onUpdateStack"
            @pick="onPickShip"
            @hover="onHoverShip" />

          <div
            v-else-if="logs"
            class="simulator-results">
            <div class="simulator-tabs">
              <button
                class="simulator-tab"
                :class="{ 'is-active': resultTab === 'log' }"
                @click="resultTab = 'log'">
                {{ $t('page.fight_simulator.tab_log') }}
              </button>
              <button
                class="simulator-tab"
                :class="{ 'is-active': resultTab === 'debug' }"
                @click="resultTab = 'debug'">
                {{ $t('page.fight_simulator.tab_debug') }}
              </button>
            </div>

            <template v-if="resultTab === 'log'">
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
                    <simulator-round-log
                      :round="round"
                      :get-ship="getShip"
                      :compute-strikes="computeStrikes" />
                  </div>
                </div>
              </div>
            </template>

            <simulator-debug-view
              v-else
              :round-states="roundStates"
              :logs="logs"
              :get-ship="getShip"
              :compute-strikes="computeStrikes" />

            <hr class="margin">
          </div>

          <div
            v-else
            class="simulator-empty-hint">
            {{ $t('page.fight_simulator.empty_hint') }}
          </div>
        </v-scrollbar>
      </div>

      <!-- RIGHT RAIL: hotkeys + ship info card -->
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-info">
          <h2>{{ $t('page.fight_simulator.controls') }}</h2>
        </div>

        <div class="panel-aside-bloc simulator-hotkeys">
          <ul>
            <li><kbd>Shift</kbd> + {{ $t('page.fight_simulator.hotkey_fill') }}</li>
            <li><kbd>Ctrl</kbd>+<kbd>Shift</kbd> + {{ $t('page.fight_simulator.hotkey_override') }}</li>
          </ul>
        </div>

        <hr class="margin">

        <div class="panel-aside-bloc simulator-info-card">
          <template v-if="infoShip">
            <h3>{{ $t(`data.ship.${infoShip.key}.name`) }}</h3>
            <div class="info-sub">{{ infoShip.class }} · ×{{ infoShip.unit_count }}</div>
            <table class="info-stats">
              <tr
                v-for="st in infoStats"
                :key="st.label"
                :class="{ 'is-changed': st.changed }">
                <td>{{ st.label }}</td>
                <td>
                  <template v-if="st.changed">
                    <span class="base-val">{{ st.base }}</span>
                    <span class="arrow">→</span>
                    <span class="tuned-val">{{ st.tuned }}</span>
                  </template>
                  <template v-else>{{ st.tuned }}</template>
                </td>
              </tr>
            </table>
            <p class="info-note">{{ $t('page.fight_simulator.info_note') }}</p>
          </template>
          <p
            v-else
            class="info-hint">
            {{ $t('page.fight_simulator.info_hint') }}
          </p>
        </div>
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import SimulatorArmy from '@/portal/components/SimulatorArmy.vue';
import SimulatorShipPicker from '@/portal/components/SimulatorShipPicker.vue';
import SimulatorRoundLog from '@/portal/components/SimulatorRoundLog.vue';
import SimulatorDebugView from '@/portal/components/SimulatorDebugView.vue';

const TILE_COUNT = 18;
const LINE_SIZE = 3;

export default {
  name: 'fight-simulator',
  data() {
    return {
      // tiles: Array<null | { ship_key, level }>. level is 0-indexed (combat
      // reads it directly; the army tile shows level + 1).
      attacker: { tiles: Array(TILE_COUNT).fill(null) },
      defender: { tiles: Array(TILE_COUNT).fill(null) },
      placementLevel: 0, // level newly-placed ships get (0-indexed)
      stackByClass: {}, // class -> chosen stack size; held here so it survives the picker closing
      balance: 'baseline', // 'baseline' (live data) | a Sim.Balance preset
      balancePresets: {}, // { presetName: { baseShipKey: { field: value } } }, from the API
      activePicker: null, // { side: 'attacker'|'defender', idx: number }
      infoShipKey: null, // last hovered/clicked ship, shown in the right rail
      resultTab: 'log', // 'log' | 'debug' (results view tab)
      logs: null,
      initialCharacters: { attackers: [], defenders: [] },
      finalCharacters: { attackers: [], defenders: [] },
    };
  },
  async created() {
    try {
      const { data } = await this.$axios.get('/fight-balances');
      this.balancePresets = data;
    } catch (e) {
      // Non-fatal: the info card just falls back to base stats with no deltas.
    }
  },
  computed: {
    data() { return this.$store.state.portal.data; },
    shipsData() { return this.$store.state.portal.data.ship || []; },
    attackerTheme() { return this.themeOf('myrmezir'); },
    defenderTheme() { return this.themeOf('tetrarchy'); },
    infoShip() {
      if (!this.infoShipKey) return null;
      return this.shipsData.find((s) => s.key === this.infoShipKey) || null;
    },
    // Drives the stacked left-rail fleets. Avoids `this[side]` in the template:
    // inside a v-for render callback `this` isn't the component, so indexing it
    // throws (black screen on mount).
    sides() {
      return [
        { name: 'attacker', number: 1, data: this.attacker, theme: this.attackerTheme },
        { name: 'defender', number: 2, data: this.defender, theme: this.defenderTheme },
      ];
    },
    // Right-rail stat rows for the hovered ship, reflecting the selected balance
    // mode: base value, the preset-tuned value, and whether it changed.
    infoStats() {
      if (!this.infoShip) return [];
      const s = this.infoShip;
      const ov = this.overridesFor(s.key) || {};
      const t = (key) => this.$t(`page.fight_simulator.${key}`);
      const num = (field, label) => {
        const base = field === 'unit_armor' ? (s[field] || 0) : s[field];
        const tuned = ov[field] !== undefined ? ov[field] : base;
        return { label, base, tuned, changed: tuned !== base };
      };
      const str = (field, label) => {
        const base = this.strikes(s[field]);
        const tuned = ov[field] !== undefined ? this.strikes(ov[field]) : base;
        return { label, base, tuned, changed: tuned !== base };
      };
      return [
        num('unit_handling', t('stat_handling')),
        num('unit_hull', t('stat_hull')),
        num('unit_shield', t('stat_shield')),
        num('unit_interception', t('stat_flak')),
        num('unit_armor', t('stat_armor')),
        str('unit_energy_strikes', t('stat_energy')),
        str('unit_explosive_strikes', t('stat_explosive')),
        num('unit_raid_coef', t('stat_raid')),
      ];
    },
    // Per-round battle snapshots for the Debug View, replayed once from the
    // action log + initial state. This is a computed, so Vue caches it until a
    // new fight changes `logs` — round navigation never re-runs the replay, and
    // it needs no extra API calls (everything comes from the one /run-fight).
    roundStates() {
      const rounds = this.logs || [];
      const initial = this.initialCharacters;
      const chars = (initial.attackers || []).concat(initial.defenders || []);

      const charSide = {};
      (initial.attackers || []).forEach((c) => { charSide[c.id] = 'attackers'; });
      (initial.defenders || []).forEach((c) => { charSide[c.id] = 'defenders'; });

      // Mutable per-tile state + a stable display order per side.
      const state = {};
      const order = { attackers: [], defenders: [] };
      chars.forEach((c) => {
        const side = charSide[c.id];
        (c.army.tiles || []).forEach((tile) => {
          if (tile.ship_status === 'filled' && tile.ship) {
            const maxHp = (tile.ship.units || []).reduce((a, u) => a + u.hull, 0);
            const key = `${c.id}:${tile.id}`;
            state[key] = {
              key,
              ship_key: tile.ship.key,
              level: tile.ship.level,
              maxHp,
              hp: maxHp,
              onField: false,
              escaped: false, // morale broke -> routing/routed
              destroyed: false,
              withdrawn: false, // survived to the end and stood down to the army
            };
            if (order[side]) order[side].push(key);
          }
        });
      });

      const refKey = (ref) => `${ref.character}:${ref.tile}`;
      const snapshots = [];

      rounds.forEach((actions, ri) => {
        const dmg = { attackers: {}, defenders: {} };

        (actions || []).forEach((action) => {
          if (action.type === 'transfer') {
            const st = state[refKey(action.source)];
            if (st) {
              // 'field' = deployed in; 'army' = pulled out (mid-battle this only
              // happens to a routed ship the turn after it breaks).
              st.onField = action.data.target === 'field';
            }
          } else if (action.type === 'destroyed') {
            const st = state[refKey(action.source)];
            if (st) { st.destroyed = true; st.hp = 0; st.onField = false; }
          } else if (action.type === 'escaping') {
            // Morale broke: the ship is routing. It STAYS on the field this turn
            // (still targetable — that's why it keeps taking damage) and is pulled
            // to the army by next turn's cleaning (a transfer -> army event).
            const st = state[refKey(action.source)];
            if (st) st.escaped = true;
          } else if (action.type === 'attack') {
            const dealt = (action.data.actions || []).reduce(
              (sum, a) => sum + (a.strikes || []).reduce((s, k) => s + (k.damages || 0), 0),
              0,
            );
            const tgt = state[refKey(action.data.target)];
            if (tgt) tgt.hp = Math.max(0, tgt.hp - dealt);
            const sideOfSrc = charSide[action.source.character];
            const src = state[refKey(action.source)];
            if (src && sideOfSrc) {
              dmg[sideOfSrc][src.ship_key] = (dmg[sideOfSrc][src.ship_key] || 0) + dealt;
            }
          }
        });

        const snapSide = (side) => order[side].map((k) => ({ ...state[k] }));
        const dmgSide = (side) => Object.keys(dmg[side])
          .map((shipKey) => ({ ship_key: shipKey, total: Math.round(dmg[side][shipKey]) }))
          .sort((a, b) => b.total - a.total);

        snapshots.push({
          round: ri + 1,
          attackers: snapSide('attackers'),
          defenders: snapSide('defenders'),
          damage: { attackers: dmgSide('attackers'), defenders: dmgSide('defenders') },
        });
      });

      // When the battle resolves (or hits the turn cap) the engine returns the
      // alive on-field survivors to the army — a withdrawal that happens AFTER
      // the last per-round log flush, so it never appears in `logs`. Synthesize
      // it on the final snapshot so survivors read "Withdrawn" instead of being
      // frozen mid-fight as "On field".
      const last = snapshots[snapshots.length - 1];
      if (last) {
        ['attackers', 'defenders'].forEach((side) => {
          last[side].forEach((t) => {
            if (t.onField && !t.destroyed) {
              t.onField = false;
              // Non-routed survivors stood down; routed ones already read as
              // withdrawn once off-field (see SimulatorDebugView.statusOf).
              if (!t.escaped) t.withdrawn = true;
            }
          });
        });
      }

      return snapshots;
    },
  },
  methods: {
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
    clearAll(side) {
      this[side].tiles = Array(TILE_COUNT).fill(null);
      if (this.activePicker && this.activePicker.side === side) {
        this.activePicker = null;
      }
    },
    onBump(side, idx, direction) {
      const current = this[side].tiles[idx];
      if (!current) return;
      const ship = this.shipsData.find((s) => s.key === current.ship_key);
      if (!ship) return;
      const variants = this.shipsData
        .filter((s) => s.model === ship.model)
        .sort((a, b) => a.unit_count - b.unit_count);
      const i = variants.findIndex((s) => s.key === current.ship_key);
      const next = direction === 'next' ? variants[i + 1] : variants[i - 1];
      if (next) this.$set(this[side].tiles, idx, { ship_key: next.key, level: current.level });
    },
    onPickShip(shipKey, mods = {}) {
      this.infoShipKey = shipKey;
      if (!this.activePicker) return;
      const { side, idx } = this.activePicker;
      const tiles = this[side].tiles;
      const make = () => ({ ship_key: shipKey, level: this.placementLevel });

      // Shift: fill the active slot's column / L-group (LINE_SIZE tiles), empty
      // slots only — unless Ctrl is also held (override). Other columns untouched.
      if (mods.shift) {
        const start = Math.floor(idx / LINE_SIZE) * LINE_SIZE;
        for (let i = start; i < start + LINE_SIZE; i += 1) {
          if (mods.ctrl || tiles[i] === null) this.$set(tiles, i, make());
        }
      } else {
        this.$set(tiles, idx, make());
      }

      // In every case advance the selector to the next column over (same row),
      // so you can place/fill column by column.
      this.advanceSelector(side, idx);
    },
    // Slot order that steps across columns first (next column, same row), then
    // down a row: for LINE_SIZE 3 over 18 tiles this is
    // [0,3,6,9,12,15, 1,4,7,10,13,16, 2,5,8,11,14,17].
    columnFirstOrder() {
      const cols = TILE_COUNT / LINE_SIZE;
      const order = [];
      for (let row = 0; row < LINE_SIZE; row += 1) {
        for (let col = 0; col < cols; col += 1) {
          order.push((col * LINE_SIZE) + row);
        }
      }
      return order;
    },
    advanceSelector(side, fromIdx) {
      const order = this.columnFirstOrder();
      const tiles = this[side].tiles;
      const pos = order.indexOf(fromIdx);
      for (let k = 1; k <= order.length; k += 1) {
        const nextIdx = order[(pos + k) % order.length];
        if (tiles[nextIdx] === null) {
          this.activePicker = { side, idx: nextIdx };
          return;
        }
      }
      this.activePicker = null; // fleet full
    },
    // The selected balance preset's overrides for a ship key, matching the base
    // key or any of its stack variants (e.g. corvette_1 -> corvette_1v2).
    overridesFor(shipKey) {
      const preset = this.balancePresets[this.balance];
      if (!preset) return null;
      const baseKey = Object.keys(preset).find(
        (k) => shipKey === k || shipKey.startsWith(`${k}v`),
      );
      return baseKey ? preset[baseKey] : null;
    },
    onHoverShip(shipKey) {
      if (shipKey) this.infoShipKey = shipKey;
    },
    onUpdateStack({ category, size }) {
      this.$set(this.stackByClass, category, size);
    },
    async fight() {
      try {
        const { data } = await this.$axios.post(
          '/run-fight',
          { attacker: this.attacker, defender: this.defender, balance: this.balance },
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
    // Compact strike-list label: "2×6", "1×23", or "—" when empty. Mixed sizes
    // (rare) fall back to a slash-joined list.
    strikes(list) {
      if (!Array.isArray(list) || list.length === 0) return '—';
      const allEqual = list.every((d) => d === list[0]);
      return allEqual ? `${list.length}×${list[0]}` : list.join('/');
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
    SimulatorRoundLog,
    SimulatorDebugView,
  },
};
</script>

<style lang="scss" scoped>
.simulator-army-bloc {
  display: flex;
  justify-content: center;
}

.simulator-fleet-actions {
  display: flex;
  justify-content: center;
  padding-top: 8px;
}

.panel-header {
  display: flex;
  align-items: center;
  gap: 16px;
}

.simulator-balance {
  display: flex;
  align-items: center;
  gap: 8px;
}

.simulator-launch {
  margin-left: auto;
}

.simulator-empty-hint {
  padding: 40px 20px;
  text-align: center;
  opacity: 0.6;
}

.simulator-results {
  padding: 20px;
}

.simulator-tabs {
  display: flex;
  gap: 4px;
  margin-bottom: 16px;
  border-bottom: solid 1px rgba(255, 255, 255, 0.1);
}

.simulator-tab {
  background: none;
  border: none;
  border-bottom: solid 2px transparent;
  padding: 8px 16px;
  cursor: pointer;
  color: inherit;
  opacity: 0.6;
  font-size: 1rem;

  &.is-active {
    opacity: 1;
    border-bottom-color: currentColor;
    font-weight: bold;
  }
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

.simulator-hotkeys {
  font-size: 0.95rem;
  opacity: 0.95;

  ul {
    margin: 0;
    padding-left: 0;
    list-style: none;
  }

  li {
    margin-bottom: 8px;
    line-height: 1.5;
  }

  kbd {
    display: inline-block;
    padding: 1px 6px;
    border-radius: 3px;
    border: solid 1px rgba(255, 255, 255, 0.35);
    background: rgba(255, 255, 255, 0.1);
    font-size: 0.9rem;
  }
}

.simulator-info-card {
  h3 {
    margin: 0 0 2px 0;
  }

  .info-sub {
    opacity: 0.6;
    text-transform: capitalize;
    margin-bottom: 10px;
  }

  .info-stats {
    width: 100%;
    border-collapse: collapse;

    td {
      padding: 3px 0;
      border-bottom: solid 1px rgba(255, 255, 255, 0.06);
    }

    td:first-child {
      opacity: 0.6;
    }

    td:last-child {
      text-align: right;
      font-weight: bold;
    }

    .base-val {
      opacity: 0.45;
      text-decoration: line-through;
      font-weight: normal;
    }

    .arrow {
      opacity: 0.45;
      margin: 0 4px;
    }

    .tuned-val {
      font-weight: bold;
    }

    tr.is-changed td:first-child {
      opacity: 0.85;
    }
  }

  .info-note {
    margin-top: 10px;
    font-size: 0.85rem;
    opacity: 0.7;
  }

  .info-hint {
    opacity: 0.5;
  }
}
</style>
