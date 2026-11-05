<template>
  <div v-if="validBodies.includes(body.type)">
    <div class="system-content-group-item">
      <div class="body-icon">
        <svgicon :name="`stellar_body/${body.type}`" />
      </div>
      <div class="body-info">
        <div class="body-info-type">
          {{ $t(`data.stellar_body.${body.type}.name`) }}
        </div>
        <div class="body-info-potentials">
          <div
            class="potential-item"
            :class="`f-${body.industrial_factor}`"
            v-tooltip="$t(`data.bonus_pipeline_in.body_ind.name`)">
            <span>{{ body.industrial_factor }}</span>
            <svgicon name="stellar_body/industrial_factor" />
          </div>
          <div
            class="potential-item"
            :class="`f-${body.technological_factor}`"
            v-tooltip="$t(`data.bonus_pipeline_in.body_tec.name`)">
            <span>{{ body.technological_factor }}</span>
            <svgicon name="stellar_body/technological_factor" />
          </div>
          <div
            class="potential-item"
            :class="`f-${body.activity_factor}`"
            v-tooltip="$t(`data.bonus_pipeline_in.body_act.name`)">
            <span>{{ body.activity_factor }}</span>
            <svgicon name="stellar_body/activity_factor" />
          </div>
        </div>
      </div>
      <div class="body-tiles">
        <!-- Phones: tap = the tile's next step (upgrade, or repair),
             press-and-hold = its card (level comparison, demolish). The
             corner buttons below are desktop-only: 20px hover targets
             that a thumb hits by accident. -->
        <div
          v-for="({ tile, status, icon, level, classes, iconClasses, actions }, index) in tiles"
          :key="index"
          :class="classes"
          class="tile"
          data-long-press
          @pointerdown="pressStart(tile, $event)"
          @pointermove="pressMove"
          @pointerup="pressEnd"
          @pointercancel="pressEnd"
          @click="clickTile(tile, actions)">
          <template v-if="status === 'visible'">
            <svgicon
              class="tile-icon"
              :class="iconClasses"
              :name="icon"
              @mouseenter.native="enterTile(tile, body, false)"
              @mouseleave.native="leaveTile()" />
            <div
              v-if="!['none', 'hidden'].includes(tile.construction_status)"
              v-tooltip.bottom="$t(`card.building.production.${tile.construction_status}`)"
              class="tile-toast bottom left">
              <svgicon name="options" />
            </div>
            <div
              v-if="level"
              class="tile-level">
              {{ level }}
            </div>
            <template v-if="isOwnSystem && !isMobileView">
              <div
                v-if="actions.includes('repair')"
                v-tooltip="$t('card.building.repair')"
                class="tile-toast top left is-active"
                @click.stop="buildTile(tile, 'repair')">
                <svgicon name="check" />
              </div>
              <div
                v-else-if="actions.includes('upgrade')"
                v-tooltip="$t('card.building.upgrade')"
                class="tile-toast top left is-active"
                @click.stop="buildTile(tile, 'build')"
                @mouseenter="enterTile(tile, body, true)"
                @mouseleave="leaveTile()">
                <svgicon name="caret-up" />
              </div>
              <div
                v-if="actions.includes('delete')"
                v-tooltip.bottom="$t('card.building.delete')"
                class="tile-toast is-hidden bottom right is-active"
                @click.stop="removeTile(tile)">
                <svgicon name="close" />
              </div>
            </template>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import buildingValidation from '@/utils/buildingValidation';
import viewport from '@/utils/viewport';

// Same hold time as the bottom-bar gauges and the map's action wheel.
const LONG_PRESS_MS = 450;
// A finger that travels this far is scrolling the list, not pressing.
const PRESS_SLOP_PX = 10;

