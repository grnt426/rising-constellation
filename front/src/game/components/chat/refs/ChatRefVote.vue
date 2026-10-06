<template>
  <button
    type="button"
    class="chat-ref chat-ref-vote"
    :class="`is-${state}`"
    :aria-label="`${text}. ${tooltip}`"
    v-tooltip="tooltip"
    @click.stop="onClick">
    <span class="chat-ref-icon">{{ state === 'pending' ? '●' : '☑' }}</span>
    <span class="chat-ref-label">{{ text }}</span>
  </button>
</template>

<script>
import { navigateRef } from '../refNavigation';

/**
 * Renders a `[[vote:12|leader]]` chip: a ballot of the faction's
 * government, posted by the game when the vote opened. Like a sighting,
 * the chip is drawn from the live record rather than from the message,
 * so the same line reads differently as the vote goes on:
 *
 *   pending — open, and still waiting on this player: lit.
 *   open    — open, and answered (voted or abstained).
 *   closed  — over: shows the outcome, opens the result.
 *   gone    — aged out of the government's history: the seat is all the
 *             message still carries (its label).
 */
export default {
  name: 'chat-ref-vote',
  props: {
    id: { type: String, required: true },
    label: { type: String, default: null },
  },
  computed: {
    faction() { return this.$store.state.game.faction; },
    government() { return this.faction.government || null; },
    ballotId() { return parseInt(this.id, 10); },
    ballot() {
      return this.$store.getters['game/openBallots'].find((b) => b.id === this.ballotId) || null;
    },
    result() {
      const history = (this.government && this.government.history) || [];
      return history.find((h) => h.ballot_id === this.ballotId) || null;
    },
    state() {
      if (this.ballot) {
        const waiting = this.$store.getters['game/pendingBallots'].some((b) => b.id === this.ballotId);
        return waiting ? 'pending' : 'open';
      }

      return this.result ? 'closed' : 'gone';
    },
    seatName() {
      const seat = (this.ballot || this.result || {}).seat || this.label;

      // pseudo-seats (the laws referendum) have faction-independent names
      if (seat === 'laws') return this.$t('panel.faction_government.laws_seat');

      const key = `panel.faction_government.seat_names.${this.faction.key}.${seat}`;
      return this.$te(key) ? this.$t(key) : this.$t('panel.faction_government.title');
    },
    text() {
      if (this.ballot) {
        const { question, kind } = this.ballot;
        // its "seat" already names the question
        if (question === 'laws') return this.seatName;

        const what = question && question !== 'elect'
          ? this.$t(`panel.faction_government.questions.${question}`)
          : this.$t(`panel.faction_government.kinds.${kind}`);

        return this.$t('in_game_chat.vote.open', { seat: this.seatName, what });
      }

      if (this.result) {
        return this.$t('in_game_chat.vote.closed', {
          seat: this.seatName,
          outcome: this.$t(`panel.faction_government.outcomes.${this.result.outcome}`),
        });
      }

      return this.$t('in_game_chat.vote.gone', { seat: this.seatName });
    },
    tooltip() { return this.$t(`in_game_chat.vote.tooltip_${this.state}`); },
  },
  methods: {
    onClick() {
      navigateRef(this, 'vote', this.id);
    },
  },
};
</script>
