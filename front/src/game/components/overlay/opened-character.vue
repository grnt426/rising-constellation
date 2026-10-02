<template>
  <div
    @click.self="close"
    v-if="character && character.owner"
    :class="`f-${theme}`"
    class="opened-character-container"
    role="dialog"
    aria-modal="true"
    :aria-label="character.name">
    <!-- Mobile-only (styled in game/mobile.scss): the stacked layout
         leaves little backdrop to tap, so give an explicit close. -->
    <button
      type="button"
      :aria-label="$t('a11y.agent.close_panel')"
      @click="close"
      class="system-close-button">
      <svgicon
        name="close"
        aria-hidden="true" />
    </button>

    <div class="opened-character">
      <div class="opened-character-owner">
        <span v-html="$tmd('galaxy.opened_character.commanded_by', {characterName: character.owner.name})"/>
        <hr />
        <span v-html="$tmd('galaxy.opened_character.character_faction', {faction: character.owner.faction})"/>
      </div>

      <div class="opened-character-card">
        <character-card
          v-if="character"
          ref="card"
          @deactivated="deactivateCharacter"
          :open="true"
          :character="character"
          :theme="theme"
          :lock="true" />
      </div>

      <div
        v-if="character.status === 'on_board'"
        class="opened-character-aside">
        <army
          v-if="character.type === 'admiral'"
          :theme="theme"
          :valign="'top'"
          :halign="'right'"
          :context="'display'"
          :character="character" />

        <spy
          v-if="character.type === 'spy'"
          :character="character" />

        <speaker
          v-if="character.type === 'speaker'"
          :character="character" />
      </div>
    </div>
  </div>
</template>

<script>
import CharacterCard from '@/game/components/card/CharacterCard.vue';
import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

export default {
  name: 'opened-character',
  computed: {
    character() { return this.$store.state.game.openedCharacter; },
    theme() {
      return this.character?.owner && this.$store.getters['game/themeByKey'](this.character.owner.faction);
    },
  },
  watch: {
    // Opening reads the card out; closing (Esc via Game.vue, the
    // backdrop, the button) returns focus to where it was.
    'character.id': function onOpenedChanged(id, previousId) {
      if (id && !previousId) this.returnFocus = document.activeElement;
      if (id) {
        this.$nextTick(() => {
          if (this.$refs.card) this.$refs.card.focusSummary();
        });
      } else {
        const target = this.returnFocus;
        this.returnFocus = null;
        if (target && document.body.contains(target) && target.focus) target.focus();
      }
    },
  },
  methods: {
    close() {
      this.$store.dispatch('game/closeCharacter');
    },
    deactivateCharacter() {
      this.$store.dispatch('game/closeCharacter');
    },
  },
  components: {
    CharacterCard,
    Army,
    Spy,
    Speaker,
  },
};
</script>
