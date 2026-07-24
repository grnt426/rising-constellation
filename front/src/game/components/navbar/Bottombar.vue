<template>
  <div class="navbar-container">
    <!-- Phone bar: ring gauges (fill = usage of cap) and bare resource
         totals — income rates and the center player block live in
         tooltips/panels instead. Desktop bar below is untouched. -->
    <div
      v-if="isMobileView"
      class="navbar bottom is-mobile">
      <div class="mobile-bottombar">
        <div
          class="mobile-bb-btn"
          @click="togglePanel('empire')">
          <svgicon class="icon" name="empire" />
        </div>

        <div
          class="mobile-gauge-press"
          @pointerdown="gaugePressStart('systems', $event)"
          @pointerup="gaugePressEnd('systems', $event)"
          @pointercancel="gaugePressCancel"
          @contextmenu.prevent>
          <mobile-gauge
            :value="ownSystems.length"
            :max="player.max_systems.value"
            glyph="system"
            :theme="theme"
            :tooltip="`${$t('navbar.bottombar.systems')}: ${ownSystems.length}/${player.max_systems.value}`" />
        </div>
        <div
          class="mobile-gauge-press"
          @pointerdown="gaugePressStart('dominions', $event)"
          @pointerup="gaugePressEnd('dominions', $event)"
          @pointercancel="gaugePressCancel"
          @contextmenu.prevent>
          <mobile-gauge
            :value="ownDominions.length"
            :max="player.max_dominions.value"
            glyph="dominion"
            :theme="theme"
            :tooltip="`${$t('navbar.bottombar.dominions')}: ${ownDominions.length}/${player.max_dominions.value}`" />
        </div>

        <span class="mobile-bb-divider"></span>

        <div
          ref="nesGauge"
          class="mobile-gauge-press"
          @pointerdown="gaugePressStart('nes', $event)"
          @pointerup="gaugePressEnd('nes', $event)"
          @pointercancel="gaugePressCancel"
          @contextmenu.prevent>
          <mobile-tri-gauge
            :segments="nesSegments"
            :tooltip="nesTooltip" />
        </div>

        <div
          class="mobile-bb-minipanel"
          @click="toggleMiniPanel('doctrine')">
          <svgicon name="doctrine/frame_doctrine" />
          {{ $t('navbar.bottombar.lexes') }}
        </div>
        <div
          class="mobile-bb-minipanel"
          @click="toggleMiniPanel('patent')">
          <svgicon name="patent/frame_patent" />
          {{ $t('navbar.bottombar.patents') }}
        </div>

        <span class="mobile-bb-spacer"></span>

        <div
          v-for="res in ['credit', 'technology', 'ideology']"
          :key="`res-${res}`"
          class="mobile-bb-resource"
          v-tooltip="`${$t(`data.bonus_pipeline_in.player_${res}.name`)}: ${Math.floor(player[res].value)}`">
          <svgicon :name="`resource/${res}`" />
          {{ compactNumber(player[res].value) }}
        </div>

        <div
          class="mobile-bb-btn"
          @click="togglePanel('operations')">
          <svgicon class="icon" name="operation" />
        </div>
      </div>
    </div>

    <!-- The desktop bar must IMMEDIATELY follow the mobile bar's div:
         v-else detaches from its v-if if any element sits between
         them, and the desktop bar then renders unconditionally. -->
    <div
      v-else
      class="navbar bottom">
      <div class="navbar-left">
        <!-- TODO: should be a component -->
        <div class="navbar-main-button">
          <div class="navbar-main-button-toolbox">
            <div
              class="button"
              v-if="ownSystems.length > 0"
              @click="toggleSystemList">
              <template v-if="isSystemListOpen">
                <svgicon class="icon" name="caret-down" />
              </template>
              <template v-else>
                <svgicon class="icon" name="caret-up" />
              </template>
            </div>
          </div>

          <div
            @click="togglePanel('empire')"
            class="navbar-main-button-icon">
            <svgicon class="icon" name="empire" />
          </div>
        </div>

        <div class="navbar-group-buttons left">
          <div
            v-if="tutorialStep === 6"
            class="tutorial-pointer is-technology is-bottom">
          </div>
          <div
            v-if="tutorialStep === 10"
            class="tutorial-pointer is-ideology is-bottom">
          </div>
          <v-popover trigger="hover">
            <navbar-maxed-value
              :label="$t('navbar.bottombar.systems')"
              :value="player.stellar_systems.length"
              :maximum="player.max_systems.value" />
            <resource-detail
              slot="popover"
              :title="$t('navbar.bottombar.systems_limit')"
              :precision="0"
              :value="player.max_systems.value"
              :details="player.max_systems.details" />
          </v-popover>

          <v-popover trigger="hover">
            <navbar-maxed-value
              :label="$t('navbar.bottombar.dominions')"
              :value="player.dominions.length"
              :maximum="player.max_dominions.value" />
            <resource-detail
              slot="popover"
              :title="$t('navbar.bottombar.dominions_limit')"
              :precision="0"
              :value="player.max_dominions.value"
              :details="player.max_dominions.details" />
          </v-popover>

          <v-popover
            trigger="hover"
            @mouseenter.native="setHoveredResource('credit')"
            @mouseleave.native="setHoveredResource(null)">
            <navbar-dynamic-value
              icon="resource/credit"
              :initial="player.credit" />
            <resource-detail
              slot="popover"
              :title="$t('data.bonus_pipeline_in.player_credit.name')"
              :description="$t(`resource-description.credit`)"
              :value="player.credit.change"
              :rates="resourceRates(player.credit)"
              :totals="resourceTotals(player.credit)"
              :details="player.credit.details" />
          </v-popover>

          <v-popover
            trigger="hover"
            @mouseenter.native="setHoveredResource('technology')"
            @mouseleave.native="setHoveredResource(null)">
            <navbar-dynamic-value
              icon="resource/technology"
              :initial="player.technology" />
            <resource-detail
              slot="popover"
              :title="$t('data.bonus_pipeline_in.player_technology.name')"
              :description="$t(`resource-description.technology`)"
              :value="player.technology.change"
              :rates="resourceRates(player.technology)"
              :totals="resourceTotals(player.technology)"
              :details="player.technology.details" />
          </v-popover>

          <v-popover
            trigger="hover"
            @mouseenter.native="setHoveredResource('ideology')"
            @mouseleave.native="setHoveredResource(null)">
            <navbar-dynamic-value
              icon="resource/ideology"
              :initial="player.ideology" />
            <resource-detail
              slot="popover"
              :title="$t('data.bonus_pipeline_in.player_ideology.name')"
              :description="$t(`resource-description.ideology`)"
              :value="player.ideology.change"
              :rates="resourceRates(player.ideology)"
              :totals="resourceTotals(player.ideology)"
              :details="player.ideology.details" />
          </v-popover>
        </div>
      </div>

      <div class="navbar-center">
        <div
          v-if="tutorialStep === 7"
          class="tutorial-pointer is-patent is-bottom">
        </div>
        <div
          v-if="tutorialStep === 11"
          class="tutorial-pointer is-doctrine is-bottom">
        </div>

        <div
          @click="switchSystem('prev')"
          v-if="ownSystems.length > 1"
          v-tooltip="$t('navbar.bottombar.previous_system')"
          class="mini-panel-switcher left">
          <svgicon name="caret-left" />
        </div>

        <div
          @click="toggleMiniPanel('patent')"
          :class="{
            'active': activeMiniPanel.name === 'patent',
            'visible': player.technology.change > 0,
          }"
          v-tooltip="$t('navbar.bottombar.patents')"
          class="mini-panel-button left">
          <svgicon name="patent/frame_patent" />
        </div>

        <navbar-player />

        <div
          @click="toggleMiniPanel('doctrine')"
          :class="{
            'active': activeMiniPanel.name === 'doctrine',
            'visible': player.ideology.change > 0,
          }"
          v-tooltip="$t('navbar.bottombar.lexes')"
          class="mini-panel-button right">
          <svgicon name="doctrine/frame_doctrine" />
        </div>

        <div
          @click="switchSystem('next')"
          v-if="ownSystems.length > 1"
          v-tooltip="$t('navbar.bottombar.next_system')"
          class="mini-panel-switcher right">
          <svgicon name="caret-right" />
        </div>
      </div>

      <div class="navbar-right">
        <div class="navbar-group-buttons right">
          <div
            class="navbar-deploy-button"
            @click="toggleMiniPanel('character-deck')">
            <strong>{{ $t('navbar.bottombar.agents') }}</strong>
            {{ $t('navbar.bottombar.n_available', {n: playerDeck.length}) }}
          </div>

          <v-popover
            v-for="type in characterData"
            :key="type.key"
            trigger="hover">
            <navbar-maxed-value
              :label="$tc(`data.character.${type.key}.name`, type.activeNumber)"
              :value="type.activeNumber"
              :maximum="type.maxNumber" />
            <resource-detail
              slot="popover"
              :title="$t('navbar.bottombar.character_type_limit', {characterType: $tc(`data.character.${type.key}.name`, 2)})"
              :precision="0"
              :value="player[charactersBonusName[type.key]].value"
              :details="player[charactersBonusName[type.key]].details" />
          </v-popover>
        </div>

        <!-- TODO: should be a component -->
        <div class="navbar-main-button">
          <div class="navbar-main-button-toolbox">
            <div
              class="button"
              v-if="onBoardCharacters.length > 0"
              @click="toggleActiveCharacterList">
              <template v-if="isActiveCharacterListOpen">
                <svgicon class="icon" name="caret-down" />
              </template>
              <template v-else>
                <svgicon class="icon" name="caret-up" />
              </template>
            </div>
          </div>

          <div
            @click="togglePanel('operations')"
            class="navbar-main-button-icon">
            <svgicon class="icon" name="operation" />
          </div>
        </div>
      </div>
    </div>

    <div
      class="navbar-panel"
      v-if="!isMobileView"
      v-show="isActiveCharacterListOpen && onBoardCharacters.length > 0 && !selection">
      <div
        v-for="type in characterData"
        :key="type.key">
        <navbar-panel-block
          v-show="type.onBoardNumber > 0"
          :title="`
            ${type.onBoardNumber}
            ${$tc(`data.character.${type.key}.name`, type.onBoardNumber)}
          `">
          <closed-character-card
            v-for="character in type.onBoard"
            :key="character.id"
            :character="character"
            :theme="theme"
            @select="selectCharacter" />
        </navbar-panel-block>
      </div>
    </div>

    <div
      class="navbar-panel"
      v-if="!isMobileView"
      v-show="!selectedSystem && isSystemListOpen"
      style="left: 0; right: auto;">
      <navbar-panel-block
        v-if="ownDominions.length"
        :title="`
          ${ ownDominions.length }
          ${ $tc('system.dominion', ownDominions.length) }
        `">
        <closed-system-card
          v-for="system in ownDominions"
          :key="system.id"
          :system="system"
          :theme="theme"
          @select="selectSystem" />
      </navbar-panel-block>

      <navbar-panel-block
        v-if="ownSystems.length"
        :title="`
          ${ ownSystems.length }
          ${ $tc('system.system', ownSystems.length) }
        `">
        <closed-system-card
          v-for="system in ownSystems"
          :key="system.id"
          :system="system"
          :theme="theme"
          @select="selectSystem" />
      </navbar-panel-block>
    </div>

    <!-- Long-press radial: N / E / S bubbles over the tri-gauge;
         release (or tap) on one lists that class's agents. Lives
         outside .navbar.bottom — its overflow clipping would swallow
         anything drawn above the 44px bar. -->
    <div
      v-if="radialOpen"
      class="mobile-radial"
      :style="{ left: `${radialX}px` }">
      <div
        v-for="(type, i) in characterData"
        :key="`radial-${type.key}`"
        class="mobile-radial-item"
        :class="`is-pos-${i}`"
        :data-agent-type="type.key"
        @click="openAgentsModal(type.key)">
        <span class="letter">{{ $tc(`data.character.${type.key}.name`, 1).charAt(0) }}</span>
        <span class="count">{{ type.activeNumber }}/{{ type.maxNumber }}</span>
      </div>
    </div>

    <mobile-list-modal
      v-if="activeListModal"
      :title="activeListModal.title"
      :items="activeListModal.items"
      @select="onModalSelect"
      @close="activeListModal = null" />

    <div
      class="mini-panels-container"
      ref="miniPanelsContainer"
      @click.self="closeMiniPanel">
      <character-deck-mini-panel
        v-show="activeMiniPanel.name === 'character-deck'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
      <patent-mini-panel
        v-show="activeMiniPanel.name === 'patent'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
      <doctrine-mini-panel
        v-show="activeMiniPanel.name === 'doctrine'"
        :active-panel="activeMiniPanel.name"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
      <faction-tree-mini-panel
        v-if="['faction-patent', 'faction-lex'].includes(activeMiniPanel.name)"
        :default-tab="activeMiniPanel.name === 'faction-patent' ? 'patent' : 'lex'"
        :height="activeMiniPanel.height"
        @close="closeMiniPanel" />
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import viewport from '@/utils/viewport';

import NavbarDynamicValue from '@/game/components/navbar/NavbarDynamicValue.vue';
import MobileGauge from '@/game/components/navbar/MobileGauge.vue';
import MobileTriGauge from '@/game/components/navbar/MobileTriGauge.vue';
import MobileListModal from '@/game/components/navbar/MobileListModal.vue';
import NavbarMaxedValue from '@/game/components/navbar/NavbarMaxedValue.vue';
import NavbarPanelBlock from '@/game/components/navbar/NavbarPanelBlock.vue';

import NavbarPlayer from '@/game/components/navbar/NavbarPlayer.vue';
import ResourceDetail from '@/game/components/generic/ResourceDetail.vue';

import ClosedCharacterCard from '@/game/components/card/ClosedCharacterCard.vue';
import ClosedSystemCard from '@/game/components/card/ClosedSystemCard.vue';

import CharacterDeckMiniPanel from '@/game/components/mini-panel/CharacterDeckMiniPanel.vue';
import PatentMiniPanel from '@/game/components/mini-panel/PatentMiniPanel.vue';
import DoctrineMiniPanel from '@/game/components/mini-panel/DoctrineMiniPanel.vue';
import FactionTreeMiniPanel from '@/game/components/mini-panel/FactionTreeMiniPanel.vue';

export default {
  name: 'bottombar',
  data() {
    return {
      activeMiniPanel: { name: '' },
      isMiniPanelOpen: false,
      miniPanels: [
        { name: 'character-deck', height: 480 },
        { name: 'patent', height: 480 },
        { name: 'doctrine', height: 480 },
        { name: 'faction-patent', height: 480 },
        { name: 'faction-lex', height: 480 },
      ],
      isActiveCharacterListOpen: true,
      isSystemListOpen: true,
      // Mobile long-press state: the radial N/E/S picker over the
      // tri-gauge, and the full-screen list modals that replace the
      // desktop pull-up docks.
      radialOpen: false,
      radialX: 0,
      activeListModal: null,
      pressTimer: null,
      pressFiredLong: false,
      characterDeck: false,
      charactersBonusName: {
        admiral: 'max_admirals',
        spy: 'max_spies',
        speaker: 'max_speakers',
      },
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    tutorialStep() { return this.$store.state.game.tutorialStep; },
    theme() { return this.$store.getters['game/theme']; },
    view() { return this.$store.state.game.view; },
    isDaily() { return this.$store.state.game.time.speed === 'daily'; },
    player() { return this.$store.state.game.player; },
    ownSystems() { return this.player.stellar_systems; },
    ownDominions() { return this.player.dominions; },
    selection() { return this.$store.state.game.selectedCharacter; },
    selectedSystem() { return this.$store.state.game.selectedSystem; },
    onBoardCharacters() { return this.player.characters.filter((p) => p.status === 'on_board'); },
    playerDeck() { return this.$store.state.game.player.character_deck; },
    nesSegments() {
      return this.characterData.map((type) => ({
        letter: this.$tc(`data.character.${type.key}.name`, 1).charAt(0),
        value: type.activeNumber,
        max: type.maxNumber,
      }));
    },
    nesTooltip() {
      return this.characterData
        .map((t) => `${this.$tc(`data.character.${t.key}.name`, 2)}: ${t.activeNumber}/${t.maxNumber}`)
        .join(' · ');
    },
    characterData() {
      return this.$store.state.game.data.character.map((data) => {
        const onBoard = this.onBoardCharacters
          .filter((c) => c.type === data.key)
          .map((c) => (({ ...c, receivedAt: this.player.receivedAt })));

        const activeNumber = this.player.characters.filter((c) => c.type === data.key).length;
        const onBoardNumber = onBoard.length;
        const maxNumber = this.player[this.charactersBonusName[data.key]].value;

        return { ...data, ...{ onBoard, activeNumber, onBoardNumber, maxNumber } };
      });
    },
  },
  methods: {
    // --- mobile long-press gauges -----------------------------------
    // Tap the tri-gauge: toggles the radial (then tap a letter).
    // Long-press: radial opens mid-hold, releasing over a letter picks
    // it — the gesture the user described. Systems/dominions gauges
    // long-press straight into their list modal.
    gaugePressStart(kind, event) {
      this.pressFiredLong = false;
      clearTimeout(this.pressTimer);
      this.pressTimer = setTimeout(() => {
        this.pressFiredLong = true;
        if (kind === 'nes') {
          this.openRadial(event);
        } else if (kind === 'systems') {
          this.openSystemsModal('systems');
        } else if (kind === 'dominions') {
          this.openSystemsModal('dominions');
        }
      }, 450);
    },
    gaugePressEnd(kind, event) {
      clearTimeout(this.pressTimer);

      if (kind !== 'nes') return;

      if (!this.pressFiredLong) {
        // plain tap: toggle the radial
        if (this.radialOpen) {
          this.radialOpen = false;
        } else {
          this.openRadial(event);
        }
        return;
      }

      // long-press release: select whichever bubble the finger is on
      const el = document.elementFromPoint(event.clientX, event.clientY);
      const bubble = el && el.closest('.mobile-radial-item');
      if (bubble) {
        this.openAgentsModal(bubble.dataset.agentType);
      }
      // released elsewhere: keep the radial open so a follow-up tap
      // can still choose (dismiss by tapping the gauge again)
    },
    gaugePressCancel() {
      clearTimeout(this.pressTimer);
    },
    openRadial(event) {
      const rect = (this.$refs.nesGauge || event.target).getBoundingClientRect
        ? (this.$refs.nesGauge || event.target).getBoundingClientRect()
        : { left: event.clientX, width: 0 };
      this.radialX = Math.round(rect.left + rect.width / 2);
      this.radialOpen = true;
    },
    openAgentsModal(typeKey) {
      this.radialOpen = false;
      if (!typeKey) return;
      const items = this.player.characters
        .filter((c) => c.type === typeKey)
        .map((c) => ({
          id: c.id,
          icon: `agent/${c.type}`,
          label: c.name,
          sub: this.$tc(`data.character.${c.type}.name`, 1),
          right: `lv ${c.level}`,
          kind: 'character',
        }));
      this.activeListModal = {
        title: this.$tc(`data.character.${typeKey}.name`, 2),
        items,
      };
    },
    openSystemsModal(which) {
      const source = which === 'systems' ? this.ownSystems : this.ownDominions;
      this.activeListModal = {
        title: this.$t(`navbar.bottombar.${which}`),
        items: source.map((s) => ({
          id: s.id,
          icon: null,
          label: s.name,
          sub: `${Math.trunc(s.position.x)}:${Math.trunc(s.position.y)}`,
          kind: 'system',
        })),
      };
    },
    onModalSelect(item) {
      this.activeListModal = null;
      if (item.kind === 'character') {
        this.$store.dispatch('game/selectCharacter', { vm: this, id: item.id });
      } else if (item.kind === 'system') {
        this.$store.dispatch('game/openSystem', { vm: this, id: item.id });
      }
    },

    // Bar space on a phone is too tight for full figures — 300,018
    // reads as 300k; precision lives in the tooltip.
    compactNumber(value) {
      const n = Math.floor(value);
      if (Math.abs(n) >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
      if (Math.abs(n) >= 10_000) return `${Math.round(n / 1000)}k`;
      return `${n}`;
    },
    toggleActiveCharacterList() {
      this.isActiveCharacterListOpen = !this.isActiveCharacterListOpen;
    },
    toggleSystemList() {
      this.isSystemListOpen = !this.isSystemListOpen;
    },
    toggleMiniPanel(name) {
      if (this.isMiniPanelOpen && this.activeMiniPanel.name === name) {
        this.closeMiniPanel();
      } else {
        this.openMiniPanel(name);
      }
    },
    openMiniPanel(name) {
      this.$root.$emit('closePanel');
      this.$root.$emit('closeTopMiniPanel');

      this.animateCloseMiniPanelContainer().then(() => {
        this.animateOpenMiniPanelContainer(name);
      });
    },
    closeMiniPanel() {
      this.$store.commit('game/clearAssignment');

      this.animateCloseMiniPanelContainer().then(() => {
        this.isMiniPanelOpen = false;
        this.activeMiniPanel = { name: '' };
      });
    },
    switchSystem(mode) {
      let nextSystemId;

      if (mode === 'first') {
        nextSystemId = this.ownSystems[0].id;
      } else {
        const i = this.selectedSystem
          ? this.ownSystems.findIndex((s) => s.id === this.selectedSystem.id)
          : -1;

        nextSystemId = mode === 'prev'
          ? this.ownSystems[(i + this.ownSystems.length - 1) % this.ownSystems.length].id
          : this.ownSystems[(i + 1) % this.ownSystems.length].id;
      }

      this.$store.dispatch('game/openSystem', { vm: this, id: nextSystemId });
    },
    animateOpenMiniPanelContainer(name) {
      return new Promise((resolve) => {
        this.$ambiance.sound('mini-panel-open');

        this.$refs.miniPanelsContainer.style.display = 'flex';
        this.activeMiniPanel = this.miniPanels.find((p) => p.name === name);
        this.isMiniPanelOpen = true;

        new TimelineLite({
          onComplete() { resolve(); },
        }).set(this.$refs.miniPanelsContainer, { bottom: `-${this.activeMiniPanel.height}px` })
          .to(this.$refs.miniPanelsContainer, { bottom: '52px', ease: Expo.easeOut, duration: 0.8 }, 0);
      });
    },
    animateCloseMiniPanelContainer() {
      if (!this.isMiniPanelOpen) {
        return Promise.resolve();
      }

      return new Promise((resolve) => {
        this.$ambiance.sound('mini-panel-close');

        const self = this;

        if (!this.isMiniPanelOpen) {
          resolve();
        } else {
          const position = `-${this.activeMiniPanel.height}px`;

          new TimelineLite({
            onComplete() {
              self.$refs.miniPanelsContainer.style.display = 'none';
              resolve();
            },
          }).to(this.$refs.miniPanelsContainer, { bottom: position, ease: Expo.linear, duration: 0.4 }, 0);
        }
      });
    },
    selectSystem(system) {
      this.$store.dispatch('game/openSystem', { vm: this, id: system.id });
    },
    selectCharacter(character) {
      this.$store.dispatch('game/selectCharacter', { vm: this, id: character.id });
    },
    togglePanel(name) {
      this.$root.$emit('togglePanel', name);
    },
    setHoveredResource(name) {
      this.$root.$emit('hoveredResource', name);
    },
    // How many game ticks (UTs) elapse per real hour, at the speed actually
    // in effect (base speed × runtime speed cheat). At 1× a tick is 3 real
    // minutes, so 20 ticks/hour. Undefined until the join payload primes the
    // speed data.
    ticksPerHour() {
      const factor = this.$store.getters['game/effectiveSpeedFactor'];
      return factor ? 20 * factor : undefined;
    },
    // Per-real-time income rates shown directly under the main (per-tick) line.
    // These translate the raw per-tick change into the figures players
    // actually reason about. Dailies run on a ~30-minute clock, so hourly/daily
    // rates are meaningless — they get a per-minute rate instead.
    resourceRates(resource) {
      const perHour = this.ticksPerHour();
      if (!resource || typeof resource.change !== 'number' || !perHour) return [];
      const rateHour = resource.change * perHour;
      if (this.isDaily) {
        return [{ label: this.$t('resource-detail.rate_minute'), value: rateHour / 60 }];
      }
      return [
        { label: this.$t('resource-detail.rate_hour'), value: rateHour },
        { label: this.$t('resource-detail.rate_day'), value: rateHour * 24 },
      ];
    },
    // Projected stockpile totals shown at the foot of the tooltip: current
    // amount plus the income that would accrue over the horizon if nothing
    // changed (ignores future buildings, conquests, agent losses). Dailies
    // last 30 minutes, so they get a near-term 3-minute projection instead.
    resourceTotals(resource) {
      const perHour = this.ticksPerHour();
      if (!resource || typeof resource.value !== 'number' || !perHour) return [];
      const change = resource.change || 0;
      if (this.isDaily) {
        // 3 real minutes = a twentieth of an hour's worth of ticks.
        const per3min = change * (perHour / 20);
        return [{ label: this.$t('resource-detail.projection_3min'), value: resource.value + per3min }];
      }
      const rateHour = change * perHour;
      return [
        { label: this.$t('resource-detail.total_1h'), value: resource.value + rateHour },
        { label: this.$t('resource-detail.total_24h'), value: resource.value + rateHour * 24 },
      ];
    },
  },
  mounted() {
    this.$root.$on('openBottomMiniPanel', (name) => { this.openMiniPanel(name); });
    this.$root.$on('closeBottomMiniPanel', () => { this.closeMiniPanel(); });
    this.$root.$on('switchSystem', (mode) => { this.switchSystem(mode); });
  },
  components: {
    MobileGauge,
    MobileTriGauge,
    MobileListModal,
    NavbarDynamicValue,
    NavbarMaxedValue,
    NavbarPanelBlock,
    NavbarPlayer,
    ResourceDetail,
    ClosedCharacterCard,
    ClosedSystemCard,
    CharacterDeckMiniPanel,
    PatentMiniPanel,
    DoctrineMiniPanel,
    FactionTreeMiniPanel,
  },
};
</script>
