<template>
  <!-- The planned system's numbers, as the game computes them (the
       server runs the game's own bonus pipeline). Each row opens the
       in-game breakdown; the arrow column is the change against the
       baseline (what was imported, or the last "Set as baseline"). -->
  <div class="planner-outputs">
    <div
      v-for="group in groups"
      :key="group.key"
      class="planner-output-group">
      <h3>{{ $t(`page.system_planner.outputs_${group.key}`) }}</h3>

      <hover-popover
        v-for="row in group.rows"
        :key="row.key"
        placement="left">
        <div
          class="planner-output-row"
          :class="{ 'is-alert': row.alert }">
          <svgicon
            class="planner-output-icon"
            :name="row.icon" />
          <span class="planner-output-label">{{ row.label }}</span>
          <span class="planner-output-value">{{ row.text }}</span>
          <span
            class="planner-output-delta"
            :class="{ 'is-empty': !row.delta }">
            <template v-if="row.delta">
              <svgicon :name="row.delta > 0 ? 'caret-up' : 'caret-down'" />{{ row.deltaText }}
            </template>
          </span>
        </div>
        <resource-detail
          slot="popover"
          :title="row.title"
          :value="row.detailValue"
          :details="row.details"
          :income="!!row.income"
          :help="row.help"
          :description="row.description"
          :precision="row.precision === undefined ? 1 : row.precision" />
      </hover-popover>
    </div>
  </div>
</template>

<script>
import format from '@/utils/format';
import HoverPopover from '@/game/components/generic/HoverPopover.vue';
import ResourceDetail from '@/game/components/generic/ResourceDetail.vue';

// [group, [rows]]. `get(system)` reads the row's number, `details` its
// breakdown; most rows are a plain {value, details} field.
const field = (key) => ({ key, get: (s) => s[key].value, details: (s) => s[key].details });

const LAYOUT = [
  ['yields', [
    { ...field('production'), icon: 'resource/production', label: 'data.bonus_pipeline_in.sys_production.name', income: true, help: 'production', describe: 'production' },
    { ...field('credit'), icon: 'resource/credit', label: 'data.bonus_pipeline_in.sys_credit.name', income: true, help: 'credit', describe: 'credit' },
    { ...field('technology'), icon: 'resource/technology', label: 'data.bonus_pipeline_in.sys_technology.name', income: true, help: 'technology', describe: 'technology' },
    { ...field('ideology'), icon: 'resource/ideology', label: 'data.bonus_pipeline_in.sys_ideology.name', income: true, help: 'ideology', describe: 'ideology' },
  ]],
  ['population', [
    { ...field('happiness'), icon: 'resource/happiness', label: 'data.bonus_pipeline_out.sys_happiness.name', help: 'stability', describe: 'happiness', precision: 0 },
    { ...field('habitation'), icon: 'resource/habitation', label: 'galaxy.system.population.habitation', help: 'housing', describe: 'habitation', precision: 0 },
    { key: 'workforce', icon: 'resource/population', label: 'galaxy.system.population.workforce', help: 'population', describe: 'workforce', precision: 0 },
    { key: 'growth', icon: 'stellar_body/population', label: 'page.system_planner.growth', precision: 3 },
    { key: 'status', icon: 'resource/happiness', label: 'galaxy.system.pop_status.title', precision: 0 },
    { key: 'class', icon: 'victory', label: 'page.system_planner.population_class', precision: 0 },
  ]],
  ['military', [
    { ...field('defense'), icon: 'resource/defense', label: 'data.bonus_pipeline_in.sys_defense.name', precision: 0 },
    { ...field('radar'), icon: 'resource/radar', label: 'galaxy.system.details.radar', help: 'slsd', describe: 'radar' },
  ]],
  // ships built here start with this much experience
  ['training', [
    { ...field('fighter_lvl'), icon: 'resource/fighter_lvl', label: 'page.system_planner.xp_fighter', title: 'galaxy.system.details.fighters_init_xp', precision: 0 },
    { ...field('corvette_lvl'), icon: 'resource/corvette_lvl', label: 'page.system_planner.xp_corvette', title: 'galaxy.system.details.corvettes_init_xp', precision: 0 },
    { ...field('frigate_lvl'), icon: 'resource/frigate_lvl', label: 'page.system_planner.xp_frigate', title: 'galaxy.system.details.frigates_init_xp', precision: 0 },
    { ...field('capital_lvl'), icon: 'resource/capital_lvl', label: 'page.system_planner.xp_capital', title: 'galaxy.system.details.capital_ships_init_xp', precision: 0 },
  ]],
  ['infrastructure', [
    { ...field('mobility'), icon: 'resource/mobility', label: 'galaxy.system.details.mobility', help: 'mobility', describe: 'mobility' },
    { ...field('counter_intelligence'), icon: 'resource/counter_intelligence', label: 'galaxy.system.details.counterintelligence', help: 'intelligence', describe: 'counter_intelligence', precision: 0 },
    {
      key: 'remove_contact', get: (s) => s.remove_contact.change, details: (s) => s.remove_contact.details, icon: 'resource/remove_contact', label: 'galaxy.system.details.fixing', help: 'cybersecurity', describe: 'remove_contact',
    },
  ]],
];

