<template>
  <div ref="container">
    <!-- contextual actions of the selected character, inner ring, upper-right -->
    <div
      class="system-actions"
      v-if="actions.length > 0">
      <div
        v-for="(action, i) in actions"
        :key="action.icon"
        class="orbit-item"
        :style="orbitStyle(contextualAngles[i], 'inner')">
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

    <div class="system-actions">
      <!-- deploy slot + own agents, inner ring, lower-left -->
      <div
        v-if="isOwnSystem"
        class="orbit-item"
        :style="orbitStyle(innerAngles[0], 'inner')">
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

      <div
        v-for="(entry, i) in ownEntries"
        :key="entry.character.id"
        class="orbit-item"
        :style="orbitStyle(innerAngles[(isOwnSystem ? 1 : 0) + i], 'inner')">
        <agent-badge
          :character="entry.character"
          :actions="entry.actions"
          :theme="getTheme(entry.character.owner.faction)"
          :system="system"
          small
          @select="clickCharacter" />
      </div>

      <!-- foreign agents and squadrons, outer fan -->
      <div
        v-for="slot in outerSlots"
        :key="slot.key"
        class="orbit-item"
        :class="{ 'is-raised': openedCluster === slot.key }"
        :style="orbitStyle(slot.angle, 'outer')">
        <agent-badge
          v-if="slot.kind === 'single'"
          :character="slot.entry.character"
          :actions="slot.entry.actions"
          :theme="getTheme(slot.entry.character.owner.faction)"
          :system="system"
          :isBesieger="slot.isBesieger"
          :flipped="slot.angle < -30"
          @select="clickCharacter" />

        <div
          v-else
          :ref="`cluster-${slot.key}`"
          class="cluster"
          :class="`force-${slot.theme}`"
          @mouseenter="enterCluster(slot.key)">
          <div class="cluster-ghost is-far"></div>
          <div class="cluster-ghost is-near"></div>
          <div
            class="round-icon is-active has-hover"
            @click="clickCluster(slot.key)">
            <svgicon :name="`agent/${slot.lead.character.type}`" />
            <span class="number">
              {{ slot.lead.character.level }}
            </span>
          </div>
          <div
            class="cluster-count"
            @click="clickCluster(slot.key)">
            ×{{ slot.entries.length }} · {{ slot.owner.name }}
          </div>
          <div
            v-if="openedCluster === slot.key"
            class="cluster-fan">
            <div
              v-for="(entry, mi) in slot.entries"
              :key="entry.character.id"
              class="fan-member"
              :style="unfurlOffsets(slot.entries.length, slot.angle)[mi]">
              <agent-badge
                :character="entry.character"
                :actions="entry.actions"
                :theme="getTheme(entry.character.owner.faction)"
                :system="system"
                :flipped="slot.angle < -30"
                @select="clickCharacter" />
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="system.siege !== null"
      class="siege has-hover"
      v-tooltip="$t(`data.character_action_status.${system.siege.type}.name`)"
      @click="openBesieger">
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