export default {
  name: 'system-bodies-item',
  data() {
    return {
      validBodies: [
        'habitable_planet',
        'sterile_planet',
        'moon',
        'asteroid',
      ],
    };
  },
  created() {
    // Phone press-and-hold state (see pressStart). Not reactive: it
    // holds a timer, and nothing renders from it.
    this.press = null;
  },
  beforeDestroy() {
    this.clearPress();
  },
  props: {
    body: Object,
    isOwnSystem: Boolean,
    system: Object,
    visibility: Number,
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    patents() { return this.$store.state.game.player.patents; },
    production() { return this.$store.state.game.production; },
    buildings() { return this.$store.state.game.data.building; },
    bodies() { return this.$store.state.game.data.stellar_body; },
    bodyData() { return this.bodies.find((b) => b.key === this.body.type); },
    tiles() {
      return [...Array(8).keys()]
        .map((i) => {
          const tile = this.body.tiles[i];
          const payload = {
            tile,
            status: '',
            icon: '',
            level: '',
            classes: [],
            iconClasses: [],
            actions: [],
          };

          if (tile === undefined) {
            payload.status = 'nonexistent';
            payload.classes.push('is-transparent');
            return payload;
          }

          if (tile.type === 'infrastructure') {
            payload.classes.push('is-important');
          }

          if (['uninhabitable', 'uninhabited'].includes(this.system.status)) {
            payload.status = 'hidden';
            payload.classes.push('is-fadded');
            return payload;
          }

          payload.status = 'visible';

          if (!this.isOwnSystem) {
            if (tile.building_status === 'hidden') {
              payload.classes.push('is-fadded');
              return payload;
            }

            if (tile.building_status === 'empty') {
              return payload;
            }

            if (tile.building_status === 'damaged') {
              payload.classes.push('has-dashed-background');
            }

            payload.status = 'visible';
            payload.iconClasses.push('is-transparent');

            payload.icon = tile.building_key === 'hidden'
              ? `building/frame_${this.bodyData.biome}_hidden`
              : `building/${tile.building_key}`;

            payload.level = tile.building_level === 'hidden'
              ? '?' : tile.building_level;
          } else {
            if (this.production
              && this.production.data.type === 'building'
              && this.production.data.targetId === this.body.uid
              && this.production.data.tileId === tile.id
              && !tile.building_key) {
              payload.classes.push('is-active');
            }

            if (tile && tile.building_status === 'empty') {
              const data = { playerPatents: this.patents, bodiesData: this.bodies, buildingsData: this.buildings };

              if (buildingValidation.isBuildable(tile, this.body, data)) {
                if (tile.building_key) {
                  payload.icon = `building/${tile.building_key}`;
                  payload.iconClasses.push('is-transparent');
                  return payload;
                }

                payload.icon = `building/frame_${this.bodyData.biome}`;
                payload.iconClasses.push('is-transparent');

                if (this.isOwnSystem) {
                  payload.classes.push('is-hoverable');
                }

                return payload;
              }

              payload.classes.push('has-dashed-background');
              payload.icon = 'unlock';
              payload.iconClasses.push('is-small');
              payload.iconClasses.push('is-transparent');
              return payload;
            }

            payload.icon = `building/${tile.building_key}`;
            payload.level = tile.building_level;

            if (tile.building_status === 'damaged') {
              payload.classes.push('has-dashed-background');
              payload.iconClasses.push('is-transparent');

              if (tile.construction_status === 'none') {
                payload.actions.push('repair');
              }
            }

            const data = this.buildings.find((b) => b.key === tile.building_key);

            if (data) {
              if (buildingValidation.upgradeBuildingStatus(tile, this.body, this.patents, data)) {
                payload.actions.push('upgrade');
              }

              if (data.type !== 'infrastructure' && tile.construction_status === 'none') {
                payload.actions.push('delete');
              }
            }
          }

          return payload;
        });
    },
  },
  methods: {
    enterTile(tile, body, wantToUpgrade) {
      if (tile && tile.building_key !== null) {
        this.$emit('enterTile', { body, tile: { ...tile }, wantToUpgrade });
      }
    },
    leaveTile() {
      this.$emit('leaveTile');
    },
    isInspectable(tile) {
      return !!(tile && tile.building_key && tile.building_status !== 'hidden'
        && tile.building_key !== 'hidden');
    },
    // Phones: holding a built tile opens its card in the construction
    // dock (every level's numbers, the demolish button). The click the
    // release produces is swallowed in clickTile: the hold already did
    // what it meant.
    pressStart(tile, event) {
      this.clearPress();
      if (!this.isMobileView || event.pointerType === 'mouse' || !this.isInspectable(tile)) return;

      const press = {
        x: event.clientX, y: event.clientY, fired: false, timer: null,
      };
      press.timer = setTimeout(() => {
        press.fired = true;
        this.$emit('inspectTile', { body: this.body, tile });
      }, LONG_PRESS_MS);
      this.press = press;
    },
    pressMove(event) {
      const { press } = this;
      if (!press || press.fired) return;
      if (Math.abs(event.clientX - press.x) > PRESS_SLOP_PX
        || Math.abs(event.clientY - press.y) > PRESS_SLOP_PX) {
        this.clearPress();
      }
    },
    pressEnd(event) {
      if (!this.press) return;
      clearTimeout(this.press.timer);
      // A cancelled pointer is the browser taking the touch for a
      // scroll: no click follows, so nothing is left to swallow.
      if (event.type === 'pointercancel') this.press = null;
    },
    clearPress() {
      if (this.press) clearTimeout(this.press.timer);
      this.press = null;
    },
    clickTile(tile, actions = []) {
      const held = this.press && this.press.fired;
      this.clearPress();
      if (held) return;

      // A tile that already holds something is an inspect target, not a
      // build target: emitting on the CLICK (rather than relying on the
      // browser's emulated mouseenter) is what makes the phone build
      // dock predictable.
      if (this.isInspectable(tile)) {
        // Phones: a tap is the tile's next step. A building with no next
        // step (top level, waiting on a patent, already in the queue)
        // opens its card instead, which shows why.
        if (this.isMobileView && this.isOwnSystem) {
          if (actions.includes('repair')) {
            this.buildTile(tile, 'repair');
            return;
          }
          if (actions.includes('upgrade')) {
            this.buildTile(tile, 'build');
            return;
          }
        }
        this.$emit('inspectTile', { body: this.body, tile });
        return;
      }

      if (this.isOwnSystem) {
        const data = { playerPatents: this.patents, bodiesData: this.bodies, buildingsData: this.buildings };

        if (this.production && tile
          && this.production.data.type === 'building'
          && this.production.data.targetId === this.body.uid
          && this.production.data.tileId === tile.id) {
          this.$store.commit('game/clearProduction');
        } else if ((buildingValidation.isBuildable(tile, this.body, data))
          && tile.building_key === null) {
          this.$ambiance.sound('open-production');
          this.$store.commit('game/prepareProduction', {
            systemId: this.system.id,
            data: {
              type: 'building',
              targetId: this.body.uid,
              tileId: tile.id,
            },
          });
        }
      }
    },
    buildTile(tile, type) {
      if (this.isOwnSystem) {
        const productionLevel = type === 'build'
          ? tile.building_level + 1
          : tile.building_level;

        this.$ambiance.sound('order-building');

        this.$socket.player.push('order_building', {
          system_id: this.system.id,
          production_data: {
            type,
            target_id: this.body.uid,
            tile_id: tile.id,
            prod_key: tile.building_key,
            prod_level: productionLevel,
          },
        }).receive('ok', () => {
          // On a phone the tap that queued this is the whole gesture:
          // say what it did, since nothing else on the tile changes
          // until the next sync.
          if (!this.isMobileView) return;
          const name = this.$t(`data.building.${tile.building_key}.name`);
          this.$toasted.show(type === 'repair'
            ? this.$t('galaxy.system.mobile.repair_queued', { name })
            : this.$t('galaxy.system.mobile.upgrade_queued', { name, level: productionLevel }),
          { duration: 2500 });
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
    removeTile(tile) {
      if (this.isOwnSystem) {
        this.$socket.player.push('remove_building', {
          system_id: this.system.id,
          production_data: {
            target_id: this.body.uid,
            tile_id: tile.id,
          },
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
  },
};
</script>