export default {
  name: 'planner-outputs',
  props: {
    system: { type: Object, required: true },
    growth: { type: Number, default: 0 },
    baseline: { type: Object, default: null },
    baselineGrowth: { type: Number, default: 0 },
    // game data (population statuses and classes)
    data: { type: Object, required: true },
  },
  computed: {
    groups() {
      return LAYOUT.map(([key, rows]) => ({ key, rows: rows.map((row) => this.row(row)) }));
    },
  },
  methods: {
    value(row, system, growth) {
      if (row.key === 'workforce') return system.used_workforce;
      if (row.key === 'growth') return growth;
      if (row.key === 'status') return 100 * (1 - this.status(system).penalty);
      if (row.key === 'class') return this.populationClass(system).points;
      return row.get(system);
    },
    status(system) {
      return this.data.population_status.find((ps) => ps.key === system.population_status)
        || { key: system.population_status, penalty: 0 };
    },
    populationClass(system) {
      return this.data.population_class.find((pc) => pc.key === system.population_class)
        || { key: system.population_class, points: 0, threshold: 0 };
    },
    row(def) {
      const value = this.value(def, this.system, this.growth);
      const base = this.baseline ? this.value(def, this.baseline, this.baselineGrowth) : value;
      const precision = def.precision === undefined ? 1 : def.precision;
      // ignore float noise below the shown precision
      const delta = Math.abs(value - base) >= 0.5 * (10 ** -precision) ? value - base : 0;

      const row = {
        key: def.key,
        icon: def.icon,
        label: this.$t(def.label),
        title: this.$t(def.title || def.label),
        income: def.income,
        help: def.help,
        precision,
        description: def.describe ? this.$t(`resource-description.${def.describe}`) : undefined,
        delta,
        deltaText: this.fmt(def, Math.abs(delta), precision),
        text: this.fmt(def, value, precision),
        detailValue: value,
        details: def.details ? def.details(this.system) : [],
        alert: false,
      };

      if (def.key === 'workforce') {
        row.text = `${this.system.used_workforce}/${this.system.workforce}`;
        row.alert = this.system.used_workforce > this.system.workforce;
        row.detailValue = undefined;
        row.details = [
          { reason: this.$t('galaxy.system.population.workforce_mobilized'), value: this.system.used_workforce },
          { reason: this.$t('galaxy.system.population.workforce_total'), value: this.system.workforce },
        ];
      } else if (def.key === 'growth') {
        row.text = format.float(value, 3, true);
        row.deltaText = format.float(Math.abs(delta), 3);
        row.details = [
          { reason: this.$t('page.system_planner.growth_population'), value: format.float(this.system.population.value, 2) },
          { reason: this.$t('page.system_planner.growth_settles'), value: format.float(this.system.habitation.value + 0.75, 2) },
        ];
      } else if (def.key === 'happiness') {
        row.alert = value <= 0;
      } else if (def.key === 'status') {
        // "Normal 100%": the status, and the productivity it leaves
        const status = this.status(this.system);
        row.label = this.$t(`data.population_status.${status.key}.name`);
        row.text = `${format.integer(value)}%`;
        row.deltaText = `${format.integer(Math.abs(delta))}%`;
        row.alert = status.penalty > 0;
        row.detailValue = undefined;
        row.description = this.$t(`data.population_status.${status.key}.desc`);
        row.details = this.data.population_status.map((ps) => ({
          reason: this.$t(`data.population_status.${ps.key}.name`),
          value: `${format.integer(100 * (1 - ps.penalty))}%`,
          active: ps.key === status.key,
        }));
      } else if (def.key === 'class') {
        // "Outpost 1": the class, and its star system points
        const pc = this.populationClass(this.system);
        row.label = this.$t(`data.population_class.${pc.key}`);
        row.text = format.integer(pc.points);
        row.detailValue = undefined;
        row.description = this.$t('galaxy.system.pop_class.info');
        row.details = [...this.data.population_class].reverse().map((c) => ({
          reason: this.$t('galaxy.system.pop_class.label', { label: this.$t(`data.population_class.${c.key}`), pop: c.threshold }),
          value: c.points,
          active: c.key === pc.key,
        }));
      }

      return row;
    },
    fmt(def, value, precision) {
      if (def.income) return format.income(value, precision);
      return precision === 0 ? format.integer(value) : format.float(value, precision);
    },
  },
  components: {
    HoverPopover,
    ResourceDetail,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-output-group {
  margin-bottom: 14px;

  h3 {
    margin: 0 0 4px;
    font-size: 1.2rem;
    text-transform: uppercase;
    opacity: .6;
  }
}

// v-popover renders inline-block wrappers with inline styles: a row is
// a full-width line
.planner-outputs ::v-deep {
  .v-popover,
  .v-popover > .trigger,
  .hover-popover-trigger {
    display: block !important;
  }
}

.planner-output-row {
  display: grid;
  grid-template-columns: 18px minmax(0, 1fr) auto 52px;
  align-items: center;
  gap: 8px;
  padding: 3px 4px;
  border-radius: 3px;
  font-size: 1.3rem;
  cursor: default;

  &:hover {
    background: rgba(255, 255, 255, .05);
  }

  &.is-alert .planner-output-value {
    color: $color-alert;
  }
}

.planner-output-icon {
  width: 16px;
  height: 16px;
}

.planner-output-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.planner-output-value {
  font-weight: bold;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.planner-output-delta {
  font-size: 1.2rem;
  font-variant-numeric: tabular-nums;
  text-align: right;
  white-space: nowrap;
  opacity: .85;

  .svg-icon {
    width: 9px;
    height: 9px;
    margin-right: 2px;
    vertical-align: 0;
  }
}
</style>
