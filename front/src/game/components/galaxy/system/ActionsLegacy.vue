<template>
  <div ref="container">
    <!-- Phone layout: flat list instead of the orbital arrangement.
         Own agents anchor left, everyone else anchors right, and the
         action buttons sit opposite the identity — the mirroring reads
         as "mine vs theirs" before color does. Actions stay contextual
         on the currently selected own agent, same computeds as
         desktop. -->
    <div
      v-if="isMobileView"
      class="mobile-agents">
      <div class="mobile-agents-header">
        <span>{{ $t('navbar.bottombar.agents') }}</span>
        <button
          v-if="isOwnSystem"
          class="mobile-agent-deploy"
          @click="prepareAgentAssignment()">
          {{ $t('galaxy.system.actions.deploy') }}
        </button>
      </div>

      <div
        v-if="system.siege !== null"
        class="mobile-siege">
        <svgicon :name="`action/${system.siege.type}_alt`" />
        <span>{{ $t(`data.character_action_status.${system.siege.type}.name`) }}</span>
        <counter
          class="counter"
          :current="system.siege.days.value"
          :receivedAt="system.receivedAt" />
        <span>/ {{ system.siege.duration }}</span>
      </div>

      <div
        v-if="selectedCharacter && actions.length > 0"
        class="mobile-system-orders">
        <div class="mobile-orders-label">{{ selectedCharacter.name }}</div>
        <button
          v-for="action in actions"
          :key="`sys-${action.name}`"
          class="mobile-order-button"
          :class="{ 'is-disabled': action.status !== 'available' }"
          v-tooltip="action.status === 'available' ? action.tooltip : action.reasons"
          @click="action.status === 'available' && doAction(action.icon)">
          <svgicon :name="`action/${action.icon}_alt`" />
          {{ $t(`galaxy.system.actions.${action.name}`) }}
        </button>
      </div>

      <div
        v-for="{ character, actions: characterActions } in sortedSystemCharacters"
        :key="`m-${character.id}`"
        class="mobile-agent-row"
        :class="[
          `force-${getTheme(character.owner.faction)}`,
          character.owner.id === player.id ? 'is-mine' : 'is-other',
          {
            'is-selected': selectedCharacter && selectedCharacter.id === character.id,
            'is-armada': character.armada_id != null,
          },
        ]">
        <div
          class="mobile-agent-identity"
          @click="clickCharacter(character)">
          <div class="mobile-agent-icon">
            <svgicon :name="`agent/${character.type}`" />
            <span class="number">{{ character.level }}</span>
          </div>
          <div class="mobile-agent-name">
            <div class="name">{{ character.name }}</div>
            <div
              v-if="character.owner.id !== player.id"
              class="info"
              @click.stop="openPlayer(character.owner.id)">
              {{ character.owner.name }}
            </div>
            <div
              v-else
              class="info">
              {{ $tc(`data.character.${character.type}.name`, 1) }}
            </div>
          </div>
        </div>

        <div class="mobile-agent-buttons">
          <template v-if="character.owner.id === player.id">
            <button
              class="mobile-order-button"
              @click="clickCharacter(character)">
              {{ selectedCharacter && selectedCharacter.id === character.id
                ? $t('galaxy.system.actions.selected')
                : $t('galaxy.system.actions.select') }}
            </button>
            <!-- own-vs-own actions (Form/Join Armada) -->
            <button
              v-for="action in characterActions"
              :key="`m-${character.id}-${action.name}`"
              class="mobile-order-button"
              :class="{ 'is-disabled': action.status !== 'available' }"
              v-tooltip="action.status === 'available' ? action.tooltip : action.reasons"
              @click="action.status === 'available' && doCharacterAction(action, character.id)">
              <svgicon :name="action.iconPath || `action/${action.icon}_alt`" />
              {{ $t(`galaxy.system.actions.${action.name}`) }}
            </button>
          </template>
          <template v-else>
            <button
              v-for="action in characterActions"
              :key="`m-${character.id}-${action.name}`"
              class="mobile-order-button"
              :class="{ 'is-disabled': action.status !== 'available' }"
              v-tooltip="action.status === 'available' ? action.tooltip : action.reasons"
              @click="action.status === 'available' && doCharacterAction(action, character.id)">
              <svgicon :name="action.iconPath || `action/${action.icon}_alt`" />
              {{ $t(`galaxy.system.actions.${action.name}`) }}
            </button>
          </template>
        </div>
      </div>
    </div>

    <div
      v-if="!isMobileView && actions.length > 0"
      class="system-actions-legacy top-shifted">
      <div
        v-for="action in actions"
        :key="action.icon"
        class="action-item">
        <div class="action-item-container">
          <div
            v-if="action.status === 'available'"
            class="round-icon is-active has-hover"
            @click="doAction(action.icon)"
            @mouseover="hoveredAction = action.name"
            @mouseleave="hoveredAction = null">
            <svgicon :name="`action/${action.icon}_alt`" />
          </div>
          <div
            v-if="action.status === 'unavailable'"
            v-tooltip="action.reasons"
            class="round-icon is-disabled">
            <svgicon :name="`action/${action.icon}_alt`" />
          </div>
          <div
            v-if="action.overview && hoveredAction === action.name"
            class="toolbox-actions">
            <action-overview :data="action.overview" />
          </div>
          <div class="action-label">
            <div class="name">{{ $t(`galaxy.system.actions.${action.name}`) }}</div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="!isMobileView"
      ref="agentArc"
      class="system-actions-legacy">
      <!-- formation bands: exact arc geometry (items rotate 7° apart
           around the container's mid-top pivot; icon centers sit at
           90.2% + 25px), drawn once in pixel space so adjacent members
           share one continuous capsule — same visual as the fan view -->
      <svg
        v-if="legacyArmadaBands.length > 0"
        class="armada-links-legacy">
        <path
          v-for="band in legacyArmadaBands"
          :key="band.key"
          class="armada-band-shape"
          :d="band.d" />
      </svg>

      <div
        v-if="isOwnSystem"
        class="action-item">
        <div class="action-item-container">
          <div
            v-if="tutorialStep === 14"
            class="tutorial-pointer is-right">
          </div>
          <div
            @click="prepareAgentAssignment()"
            class="round-icon has-hover">
          </div>
          <div
            @click="prepareAgentAssignment()"
            class="action-label">
            <div class="name">{{ $t('galaxy.system.actions.deploy') }}</div>
          </div>
        </div>
      </div>

      <div
        v-for="({ character, actions }, idx) in orderedSystemCharacters"
        class="action-item"
        :key="character.id">
        <div
          :class="[
            `force-${getTheme(character.owner.faction)}`,
            { 'is-active': system.siege !== null && character.id === system.siege.besieger_id },
          ]"
          class="action-item-container">
          <div
            class="round-icon is-active has-hover"
            :class="{
              'has-border': character.owner.id === player.id,
              'has-circle': selectedCharacter && selectedCharacter.id === character.id,
            }"
            @click="clickCharacter(character)">
            <svgicon :name="`agent/${character.type}`" />
            <span class="number">
              {{ character.level }}
            </span>
          </div>
          <div
            v-if="actions.length > 0"
            class="toolbox-actions">
            <div
              v-for="action in actions"
              :key="`${character.id}-${action.name}-overview`"
              class="actions">
              <action-overview
                v-if="action.overview && hoveredAction === `${character.id}-${action.name}`"
                class="is-top-shifted"
                :theme="getTheme(character.owner.faction)"
                :name="hoveredAction"
                :data="action.overview" />
            </div>
            <div
              v-for="action in actions"
              :key="`${character.id}-${action.name}-actions`"
              class="actions">
              <div
                v-if="action.status === 'available'"
                v-tooltip="action.tooltip"
                class="actions-item is-active has-hover"
                @click="doCharacterAction(action, character.id)"
                @mouseover="hoveredAction = `${character.id}-${action.name}`"
                @mouseleave="hoveredAction = null">
                <svgicon :name="action.iconPath || `action/${action.icon}_alt`" />
              </div>
              <div
                v-if="action.status === 'unavailable'"
                v-tooltip="action.reasons"
                class="actions-item is-disabled">
                <svgicon :name="action.iconPath || `action/${action.icon}_alt`" />
              </div>
            </div>
          </div>
          <div class="action-label colored">
            <div class="name">{{ character.name }}</div>
            <div
              class="info"
              @click="openPlayer(character.owner.id)"
              v-if="character.owner.id !== player.id">
              {{ character.owner.name }}
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="!isMobileView && system.siege !== null"
      class="siege"
      v-tooltip="$t(`data.character_action_status.${system.siege.type}.name`)">
      <svgicon :name="`action/${system.siege.type}_alt`" />
      <counter
        class="counter"
        :current="system.siege.days.value"
        :receivedAt="system.receivedAt" />
      <circle-progress-value
        :current="system.siege.days.value"
        :total="system.siege.duration"
        :increase="system.siege.days.change"
        :size="98"
        :width="4"
        :theme="systemTheme" />
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import actionValidation from '@/utils/actionValidation';
import armadaUtil from '@/utils/armada';
import viewport from '@/utils/viewport';