import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';
import AgentBadge from '@/game/components/galaxy/system/AgentBadge.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'system-actions',
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
      openedCluster: null,
      clusterPinned: false,
      docListenersAttached: false,
    };
  },
  computed: {
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

      // move action
      if (this.selectedCharacter.actions && this.selectedCharacter.actions.virtual_position !== this.system.id) {
        actions.push({ status: 'available', icon: 'jump', name: 'move', reasons: '' });
      }

      return actions;
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
          }

          return actions;
        });
      }

      return [];
    },
    besiegerId() {
      return this.system.siege ? this.system.siege.besieger_id : null;
    },
    besiegerEntry() {
      return this.systemCharacters
        .find((entry) => entry.character.id === this.besiegerId) || null;
    },
    // own agents (minus a besieging one, which stays on the outer fan)
    ownEntries() {
      return this.systemCharacters.filter((entry) => entry.character.owner.id === this.player.id
        && entry.character.id !== this.besiegerId);
    },
    foreignEntries() {
      return this.systemCharacters.filter((entry) => entry.character.owner.id !== this.player.id
        && entry.character.id !== this.besiegerId);
    },
    // deploy slot + own agents on the inner ring, lower-left arc
    innerAngles() {
      const count = this.ownEntries.length + (this.isOwnSystem ? 1 : 0);
      const step = Math.min(20, 124 / Math.max(count - 1, 1));
      return Array.from({ length: count }, (_, i) => 134 + i * step);
    },
    // selected-character actions on the inner ring, upper-right arc
    contextualAngles() {
      const n = this.actions.length;
      const step = 13;
      return this.actions.map((_, i) => -46 - (((n - 1) / 2) * step) + (i * step));
    },
    // foreign agents: one slot per owner (cluster when an owner has several),
    // besieger pinned on top, faction mates at the bottom end
    outerSlots() {
      const groups = [];
      const byOwner = {};

      this.foreignEntries.forEach((entry) => {
        const ownerId = entry.character.owner.id;
        if (!byOwner[ownerId]) {
          byOwner[ownerId] = { owner: entry.character.owner, entries: [] };
          groups.push(byOwner[ownerId]);
        }
        byOwner[ownerId].entries.push(entry);
      });

      const slots = groups.map((group) => {
        const entries = group.entries.slice()
          .sort((a, b) => this.characterRank(a.character) - this.characterRank(b.character)
            || b.character.level - a.character.level);
        const lead = entries[0];

        return {
          key: `owner-${group.owner.id}`,
          kind: entries.length > 1 ? 'cluster' : 'single',
          entry: lead,
          entries,
          lead,
          owner: group.owner,
          theme: this.getTheme(group.owner.faction),
          isBesieger: false,
          rank: this.characterRank(lead.character),
          maxLevel: lead.character.level,
        };
      });

      slots.sort((a, b) => a.rank - b.rank
        || b.maxLevel - a.maxLevel
        || a.owner.name.localeCompare(b.owner.name));

      if (this.besiegerEntry) {
        slots.unshift({
          key: `besieger-${this.besiegerEntry.character.id}`,
          kind: 'single',
          entry: this.besiegerEntry,
          entries: [this.besiegerEntry],
          lead: this.besiegerEntry,
          owner: this.besiegerEntry.character.owner,
          theme: this.getTheme(this.besiegerEntry.character.owner.faction),
          isBesieger: true,
          rank: -1,
          maxLevel: this.besiegerEntry.character.level,
        });
      }

      const n = slots.length;
      const step = n > 1 ? Math.min(13.5, Math.max(9, 116 / (n - 1))) : 0;
      const start = -((n - 1) / 2) * step;
      slots.forEach((slot, i) => {
        slot.angle = start + (i * step);
      });
      if (n > 0 && slots[0].isBesieger) {
        slots[0].angle -= 6;
      }

      return slots;
    },
    hasSystemSlot() {
      return this.player.stellar_systems.length < this.player.max_systems.value;
    },
    hasDominionSlot() {
      return this.player.dominions.length < this.player.max_dominions.value;
    },
  },
  watch: {
    'system.id': function systemChanged() {
      this.closeCluster();
    },
  },
  methods: {
    getTheme(faction) {
      return this.$store.getters['game/themeByKey'](faction);
    },
    characterRank(character) {
      if (character.owner.faction === this.player.faction) {
        return 3;
      }
      return character.type === 'admiral' ? 1 : 2;
    },
    // percentages resolve against .system-content (left → width, top →
    // height), so the ring scales with the view container on any screen
    orbitStyle(angle, ring) {
      const rad = (angle * Math.PI) / 180;
      const radius = ring === 'inner' ? 21 : 40;
      return {
        left: `calc(50% + ${(Math.cos(rad) * radius).toFixed(2)}%)`,
        top: `calc(50% + ${(Math.sin(rad) * radius).toFixed(2)}%)`,
      };
    },
    // members fan out toward the system center; layers grow outward so any
    // squadron size stays readable: ~7 in the first ring, ~10 in the second…
    // The 112px first ring keeps members clear of the neighbouring slots'
    // action buttons, which sit ~32px inward of the outer ring.
    unfurlOffsets(count, slotAngle) {
      const offsets = [];
      let layer = 0;
      let placed = 0;

      while (placed < count) {
        const r = 112 + (62 * layer);
        const stepDeg = ((2 * Math.asin(27 / r)) * 180) / Math.PI;
        const cap = Math.min(count - placed, Math.floor(170 / stepDeg) + 1);

        for (let i = 0; i < cap; i += 1) {
          const deg = slotAngle + 180 + (stepDeg * (i - ((cap - 1) / 2)));
          const rad = (deg * Math.PI) / 180;
          offsets.push({
            left: `${(r * Math.cos(rad)).toFixed(1)}px`,
            top: `${(r * Math.sin(rad)).toFixed(1)}px`,
          });
        }

        placed += cap;
        layer += 1;
      }

      return offsets;
    },
    unfurlMaxRadius(count) {
      let layer = 0;
      let placed = 0;

      while (placed < count) {
        const r = 112 + (62 * layer);
        const stepDeg = ((2 * Math.asin(27 / r)) * 180) / Math.PI;
        placed += Math.floor(170 / stepDeg) + 1;
        layer += 1;
      }

      return 112 + (62 * (layer - 1)) + 25;
    },
    enterCluster(key) {
      if (this.clusterPinned && this.openedCluster !== key) {
        return;
      }
      this.openedCluster = key;
      this.attachDocListeners();
    },
    clickCluster(key) {
      if (this.openedCluster === key && this.clusterPinned) {
        this.closeCluster();
        return;
      }
      this.openedCluster = key;
      this.clusterPinned = true;
      this.attachDocListeners();
    },
    closeCluster() {
      this.openedCluster = null;
      this.clusterPinned = false;
      this.detachDocListeners();
    },
    clusterRoot() {
      const refs = this.$refs[`cluster-${this.openedCluster}`];
      return Array.isArray(refs) ? refs[0] : refs;
    },
    onDocMove(event) {
      if (!this.openedCluster) {
        return;
      }
      const root = this.clusterRoot();
      const slot = this.outerSlots.find((s) => s.key === this.openedCluster);
      if (!root || !slot) {
        this.closeCluster();
        return;
      }
      const rect = root.getBoundingClientRect();
      const dx = event.clientX - (rect.left + (rect.width / 2));
      const dy = event.clientY - (rect.top + (rect.height / 2));
      const buffer = this.clusterPinned ? 170 : 90;
      const threshold = this.unfurlMaxRadius(slot.entries.length) + buffer;

      if (Math.sqrt((dx * dx) + (dy * dy)) > threshold) {
        this.closeCluster();
      }
    },
    onDocClick(event) {
      if (!this.openedCluster || !this.clusterPinned) {
        return;
      }
      const root = this.clusterRoot();
      if (!root || !root.contains(event.target)) {
        this.closeCluster();
      }
    },
    attachDocListeners() {
      if (this.docListenersAttached) {
        return;
      }
      document.addEventListener('mousemove', this.onDocMove);
      document.addEventListener('click', this.onDocClick);
      this.docListenersAttached = true;
    },
    detachDocListeners() {
      if (!this.docListenersAttached) {
        return;
      }
      document.removeEventListener('mousemove', this.onDocMove);
      document.removeEventListener('click', this.onDocClick);
      this.docListenersAttached = false;
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
    openBesieger() {
      if (this.besiegerId) {
        this.$store.dispatch('game/openCharacter', { vm: this, id: this.besiegerId });
      }
    },
    doAction(action) {
      this.hoveredAction = null;
      this.$root.$emit('map:addAction', action, { system: this.system });
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
  },
  beforeDestroy() {
    this.detachDocListeners();
  },
  components: {
    ActionOverview,
    AgentBadge,
    CircleProgressValue,
    Counter,
  },
};
</script>
