<template>
  <!-- The system's bodies and building tiles, drawn like the in-game
       system view's Bodies tab (same classes, see system/content.scss)
       but every tile is editable: click to select it, and hover a built
       tile for its level and removal shortcuts. -->
  <div
    class="planner-bodies"
    :class="{ 'is-compact': compact }">
    <div
      v-for="([body, path]) in primaryBodies"
      :key="path.join('-')"
      class="system-content-group"
      :class="{ active: hasBuilding(body) }">
      <div class="system-content-group-header">
        <div class="main">
          {{ bodyName(body, path) }}
          <span
            class="small"
            v-if="!hasTiles(body)">
            / {{ $t(`data.stellar_body.${body.type}.name`) }}
          </span>
        </div>
        <div
          v-if="bodyPopulation(path) > 0"
          class="secondary">
          <span
            class="potential-item"
            :class="{ 'f-1': bodyPopulation(path) < 5, 'f-5': bodyPopulation(path) > 12 }"
            v-tooltip="$t('data.bonus_pipeline_in.body_pop.name')">
            <span>{{ bodyPopulation(path) }}</span>
            <svgicon name="stellar_body/population" />
          </span>
        </div>
      </div>

      <div
        v-for="([item, itemPath]) in withSubBodies(body, path)"
        v-show="hasTiles(item)"
        :key="itemPath.join('-')"
        class="system-content-group-item">
        <div class="body-icon">
          <svgicon :name="`stellar_body/${item.type}`" />
        </div>
        <div class="body-info">
          <div class="body-info-type">
            {{ $t(`data.stellar_body.${item.type}.name`) }}
          </div>
          <div class="body-info-potentials">
            <button
              v-for="factor in factors"
              :key="factor.key"
              type="button"
              class="potential-item planner-factor"
              :class="`f-${item[factor.key]}`"
              v-tooltip="factorTooltip(factor)"
              @click="stepFactor(itemPath, factor.key, item[factor.key], 1)"
              @contextmenu.prevent="stepFactor(itemPath, factor.key, item[factor.key], -1)">
              <span>{{ item[factor.key] }}</span>
              <svgicon :name="factor.icon" />
            </button>
          </div>
        </div>
        <div class="body-tiles">
          <div
            v-for="slot in tileSlots(item, itemPath)"
            :key="slot.index"
            class="tile"
            :class="slot.classes"
            :role="slot.exists ? 'button' : null"
            :tabindex="slot.exists ? 0 : null"
            :aria-label="slot.label"
            v-tooltip="slot.warning"
            @click="slot.exists && $emit('select', { path: itemPath, tile: slot.index })"
            @keydown.enter.prevent="slot.exists && $emit('select', { path: itemPath, tile: slot.index })">
            <template v-if="slot.exists">
              <svgicon
                class="tile-icon"
                :class="slot.iconClasses"
                :name="slot.icon" />
              <div
                v-if="slot.tile.building_key"
                class="tile-level">
                {{ slot.tile.building_level }}
              </div>
              <template v-if="slot.tile.building_key">
                <div
                  v-if="slot.tile.building_status === 'damaged'"
                  class="tile-toast top left is-active"
                  v-tooltip="$t('page.system_planner.repair')"
                  @click.stop="$emit('repair', { path: itemPath, tile: slot.index })">
                  <svgicon name="check" />
                </div>
                <div
                  v-else-if="slot.canRaise"
                  class="tile-toast is-hidden top left is-active"
                  v-tooltip="$t('page.system_planner.level_up')"
                  @click.stop="$emit('level', { path: itemPath, tile: slot.index, level: slot.tile.building_level + 1 })">
                  <svgicon name="caret-up" />
                </div>
                <div
                  v-if="slot.tile.building_level > 1"
                  class="tile-toast is-hidden bottom left is-active"
                  v-tooltip.bottom="$t('page.system_planner.level_down')"
                  @click.stop="$emit('level', { path: itemPath, tile: slot.index, level: slot.tile.building_level - 1 })">
                  <svgicon name="caret-down" />
                </div>
                <div
                  v-if="slot.removable"
                  class="tile-toast is-hidden bottom right is-active"
                  v-tooltip.bottom="$t('page.system_planner.remove')"
                  @click.stop="$emit('remove', { path: itemPath, tile: slot.index })">
                  <svgicon name="close" />
                </div>
              </template>
            </template>
          </div>
        </div>
      </div>

      <!-- the selected tile's editor opens right under its body -->
      <div
        v-if="selected && selected.path[0] === path[0] && $scopedSlots.editor"
        ref="editor"
        class="planner-inline-editor">
        <slot name="editor" />
      </div>
    </div>
  </div>
</template>

<script>
import {
  walkBodies, tileType, maxLevel, infrastructureShortfall, needsInfrastructure,
} from '@/portal/planner/plan';

// The in-game view pads every body to 8 slots.
const SLOTS = 8;
// one in-game body row (icon, info, 8 tiles) plus the group padding
const ROW_WIDTH = 560;