import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'system-actions-legacy',
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
      // measured width of the desktop agent arc, for the band geometry
      arcWidth: 0,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    tutorialStep() { return this.$store.state.game.tutorialStep; },
    systemTheme() {
      return this.system.owner
        ? this.getTheme(this.system.owner.faction)
        : null;
    },
    selectedCharacterTheme() {
      return this.selectedCharacter
        ? this.getTheme(this.selectedCharacter.owner.faction)
        : null;
    },
    player() { return this.$store.state.game.player; },
    characters() { return this.$store.state.game.player.characters; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    sectors() { return this.$store.state.game.galaxy.sectors; },
    actions() {
      const actions = [];
      const context = {
        vm: this,
        selectedCharacter: this.selectedCharacter,
        system: this.system,
        sectors: this.sectors,
        themes: {
          system: this.systemTheme,
          character: this.selectedCharacterTheme,
        },
      };

      if (!this.selectedCharacter) {
        return actions;
      }

      if (this.selectedCharacter.type === 'admiral' && !this.isOwnProperty) {
        if (this.system.owner === null && this.system.status === 'uninhabited') {
          actionValidation.colonization(actions, context, this.hasSystemSlot);
        }

        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          const defense = this.system.defense ? this.system.defense.value : null;
          const overview = {
            attacker: this.selectedCharacter.army.raid_coef.value,
            attackerIcon: 'ship/raid',
            attackerModifier: this.selectedCharacter.level,
            attackerTheme: context.themes.character,
            defender: defense,
            defenderIcon: 'resource/defense',
            defenderTheme: context.themes.system,
          };

          actionValidation.conquest(actions, context, this.hasSystemSlot, this.systemTheme);
          actionValidation.raid(actions, context, overview);
          actionValidation.loot(actions, context, overview);
        }
      }

      if (this.selectedCharacter.type === 'spy' && !this.isOwnProperty) {
        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          actionValidation.infiltrate(actions, context);
        }
      }

      if (this.selectedCharacter.type === 'speaker' && !this.isOwnProperty) {
        if (['inhabited_neutral', 'inhabited_dominion'].includes(this.system.status)) {
          actionValidation.makeDominion(actions, context, this.hasDominionSlot);
        }

        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          actionValidation.encourageHate(actions, context);
        }
      }

      // faction gateway: any own agent may portal from a linked, free
      // gateway pair (docs/faction-buildings.md)
      if (this.gatewayAction) {
        actions.push(this.gatewayAction);
      }

      // move action
      if (this.selectedCharacter.actions && this.selectedCharacter.actions.virtual_position !== this.system.id) {
        actions.push({ status: 'available', icon: 'jump', name: 'move', reasons: '' });
      }

      return actions;
    },
    gatewayAction() {
      const faction = this.$store.state.game.faction;
      const government = faction && faction.government;
      if (!government || !this.selectedCharacter) return null;

      const links = government.gateway_links || [];
      const link = links.find((l) => l.endpoints.some((e) => e.system_id === this.system.id));
      if (!link) return null;

      if (link.status !== 'linked') {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_not_ready'),
        };
      }
      if (link.transit) {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_busy'),
        };
      }
      if (government.station_powered === false) {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_unpowered'),
        };
      }

      return { status: 'available', icon: 'gateway_charge', name: 'gateway_charge', reasons: '' };
    },
    systemCharacters() {
      if (this.system.characters) {
        const context = {
          vm: this,
          selectedCharacter: this.selectedCharacter,
          system: this.system,
          characterTheme: this.selectedCharacterTheme,
        };

        return this.system.characters.map((character) => {
          const actions = { character, actions: [] };
          const targetTheme = this.getTheme(character.owner.faction);

          if (!this.selectedCharacter) {
            return actions;
          }

          if (this.selectedCharacter.owner.id !== character.owner.id) {
            if (this.selectedCharacter.type === 'admiral'
              && character.type === 'admiral'
              && (this.selectedCharacter.action_status === 'idle'
                || (this.selectedCharacter.action_status === 'docking'
                  && this.selectedCharacter.system === this.system.id)
              )) {
              actionValidation.fight(actions, context);
            }

            if (this.selectedCharacter.type === 'spy') {
              actionValidation.assassination(actions, context, character, targetTheme);

              if (character.type === 'admiral') {
                actionValidation.sabotage(actions, context, character, targetTheme);
              }
            }

            if (this.selectedCharacter.type === 'speaker') {
              actionValidation.conversion(actions, context, character, this.player, targetTheme);
            }
          } else if (this.selectedCharacter.id !== character.id
            && this.selectedCharacter.type === 'admiral'
            && character.type === 'admiral'
            && character.owner.id === this.player.id) {
            // own admiral pair: offer Form/Join Armada on the target
            actionValidation.armada(actions, context, character, this.characters);
          }

          return actions;
        });
      }

      return [];
    },
    // Desktop arc order comes from nth-child rotation, so grouping
    // armada members adjacent in the array is all the layout needs.
    orderedSystemCharacters() {
      return armadaUtil.groupAdjacent(this.systemCharacters);
    },
    // Mobile list order: own agents first (armada members adjacent),
    // everyone else after — pairs with the left/right anchoring in the
    // row layout.
    sortedSystemCharacters() {
      const sorted = [...this.systemCharacters].sort((a, b) => {
        const aMine = a.character.owner.id === this.player.id ? 0 : 1;
        const bMine = b.character.owner.id === this.player.id ? 0 : 1;
        return aMine - bMine;
      });

      return armadaUtil.groupAdjacent(sorted);
    },
    // Formation bands over the desktop arc, in container pixel space.
    // Geometry mirrors the SCSS: every .action-item rotates (i-1)*7°
    // around the container's mid-top; icon centers sit at
    // left 90.2% + 25px, vertically on the pivot line — so all icons
    // lie on one circle of radius 0.402*W + 25. The band path runs
    // slightly INSIDE that circle with a wide stroke: the inner edge
    // reaches ~11px further than the outer, keeping the thick side on
    // the arc's inner portion, away from the name plates. A relocated
    // besieger (is-active shifts its row) is skipped and breaks its
    // run.
    legacyArmadaBands() {
      if (!this.arcWidth) return [];

      const pivotX = this.arcWidth * 0.5;
      const radius = (this.arcWidth * 0.402) + 25;
      const step = 7;
      const offset = this.isOwnSystem ? 1 : 0;
      const pad = 2.4;

      const bands = armadaUtil.bands(
        this.orderedSystemCharacters,
        (e) => e.character,
        (e) => this.system.siege !== null && e.character.id === this.system.siege.besieger_id,
      );

      return bands.map((band) => {
        const a0 = ((offset + band.indexes[0]) * step) - pad;
        const a1 = ((offset + band.indexes[band.indexes.length - 1]) * step) + pad;

        return {
          key: `legacy-${band.groupId}`,
          // asymmetric radii: the capsule reaches ~11px further toward
          // the arc's inner side, where no name plates compete
          d: armadaUtil.capsulePath(pivotX, 0, radius + 25, radius - 36, a0, a1),
        };
      });
    },
    hasSystemSlot() {
      return this.player.stellar_systems.length < this.player.max_systems.value;
    },
    hasDominionSlot() {
      return this.player.dominions.length < this.player.max_dominions.value;
    },
  },
  methods: {
    getTheme(faction) {
      return this.$store.getters['game/themeByKey'](faction);
    },
    clickCharacter(character) {
      if (this.characters.find((c) => c.id === character.id)) {
        if (this.selectedCharacter && this.selectedCharacter.id === character.id) {
          this.$store.dispatch('game/unselectCharacter');
        } else {
          this.$store.dispatch('game/selectCharacter', { vm: this, id: character.id });
        }
      } else {
        this.$store.dispatch('game/openCharacter', { vm: this, id: character.id });
      }
    },
    openPlayer(playerId) {
      this.$store.dispatch('game/openPlayer', { vm: this, id: playerId });
    },
    doAction(action) {
      this.hoveredAction = null;
      this.$root.$emit('map:addAction', action, { system: this.system });
    },
    doCharacterAction(action, targetId) {
      this.hoveredAction = null;

      // armada formation is a state change, not a queued action: it
      // goes straight to the player channel, never through the
      // map:addAction itinerary-prepend path
      if (action.armadaEvent) {
        this.$socket.player.push(action.armadaEvent, action.armadaPayload)
          .receive('error', (data) => { this.$toastError(data.reason); });
        return;
      }

      this.$root.$emit('map:addAction', action.icon, { character: targetId, system: this.system });
    },
    measureArc() {
      const el = this.$refs.agentArc;
      this.arcWidth = el ? el.clientWidth : 0;
    },
    prepareAgentAssignment() {
      const mode = 'on_board';
      const systemId = this.system.id;

      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', { systemId, mode });
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { css: { opacity: 0 } })
      .to(this.$refs.container, { css: { opacity: 1 }, ease: Expo.linear, duration: 1 }, 0);

    this.measureArc();
    window.addEventListener('resize', this.measureArc);
  },
  updated() {
    // the arc container mounts/unmounts with the mobile switch
    this.measureArc();
  },
  beforeDestroy() {
    window.removeEventListener('resize', this.measureArc);
  },
  components: {
    ActionOverview,
    CircleProgressValue,
    Counter,
  },
};
</script>
