<template>
  <!-- The construction screen's fixed top third. Everything a build
       decision needs lives here — palette, details, cost, confirm — so
       the tile grid below stays a map you point at rather than a field
       of 20px icons you have to hit exactly. -->
  <div
    class="msv-dock msv-build-dock"
    :class="{ 'is-active': mode !== 'idle' }">
    <!-- 1. an empty slot is selected: pick what goes in it -->
    <template v-if="mode === 'palette'">
      <div class="msv-dock-head">
        <svgicon :name="`stellar_body/${body.type}`" />
        <span class="msv-dock-title">{{ body.name }}</span>
        <span class="msv-dock-sub">{{ $t(`data.stellar_body.${body.type}.name`) }}</span>
        <button
          class="msv-dock-dismiss"
          @click="clearSlot">
          <svgicon name="close" />
        </button>
      </div>

      <div class="msv-palette">
        <div
          v-for="opt in options"
          :key="opt.data.key"
          class="msv-palette-item tile"
          :class="{
            'is-selected': choiceKey === opt.data.key,
            'has-dashed-background': opt.status === 'locked',
            'is-disabled': opt.status === 'disabled',
          }"
          @click="choiceKey = opt.data.key">
          <svgicon
            v-if="opt.status === 'locked'"
            class="tile-icon is-transparent is-small"
            name="unlock" />
          <svgicon
            v-else
            class="tile-icon"
            :class="{ 'is-transparent': opt.status === 'disabled' }"
            :name="`building/${opt.data.key}`" />
        </div>
      </div>

      <div
        v-if="choice"
        class="msv-dock-detail">
        <building-card
          class="is-dock-card"
          :buildingKey="choice.data.key"
          :level="1"
          :body="body"
          :system="system"
          :theme="color"
          :showCost="true"
          :disabled="choice.message"
          context="blueprint" />
      </div>
      <div
        v-else
        class="msv-dock-hint">
        {{ $t('galaxy.system.mobile.pick_building') }}
      </div>

      <div class="msv-dock-actions">
        <button
          class="msv-dock-button is-primary"
          :class="{ 'is-disabled': !canBuild }"
          @click="canBuild && orderBuild()">
          {{ $t('galaxy.system.mobile.build') }}
        </button>
      </div>
    </template>

    <!-- 2. a built (or damaged) building is selected: inspect and act -->
    <template v-else-if="mode === 'inspect'">
      <div class="msv-dock-head">
        <svgicon :name="`stellar_body/${inspect.body.type}`" />
        <span class="msv-dock-title">{{ inspect.body.name }}</span>
        <button
          class="msv-dock-dismiss"
          @click="$emit('clearInspect')">
          <svgicon name="close" />
        </button>
      </div>

      <div class="msv-dock-detail is-single">
        <building-card
          class="is-dock-card"
          :buildingKey="inspect.tile.building_key"
          :level="inspect.tile.building_level || 1"
          :body="inspect.body"
          :system="system"
          :theme="color"
          :showCost="false"
          context="built" />
      </div>

      <div
        v-if="isOwnSystem"
        class="msv-dock-actions">
        <button
          v-if="inspectActions.includes('repair')"
          class="msv-dock-button is-primary"
          @click="orderTile('repair')">
          {{ $t('card.building.repair') }}
        </button>
        <button
          v-if="inspectActions.includes('upgrade')"
          class="msv-dock-button is-primary"
          @click="orderTile('build')">
          {{ $t('card.building.upgrade') }}
        </button>
        <button
          v-if="inspectActions.includes('delete')"
          class="msv-dock-button is-danger"
          :class="{ 'is-armed': confirmingDelete }"
          @click="destroyTile">
          {{ confirmingDelete
            ? $t('galaxy.system.mobile.confirm_destroy')
            : $t('card.building.delete') }}
        </button>
      </div>
    </template>

    <!-- 3. nothing selected: what's cooking, and how to start -->
    <template v-else>
      <div class="msv-dock-head">
        <span class="msv-dock-title">{{ $t('galaxy.system.mobile.construction') }}</span>
      </div>

      <div
        v-if="queue.length > 0"
        class="msv-dock-queue">
        <div
          v-for="item in queue"
          :key="`q-${item.id}`"
          class="msv-queue-item">
          <svgicon :name="item.type === 'ship' ? `ship/${item.prod_key}` : `building/${item.prod_key}`" />
          <span class="msv-queue-name">
            {{ item.type === 'ship'
              ? $t(`data.ship.${item.prod_key}.name`)
              : $t(`data.building.${item.prod_key}.name`) }}
          </span>
          <counter
            class="msv-queue-eta"
            :current="etaTicks(item)"
            :receivedAt="system.receivedAt" />
        </div>
      </div>

      <div class="msv-dock-hint">
        {{ isOwnSystem
          ? $t('galaxy.system.mobile.build_hint')
          : $t('galaxy.system.mobile.inspect_hint') }}
      </div>
    </template>
  </div>
