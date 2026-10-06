<template>
  <!-- Top-centre box. In a game with faction governments it reads who
       leads the faction and whether a vote is running, stays lit while a
       vote still waits on the player, and opens the Government drawer.
       Everywhere else it is the in-universe date, as before, and opens
       the event timeline. -->
  <div
    class="navbar-central-box navbar-government"
    :class="{
      'is-plain': !government,
      'is-inert': !clickable,
      'has-vote': openBallots.length > 0,
      'needs-vote': pendingCount > 0,
    }"
    v-press="{ disabled: !clickable }"
    v-tooltip.bottom="tooltip"
    :aria-label="tooltip"
    @click="open">
    <calendar v-if="!government" />

    <template v-else>
      <div class="gov-seat">
        {{ founding ? $t('navbar.government.title') : leaderTitle }}
      </div>
      <div
        class="gov-name"
        :class="{ 'is-vacant': !founding && !leader }">
        <template v-if="founding">
          {{ $t('navbar.government.founding') }}
        </template>
        <template v-else-if="leader">
          {{ leader.name }}
        </template>
        <template v-else>
          {{ $t('panel.faction_government.vacant') }}
        </template>
      </div>
      <div class="gov-status">
        <template v-if="founding">
          {{ $t('navbar.government.elections_in') }}
          <counter :current="government.founding.value" />
        </template>
        <template v-else-if="pendingCount > 0">
          <span class="gov-dot"></span>
          {{ isMobileView
            ? $t('navbar.government.vote_needed_short')
            : $tc('navbar.government.vote_needed', pendingCount, { n: pendingCount }) }}
        </template>
        <template v-else-if="openBallots.length > 0">
          {{ isMobileView
            ? $t('navbar.government.vote_open_short')
            : $tc('navbar.government.vote_open', openBallots.length, { n: openBallots.length }) }}
        </template>
        <calendar
          v-else
          compact />
      </div>
    </template>
  </div>
</template>

<script>
import viewport from '@/utils/viewport';
import Calendar from '@/game/components/navbar/Calendar.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'government-status',
  computed: {
    isMobileView() { return viewport.isMobile; },
    faction() { return this.$store.state.game.faction; },
    government() { return this.faction.government || null; },
    founding() { return this.government.phase === 'founding'; },
    leader() { return this.government.seats.leader; },
    leaderTitle() {
      return this.$t(`panel.faction_government.seat_names.${this.faction.key}.leader`);
    },
    openBallots() { return this.$store.getters['game/openBallots']; },
    pendingBallots() { return this.$store.getters['game/pendingBallots']; },
    pendingCount() { return this.pendingBallots.length; },
    // Without a government the box opens the event timeline, which
    // real-time games and the tutorial don't keep.
    clickable() {
      if (this.government) return true;

      return this.$store.state.game.time.speed !== 'fast'
        && !this.$store.state.game.galaxy.tutorial_id;
    },
    // The ballots themselves are replaced on every faction broadcast:
    // only a change in WHICH ballots are open is worth a round trip.
    ballotIds() { return this.openBallots.map((ballot) => ballot.id).join(','); },
    tooltip() {
      if (!this.government) {
        return this.clickable ? this.$t('navbar.government.tooltip.events') : '';
      }
      if (this.founding) return this.$t('navbar.government.tooltip.founding');
      if (this.pendingCount > 0) {
        return this.$tc('navbar.government.tooltip.vote_needed', this.pendingCount, { n: this.pendingCount });
      }
      if (this.openBallots.length > 0) return this.$t('navbar.government.tooltip.vote_open');
      return this.$t('navbar.government.tooltip.quiet');
    },
  },
  watch: {
    ballotIds: {
      immediate: true,
      handler() {
        if (this.government) this.$store.dispatch('game/refreshGovernmentVotes', this);
      },
    },
    // A vote that starts waiting on the player while they are looking
    // elsewhere: say so once, for those who can't see the box light up.
    pendingCount(count, previous) {
      if (count > previous) {
        this.$announce(this.$tc('navbar.government.tooltip.vote_needed', count, { n: count }));
      }
    },
  },
  methods: {
    open() {
      if (!this.clickable) return;

      if (!this.government) {
        this.$root.$emit('togglePanel', 'operations', { tab: 'events' });
        return;
      }

      // Straight to the vote that waits on the player, if one does.
      const ballot = this.pendingBallots[0] || null;
      this.$root.$emit('togglePanel', 'government', ballot ? { ballotId: ballot.id } : undefined);
    },
  },
  components: {
    Calendar,
    Counter,
  },
};
</script>
