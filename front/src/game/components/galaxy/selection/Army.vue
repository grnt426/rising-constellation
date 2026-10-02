<template>
  <!-- A labelled region (a landmark screen readers can jump to): the
       agent card only says a fleet exists, the ships are read here when
       the player moves into this section. The visual grid is hidden from
       screen readers in favor of the spoken list; its controls (reaction
       picker, scrap, build) stay reachable with the keyboard. -->
  <div
    class="army-container"
    :class="`context-${context}`"
    :role="diff ? 'group' : 'region'"
    :aria-label="$t('a11y.fleet.region', { name: character.name })">
    <p class="sr-only">{{ fleetSummaryText }}</p>
    <ul class="sr-only">
      <li
        v-for="item in spokenSlots"
        :key="item.index">{{ item.label }}</li>
      <li v-if="emptySlots">{{ $tc('a11y.fleet.empty_slots', emptySlots, { n: emptySlots }) }}</li>
    </ul>

    <template v-if="hasHeader">
      <div
        class="army-reactions"
        :class="`is-${halign}`">
        <div
          v-if="character.army.reaction"
          class="item active"
          role="img"
          :tabindex="context === 'selection' ? 0 : null"
          :aria-label="reactionLabel(character.army.reaction)"
          v-tooltip.left="$t(`character_reaction.${character.army.reaction}`)">
          <svgicon
            :name="`reaction/${character.army.reaction}`"
            aria-hidden="true" />
        </div>
        <div
          v-else
          class="item active">
          ?
        </div>

        <div
          v-if="context === 'selection'"
          class="hidden">
          <div
            v-for="reaction in reactions"
            v-press
            v-tooltip.left="$t(`character_reaction.${reaction}`)"
            class="item"
            :key="reaction"
            :aria-pressed="String(reaction === character.army.reaction)"
            :aria-label="reactionLabel(reaction)"
            @click="updateReaction(reaction)">
            <svgicon
              :name="`reaction/${reaction}`"
              aria-hidden="true" />
          </div>
        </div>
      </div>
      <div class="army-header">
        <div>
          <div
            v-if="!character.army.repair_coef"
            class="def-list-prop">
            <span aria-hidden="true">░░ <svgicon name="ship/repair" /></span>
            <span class="sr-only">{{ $t('galaxy.selection.view.army_repair') }}: {{ $t('a11y.unknown') }}</span>
          </div>
          <v-popover
            v-else
            :trigger="popoverTrigger">
            <div class="def-list-prop">
              <span class="sr-only">{{ $t('galaxy.selection.view.army_repair') }}:</span>
              {{ character.army.repair_coef.value | integer }}
              <svgicon
                name="ship/repair"
                aria-hidden="true" />
            </div>
            <resource-detail
              slot="popover"
              :title="$t('galaxy.selection.view.army_repair')"
              :precision="0"
              :value="character.army.repair_coef.value"
              :details="character.army.repair_coef.details" />
          </v-popover>

          <div
            v-if="!character.army.raid_coef"
            class="def-list-prop">
            <span aria-hidden="true">░░ <svgicon name="ship/raid" /></span>
            <span class="sr-only">{{ $t('galaxy.selection.view.army_raid') }}: {{ $t('a11y.unknown') }}</span>
          </div>
          <v-popover
            v-else
            :trigger="popoverTrigger">
            <div class="def-list-prop">
              <span class="sr-only">{{ $t('galaxy.selection.view.army_raid') }}:</span>
              {{ character.army.raid_coef.value | integer }}
              <svgicon
                name="ship/raid"
                aria-hidden="true" />
            </div>
            <resource-detail
              slot="popover"
              :title="$t('galaxy.selection.view.army_raid')"
              :precision="0"
              :value="character.army.raid_coef.value"
              :details="character.army.raid_coef.details" />
          </v-popover>

          <div
            v-if="!character.army.invasion_coef"
            class="def-list-prop">
            <span aria-hidden="true">░░ <svgicon name="ship/invasion" /></span>
            <span class="sr-only">{{ $t('galaxy.selection.view.army_invasion') }}: {{ $t('a11y.unknown') }}</span>
          </div>
          <v-popover
            v-else
            :trigger="popoverTrigger">
            <div class="def-list-prop">
              <span class="sr-only">{{ $t('galaxy.selection.view.army_invasion') }}:</span>
              {{ character.army.invasion_coef.value | integer }}
              <svgicon
                name="ship/invasion"
                aria-hidden="true" />
            </div>
            <resource-detail
              slot="popover"
              :title="$t('galaxy.selection.view.army_invasion')"
              :precision="0"
              :value="character.army.invasion_coef.value"
              :details="character.army.invasion_coef.details" />
          </v-popover>
        </div>

        <div>
          <div
            v-if="!character.army.maintenance"
            class="def-list-prop">
            <span aria-hidden="true">░░░ <svgicon name="resource/credit" /></span>
            <span class="sr-only">{{ $t('galaxy.selection.view.army_maintenance') }}: {{ $t('a11y.unknown') }}</span>
          </div>
          <v-popover
            v-else
            :trigger="popoverTrigger">
            <div class="def-list-prop">
              <span class="sr-only">{{ $t('galaxy.selection.view.army_maintenance') }}:</span>
              {{ character.army.maintenance.value | income(0) }}
              <svgicon
                name="resource/credit"
                aria-hidden="true" />
            </div>
            <resource-detail
              slot="popover"
              :income="true"
              :title="$t('galaxy.selection.view.army_maintenance')"
              :precision="0"
              :value="character.army.maintenance.value"
              :details="character.army.maintenance.details" />
          </v-popover>
        </div>
      </div>
    </template>

    <div
      class="army-line"
      v-for="i in character.army.tiles.length / armyLineSize"
      :key="i">
      <div
        class="header"
        aria-hidden="true">
        {{ $t('galaxy.selection.view.line_short', {n: i}) }}
      </div>
      <div
        v-for="j in armyLineSize"
        :key="getTileIndex(i, j)">
        <template v-if="getTile(i, j).ship_status === 'filled'">
          <div
            class="tile"
            :class="{ 'is-destroyed': diff && getTile(i, j, true).ship_status === 'empty' }"
            @mouseenter="enterTile(getTile(i, j))"
            @mouseleave="leaveTile">
            <svgicon
              v-if="getTile(i, j).ship !== 'hidden'"
              class="tile-icon is-rotated"
              aria-hidden="true"
              :name="`ship/${getTile(i, j).ship.key}`" />
            <svgicon
              v-else
              class="tile-icon is-rotated"
              aria-hidden="true"
              name="ship/frame_ship_hidden" />
            <div
              class="tile-level"
              aria-hidden="true">
              <template v-if="getTile(i, j).ship !== 'hidden' && getTile(i, j).ship.level !== 'hidden'">
                <template v-if="!diff">
                  {{ getTile(i, j).ship.level + 1 }}
                </template>
                <template v-else-if="getTile(i, j, true).ship_status !== 'empty'">
                  {{ getTile(i, j, true).ship.level + 1 }}
                </template>
              </template>
              <template v-else>?</template>
            </div>
            <div
              v-if="getTile(i, j).ship !== 'hidden' && getTile(i, j).ship.units !== 'hidden'"
              class="life-container"
              aria-hidden="true">
              <template v-if="!diff">
                <div class= "life-content" :style="{ 'height': `${getTileLife(i, j)}%` }"></div>
              </template>
              <template v-else>
                <div class= "life-content is-fadded" :style="{ 'height': `${getTileLife(i, j)}%` }"></div>
                <template v-if="getTile(i, j, true).ship_status !== 'empty'">
                  <div class= "life-content" :style="{ 'height': `${getTileLife(i, j, true)}%` }"></div>
                </template>
              </template>
            </div>
            <div
              v-if="context === 'selection'"
              v-press
              v-tooltip.bottom="$t('card.ship.scrap_ship')"
              :aria-label="`${$t('card.ship.scrap_ship')}: ${slotLabel(i, j)}`"
              class="tile-toast is-hidden bottom right is-active"
              @click="destroyShip(getTile(i, j).id)">
              <svgicon
                name="close"
                aria-hidden="true" />
            </div>
          </div>
        </template>
        <template v-if="getTile(i, j).ship_status === 'planned'">
          <div
            class="tile"
            @mouseenter="enterTile(getTile(i, j))"
            @mouseleave="leaveTile">
            <svgicon
              class="tile-icon is-rotated is-transparent"
              aria-hidden="true"
              :name="`ship/${getTile(i, j).ship.key}`" />
            <div
              v-tooltip.bottom="$t('card.ship.under_production')"
              class="tile-toast bottom left"
              aria-hidden="true">
              <svgicon name="options" />
            </div>
          </div>
        </template>
        <template v-if="getTile(i, j).ship_status === 'empty'">
          <div
            :class="{
              'is-hoverable': isIdleAndAtHome,
              'is-active': isIdleAndAtHome && false,
              'has-dashed-background': context === 'selection' && !isIdleAndAtHome,
              'is-active': activeTile === getTile(i, j).id,
            }"
            class="tile"
            v-bind="emptyTileAttrs(i, j)"
            @click="clickTile(getTileIndex(i, j))"
            @keydown.enter.self.prevent="clickTile(getTileIndex(i, j))"
            @keydown.space.self.prevent="clickTile(getTileIndex(i, j))">
            <svgicon
              v-if="context === 'selection' && !isIdleAndAtHome"
              class="tile-icon is-transparent is-small"
              aria-hidden="true"
              name="unlock" />
          </div>
        </template>
      </div>
    </div>
    <div
      v-if="hoveredTile"
      class="army-ship-card"
      :class="`is-${valign} is-${halign}`">
      <ship-card
        :shipKey="hoveredTile.ship.key"
        :ship="hoveredTile.ship"
        :theme="theme" />
    </div>
  </div>