</template>

<script>
import { buildingOptions } from '@/game/production-options';
import buildingValidation from '@/utils/buildingValidation';
import BuildingCard from '@/game/components/card/BuildingCard.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'mobile-build-dock',
  props: {
    system: Object,
    color: String,
    isOwnSystem: Boolean,
    // { body, tile } of a built building the player tapped, or null
    inspect: { type: Object, default: null },
  },
  data() {
    return {
      // key of the palette entry whose card is showing
      choiceKey: null,
      // demolition is destructive and the button sits under a thumb —
      // the first tap arms it, the second does it
      confirmingDelete: false,
      confirmTimer: null,
    };
  },
  computed: {
    production() { return this.$store.state.game.production; },
    // The palette only opens for THIS system's slot: prepareProduction
    // also drives ship orders from a fleet elsewhere.
    slot() {
      const p = this.production;
      if (!p || p.data.type !== 'building') return null;
      if (p.systemId !== undefined && p.systemId !== this.system.id) return null;
      return p.data;
    },
    mode() {
      if (this.slot && this.body && this.tile) return 'palette';
      if (this.inspect) return 'inspect';
      return 'idle';
    },
    body() { return this.slot ? this.findBody(this.slot.targetId) : null; },
    tile() {
      return this.body ? this.body.tiles.find((t) => t.id === this.slot.tileId) : null;
    },
    options() {
      return this.mode === 'palette'
        ? buildingOptions(this.$store.state.game, this.system, this.body, this.tile)
        : [];
    },
    choice() {
      return this.options.find((o) => o.data.key === this.choiceKey) || null;
    },
    canBuild() {
      return this.isOwnSystem && this.choice && this.choice.status === 'buildable';
    },
    // Same rules the tile grid uses for its corner buttons, so the dock
    // never offers an action the grid would refuse.
    inspectActions() {
      if (!this.inspect) return [];
      const { tile, body } = this.inspect;
      const actions = [];
      const data = this.$store.state.game.data.building.find((b) => b.key === tile.building_key);

      if (tile.building_status === 'damaged' && tile.construction_status === 'none') {
        actions.push('repair');
      }
      if (data) {
        const patents = this.$store.state.game.player.patents;
        if (buildingValidation.upgradeBuildingStatus(tile, body, patents, data)) {
          actions.push('upgrade');
        }
        if (data.type !== 'infrastructure' && tile.construction_status === 'none') {
          actions.push('delete');
        }
      }

      return actions;
    },
    queue() {
      return this.system.queue ? this.system.queue.queue : [];
    },
  },
  watch: {
    // A fresh slot must not inherit the previous slot's highlighted
    // option — the two tiles rarely accept the same buildings.
    slot() { this.choiceKey = null; },
    inspect() { this.disarmDelete(); },
  },
  methods: {
    findBody(uid) {
      for (let i = 0; i < this.system.bodies.length; i += 1) {
        const body = this.system.bodies[i];
        if (body.uid === uid) return body;
        const sub = body.bodies.find((sb) => sb.uid === uid);
        if (sub) return sub;
      }
      return null;
    },
    etaTicks(item) {
      return this.system.production && this.system.production.value
        ? item.remaining_prod / this.system.production.value
        : 0;
    },
    clearSlot() {
      this.$store.commit('game/clearProduction');
    },
    orderBuild() {
      this.$ambiance.sound('order-building');
      this.$socket.player.push('order_building', {
        system_id: this.system.id,
        production_data: {
          type: 'build',
          target_id: this.body.uid,
          tile_id: this.tile.id,
          prod_key: this.choice.data.key,
          prod_level: 1,
        },
      }).receive('ok', () => {
        this.choiceKey = null;
        this.clearSlot();
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    orderTile(type) {
      const { body, tile } = this.inspect;
      const level = type === 'build' ? tile.building_level + 1 : tile.building_level;

      this.$ambiance.sound('order-building');
      this.$socket.player.push('order_building', {
        system_id: this.system.id,
        production_data: {
          type,
          target_id: body.uid,
          tile_id: tile.id,
          prod_key: tile.building_key,
          prod_level: level,
        },
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    destroyTile() {
      if (!this.confirmingDelete) {
        this.confirmingDelete = true;
        // Disarm on its own: an armed demolish button left sitting
        // there is one stray thumb away from a mistake.
        this.confirmTimer = setTimeout(() => { this.confirmingDelete = false; }, 4000);
        return;
      }

      this.disarmDelete();
      const { body, tile } = this.inspect;
      this.$socket.player.push('remove_building', {
        system_id: this.system.id,
        production_data: { target_id: body.uid, tile_id: tile.id },
      }).receive('ok', () => {
        this.$emit('clearInspect');
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    disarmDelete() {
      clearTimeout(this.confirmTimer);
      this.confirmingDelete = false;
    },
  },
  beforeDestroy() {
    clearTimeout(this.confirmTimer);
  },
  components: { BuildingCard, Counter },
};
</script>
