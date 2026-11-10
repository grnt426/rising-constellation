<template>
  <!-- Phone Recall: the desktop selection panel's "back to the deck"
       icon, as a button on the agent card. It sits beside other
       buttons under a thumb, so the first tap arms it and the second
       recalls. When the agent can't be recalled right now the button
       stays, dimmed, and a tap says why. -->
  <button
    type="button"
    class="mas-bulk-button agent-recall-button"
    :class="{ 'is-armed': armed, 'is-disabled': !canRecall }"
    :aria-disabled="String(!canRecall)"
    data-bulk="recall"
    @click="tap">
    <svgicon name="drag" />
    <span>{{ armed
      ? $t('galaxy.system.mobile.recall_confirm')
      : $t('galaxy.selection.view.action_recall') }}</span>
  </button>
</template>

<script>
import isIdleAndAtHome from '@/game/recall';

// an armed button left sitting there is one stray thumb from a recall
const ARM_MS = 5000;

export default {
  name: 'agent-recall-button',
  props: {
    // a FULL character (get_character), owned by the player
    character: { type: Object, required: true },
  },
  data() {
    return { armed: false };
  },
  computed: {
    canRecall() {
      const { character } = this;
      return character.status === 'on_board'
        && !character.on_sold
        && isIdleAndAtHome(this.$store.state.game, character);
    },
  },
  watch: {
    'character.id': function reset() { this.disarm(); },
    canRecall(can) { if (!can) this.disarm(); },
  },
  methods: {
    tap() {
      if (!this.canRecall) {
        this.$toasted.show(this.$t('galaxy.selection.view.action_disabled'), { duration: 4000 });
        return;
      }

      if (!this.armed) {
        this.armed = true;
        this.timer = setTimeout(() => { this.armed = false; }, ARM_MS);
        return;
      }

      this.disarm();
      this.$socket.player.push('deactivate_character', {
        character_id: this.character.id,
      }).receive('ok', () => {
        this.$emit('recalled', this.character);
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    disarm() {
      clearTimeout(this.timer);
      this.armed = false;
    },
  },
  beforeDestroy() {
    clearTimeout(this.timer);
  },
};
</script>
