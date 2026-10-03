<template>
  <!-- The selected tile: its building's card (the in-game BuildingCard;
       a level pip builds that level), level and state controls, and what
       else the tile can hold. Hovering a choice previews its card. -->
  <div class="planner-tile-panel">
    <p
      v-if="!tile"
      class="planner-hint">
      {{ $t('page.system_planner.select_tile_hint') }}
    </p>

    <template v-else>
      <div class="planner-tile-head">
        <div class="planner-tile-title">
          <strong>{{ bodyLabel }}</strong>
          <span class="planner-tile-sub">{{ tileLabel }}</span>
        </div>

        <div
          v-if="tile.building_key"
          class="planner-tile-actions">
          <div
            class="planner-stepper"
            :aria-label="$t('page.system_planner.level')">
            <button
              type="button"
              :disabled="tile.building_level <= 1"
              v-tooltip="$t('page.system_planner.level_down')"
              @click="setLevel(tile.building_level - 1)">−</button>
            <span>{{ $t('page.system_planner.level_n', { n: tile.building_level, max: levelCount }) }}</span>
            <!-- aria-disabled: a disabled button gets no hover, and the
                 tooltip names the patent the next level needs -->
            <button
              type="button"
              :aria-disabled="tile.building_level >= levelCap ? 'true' : null"
              v-tooltip="raiseTooltip"
              @click="setLevel(tile.building_level + 1)">+</button>
          </div>
          <button
            type="button"
            class="default-button is-small"
            v-tooltip="$t('page.system_planner.damaged_hint')"
            @click="$emit('damage', { ...selected, damaged: tile.building_status !== 'damaged' })">
            {{ tile.building_status === 'damaged'
              ? $t('page.system_planner.repair')
              : $t('page.system_planner.mark_damaged') }}
          </button>
          <button
            v-if="removable"
            type="button"
            class="default-button is-small"
            @click="$emit('remove', selected)">
            {{ $t('page.system_planner.remove') }}
          </button>
        </div>
      </div>

      <p
        v-for="warning in warnings"
        :key="warning"
        class="planner-tile-warning">
        {{ warning }}
      </p>

      <div class="planner-tile-body">
        <!-- always laid out, card or not: a hover preview appearing
             must never push the choices out from under the pointer -->
        <div
          ref="card"
          class="planner-tile-card"
          :style="{ width: `${cardWidth * cardZoom}px` }">
          <p
            v-if="!cardKey"
            class="planner-card-placeholder">
            {{ $t('page.system_planner.card_hint') }}
          </p>
          <div
            v-else
            :style="{ zoom: cardZoom }">
            <building-card
              :key="cardKey"
              :buildingKey="cardKey"
              :level="cardLevel"
              :body="cardBody"
              :system="system || undefined"
              :theme="theme"
              :context="preview ? 'preview' : 'built'"
              show-cost
              @pick-level="pickLevel" />
          </div>
        </div>

        <div class="planner-choices">
          <div class="planner-choices-head">
            <span>{{ tile.building_key ? $t('page.system_planner.replace_with') : $t('page.system_planner.build') }}</span>
            <div
              v-if="maxLevels > 1"
              class="planner-placement"
              v-tooltip="$t('page.system_planner.placement_level_hint')">
              <span class="planner-placement-label">{{ $t('page.system_planner.placement_level') }}</span>
              <button
                v-for="n in maxLevels"
                :key="n"
                type="button"
                class="planner-placement-pip"
                :class="{ 'is-active': n === placementLevel }"
                @click="$emit('update:placementLevel', n)">{{ n }}</button>
            </div>
          </div>

          <div
            v-if="choices.length"
            class="planner-choices-grid">
            <button
              v-for="choice in choices"
              :key="choice.building.key"
              type="button"
              class="planner-choice"
              :class="[`is-${choice.status}`, { 'is-current': choice.building.key === tile.building_key }]"
              :aria-disabled="choice.status !== 'buildable' ? 'true' : null"
              v-tooltip="choiceTooltip(choice)"
              @mouseenter="preview = choice.building.key"
              @mouseleave="preview = null"
              @focus="preview = choice.building.key"
              @blur="preview = null"
              @click="place(choice)">
              <span class="tile">
                <svgicon
                  class="tile-icon"
                  :class="{ 'is-transparent': choice.status !== 'buildable' }"
                  :name="`building/${choice.building.key}`" />
              </span>
              <span class="planner-choice-name">{{ $t(`data.building.${choice.building.key}.name`) }}</span>
              <span
                v-if="choice.building.workforce > 0"
                class="planner-choice-workforce">
                {{ choice.building.workforce }}
                <svgicon name="resource/population" />
              </span>
            </button>
          </div>
          <p
            v-else
            class="planner-hint">
            {{ $t('page.system_planner.no_choices') }}
          </p>
        </div>
      </div>
    </template>
  </div>