</template>

<script>
import PopoverTriggerMixin from '@/game/mixins/PopoverTriggerMixin';
import { fleetSentence, fleetStats, shipSlotLabel } from '@/game/a11y/describe';
import ShipCard from '@/game/components/card/ShipCard.vue';
import ResourceDetail from '@/game/components/generic/ResourceDetail.vue';

export default {
  mixins: [PopoverTriggerMixin],
  name: 'army',
  props: {
    character: Object,
    theme: String,
    diff: {
      type: Object,
      default: null,
    },
    halign: {
      type: String,
      default: 'left',
    },
    valign: {
      type: String,
      default: 'bottom',
    },
    context: {
      type: String,
      default: 'display',
    },
    isIdleAndAtHome: {
      type: Boolean,
      default: false,
    },
    hasHeader: {
      type: Boolean,
      default: true,
    },
  },
  data() {
    return {
      hoveredTile: undefined,
      armyLineSize: 3,
      reactions: ['flee', 'fight_back', 'defend', 'attack_enemies', 'attack_everyone'],
    };
  },
  computed: {
    shipsData() { return this.$store.state.game.data.ship; },
    fleetSummaryText() {
      const stats = fleetStats(this, this.character);
      return fleetSentence(this, stats) || this.$t('a11y.fleet.no_ships');
    },
    // Built and planned ships, one spoken line each; empty slots are
    // only counted (eighteen "empty" lines help nobody).
    spokenSlots() {
      return this.character.army.tiles
        .map((tile, index) => ({ tile, index }))
        .filter(({ tile }) => tile.ship_status !== 'empty')
        .map(({ tile, index }) => ({
          index,
          label: shipSlotLabel(
            this,
            tile,
            Math.floor(index / this.armyLineSize) + 1,
            (index % this.armyLineSize) + 1,
          ),
        }));
    },
    emptySlots() {
      return this.character.army.tiles.filter((tile) => tile.ship_status === 'empty').length;
    },
    activeTile() {
      const production = this.$store.state.game.production;

      if (production && production.data.type === 'ship'
        && production.data.targetId === this.character.id) {
        return production.data.tileId;
      }
      return 0;
    },
  },
  methods: {
    // Reaction strings carry <strong> markup for the tooltip; DOMParser
    // documents are inert, so this only extracts the text.
    reactionLabel(reaction) {
      const text = this.$t(`character_reaction.${reaction}`);
      return new DOMParser().parseFromString(text, 'text/html').body.textContent;
    },
    slotLabel(line, nth) {
      return shipSlotLabel(this, this.getTile(line, nth), line, nth);
    },
    // An empty slot the player can build in is a keyboard button;
    // otherwise it's decoration.
    emptyTileAttrs(line, nth) {
      if (this.context !== 'selection' || !this.isIdleAndAtHome) return { 'aria-hidden': 'true' };
      return {
        role: 'button',
        tabindex: 0,
        'aria-label': this.$t('a11y.fleet.build_in', {
          slot: this.$t('a11y.fleet.slot', { line, slot: nth }),
        }),
      };
    },
    clickTile(tileId) {
      if (this.context === 'selection') {
        const tile = this.character.army.tiles[tileId - 1];
        if (tile.ship_status === 'empty' && this.isIdleAndAtHome) {
          if (!this.$store.state.game.selectedSystem) {
            this.$store.dispatch('game/openSystem', {
              vm: this,
              id: this.character.system,
            }).then(() => {
              this.toggleProduction(tileId);
            });
          } else {
            this.toggleProduction(tileId);
          }
        }
      }
    },
    toggleProduction(tileId) {
      if (this.context === 'selection') {
        const active = this.activeTile;

        if (active) {
          this.$store.commit('game/clearProduction');
        }

        if (active !== tileId) {
          this.$ambiance.sound('open-production');
          this.$store.commit('game/prepareProduction', {
            systemId: this.character.system,
            data: {
              type: 'ship',
              targetId: this.character.id,
              tileId,
            },
          });
        }
      }
    },
    updateReaction(reaction) {
      if (this.context === 'selection') {
        if (this.character.type === 'admiral') {
          this.$socket.player.push('update_reaction', {
            character_id: this.character.id,
            reaction,
          }).receive('error', (data) => {
            this.$toastError(data.reason);
          });
        }
      }
    },
    destroyShip(tileId) {
      if (this.context === 'selection') {
        if (this.character.type === 'admiral') {
          this.$socket.player.push('destroy_ship', {
            character_id: this.character.id,
            tile_id: tileId,
          }).receive('ok', () => {
            this.leaveTile();
          }).receive('error', (data) => {
            this.$toastError(data.reason);
          });
        }
      }
    },
    getTileIndex(line, nth) {
      return ((line - 1) * this.armyLineSize) + nth;
    },
    getTile(line, nth, isDiff = false) {
      if (isDiff) {
        return this.diff.army
          ? this.diff.army.tiles[this.getTileIndex(line, nth) - 1]
          : { id: 0, ship_status: 'empty', ship: null };
      }

      return this.character.army.tiles[this.getTileIndex(line, nth) - 1];
    },
    getTileLife(line, nth, isDiff = false) {
      const tile = this.getTile(line, nth, isDiff);
      const shipData = this.shipsData.find((ship) => ship.key === tile.ship.key);

      const maxLife = shipData.unit_hull * shipData.unit_count;
      const currentLife = tile.ship.units.reduce((acc, unit) => unit.hull + acc, 0);

      return (currentLife / maxLife) * 100;
    },
    enterTile(payload) {
      if (payload.ship !== 'hidden') {
        this.hoveredTile = payload;
      }
    },
    leaveTile() {
      this.hoveredTile = undefined;
    },
  },
  components: {
    ResourceDetail,
    ShipCard,
  },
};
</script>
