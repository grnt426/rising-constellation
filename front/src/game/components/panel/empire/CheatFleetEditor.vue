<template>
  <div class="cheat-fleet">
    <p
      v-if="!target"
      class="cheat-fleet-hint">
      {{ $t('panel.empire.cheats_fleet_no_target') }}
    </p>

    <template v-else>
      <div class="cheat-fleet-head">
        <span class="cheat-fleet-target">
          {{ $t('panel.empire.cheats_fleet_target', { name: target.name, owner: target.owner.name }) }}
        </span>
        <button
          class="cheat-fleet-button"
          @click="refresh(false)">
          {{ $t('panel.empire.cheats_fleet_refresh') }}
        </button>
        <button
          class="cheat-fleet-button"
          :disabled="!hasShips"
          @click="edit('fleet_clear', {})">
          {{ $t('panel.empire.cheats_fleet_clear') }}
        </button>
      </div>

      <div class="cheat-fleet-army">
        <simulator-army
          mode="edit"
          :ships="ships"
          :theme="theme"
          :tiles="tiles"
          :activeIdx="nextIdx"
          @clear-tile="removeShip"
          @bump-up="bump($event, 'next')"
          @bump-down="bump($event, 'prev')" />
      </div>

      <ul class="cheat-fleet-hotkeys">
        <li>{{ $t('panel.empire.cheats_fleet_hotkey_click') }}</li>
        <li><kbd>Shift</kbd> + {{ $t('panel.empire.cheats_fleet_hotkey_fill') }}</li>
        <li><kbd>Ctrl</kbd>+<kbd>Shift</kbd> + {{ $t('panel.empire.cheats_fleet_hotkey_override') }}</li>
      </ul>

      <simulator-ship-picker
        class="cheat-fleet-picker"
        :ships="ships"
        :theme="theme"
        :hint="$t('panel.empire.cheats_fleet_picker_hint')"
        :level="level"
        :stack-by-class="stackByClass"
        @update:level="level = $event"
        @update:stack="onUpdateStack"
        @pick="addShip" />
    </template>
  </div>
</template>

<script>
import SimulatorArmy from '@/portal/components/SimulatorArmy.vue';
import SimulatorShipPicker from '@/portal/components/SimulatorShipPicker.vue';

// What the grid shows of an army, comparable across the player channel's
// character ({ ship_status, ship }) and the cheat replies ({ status, ship_key }).
const signature = (tiles) => tiles
  .map((t) => [t.id, t.status, t.ship_key, t.level].join(':'))
  .sort()
  .join('|');

const fromCharacterTiles = (tiles) => tiles.map((t) => ({
  id: t.id,
  status: t.ship_status,
  ship_key: t.ship ? t.ship.key : null,
  level: t.ship ? t.ship.level : null,
}));

