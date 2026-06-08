<template>
  <div
    class="army-container simulator-army"
    :class="[`f-${theme}`, mode === 'edit' ? 'is-edit-mode' : 'is-display-mode']">
    <div
      class="army-line"
      v-for="i in lineCount"
      :key="`line-${i}`">
      <div class="header">
        {{ $t('galaxy.selection.view.line_short', { n: i }) }}
      </div>
      <div
        v-for="j in armyLineSize"
        :key="`cell-${i}-${j}`">
        <template v-if="mode === 'edit'">
          <template v-if="getTile(i, j) === null">
            <div
              :class="{
                'is-hoverable': true,
                'is-active': activeIdx === tileIndex(i, j),
              }"
              class="tile"
              @click="$emit('pick-tile', tileIndex(i, j))">
            </div>
          </template>
          <template v-else>
            <div
              class="tile"
              :class="{ 'is-active': activeIdx === tileIndex(i, j) }"
              v-tooltip.bottom="editTooltip(i, j)">
              <svgicon
                class="tile-icon is-rotated"
                :name="`ship/${getTile(i, j).ship_key}`" />
              <div
                v-if="variantChain(getTile(i, j).ship_key).next"
                v-tooltip.right="$t('page.fight_simulator.increase_stack')"
                class="tile-toast is-hidden top left is-active simulator-arrow"
                @click.stop="$emit('bump-up', tileIndex(i, j))">
                <svgicon name="caret-up" />
              </div>
              <div
                v-else
                class="tile-toast is-hidden top left simulator-arrow is-disabled">
                <svgicon name="caret-up" />
              </div>
              <div
                v-if="variantChain(getTile(i, j).ship_key).prev"
                v-tooltip.right="$t('page.fight_simulator.reduce_stack')"
                class="tile-toast is-hidden bottom left is-active simulator-arrow"
                @click.stop="$emit('bump-down', tileIndex(i, j))">
                <svgicon name="caret-down" />
              </div>
              <div
                v-else
                class="tile-toast is-hidden bottom left simulator-arrow is-disabled">
                <svgicon name="caret-down" />
              </div>
              <div
                v-tooltip.right="$t('page.fight_simulator.remove_ship')"
                class="tile-toast is-hidden bottom right is-active"
                @click.stop="$emit('clear-tile', tileIndex(i, j))">
                <svgicon name="close" />
              </div>
            </div>
          </template>
        </template>

        <template v-else>
          <template v-if="getTile(i, j) === null">
            <div class="tile"></div>
          </template>
          <template v-else>
            <div
              class="tile"
              :class="{ 'is-destroyed': diff && diffEmpty(i, j) }"
              v-tooltip.bottom="displayTooltip(i, j)">
              <svgicon
                class="tile-icon is-rotated"
                :name="`ship/${getTile(i, j).ship_key}`" />
              <div
                v-if="hasLevel(i, j)"
                class="tile-level">
                {{ levelOf(i, j) }}
              </div>
              <div
                v-if="hasUnits(i, j)"
                class="life-container">
                <template v-if="!diff">
                  <div
                    class="life-content"
                    :style="{ height: tileLifePct(getTile(i, j)) + '%' }">
                  </div>
                </template>
                <template v-else>
                  <div
                    class="life-content is-fadded"
                    :style="{ height: tileLifePct(getTile(i, j)) + '%' }">
                  </div>
                  <div
                    v-if="!diffEmpty(i, j)"
                    class="life-content"
                    :style="{ height: tileLifePct(getDiffTile(i, j)) + '%' }">
                  </div>
                </template>
              </div>
            </div>
          </template>
        </template>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'simulator-army',
  props: {
    // Length 18. Each entry is null (empty slot) or
    // { ship_key: string, level?: number, units?: [{hull}] }.
    // Edit mode passes the lean shape ({ ship_key } only);
    // display mode passes initial-state tiles with units.
    tiles: {
      type: Array,
      required: true,
    },
    // Post-fight final state, same shape as `tiles`. null in edit mode.
    // When present, surviving ships show post-fight health overlaid on a
    // faded pre-fight bar (matches Army.vue's diff overlay).
    diff: {
      type: Array,
      default: null,
    },
    mode: {
      type: String,
      default: 'edit', // 'edit' | 'display'
    },
    theme: {
      type: String,
      default: 'dark-blue',
    },
    activeIdx: {
      type: Number,
      default: -1,
    },
  },
  data() {
    return {
      armyLineSize: 3,
    };
  },
  computed: {
    shipsData() {
      return this.$store.state.portal.data.ship || [];
    },
    lineCount() {
      return this.tiles.length / this.armyLineSize;
    },
  },
  methods: {
    tileIndex(line, nth) {
      return ((line - 1) * this.armyLineSize) + (nth - 1);
    },
    getTile(line, nth) {
      return this.tiles[this.tileIndex(line, nth)];
    },
    getDiffTile(line, nth) {
      return this.diff ? this.diff[this.tileIndex(line, nth)] : null;
    },
    diffEmpty(line, nth) {
      const d = this.getDiffTile(line, nth);
      return !d || d.ship_key == null;
    },
    hasLevel(line, nth) {
      const t = this.diff ? this.getDiffTile(line, nth) : this.getTile(line, nth);
      return t && typeof t.level === 'number';
    },
    levelOf(line, nth) {
      const t = this.diff ? this.getDiffTile(line, nth) : this.getTile(line, nth);
      if (!t || typeof t.level !== 'number') return '';
      return t.level + 1;
    },
    hasUnits(line, nth) {
      const t = this.getTile(line, nth);
      return t && Array.isArray(t.units) && t.units.length > 0;
    },
    tileLifePct(tile) {
      if (!tile || !Array.isArray(tile.units)) return 0;
      const shipData = this.shipsData.find((s) => s.key === tile.ship_key);
      if (!shipData) return 0;
      const max = shipData.unit_hull * shipData.unit_count;
      const cur = tile.units.reduce((acc, u) => acc + u.hull, 0);
      return Math.max(0, Math.min(100, (cur / max) * 100));
    },
    displayTooltip(line, nth) {
      const t = this.getTile(line, nth);
      if (!t) return '';
      const name = this.$t(`data.ship.${t.ship_key}.name`);
      if (this.diff && this.diffEmpty(line, nth)) {
        return `${name} — ${this.$t('page.fight_simulator.tile_destroyed')}`;
      }
      return name;
    },
    editTooltip(line, nth) {
      const t = this.getTile(line, nth);
      if (!t) return '';
      const ship = this.shipsData.find((s) => s.key === t.ship_key);
      const name = this.$t(`data.ship.${t.ship_key}.name`);
      const count = ship ? ship.unit_count : '?';
      return `${name} × ${count}`;
    },
    // Walk the model's variants sorted by unit_count ascending so we can
    // step in either direction. We deliberately don't use the merge_to
    // chain — there's no inverse link, but unit_count is monotonic per
    // model so sorting gives both directions for free.
    variantChain(shipKey) {
      const ship = this.shipsData.find((s) => s.key === shipKey);
      if (!ship) return { prev: null, next: null };
      const variants = this.shipsData
        .filter((s) => s.model === ship.model)
        .sort((a, b) => a.unit_count - b.unit_count);
      const idx = variants.findIndex((s) => s.key === shipKey);
      return {
        prev: idx > 0 ? variants[idx - 1].key : null,
        next: idx < variants.length - 1 ? variants[idx + 1].key : null,
      };
    },
  },
};
</script>