export default {
  name: 'planner-bodies',
  props: {
    plan: { type: Object, required: true },
    data: { type: Object, required: true },
    // last computed system (bodies carry their share of the population)
    system: { type: Object, default: null },
    selected: { type: Object, default: null },
    // owned patents when research limits are on, else null
    patents: { type: Array, default: null },
  },
  data() {
    return {
      // narrower than one in-game body row: tiles wrap under the body
      compact: false,
      factors: [
        { key: 'industrial_factor', pipeline: 'body_ind', icon: 'stellar_body/industrial_factor' },
        { key: 'technological_factor', pipeline: 'body_tec', icon: 'stellar_body/technological_factor' },
        { key: 'activity_factor', pipeline: 'body_act', icon: 'stellar_body/activity_factor' },
      ],
    };
  },
  mounted() {
    if (window.ResizeObserver) {
      this.resizeObserver = new window.ResizeObserver(([entry]) => {
        this.compact = entry.contentRect.width < ROW_WIDTH;
      });
      this.resizeObserver.observe(this.$el);
    }
  },
  beforeDestroy() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
  },
  watch: {
    // the editor opens under the body: bring the body (tiles and
    // editor) to the top of the list when another body is picked
    selected(value, old) {
      if (!value || (old && old.path[0] === value.path[0])) return;
      this.$nextTick(() => {
        const group = this.$el.querySelectorAll(':scope > .system-content-group')[value.path[0]];
        if (group) group.scrollIntoView({ block: 'start', behavior: 'smooth' });
      });
    },
  },
  computed: {
    primaryBodies() {
      return this.plan.bodies.map((body, i) => [body, [i]]);
    },
  },
  methods: {
    withSubBodies(body, path) {
      return walkBodies([body]).map(([b, p]) => [b, [path[0], ...p.slice(1)]]);
    },
    hasTiles(body) {
      return body.tiles.length > 0;
    },
    hasBuilding(body) {
      return walkBodies([body]).some(([b]) => b.tiles.some((t) => t.building_key));
    },
    bodyName(body, path) {
      return body.name || this.$t('page.system_planner.body_name', { n: path[0] + 1 });
    },
    bodyPopulation(path) {
      const body = this.system && this.system.bodies && this.system.bodies[path[0]];
      return body && typeof body.population === 'number' ? body.population : 0;
    },
    biome(body) {
      const data = this.data.stellar_body.find((b) => b.key === body.type);
      return data ? data.biome : 'none';
    },
    factorTooltip(factor) {
      return `${this.$t(`data.bonus_pipeline_in.${factor.pipeline}.name`)}. ${this.$t('page.system_planner.factor_hint')}`;
    },
    stepFactor(path, key, value, step) {
      const next = ((value - 1 + step + 5) % 5) + 1;
      this.$emit('factor', { path, key, value: next });
    },
    isSelected(path, index) {
      return !!this.selected
        && this.selected.tile === index
        && this.selected.path.length === path.length
        && this.selected.path.every((v, i) => v === path[i]);
    },
    tileSlots(body, path) {
      const count = Math.max(SLOTS, body.tiles.length);
      return Array.from({ length: count }, (_, index) => {
        const tile = body.tiles[index];
        const slot = {
          index, tile, exists: !!tile, classes: [], iconClasses: [], icon: '', warning: null,
          canRaise: false, removable: false, label: null,
        };

        if (!tile) {
          slot.classes.push('is-transparent');
          return slot;
        }

        if (tileType(body, index) === 'infrastructure') slot.classes.push('is-important');
        if (this.isSelected(path, index)) slot.classes.push('is-active');
        slot.classes.push('is-hoverable');

        if (!tile.building_key) {
          slot.icon = `building/frame_${this.biome(body)}`;
          slot.iconClasses.push('is-transparent');
          slot.label = this.$t('page.system_planner.empty_tile');
          // the in-game "not yet" look: still buildable here
          if (needsInfrastructure(body, index)) {
            slot.classes.push('has-dashed-background');
            slot.warning = this.$t('page.system_planner.warning_needs_infrastructure');
          }
          return slot;
        }

        const building = this.data.building.find((b) => b.key === tile.building_key);
        slot.icon = `building/${tile.building_key}`;
        slot.label = `${this.$t(`data.building.${tile.building_key}.name`)} ${tile.building_level}`;
        slot.canRaise = !!building && tile.building_level < maxLevel(building, this.patents);
        slot.removable = !!building && building.type !== 'infrastructure';

        if (tile.building_status === 'damaged') {
          slot.classes.push('has-dashed-background');
          slot.iconClasses.push('is-transparent');
        }

        const shortfall = infrastructureShortfall(body, index);
        if (shortfall !== null) {
          slot.classes.push('has-warning');
          slot.warning = this.$t('page.system_planner.warning_infrastructure_level', { level: shortfall });
        } else if (needsInfrastructure(body, index)) {
          slot.classes.push('has-warning');
          slot.warning = this.$t('page.system_planner.warning_needs_infrastructure');
        }

        return slot;
      });
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-inline-editor {
  margin: 10px -10px -10px;
  border-top: solid 1px rgba(255, 255, 255, .1);
  background: rgba(0, 0, 0, .18);
}

// narrow: the tiles move under the body info
.planner-bodies.is-compact {
  .system-content-group-item {
    flex-wrap: wrap;
  }

  .body-info {
    flex: 1 1 auto;
    width: auto;
  }

  .body-tiles {
    flex: 1 1 100%;
    flex-wrap: wrap;
    gap: 2px 0;
    margin-top: 4px;
  }

  // the in-game padding to 8 slots would only wrap into an empty row
  .tile.is-transparent {
    display: none;
  }
}

// factor chips are buttons here (click +1, right-click -1)
.planner-factor {
  border: none;
  color: inherit;
  font: inherit;
  cursor: pointer;

  &:hover {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, .35);
  }
}

.tile {
  cursor: pointer;

  &:focus-visible {
    outline: solid 2px $white;
    outline-offset: 1px;
  }

  // a level the infrastructure doesn't allow yet, or a tile that needs
  // the infrastructure first: allowed in the planner, flagged with a
  // corner mark (the outline is the selection's)
  &.has-warning::after {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    border-top: solid 10px $color-alert;
    border-right: solid 10px transparent;
    pointer-events: none;
  }
}

.tile-toast {
  cursor: pointer;
}
</style>
