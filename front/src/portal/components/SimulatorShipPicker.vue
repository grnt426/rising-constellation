<template>
  <div
    class="simulator-ship-picker"
    :class="`f-${theme}`">
    <div class="picker-header">
      <h2>{{ $t('page.fight_simulator.picker_title') }}</h2>
      <p>{{ $t('page.fight_simulator.picker_hint') }}</p>
    </div>

    <div
      v-for="category in categories"
      :key="category"
      class="picker-category">
      <div class="picker-category-label">
        {{ category }}
      </div>
      <div class="picker-category-row">
        <div
          v-for="ship in shipsByCategory(category)"
          :key="ship.key"
          v-tooltip.bottom="tooltipFor(ship)"
          class="tile is-hoverable picker-tile"
          @click="$emit('pick', ship.key)">
          <svgicon
            class="tile-icon is-rotated"
            :name="`ship/${ship.key}`" />
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
  },
  computed: {
    ships() {
      return this.$store.state.portal.data.ship || [];
    },
    // One tile per model — pick the highest unit_count variant in the model.
    // Mirrors Production.vue's collapsed (showAllShips=false) listing so the
    // picker stays uncluttered; arrows on the army tile let the user step
    // down to smaller variants.
    representativeShips() {
      const byModel = this.ships.reduce((acc, s) => {
        if (!acc[s.model] || acc[s.model].unit_count < s.unit_count) {
          acc[s.model] = s;
        }
        return acc;
      }, {});
      return Object.values(byModel);
    },
    categories() {
      const order = [];
      const seen = new Set();
      this.representativeShips.forEach((s) => {
        if (!seen.has(s.class)) {
          seen.add(s.class);
          order.push(s.class);
        }
      });
      return order;
    },
  },
  methods: {
    shipsByCategory(category) {
      return this.representativeShips
        .filter((s) => s.class === category)
        .sort((a, b) => a.unit_count - b.unit_count || a.key.localeCompare(b.key));
    },
    tooltipFor(ship) {
      const name = this.$t(`data.ship.${ship.key}.name`);
      return `${name} (×${ship.unit_count})`;
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
      margin: 0;
      opacity: 0.7;
    }
  }

  .picker-category {
    margin-bottom: 16px;
  }

  .picker-category-label {
    font-size: 1.1rem;
    font-weight: bold;
    opacity: 0.7;
    margin-bottom: 6px;
    text-transform: uppercase;
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