</template>

<script>
import BuildingCard from '@/game/components/card/BuildingCard.vue';
import {
  bodyAt, buildingChoices, maxLevel, tileType, infrastructureShortfall, needsInfrastructure,
} from '@/portal/planner/plan';

const CARD_WIDTH = 300;

export default {
  name: 'planner-tile-panel',
  props: {
    plan: { type: Object, required: true },
    data: { type: Object, required: true },
    system: { type: Object, default: null },
    selected: { type: Object, default: null },
    patents: { type: Array, default: null },
    theme: { type: String, default: 'none' },
    placementLevel: { type: Number, default: 1 },
  },
  data() {
    return {
      preview: null,
      cardZoom: 1,
      cardWidth: CARD_WIDTH,
    };
  },
  computed: {
    body() { return this.selected ? bodyAt(this.plan, this.selected.path) : null; },
    tile() { return this.body ? this.body.tiles[this.selected.tile] || null : null; },
    building() {
      return this.tile && this.tile.building_key
        ? this.data.building.find((b) => b.key === this.tile.building_key)
        : null;
    },
    levelCount() { return this.building ? this.building.levels.length : 0; },
    levelCap() { return this.building ? maxLevel(this.building, this.patents) : 0; },
    removable() { return !!this.building && this.building.type !== 'infrastructure'; },
    raiseTooltip() {
      if (this.building && this.tile.building_level < this.levelCount && this.tile.building_level >= this.levelCap) {
        const { patent } = this.building.levels[this.tile.building_level];
        return this.$t('production.patent_needed', { patentName: this.$t(`data.patent.${patent}.name`) });
      }
      return this.$t('page.system_planner.level_up');
    },
    bodyLabel() {
      if (!this.body) return '';
      return this.body.name || this.$t(`data.stellar_body.${this.body.type}.name`);
    },
    tileLabel() {
      const n = this.selected.tile + 1;
      return tileType(this.body, this.selected.tile) === 'infrastructure'
        ? this.$t('page.system_planner.tile_infrastructure', { n })
        : this.$t('page.system_planner.tile_n', { n });
    },
    warnings() {
      const list = [];
      const shortfall = infrastructureShortfall(this.body, this.selected.tile);
      if (shortfall !== null) list.push(this.$t('page.system_planner.warning_infrastructure_level', { level: shortfall }));
      if (needsInfrastructure(this.body, this.selected.tile)) list.push(this.$t('page.system_planner.warning_needs_infrastructure'));
      return list;
    },
    choices() {
      if (!this.tile) return [];
      return buildingChoices(this.plan, this.data, this.selected.path, this.selected.tile, this.patents);
    },
    maxLevels() {
      return this.choices.reduce((max, c) => Math.max(max, c.building.levels.length), 1);
    },
    cardKey() { return this.preview || (this.tile && this.tile.building_key) || null; },
    cardLevel() {
      if (this.preview) {
        const building = this.data.building.find((b) => b.key === this.preview);
        return this.levelFor(building);
      }
      return this.tile.building_level;
    },
    // the computed body: it carries its share of the population, which
    // per-population bonuses multiply
    cardBody() {
      const sys = this.system;
      if (!sys || !sys.bodies) return this.body;
      const [top, sub] = this.selected.path;
      const computed = sub === undefined ? sys.bodies[top] : (sys.bodies[top] || { bodies: [] }).bodies[sub];
      return computed || this.body;
    },
  },
  watch: {
    selected() { this.preview = null; },
    cardKey() { this.$nextTick(this.updateCardZoom); },
  },
  mounted() {
    if (window.ResizeObserver) {
      this.resizeObserver = new window.ResizeObserver(() => this.updateCardZoom());
      this.resizeObserver.observe(this.$el);
    }
  },
  beforeDestroy() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
  },
  methods: {
    // the card is a fixed 300px: shrink it on narrow screens
    updateCardZoom() {
      const width = this.$el ? this.$el.clientWidth : 0;
      this.cardZoom = width && width < CARD_WIDTH + 20 ? Math.max(0.6, (width - 20) / CARD_WIDTH) : 1;
    },
    levelFor(building) {
      if (!building) return 1;
      return Math.max(1, Math.min(this.placementLevel, maxLevel(building, this.patents) || 1));
    },
    setLevel(level) {
      if (level < 1 || level > this.levelCap || level === this.tile.building_level) return;
      this.$emit('level', { ...this.selected, level });
    },
    pickLevel(level) {
      if (this.preview) return;
      if (level > this.levelCap) {
        this.$toasted.info(this.raiseTooltipFor(level));
        return;
      }
      this.setLevel(level);
    },
    raiseTooltipFor(level) {
      const { patent } = this.building.levels[level - 1];
      return this.$t('production.patent_needed', { patentName: this.$t(`data.patent.${patent}.name`) });
    },
    place(choice) {
      if (choice.status !== 'buildable') return;
      this.$emit('place', { ...this.selected, key: choice.building.key, level: this.levelFor(choice.building) });
      this.preview = null;
    },
    choiceTooltip(choice) {
      if (choice.reason === 'patent') {
        return this.$t('production.patent_needed', { patentName: this.$t(`data.patent.${choice.patent}.name`) });
      }
      if (choice.reason === 'unique_body') return this.$t('production.unique_building');
      if (choice.reason === 'unique_system') return this.$t('production.unique_system');
      return null;
    },
  },
  components: {
    BuildingCard,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-tile-panel {
  padding: 16px 20px 24px;
}

.planner-hint {
  margin: 0;
  padding: 12px 0;
  opacity: .6;
}

.planner-tile-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px 16px;
  margin-bottom: 12px;
}

