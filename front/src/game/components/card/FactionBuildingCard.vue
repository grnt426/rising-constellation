<template>
  <div
    class="card-container is-faction-building"
    :class="[`f-${theme}`, { 'is-pinned': pinned }]">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon :name="icon" />
        <span
          v-if="maxLevel > 1"
          class="level"
          :class="{ 'is-preview': isPreviewing }">{{ displayLevel }}</span>
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          {{ $t(`data.faction_building.${buildingKey}.name`) }}
        </div>
        <div class="title-small">
          {{ $t('card.faction_building.kind') }}
        </div>
      </div>
      <div
        v-if="pinned"
        class="card-close"
        v-tooltip="$t('card.close_hint')"
        @click="$emit('close')">
        <svgicon name="close" />
      </div>
    </div>

    <div class="card-body">
      <div class="card-illustration">
        <img
          v-if="illustration"
          :src="illustration" />

        <div
          v-if="buildingData.unique"
          class="toast"
          v-tooltip="$t('card.building.unique_hint')">
          {{ $t('card.building.unique') }}
        </div>
      </div>

      <div class="card-information">
        <div class="card-panel-controls">
          <svgicon
            v-if="leftControl"
            class="card-panel-control"
            name="caret-left"
            @click="movePanelToLeft()" />
          <div v-else></div>

          <div
            v-if="maxLevel > 1"
            class="card-level-pips">
            <div
              v-for="n in maxLevel"
              :key="`level-pip-${n}`"
              class="card-level-pip"
              :class="{
                'is-active': n === displayLevel,
                'is-built': n === level,
              }"
              v-tooltip="levelTooltip(n)"
              @click.stop="previewLevel = n">
              {{ n }}
            </div>
          </div>

          <svgicon
            v-if="rightControl"
            class="card-panel-control"
            name="caret-right"
            @click="movePanelToRight()" />
          <div v-else></div>
        </div>

        <div class="card-panel-window">
          <div
            ref="panelContainer"
            class="card-panel-container"
            :style="{ left: panelContainerPosition + 'px' }">
            <!-- what the building does -->
            <div class="card-panel">
              <p class="card-summary">
                {{ $t(`data.faction_building.${buildingKey}.description`) }}
              </p>

              <div
                v-for="row in effectRows"
                :key="row.key"
                v-tooltip="row.hint"
                class="complex-bonus"
                :class="{ 'has-hint': row.hint }">
                <div>{{ row.label }}</div>
                <div><strong>{{ row.value }}</strong></div>
              </div>

              <div
                v-tooltip="$t('card.faction_building.upkeep_hint')"
                class="complex-bonus has-hint">
                <div>{{ $t('card.faction_building.upkeep') }}</div>
                <div>
                  <span
                    v-for="amount in upkeep"
                    :key="amount.resource"
                    class="card-amount">
                    <strong>{{ amount.value | income }}</strong>
                    <svgicon :name="`resource/${amount.resource}`" />
                  </span>
                </div>
              </div>
            </div>

            <!-- gateway: what linking and unlinking a pair costs -->
            <div
              v-if="linkRows.length > 0"
              class="card-panel">
              <h2>{{ $t('card.faction_building.panel_link') }}</h2>

              <div
                v-for="row in linkRows"
                :key="row.key"
                v-tooltip="row.hint"
                class="complex-bonus"
                :class="{ 'has-hint': row.hint }">
                <div>{{ row.label }}</div>
                <div>
                  <strong v-if="row.value">{{ row.value }}</strong>
                  <span
                    v-for="amount in row.amounts || []"
                    :key="amount.resource"
                    class="card-amount">
                    <strong>{{ amount.text }}</strong>
                    <svgicon :name="`resource/${amount.resource}`" />
                  </span>
                </div>
              </div>
            </div>

            <!-- how the government gets one built -->
            <div class="card-panel">
              <h2>{{ $t('card.faction_building.panel_station') }}</h2>

              <div
                v-tooltip="$t('card.faction_building.ordered_by_hint')"
                class="complex-bonus has-hint">
                <div>{{ $t('card.faction_building.ordered_by') }}</div>
                <div><strong>{{ seatName }}</strong></div>
              </div>

              <div
                v-if="buildingData.patent"
                class="complex-bonus">
                <div>{{ $t('card.faction_building.requires') }}</div>
                <div><strong>{{ $t(`data.faction_patent.${buildingData.patent}.name`) }}</strong></div>
              </div>

              <div
                v-tooltip="$t('card.faction_building.slots_hint')"
                class="complex-bonus has-hint">
                <div>{{ $t('card.faction_building.slots') }}</div>
                <div>
                  <strong>
                    {{ $t('card.faction_building.slots_value', { n: slotCount, total: stationSlots }) }}
                  </strong>
                </div>
              </div>

              <div
                v-if="buildSeconds !== null"
                v-tooltip="$t('card.faction_building.build_time_hint')"
                class="complex-bonus has-hint">
                <div>{{ $t('card.faction_building.build_time') }}</div>
                <div><strong>{{ duration(buildSeconds) }}</strong></div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="showCost || isPreviewing"
      class="card-cost">
      <div
        class="icon-value"
        v-tooltip="{ content: laborTooltip, html: true }">
        {{ levelData.labor | compact }}
        <svgicon name="resource/production" />
      </div>
      <div
        v-for="amount in cost"
        :key="amount.resource"
        class="icon-value"
        v-tooltip="{ content: costTooltip(amount), html: true }">
        {{ amount.value | compact }}
        <svgicon :name="`resource/${amount.resource}`" />
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import format, { formatDuration } from '@/utils/format';
import {
  FACTION_BUILDING_ILLUSTRATIONS,
  STATION_SLOTS,
  factionBuildingIcon,
} from '@/game/faction-buildings';

