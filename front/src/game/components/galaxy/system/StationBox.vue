<template>
  <div
    v-if="visible"
    class="station-box"
    :class="{ 'is-unpowered': !powered }">
    <div class="station-header">
      <span class="station-title">{{ $t('galaxy.station.title') }}</span>
      <span
        v-if="!powered"
        v-tooltip="$t('galaxy.station.unpowered_hint')"
        class="station-power">
        {{ $t('galaxy.station.unpowered') }}
      </span>
    </div>

    <div class="station-grid">
      <div
        v-for="entry in gridEntries"
        :key="entry.key"
        v-tooltip="entry.tooltip"
        class="station-cell"
        :class="entry.classes"
        :style="entry.style"
        @click="entry.onClick && entry.onClick()">
        <template v-if="entry.type === 'building'">
          <svgicon
            :name="entry.icon"
            class="cell-icon" />
          <span
            v-if="entry.maxLevel > 1"
            class="cell-level">{{ entry.level }}</span>
          <span
            v-if="entry.canManage"
            class="cell-toast cell-remove"
            v-tooltip="$t('galaxy.station.demolish')"
            @click.stop="demolish(entry)">
            <svgicon name="close" />
          </span>
        </template>

        <template v-else-if="entry.type === 'construction'">
          <svgicon
            :name="entry.icon"
            class="cell-icon is-under-construction" />
          <circle-progress-value
            class="cell-progress"
            :current="entry.done"
            :total="entry.total"
            :increase="entry.increase"
            :size="26"
            :width="2"
            :theme="color" />
        </template>

        <template v-else>
          <span
            v-if="entry.clickable"
            class="cell-plus">+</span>
        </template>
      </div>
    </div>

    <div
      v-if="construction"
      class="station-construction">
      <span class="construction-name">
        {{ $t(`data.faction_building.${construction.key}.name`) }}
        <template v-if="construction.kind === 'upgrade'"> {{ construction.level }}</template>
      </span>
      <counter
        v-if="system.production.value > 0"
        :current="constructionRemainingTicks"
        :receivedAt="system.receivedAt" />
      <span v-else>&mdash;</span>
      <span
        v-if="canManageKey(construction.key)"
        class="construction-cancel"
        v-tooltip="$t('galaxy.station.cancel_refund')"
        @click="cancelConstruction">
        <svgicon name="close" />
      </span>
    </div>

    <div
      v-if="gatewayPanel"
      class="station-gateway">
      <template v-if="gatewayPanel.link">
        <span class="gateway-status">
          {{ $t(`galaxy.station.gateway_${gatewayPanel.link.status}`, { system: gatewayPanel.otherName }) }}
        </span>
        <counter
          v-if="gatewayPanel.link.remaining"
          :current="gatewayPanel.link.remaining"
          :receivedAt="factionReceivedAt" />
        <span
          v-if="gatewayPanel.link.transit"
          class="gateway-busy">
          {{ $t('galaxy.station.gateway_busy') }}
        </span>
        <span
          v-if="canManageSeat('military') && gatewayPanel.link.status === 'linked' && !gatewayPanel.link.transit"
          class="gateway-op"
          @click="unlinkGateway">
          {{ $t('galaxy.station.unlink') }}
        </span>
      </template>

      <template v-else-if="canManageSeat('military')">
        <select
          v-model="linkTarget"
          class="gateway-select">
          <option
            :value="null"
            disabled>{{ $t('galaxy.station.link_pick') }}</option>
          <option
            v-for="option in linkTargets"
            :key="option.system_id"
            :value="option.system_id">
            {{ option.name }}
          </option>
        </select>
        <span
          class="gateway-op"
          :class="{ 'is-disabled': linkTarget === null }"
          @click="linkGateway">
          {{ $t('galaxy.station.link') }}
        </span>
      </template>
    </div>

    <div
      v-if="picker !== null"
      class="station-picker">
      <div class="picker-title">{{ $t('galaxy.station.build') }}</div>

      <div
        v-for="option in buildOptions"
        :key="option.key"
        v-tooltip="option.reason"
        class="picker-option"
        :class="{ 'is-disabled': option.status !== 'available' }"
        @click="option.status === 'available' && order(option)">
        <svgicon
          :name="option.icon"
          class="option-icon" />
        <div class="option-main">
          <div class="option-name">
            {{ $t(`data.faction_building.${option.key}.name`) }}
            <span class="option-shape">{{ option.shape.cols }}&times;{{ option.shape.rows }}</span>
          </div>
          <div class="option-costs">
            <span
              v-for="cost in option.costs"
              :key="cost.icon"
              class="option-cost">
              <svgicon :name="`resource/${cost.icon}`" />
              {{ cost.value | integer }}
            </span>
          </div>
        </div>
      </div>

      <div
        class="picker-close"
        @click="picker = null">
        {{ $t('galaxy.station.close') }}
      </div>
    </div>
  </div>