<style lang="scss" scoped>
.simulator-arrow {
  cursor: pointer;

  &.is-disabled {
    opacity: 0.3;
    cursor: default;
  }
}

// Theme-coloured frame around each side's fleet so the two players are
// instantly distinguishable. Colours hardcoded to match the faction palette
// in shared/variables.scss because the $themes-list map isn't visible from
// inside this scoped block.
.simulator-army {
  display: inline-block;
  padding: 4px;
  border-radius: 4px;
  border: solid 2px transparent;

  &.f-red {
    border-color: #bc2433;
    box-shadow: 0 0 8px rgba(188, 36, 51, 0.4);
  }

  &.f-dark-blue {
    border-color: #3f66df;
    box-shadow: 0 0 8px rgba(63, 102, 223, 0.4);
  }
}

// Bigger tiles in the simulator's edit grid so the ship icons read at a
// glance — the in-game 40px tiles are too cramped for this read-heavy view.
// 48×48 tile + tight margins keeps all 6 columns fitting inside the 380px
// side panel. Display mode (results) keeps the default 40px so the diff
// overlay stays compact alongside the per-round log.
.simulator-army.is-edit-mode {
  .army-line {
    margin-right: 0;

    .tile {
      margin: 4px 2px;
      width: 48px;
      height: 48px;

      .tile-icon {
        margin: 2px;
        width: 44px;
        height: 44px;
      }
    }
  }
}
</style>