const RESOURCES = ['credit', 'technology', 'ideology'];

export default {
  name: 'faction-building-card',
  mixins: [CardMixin],
  data() {
    return {
      previewLevel: null,
    };
  },
  props: {
    buildingKey: String,
    level: {
      type: Number,
      default: 1,
    },
    // the host system, when the card describes a build there: gives the
    // construction time at its production
    system: {
      type: Object,
      required: false,
    },
    showCost: {
      type: Boolean,
      default: false,
    },
    pinned: {
      type: Boolean,
      default: false,
    },
    // what the card's anchor level means: a 'built' building's actual
    // level, or a plain 'preview' (build menu, patents)
    context: {
      type: String,
      default: 'preview',
    },
  },
  computed: {
    gameData() { return this.$store.state.game.data; },
    constant() { return (this.gameData.constant || [])[0] || {}; },
    faction() { return this.$store.state.game.faction; },
    tickToSecondFactor() { return this.$store.getters['game/tickToSecondFactor']; },
    buildingData() {
      return (this.gameData.faction_building || []).find((b) => b.key === this.buildingKey);
    },
    icon() { return factionBuildingIcon(this.buildingKey); },
    illustration() { return FACTION_BUILDING_ILLUSTRATIONS[this.buildingKey] || null; },
    stationSlots() { return STATION_SLOTS; },
    maxLevel() { return this.buildingData.levels.length; },
    displayLevel() { return this.previewLevel === null ? this.level : this.previewLevel; },
    isPreviewing() { return this.previewLevel !== null && this.previewLevel !== this.level; },
    levelData() { return this.buildingData.levels[this.displayLevel - 1]; },
    slotCount() { return this.buildingData.shape.cols * this.buildingData.shape.rows; },
    seatName() {
      return this.faction
        ? this.$t(`panel.faction_government.seat_names.${this.faction.key}.${this.buildingData.seat}`)
        : '';
    },
    cost() { return this.amounts(this.levelData.cost); },
    upkeep() { return this.amounts(this.levelData.upkeep); },
    // seconds to build this level here, at the system's current production
    buildSeconds() {
      const production = this.system && this.system.production ? this.system.production.value : 0;
      if (!(production > 0) || !this.tickToSecondFactor) return null;
      return (this.levelData.labor / production) * this.tickToSecondFactor;
    },
    laborTooltip() {
      const parts = [
        `${format.integer(this.levelData.labor)} ${this.$t('card.faction_building.labor')}`,
        this.$t('card.faction_building.labor_hint'),
      ];
      if (this.buildSeconds !== null) {
        parts.push(this.$t('card.faction_building.labor_time', { time: this.duration(this.buildSeconds) }));
      }
      return parts.join('<br>');
    },
    // the building's own mechanic, in figures read from the game data
    effectRows() {
      const c = this.constant;
      const t = (key, params) => this.$t(`card.faction_building.${key}`, params);

      switch (this.buildingData.effect) {
        case 'gateway':
          return [
            this.timeRow('gateway_charge', c.gateway_charge_time),
            this.timeRow('gateway_jump', c.gateway_jump_time),
            this.timeRow('gateway_fatigue', c.gateway_fatigue_time),
          ];
        case 'agent_training':
          return [
            this.timeRow('training_interval', c.training_center_interval),
            {
              key: 'training_xp',
              label: t('training_xp'),
              value: t('training_xp_value', { n: this.displayLevel }),
              hint: t('training_xp_hint'),
            },
          ];
        case 'cyber_command':
          return [
            this.timeRow('census_interval', c.cyber_command_interval),
            {
              key: 'census_scope',
              label: t('census_scope'),
              value: t('census_scope_value'),
              hint: t('census_scope_hint'),
            },
          ];
        default:
          return [];
      }
    },
    linkRows() {
      if (this.buildingData.effect !== 'gateway') return [];

      const c = this.constant;
      const t = (key) => this.$t(`card.faction_building.${key}`);
      const rate = (value) => format.income(value);

      return [
        this.timeRow('link_time', c.gateway_link_time),
        {
          key: 'link_cost',
          label: t('link_cost'),
          hint: t('link_cost_hint'),
          amounts: [
            { resource: 'credit', text: rate(c.gateway_link_cost_credit) },
            { resource: 'technology', text: rate(c.gateway_link_cost_technology) },
          ],
        },
        {
          key: 'charge_upkeep',
          label: t('charge_upkeep'),
          hint: t('charge_upkeep_hint'),
          amounts: [
            { resource: 'credit', text: rate(c.gateway_charge_upkeep_credit) },
            { resource: 'technology', text: rate(c.gateway_charge_upkeep_technology) },
          ],
        },
        {
          key: 'unlink_cost',
          label: t('unlink_cost'),
          hint: this.$t('card.faction_building.unlink_cost_hint', {
            time: this.duration((c.gateway_unlink_time || 0) * this.tickToSecondFactor),
          }),
          amounts: [
            { resource: 'credit', text: format.compact(c.gateway_unlink_cost_credit) },
            { resource: 'technology', text: format.compact(c.gateway_unlink_cost_technology) },
          ],
        },
      ];
    },
  },
  watch: {
    buildingKey() { this.previewLevel = null; },
    level() { this.previewLevel = null; },
    // previewing another level reveals the cost row, growing the card
    isPreviewing(value) { this.$emit('preview', value); },
  },
  methods: {
    amounts(values) {
      return RESOURCES
        .filter((resource) => (values[resource] || 0) > 0)
        .map((resource) => ({ resource, value: values[resource] }));
    },
    duration(seconds) {
      return formatDuration(seconds, (key, params) => this.$t(key, params));
    },
    // a game-time constant (in ut) as a row showing its real duration
    timeRow(key, ut) {
      return {
        key,
        label: this.$t(`card.faction_building.${key}`),
        value: this.duration((ut || 0) * this.tickToSecondFactor),
        hint: this.$te(`card.faction_building.${key}_hint`)
          ? this.$t(`card.faction_building.${key}_hint`)
          : null,
      };
    },
    costTooltip(amount) {
      return [
        `${format.integer(amount.value)} ${this.$t(`galaxy.station.resource_${amount.resource}`)}`,
        this.$t('card.faction_building.cost_hint'),
      ].join('<br>');
    },
    levelTooltip(n) {
      if (n === this.level && this.context === 'built') {
        return this.$t('card.building.level_current', { n });
      }
      return this.$t('card.building.level_preview', { n });
    },
  },
};
</script>