// Cheats tab fleet editor: instantly sets the ships of any deployed Navarch —
// the caller's own (selected) or anyone's (opened from a system view). The
// target sticks until another Navarch is selected or opened. The server
// places ships against the army as it stands (first empty tile; Shift and
// Ctrl+Shift widen that to the tile's line), so edits are sent one at a time
// and every reply carries the whole army.
export default {
  name: 'cheat-fleet-editor',
  data() {
    return {
      targetId: null, // Navarch being loaded or edited
      target: null, // { id, name, owner: { id, name, faction } } from the last reply
      fleet: [], // [{ id, status, ship_key, level }] sorted by tile id
      level: 0, // placement level, 0-indexed
      stackByClass: {}, // ship class -> chosen stack size
      queue: Promise.resolve(),
    };
  },
  computed: {
    ships() { return this.$store.state.game.data.ship || []; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    openedCharacter() { return this.$store.state.game.openedCharacter; },
    theme() {
      return this.target ? this.$store.getters['game/themeByKey'](this.target.owner.faction) : undefined;
    },
    // SimulatorArmy's shape: null (empty) | { ship_key, level, planned }
    tiles() {
      return this.fleet.map((t) => (t.status === 'empty'
        ? null
        : { ship_key: t.ship_key, level: t.level, planned: t.status === 'planned' }));
    },
    nextIdx() { return this.tiles.indexOf(null); },
    hasShips() { return this.fleet.some((t) => t.status === 'filled'); },
  },
  watch: {
    // Re-committed on every player refetch; only reload the grid when the
    // army actually changed (a fight, a finished ship, another edit).
    selectedCharacter(character) {
      if (character && character.id === this.targetId && character.army
        && signature(fromCharacterTiles(character.army.tiles)) === signature(this.fleet)) {
        return;
      }
      this.track(character);
    },
    openedCharacter(character) {
      this.track(character);
    },
  },
  mounted() {
    this.track(this.selectedCharacter || this.openedCharacter);
  },
  methods: {
    track(character) {
      if (character && character.type === 'admiral' && character.status === 'on_board') {
        this.targetId = character.id;
        this.refresh();
      }
    },
    refresh(quiet = true) {
      if (this.targetId !== null) this.send('fleet_get', {}, quiet);
    },
    edit(event, payload) {
      if (this.targetId !== null) this.send(event, payload, false);
    },
    addShip(shipKey, mods = {}) {
      this.edit('fleet_add_ship', {
        ship_key: shipKey,
        level: this.level,
        shift: !!mods.shift,
        ctrl: !!mods.ctrl,
      });
    },
    removeShip(idx) {
      this.edit('fleet_remove_ship', { tile_id: this.fleet[idx].id });
    },
    // Same stack stepping as the battle simulator: the model's variants
    // sorted by unit count.
    bump(idx, direction) {
      const tile = this.fleet[idx];
      const ship = this.ships.find((s) => s.key === tile.ship_key);
      if (!ship) return;
      const variants = this.ships
        .filter((s) => s.model === ship.model)
        .sort((a, b) => a.unit_count - b.unit_count);
      const i = variants.findIndex((s) => s.key === ship.key);
      const next = direction === 'next' ? variants[i + 1] : variants[i - 1];
      if (next) {
        this.edit('fleet_set_ship', { tile_id: tile.id, ship_key: next.key, level: tile.level });
      }
    },
    onUpdateStack({ category, size }) {
      this.$set(this.stackByClass, category, size);
    },
    // One request at a time, in click order. Replies for a Navarch that is
    // no longer the target are dropped.
    send(event, payload, quiet) {
      const characterId = this.targetId;
      const fail = (reason) => { if (!quiet) this.$toastError(reason); };

      this.queue = this.queue.then(() => new Promise((resolve) => {
        const channel = this.$socket.joinCheat();
        if (!channel) {
          fail(this.$t('panel.empire.cheats_channel_error'));
          resolve();
          return;
        }

        channel.push(event, { ...payload, character_id: characterId })
          .receive('ok', (reply) => {
            if (reply.character.id === this.targetId) {
              this.target = reply.character;
              this.fleet = reply.tiles.slice().sort((a, b) => a.id - b.id);
            }
            resolve();
          })
          .receive('error', (data) => {
            // the Navarch is gone (destroyed, back in the deck): drop it
            if (event === 'fleet_get' && characterId === this.targetId) {
              this.targetId = null;
              this.target = null;
              this.fleet = [];
            }
            fail(String((data && data.reason) || 'error'));
            resolve();
          })
          .receive('timeout', () => {
            fail(this.$t('panel.empire.cheats_channel_error'));
            resolve();
          });
      }));
    },
  },
  components: {
    SimulatorArmy,
    SimulatorShipPicker,
  },
};
</script>

<style scoped>
.cheat-fleet-hint {
  opacity: 0.6;
}
.cheat-fleet-head {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
}
.cheat-fleet-target {
  flex: 1 1 auto;
}
.cheat-fleet-button {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
  padding: 6px 10px;
  font: inherit;
  cursor: pointer;
}
.cheat-fleet-button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.15);
}
.cheat-fleet-button:disabled {
  opacity: 0.4;
  cursor: default;
}
.cheat-fleet-army {
  display: flex;
  justify-content: center;
  margin: 12px 0;
}
.cheat-fleet-hotkeys {
  list-style: none;
  margin: 0;
  padding: 0;
  opacity: 0.85;
}
.cheat-fleet-hotkeys li {
  margin-bottom: 4px;
}
.cheat-fleet-hotkeys kbd {
  display: inline-block;
  padding: 1px 6px;
  border-radius: 3px;
  border: solid 1px rgba(255, 255, 255, 0.35);
  background: rgba(255, 255, 255, 0.1);
}
.cheat-fleet .cheat-fleet-picker {
  padding: 12px 0 0;
}
</style>
