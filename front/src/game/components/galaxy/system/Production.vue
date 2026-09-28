<template>
  <div
    v-if="isQueueOpen || production"
    :class="{ 'has-background': production }"
    class="system-production">
    <template v-if="production">
      <div class="system-production-header">
        <template v-if="productionType === 'building'">
          <svgicon :name="`stellar_body/${body.type}`" />
          <span>{{ $t('production.build_on') }}</span>
          <strong>{{ body.name }}</strong>
        </template>
        <template v-else>
          <svgicon name="agent/admiral" />
          <span>{{ $t('production.order_for') }}</span>
          <strong>{{ character.name }}</strong>

          <div
            class="header-button"
            @click="showAllShips = !showAllShips">
            <span
              v-tooltip="$t('production.hide_all_ships')"
              v-if="showAllShips">−</span>
            <span
              v-tooltip="$t('production.shows_all_ships')"
              v-else>+</span>
          </div>
        </template>
      </div>
      <v-scrollbar
        :settings="scrollbarSettings"
        class="system-production-content">
        <div
          v-for="category in categories"
          :key="category"
          class="system-production-category">
          <div
            v-for="{ data, status, message } in itemByCategory(category)"
            :key="data.key">
            <div
              class="tile"
              :class="{
                'is-hoverable': status === 'buildable',
                'has-dashed-background': status === 'locked',
              }"
              @click="order(data, status, productionType)"
              @mouseenter="enterTile(data, message, productionType)"
              @mouseleave="leaveTile()">
              <svgicon
                v-if="status === 'locked'"
                class="tile-icon is-transparent is-small"
                name="unlock" />
              <template v-else>
                <svgicon
                  v-if="productionType === 'building'"
                  class="tile-icon"
                  :name="`building/${data.key}`"
                  :class="{ 'is-transparent': status === 'disabled' }" />
                <svgicon
                  v-else
                  class="tile-icon"
                  :name="`ship/${data.key}`"
                  :class="{ 'is-transparent': status === 'disabled' }" />
              </template>
            </div>
          </div>
        </div>
      </v-scrollbar>
      <div
        v-if="hoveredTile.type === 'building'"
        class="system-production-building-card"
        @mouseenter="hoverCardEnter"
        @mouseleave="hoverCardLeave">
        <building-card
          :buildingKey="hoveredTile.data.key"
          :level="1"
          :body="body"
          :system="system"
          :showCost="true"
          :theme="color"
          :disabled="hoveredTile.message"
          :pinned="cardPinned"
          context="blueprint"
          @close="hoverCardClose" />
      </div>
      <div
        v-if="hoveredTile.type === 'ship'"
        class="system-production-ship-card"
        @mouseenter="hoverCardEnter"
        @mouseleave="hoverCardLeave">
        <ship-card
          :shipKey="hoveredTile.data.key"
          :showCost="true"
          :theme="color"
          :system="system"
          :disabled="hoveredTile.message"
          :initialXP="0"
          :pinned="cardPinned"
          @close="hoverCardClose" />
      </div>
    </template>
    <v-scrollbar
      :settings="scrollbarSettings"
      v-else-if="isQueueOpen && system.queue"
      class="system-production-queue"
      :class="{ 'is-reorderable': canReorder, 'is-dragging': dragId !== null }"
      style="width: 310px;">
      <div
        v-if="canReorder && productions.length > 1"
        class="system-production-queue-hint"
        :class="{ warning: !!resetWarning }">
        {{ resetWarning || $t('system.queue_drag_hint') }}
      </div>
      <div
        v-for="(item, index) in productions"
        :key="`production-${item.id}`"
        class="system-production-queue-item"
        :class="dropClass(index)"
        :data-production-id="item.id"
        :draggable="canReorder"
        @dragstart="onDragStart($event, item)"
        @dragenter="onDragOver($event, index)"
        @dragover="onDragOver($event, index)"
        @drop="onDrop($event)"
        @dragend="onDragEnd">
        <closed-production-card
          :production="item"
          :systemId="system.id"
          :theme="color" />
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import { buildingOptions, shipOptions } from '@/game/production-options';

import buildingValidation from '@/utils/buildingValidation';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';

import BuildingCard from '@/game/components/card/BuildingCard.vue';
import ShipCard from '@/game/components/card/ShipCard.vue';
import ClosedProductionCard from '@/game/components/card/ClosedProductionCard.vue';