.planner-tile-title {
  display: flex;
  align-items: baseline;
  gap: 8px;
  font-size: 1.5rem;
  text-transform: uppercase;

  .planner-tile-sub {
    font-size: 1.2rem;
    opacity: .6;
  }
}

.planner-tile-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px;
}

.planner-stepper {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 1.3rem;
  text-transform: uppercase;
  font-variant-numeric: tabular-nums;

  button {
    width: 26px;
    height: 26px;
    border: solid 1px rgba(255, 255, 255, .3);
    border-radius: 3px;
    background: rgba(0, 0, 0, .3);
    color: $white;
    font-size: 1.6rem;
    line-height: 1;
    cursor: pointer;

    &:hover:not(:disabled):not([aria-disabled]) { border-color: $white; }
    &:disabled,
    &[aria-disabled] { opacity: .3; cursor: default; }
  }
}

.planner-tile-warning {
  margin: 0 0 10px;
  padding-left: 10px;
  border-left: solid 3px $color-alert;
  font-size: 1.3rem;
}

.planner-tile-body {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 20px;
}

.planner-tile-card {
  flex: 0 0 auto;
  // the card's cost row hangs below its fixed 418px box
  padding-bottom: 40px;
}

.planner-card-placeholder {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 418px;
  margin: 0;
  padding: 20px;
  border: dashed 1px rgba(255, 255, 255, .15);
  text-align: center;
  font-size: 1.3rem;
  opacity: .55;
}

.planner-choices {
  flex: 1 1 260px;
  min-width: 0;
}

.planner-choices-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 8px;
  font-size: 1.3rem;
  font-weight: bold;
  text-transform: uppercase;
}

.planner-placement {
  display: flex;
  align-items: center;
  gap: 3px;
  font-weight: normal;

  .planner-placement-label {
    margin-right: 4px;
    font-size: 1.1rem;
    opacity: .7;
  }
}

.planner-placement-pip {
  width: 22px;
  height: 22px;
  border: solid 1px rgba(255, 255, 255, .25);
  border-radius: 3px;
  background: rgba(0, 0, 0, .3);
  color: $white;
  font-size: 1.1rem;
  cursor: pointer;

  &.is-active {
    background: $white;
    color: $black;
    font-weight: bold;
  }
}

.planner-choices-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
  gap: 6px;
}

.planner-choice {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 3px 8px 3px 3px;
  border: solid 1px rgba(255, 255, 255, .08);
  background: rgba(0, 0, 0, .2);
  color: $white;
  font: inherit;
  text-align: left;
  cursor: pointer;

  &:hover:not([aria-disabled]),
  &:focus-visible {
    border-color: rgba(255, 255, 255, .45);
    background: rgba(255, 255, 255, .05);
    outline: none;
  }

  // not the disabled attribute: disabled buttons get no hover events,
  // and the tooltip says what unlocks the building
  &[aria-disabled] {
    cursor: default;
    opacity: .55;
  }

  &.is-current {
    border-color: rgba(255, 255, 255, .6);
  }

  .tile {
    flex: 0 0 auto;
  }
}

.planner-choice-name {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 1.25rem;
  line-height: 1.25;
}

.planner-choice-workforce {
  flex: 0 0 auto;
  font-size: 1.2rem;
  opacity: .75;

  .svg-icon {
    width: 12px;
    height: 12px;
    vertical-align: -1px;
  }
}
</style>