</template>

<script>
import Counter from '@/game/components/generic/Counter.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

const GRID_COLS = 2;
const GRID_SLOTS = 4;

const BUILDING_ICONS = {
  gateway: 'building/hypergate',
  training_center: 'building/military_school_dome',
  cyber_command: 'building/counterintelligence_open',
};

export default {
  name: 'station-box',
  components: { Counter, CircleProgressValue },
  props: {
    system: Object,
    color: String,
  },
  data() {
    return {
      picker: null,
      linkTarget: null,
    };
  },
  computed: {
    player() { return this.$store.state.game.player; },
    faction() { return this.$store.state.game.faction; },
    government() { return (this.faction && this.faction.government) || null; },
    buildingData() { return this.$store.state.game.data.faction_building || []; },
    station() { return this.system.station || null; },
    buildings() { return (this.station && this.station.buildings) || []; },
    construction() { return (this.station && this.station.construction) || null; },
    powered() {
      if (this.station && this.station.powered === false) return false;
      return !(this.government && this.government.station_powered === false
        && this.buildings.some((b) => b.status === 'built'));
    },
    // interaction requires: government formed, the system directly
    // player-controlled by my own faction — mirrors the server gates
    isOwnFactionSystem() {
      return this.system.status === 'inhabited_player'
        && this.system.owner
        && this.faction
        && this.system.owner.faction_id === this.faction.id;
    },
    isLeader() {
      const leader = this.government && this.government.seats.leader;
      return !!leader && leader.player_id === this.player.id;
    },
    // the Tetrarch may act for a council seat (royal prerogative — the
    // server bills the tyranny malus; here we only open the controls)
    canOverreach() {
      return this.faction && this.faction.key === 'tetrarchy' && this.isLeader;
    },
    isCabinet() {
      return ['economy', 'military'].some((seat) => this.holdsSeat(seat)) || this.canOverreach;
    },
    canInteract() {
      return !!this.government && this.government.phase === 'running'
        && this.isOwnFactionSystem && this.isCabinet;
    },
    visible() {
      return this.buildings.length > 0 || this.construction !== null || this.canInteract;
    },
    occupiedSlots() {
      const slots = this.buildings.flatMap((b) => b.slots);
      if (this.construction && this.construction.kind === 'new') slots.push(...this.construction.slots);
      return slots;
    },
    gridEntries() {
      const entries = [];
      const covered = new Set();

      this.buildings.forEach((building) => {
        building.slots.forEach((s) => covered.add(s));
        const data = this.dataFor(building.key);
        const seat = data ? data.seat : null;
        const disabled = building.status !== 'built';

        entries.push({
          key: `building-${building.id}`,
          type: 'building',
          icon: BUILDING_ICONS[building.key] || 'building/frame_orbital',
          level: building.level,
          maxLevel: data ? data.levels.length : 1,
          seat,
          buildingId: building.id,
          buildingKey: building.key,
          canManage: this.canInteract && this.canManageSeat(seat),
          classes: {
            'is-building': true,
            'is-disabled': disabled,
            'is-clickable': this.canInteract && this.canManageSeat(seat) && !disabled,
          },
          style: this.spanStyle(building.slots),
          tooltip: this.buildingTooltip(building, data, disabled),
          onClick: this.canInteract && this.canManageSeat(seat) && !disabled
            ? () => this.openUpgrade(building, data)
            : null,
        });
      });

      if (this.construction && this.construction.kind === 'new') {
        this.construction.slots.forEach((s) => covered.add(s));
        entries.push({
          key: 'construction',
          type: 'construction',
          icon: BUILDING_ICONS[this.construction.key] || 'building/frame_orbital',
          done: this.construction.total_labor - this.construction.remaining_labor,
          total: this.construction.total_labor,
          increase: this.system.production.value,
          classes: { 'is-construction': true },
          style: this.spanStyle(this.construction.slots),
          tooltip: this.$t('galaxy.station.under_construction'),
          onClick: null,
        });
      }

      for (let slot = 0; slot < GRID_SLOTS; slot += 1) {
        if (!covered.has(slot)) {
          const clickable = this.canInteract && !this.construction;
          entries.push({
            key: `slot-${slot}`,
            type: 'empty',
            clickable,
            classes: { 'is-empty': true, 'is-clickable': clickable },
            style: this.spanStyle([slot]),
            tooltip: clickable
              ? this.$t('galaxy.station.slot_hint')
              : this.$t('galaxy.station.slot_empty'),
            onClick: clickable ? () => { this.picker = slot; } : null,
          });
        }
      }

      return entries;
    },
    buildOptions() {
      if (this.picker === null) return [];
      const anchor = this.picker;

      return this.buildingData.map((data) => {
        const levelInfo = data.levels[0];
        const reasons = [];

        if (this.buildings.some((b) => b.key === data.key)) {
          reasons.push(this.$t('galaxy.station.already_built'));
        }
        if (!this.canManageSeat(data.seat)) {
          reasons.push(this.$t(`galaxy.station.requires_seat_${data.seat}`));
        }
        if (data.patent && !(this.government.faction_patents || []).includes(data.patent)) {
          reasons.push(this.$t('galaxy.station.requires_patent', {
            patent: this.$t(`data.faction_patent.${data.patent}.name`),
          }));
        }
        if (!this.fits(data.shape, anchor)) {
          reasons.push(this.$t('galaxy.station.doesnt_fit'));
        }
        if (!this.affordable(levelInfo.cost)) {
          reasons.push(this.$t('galaxy.station.treasury_insufficient'));
        }

        return {
          key: data.key,
          seat: data.seat,
          shape: data.shape,
          anchor,
          icon: BUILDING_ICONS[data.key] || 'building/frame_orbital',
          costs: this.costList(levelInfo.cost),
          status: reasons.length === 0 ? 'available' : 'unavailable',
          reason: reasons.join('<br>'),
        };
      });
    },
    constructionRemainingTicks() {
      if (!this.construction || this.system.production.value <= 0) return 0;
      return this.construction.remaining_labor / this.system.production.value;
    },
    factionReceivedAt() {
      return (this.faction && this.faction.receivedAt) || Date.now();
    },
    myGateway() {
      return this.buildings.find((b) => b.key === 'gateway' && b.status === 'built'
        && this.faction && b.faction_id === this.faction.id);
    },
    gatewayLink() {
      const links = (this.government && this.government.gateway_links) || [];
      return links.find((l) => l.endpoints.some((e) => e.system_id === this.system.id)) || null;
    },
    gatewayPanel() {
      if (!this.myGateway || !this.government) return null;
      const link = this.gatewayLink;
      const other = link && link.endpoints.find((e) => e.system_id !== this.system.id);
      return { link, otherName: other ? this.systemName(other.system_id) : '' };
    },
    linkTargets() {
      const registry = (this.government && this.government.station_buildings) || [];
      const links = (this.government && this.government.gateway_links) || [];

      return registry
        .filter((entry) => entry.key === 'gateway' && entry.status === 'built' && entry.system_id !== this.system.id)
        .filter((entry) => !links.some((l) => l.endpoints.some((e) => e.system_id === entry.system_id)))
        .map((entry) => ({ system_id: entry.system_id, name: this.systemName(entry.system_id) }));
    },
  },
  watch: {
    'system.id': function onSystemChange() { this.picker = null; },
  },
  methods: {
    dataFor(key) { return this.buildingData.find((d) => d.key === key); },
    holdsSeat(seat) {
      const holder = this.government && this.government.seats[seat];
      return !!holder && holder.player_id === this.player.id;
    },
    canManageSeat(seat) { return this.holdsSeat(seat) || this.canOverreach; },
    canManageKey(key) {
      const data = this.dataFor(key);
      return this.canInteract && data && this.canManageSeat(data.seat);
    },
    fits(shape, anchor) {
      const anchorCol = anchor % GRID_COLS;
      const anchorRow = Math.floor(anchor / GRID_COLS);
      if (anchorCol + shape.cols > GRID_COLS || anchorRow + shape.rows > GRID_SLOTS / GRID_COLS) return false;

      const occupied = this.occupiedSlots;
      for (let r = 0; r < shape.rows; r += 1) {
        for (let c = 0; c < shape.cols; c += 1) {
          if (occupied.includes(anchor + r * GRID_COLS + c)) return false;
        }
      }
      return true;
    },
    affordable(cost) {
      const treasury = (this.government && this.government.treasury) || {};
      return ['credit', 'technology', 'ideology']
        .every((resource) => (treasury[resource] || 0) >= (cost[resource] || 0));
    },
    costList(cost) {
      return ['credit', 'technology', 'ideology']
        .filter((resource) => (cost[resource] || 0) > 0)
        .map((resource) => ({ icon: resource, value: cost[resource] }));
    },
    spanStyle(slots) {
      const rows = slots.map((s) => Math.floor(s / GRID_COLS));
      const cols = slots.map((s) => s % GRID_COLS);
      const rowStart = Math.min(...rows) + 1;
      const colStart = Math.min(...cols) + 1;
      return {
        gridRow: `${rowStart} / span ${Math.max(...rows) - rowStart + 2}`,
        gridColumn: `${colStart} / span ${Math.max(...cols) - colStart + 2}`,
      };
    },
    buildingTooltip(building, data, disabled) {
      const name = this.$t(`data.faction_building.${building.key}.name`);
      const parts = [`<strong>${name}</strong>`];
      if (data && data.levels.length > 1) parts.push(this.$t('galaxy.station.level', { level: building.level }));
      if (disabled) parts.push(this.$t('galaxy.station.disabled_hint'));
      else if (!this.powered) parts.push(this.$t('galaxy.station.unpowered_hint'));
      return parts.join('<br>');
    },
    openUpgrade(building, data) {
      if (!data || building.level >= data.levels.length) return;
      const levelInfo = data.levels[building.level];
      const costs = this.costList(levelInfo.cost)
        .map((c) => `${Math.floor(c.value)} ${this.$t(`galaxy.station.resource_${c.icon}`)}`)
        .join(', ');

      // eslint-disable-next-line no-alert
      if (window.confirm(this.$t('galaxy.station.upgrade_confirm', {
        name: this.$t(`data.faction_building.${building.key}.name`),
        level: building.level + 1,
        costs,
      }))) {
        this.push('gov_order_station_building', {
          system_id: this.system.id,
          key: building.key,
          anchor: building.slots[0],
        });
      }
    },
    order(option) {
      this.picker = null;
      this.push('gov_order_station_building', {
        system_id: this.system.id,
        key: option.key,
        anchor: option.anchor,
      });
    },
    demolish(entry) {
      // eslint-disable-next-line no-alert
      if (window.confirm(this.$t('galaxy.station.demolish_confirm', {
        name: this.$t(`data.faction_building.${entry.buildingKey}.name`),
      }))) {
        this.push('gov_demolish_station_building', {
          system_id: this.system.id,
          building_id: entry.buildingId,
        });
      }
    },
    cancelConstruction() {
      this.push('gov_cancel_station_building', { system_id: this.system.id });
    },
    systemName(systemId) {
      const galaxy = this.$store.state.game.galaxy;
      const systems = (galaxy && galaxy.stellar_systems) || [];
      const found = systems.find((s) => s.id === systemId);
      return found ? found.name : `#${systemId}`;
    },
    linkGateway() {
      if (this.linkTarget === null) return;
      this.push('gov_gateway_link', { system_a: this.system.id, system_b: this.linkTarget });
      this.linkTarget = null;
    },
    unlinkGateway() {
      // eslint-disable-next-line no-alert
      if (window.confirm(this.$t('galaxy.station.unlink_confirm'))) {
        this.push('gov_gateway_unlink', { system_id: this.system.id });
      }
    },
    push(message, payload) {
      this.$socket.faction.push(message, payload)
        .receive('ok', () => this.$store.dispatch('game/reloadSystem', this.$socket))
        .receive('error', (err) => this.$toastError(err.reason));
    },
  },
};
</script>
