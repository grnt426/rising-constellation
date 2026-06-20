<template>
  <div
    class="simulator-ship-picker"
    :class="`f-${theme}`">
    <div class="picker-header">
      <h2>{{ $t('page.fight_simulator.picker_title') }}</h2>
      <p>{{ $t('page.fight_simulator.picker_hint') }}</p>

      <div class="picker-level default-input">
        <label for="placement_level">{{ $t('page.fight_simulator.ship_level') }}</label>
        <input
          id="placement_level"
          type="number"
          min="1"
          :max="maxLevel"
          :value="level + 1"
          @input="onLevelInput" />
      </div>
    </div>

    <div
      v-for="category in categories"
      :key="category"
      class="picker-category">
      <div class="picker-category-head">
        <div class="picker-category-label">
          {{ category }}
        </div>
        <div class="picker-stack-radios">
          <label
            v-for="size in stackSizes(category)"
            :key="`${category}-${size}`"
            class="stack-radio"
            :class="{ 'is-active': stackFor(category) === size }">
            <input
              type="radio"
              :name="`stack-${category}`"
              :value="size"
              :checked="stackFor(category) === size"
              @change="setStack(category, size)" />
            ×{{ size }}
          </label>
        </div>
      </div>
      <div class="picker-category-row">
        <div
          v-for="model in modelsOfClass(category)"
          :key="model.model"
          v-tooltip.bottom="tooltipFor(category, model)"
          class="tile is-hoverable picker-tile"
          @mouseenter="$emit('hover', resolveKey(category, model))"
          @click="onClick(category, model, $event)">
          <svgicon
            class="tile-icon is-rotated"
            :name="`ship/${resolveKey(category, model)}`" />
        </div>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'simulator-ship-picker',
  props: {
    theme: {
      type: String,
      default: 'dark-blue',
    },
    // 0-indexed placement level (the level newly placed ships get). The input
    // shows it 1-indexed to match the in-game level display (level + 1).
    level: {
      type: Number,
      default: 0,
    },
  },
  data() {
    return {
      maxLevel: 16,
      // class -> chosen stack size (unit_count). Defaults lazily to the class's
      // largest stack via stackFor(); setStack() pins an explicit choice.
      selectedStack: {},
    };
  },
  computed: {
    ships() {
      return this.$store.state.portal.data.ship || [];
    },
    // One entry per model, carrying every stack variant sorted ascending.
    models() {
      const byModel = this.ships.reduce((acc, s) => {
        if (!acc[s.model]) acc[s.model] = { model: s.model, class: s.class, variants: [] };
        acc[s.model].variants.push(s);
        return acc;
      }, {});
      Object.values(byModel).forEach((m) => m.variants.sort((a, b) => a.unit_count - b.unit_count));
      return Object.values(byModel);
    },
    categories() {
      const order = [];
      const seen = new Set();
      this.models.forEach((m) => {
        if (!seen.has(m.class)) {
          seen.add(m.class);
          order.push(m.class);
        }
      });
      return order;
    },
  },
  methods: {
    modelsOfClass(category) {
      return this.models
        .filter((m) => m.class === category)
        .sort((a, b) => a.model.localeCompare(b.model));
    },
    // Available stack sizes for a class = the union of its variants' unit_counts.
    stackSizes(category) {
      const sizes = new Set();
      this.models
        .filter((m) => m.class === category)
        .forEach((m) => m.variants.forEach((v) => sizes.add(v.unit_count)));
      return Array.from(sizes).sort((a, b) => a - b);
    },
    stackFor(category) {
      if (this.selectedStack[category] != null) return this.selectedStack[category];
      const sizes = this.stackSizes(category);
      return sizes.length ? sizes[sizes.length - 1] : null; // default: largest
    },
    setStack(category, size) {
      this.$set(this.selectedStack, category, size);
    },
    // Resolve a model to the variant matching the chosen stack — exact, else the
    // largest variant not exceeding it, else the smallest.
    resolveVariant(category, model) {
      const target = this.stackFor(category);
      const exact = model.variants.find((v) => v.unit_count === target);
      if (exact) return exact;
      const under = [...model.variants].reverse().find((v) => v.unit_count <= target);
      return under || model.variants[0];
    },
    resolveKey(category, model) {
      const v = this.resolveVariant(category, model);
      return v ? v.key : model.model;
    },
    onClick(category, model, event) {
      this.$emit('pick', this.resolveKey(category, model), {
        shift: event.shiftKey,
        ctrl: event.ctrlKey || event.metaKey,
      });
    },
    onLevelInput(event) {
      const display = parseInt(event.target.value, 10);
      const internal = Number.isNaN(display) ? 0 : Math.max(0, Math.min(this.maxLevel - 1, display - 1));
      this.$emit('update:level', internal);
    },
    tooltipFor(category, model) {
      const v = this.resolveVariant(category, model);
      const name = this.$t(`data.ship.${v.key}.name`);
      return `${name} (×${v.unit_count})`;
    },
  },
};
</script>

<style lang="scss" scoped>
.simulator-ship-picker {
  padding: 20px;

  .picker-header {
    margin-bottom: 16px;

    h2 {
      margin: 0 0 4px 0;
    }

    p {
      margin: 0 0 8px 0;
      opacity: 0.7;
    }
  }

  .picker-level {
    display: flex;
    align-items: center;
    gap: 8px;

    input {
      width: 72px;
    }
  }

  .picker-category {
    margin-bottom: 16px;
  }

  .picker-category-head {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 6px;
  }

  .picker-category-label {
    font-size: 1.1rem;
    font-weight: bold;
    opacity: 0.7;
    text-transform: uppercase;
  }

  .picker-stack-radios {
    display: flex;
    gap: 4px;
  }

  .stack-radio {
    cursor: pointer;
    padding: 1px 7px;
    border-radius: 3px;
    border: solid 1px rgba(255, 255, 255, 0.2);
    font-size: 0.85rem;
    opacity: 0.6;
    user-select: none;

    input {
      display: none;
    }

    &.is-active {
      opacity: 1;
      border-color: currentColor;
      background: rgba(255, 255, 255, 0.08);
    }
  }

  .picker-category-row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .picker-tile {
    width: 50px;
    height: 50px;
    cursor: pointer;

    .tile-icon {
      width: 46px;
      height: 46px;
    }
  }
}
</style>