export default {
  name: 'system-production',
  mixins: [HoverCardMixin],
  data() {
    return {
      hoveredTile: {},
      showAllShips: false,
      scrollbarSettings: VERTICAL_SCROLL_SETTINGS,
      // Desktop drag-to-reorder of the construction queue. `dropIndex` is
      // an insertion slot (0..n) in the displayed order; `pendingIds` is
      // the order just pushed, shown until the server's queue lands.
      dragId: null,
      dropIndex: null,
      pendingIds: null,
    };
  },
  watch: {
    // Any fresh queue from the server (delta, refetch, or a construction
    // completing) supersedes the optimistic order.
    'system.queue': function onQueueReplaced() {
      this.pendingIds = null;
    },
  },
  props: {
    system: Object,
    color: String,
    isQueueOpen: Boolean,
  },
  computed: {
    tickToMilisecondFactor() { return this.$store.getters['game/tickToMilisecondFactor']; },
    production() { return this.$store.state.game.production; },
    character() { return this.$store.state.game.selectedCharacter; },
    patents() { return this.$store.state.game.player.patents; },
    productionType() {
      return this.production
        ? this.production.data.type : '';
    },
    body() {
      return this.productionType === 'building'
        ? this.getBody(this.system, this.production.data.targetId)
        : null;
    },
    tile() {
      return this.productionType === 'building'
        ? this.body.tiles.find((t) => t.id === this.production.data.tileId)
        : null;
    },
    categories() {
      const categories = this.items.reduce((acc, item) => {
        if (this.productionType === 'building') {
          return acc.add(item.data.display);
        }
        return acc.add(item.data.class);
      }, new Set());

      return Array.from(categories);
    },
    items() {
      return this.productionType === 'building'
        ? this.buildings : this.ships;
    },
    queueItems() {
      const items = this.system.queue.queue;
      if (!this.pendingIds || this.pendingIds.length !== items.length) return items;
      const byId = new Map(items.map((item) => [item.id, item]));
      const ordered = this.pendingIds.map((id) => byId.get(id));
      return ordered.every(Boolean) ? ordered : items;
    },
    // Mobile is out of scope for reordering (no touch drag yet).
    canReorder() {
      return !viewport.isMobile && this.system.queue.queue.length > 1;
    },
    // Order the queue would have if the current drag were dropped now.
    previewIds() {
      if (this.dragId === null || this.dropIndex === null) return null;
      const ids = this.queueItems.map((item) => item.id);
      const from = ids.indexOf(this.dragId);
      if (from === -1) return null;
      ids.splice(from, 1);
      ids.splice(this.dropIndex > from ? this.dropIndex - 1 : this.dropIndex, 0, this.dragId);
      return ids;
    },
    // Progress is not carried across a reorder: warn while hovering a drop
    // that would displace the head. The head is always being built while
    // the system produces, so the stored remaining_prod (a snapshot) may
    // not show its progress yet.
    resetWarning() {
      const head = this.system.queue.queue[0];
      if (!this.previewIds || !head || this.previewIds[0] === head.id) return null;
      const started = head.remaining_prod < head.total_prod || this.system.production.value > 0;
      if (!started) return null;
      return this.$t('system.queue_reset_warning', { name: this.productionName(head) });
    },
    productions() {
      return this.queueItems.reduce((acc, item) => {
        acc.prod += item.remaining_prod;

        const remainingTicks = acc.prod / this.system.production.value;
        item.timestamp = Math.round(this.system.receivedAt + (remainingTicks * this.tickToMilisecondFactor));
        acc.queue.push(item);
        return acc;
      }, { queue: [], prod: 0 }).queue;
    },
    buildings() {
      return buildingOptions(this.$store.state.game, this.system, this.body, this.tile);
    },
    ships() {
      return shipOptions(this.$store.state.game, this.system, !this.showAllShips);
    },
  },
  methods: {
    // Phone-only outside-tap dismiss: desktop closes this panel via the
    // SVG backdrop / queue toggle, neither of which exists on mobile.
    onDocumentPointerDown(event) {
      if (!viewport.isMobile) return;
      if (this.$el && this.$el.contains && this.$el.contains(event.target)) return;
      if (this.production) {
        this.$store.commit('game/clearProduction');
      } else if (this.isQueueOpen) {
        this.$emit('closeQueue');
      }
    },
    productionName(item) {
      return item.type === 'ship'
        ? this.$t(`data.ship.${item.prod_key}.name`)
        : this.$t(`data.building.${item.prod_key}.name`);
    },
    dropClass(index) {
      if (this.dragId === null) return null;
      const item = this.productions[index];
      return {
        'is-dragged': item && item.id === this.dragId,
        'drop-before': this.dropIndex === index,
        'drop-after': this.dropIndex === index + 1 && index === this.productions.length - 1,
      };
    },
    onDragStart(event, item) {
      if (!this.canReorder) {
        event.preventDefault();
        return;
      }
      this.dragId = item.id;
      this.dropIndex = null;
      event.dataTransfer.effectAllowed = 'move';
      // Firefox refuses to start a drag without data.
      event.dataTransfer.setData('text/plain', String(item.id));
    },
    onDragOver(event, index) {
      if (this.dragId === null) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      const rect = event.currentTarget.getBoundingClientRect();
      const after = event.clientY > rect.top + (rect.height / 2);
      this.dropIndex = after ? index + 1 : index;
    },
    onDrop(event) {
      if (this.dragId === null) return;
      event.preventDefault();
      const ids = this.previewIds;
      const current = this.queueItems.map((item) => item.id);
      this.onDragEnd();
      if (!ids || ids.every((id, i) => id === current[i])) return;

      this.pendingIds = ids;
      this.$socket.player.push('reorder_production', {
        system_id: this.system.id,
        production_ids: ids,
      }).receive('error', (data) => {
        this.pendingIds = null;
        this.$toastError(data.reason);
      });
    },
    onDragEnd() {
      this.dragId = null;
      this.dropIndex = null;
    },
    enterTile(data, message, type) {
      this.hoverCardShow({ data, message, type });
    },
    leaveTile() {
      this.hoverCardHide();
    },
    hoverCardApply(payload) {
      this.hoveredTile = payload || {};
    },
    hoverCardVisible() {
      return !!this.hoveredTile.type;
    },
    order(item, status, type) {
      if (status === 'buildable') {
        const payload = type === 'building'
          ? { target_id: this.body.uid, tile_id: this.tile.id, prod_key: item.key, prod_level: 1, type: 'build' }
          : { target_id: this.character.id, tile_id: this.production.data.tileId, prod_key: item.key };

        if (type === 'building') {
          this.$ambiance.sound('order-building');
        } else {
          this.$ambiance.sound('order-ship');
        }

        this.$socket.player.push(`order_${type}`, {
          system_id: this.system.id,
          production_data: payload,
        }).receive('ok', () => {
          this.nextTile();
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
    nextTile() {
      if (this.productionType === 'building') {
        const initial = { lookingNext: false, found: false };
        const data = {
          playerPatents: this.patents,
          bodiesData: this.$store.state.game.data.stellar_body,
          buildingsData: this.$store.state.game.data.building,
        };

        const location = buildingValidation
          .findEmptyTile(this.system.bodies, this.body.uid, this.tile.id, initial, data);

        if (location.found) {
          this.$store.commit('game/prepareProduction', {
            systemId: this.systemId,
            data: {
              type: 'building',
              targetId: location.body.uid,
              tileId: location.tile.id,
            },
          });
        } else {
          this.$store.commit('game/clearProduction');
        }
      } else {
        let tile = this.character.army.tiles
          .find((t) => t.id > this.production.data.tileId && t.ship_status === 'empty');

        if (!tile) {
          tile = this.character.army.tiles.find((t) => t.id > 0 && t.ship_status === 'empty');
        }

        if (tile && tile.id !== this.production.data.tileId) {
          this.$store.commit('game/prepareProduction', {
            systemId: this.character.system,
            data: {
              type: 'ship',
              targetId: this.character.id,
              tileId: tile.id,
            },
          });
        } else {
          this.$store.commit('game/clearProduction');
        }
      }
    },
    itemByCategory(category) {
      return this.productionType === 'building'
        ? this.items.filter((item) => item.data.display === category)
        : this.items.filter((item) => item.data.class === category);
    },
    getBody(system, bodyUId) {
      for (let i = 0; i < system.bodies.length; i += 1) {
        const body = system.bodies[i];
        if (body.uid === bodyUId) return body;

        const subbody = body.bodies.find((sb) => sb.uid === bodyUId);
        if (subbody) return subbody;
      }
      return null;
    },
  },
  mounted() {
    this.onDocumentPointerDownBound = this.onDocumentPointerDown.bind(this);
    document.addEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
  beforeDestroy() {
    document.removeEventListener('pointerdown', this.onDocumentPointerDownBound, true);
  },
  components: {
    BuildingCard,
    ShipCard,
    ClosedProductionCard,
  },
};
</script>
