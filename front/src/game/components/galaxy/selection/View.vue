<template>
  <div
    :class="`f-${theme}`"
    ref="container"
    class="selection-view-container">
    <div class="selection-view">
      <div class="selection-view-content">
        <div class="selection-status">
          <div
            class="selection-status-info"
            v-html="$tmd('galaxy.selection.view.state', {state: $t(`data.character_action_status.${this.character.action_status}.name`)})" />
          <div class="selection-status-actions">
            <svgicon
              name="disc"
              v-tooltip="$t('galaxy.selection.view.action_center')"
              @click="centerToPosition" />
            <svgicon
              name="drag"
              v-if="isIdleAndAtHome && !character.on_sold"
              v-tooltip="$t('galaxy.selection.view.action_recall')"
              @click="deactivate" />
            <svgicon
              name="drag"
              class="disabled"
              v-else
              v-tooltip="$t('galaxy.selection.view.action_disabled')" />
            <svgicon
              name="unlock"
              v-if="armada && canBreakArmada"
              v-tooltip="$t('galaxy.selection.view.action_break_armada')"
              @click="breakArmada" />
            <svgicon
              name="unlock"
              class="disabled"
              v-else-if="armada"
              v-tooltip="$t('galaxy.selection.view.action_break_armada_disabled')" />
          </div>
        </div>

        <div
          v-if="armada"
          class="selection-status-armada">
          {{ armadaLabel }}
        </div>

        <agent-action-queue
          :character="character"
          :theme="theme"
          can-clear />

        <div class="selection-data">
          <army
            v-if="character.type === 'admiral'"
            :theme="theme"
            :context="'selection'"
            :character="character"
            :isIdleAndAtHome="isIdleAndAtHome" />

          <spy
            v-if="character.type === 'spy'"
            :character="character" />

          <speaker
            v-if="character.type === 'speaker'"
            :character="character" />
        </div>
      </div>

      <div class="selection-view-character">
        <character-card
          :closeable="true"
          :open="true"
          :character="character"
          :theme="theme"
          :lock="true" />
      </div>

      <div
        @click="close"
        class="selection-close">
        ×
      </div>
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import CharacterCard from '@/game/components/card/CharacterCard.vue';
import AgentActionQueue from '@/game/components/galaxy/selection/ActionQueue.vue';

import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

export default {
  name: 'selection-view',
  computed: {
    constant() { return this.$store.state.game.data.constant[0]; },
    theme() { return this.$store.getters['game/theme']; },
    character() { return this.$store.state.game.selectedCharacter; },
    playerCharacters() { return this.$store.state.game.player.characters; },
    isAtHome() {
      return (!!this.$store.state.game.player.stellar_systems.find((s) => s.id === this.character.system)
        || !!this.$store.state.game.player.dominions.find((d) => d.id === this.character.system));
    },
    // the full character fetch carries the armada map (owner-only)
    armada() {
      return this.character.armada || null;
    },
    armadaLabel() {
      const name = this.armada.name || this.$t('galaxy.selection.view.armada_unnamed');
      return `${this.$t('galaxy.selection.view.armada_label')} — ${name} · ${this.armada.member_ids.length}/3`;
    },
    // break is only offered while the armada is at rest: every member
    // idle-ish with an empty queue (server-checked again on push)
    canBreakArmada() {
      if (!this.armada) {
        return false;
      }

      return this.armada.member_ids.every((id) => {
        const member = this.playerCharacters.find((c) => c.id === id);
        return member
          && ['idle', 'docking'].includes(member.action_status)
          && (!member.actions || !member.actions.queue || member.actions.queue.length === 0);
      });
    },
    isIdleAndAtHome() {
      if (this.character.type === 'spy' && this.character.spy.cover.value <= this.constant.cover_threshold) {
        return false;
      }

      if (this.character.type === 'speaker' && this.character.speaker && this.character.speaker.cooldown.value > 0) {
        return false;
      }

      return ['idle', 'docking'].includes(this.character.action_status) && (this.isAtHome || this.recallAnywhere);
    },
    // "Recall from anywhere" cheat toggle (server-enforced as well).
    recallAnywhere() {
      return !!this.$store.state.game.instanceInfo.recall_anywhere;
    },
  },
  watch: {
    playerCharacters(characters) {
      const own = characters.find((c) => c.id === this.character.id);

      if (!own) {
        this.$store.dispatch('game/unselectCharacter');
      }
    },
  },
  methods: {
    close() {
      this.$store.dispatch('game/unselectCharacter');
    },
    centerToPosition() {
      this.$root.$emit('map:centerToCharacter', this.character);
    },
    breakArmada() {
      this.$socket.player.push('break_armada', {
        character_id: this.character.id,
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    deactivate() {
      if (this.isIdleAndAtHome) {
        const characterId = this.character.id;

        this.$store.dispatch('game/unselectCharacter');
        this.$socket.player.push('deactivate_character', {
          character_id: characterId,
        }).receive('error', (data) => {
          this.$toastError(data.reason);
        });
      }
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { right: -500, opacity: 0 })
      .to(this.$refs.container, { right: 0, opacity: 1, ease: Expo.easeOut, duration: 1 }, 0);
  },
  components: {
    CharacterCard,
    AgentActionQueue,
    Army,
    Spy,
    Speaker,
  },
};
</script>
