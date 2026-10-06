<template>
  <!-- What a yes/no vote decides. "Approve / Reject" alone says nothing:
       this spells out the question, who put it, what each outcome does,
       and what it takes to pass. Elections need none of it (the seat and
       the candidates are the question) and render nothing. -->
  <div
    v-if="kind"
    class="fg-decision panel-content-text-bloc">
    <div class="header">
      <strong>{{ $t('panel.faction_government.decision.title') }}</strong>
    </div>
    <div class="body">
      <p>{{ intro }}</p>

      <template v-if="kind === 'laws' && proposedLaws">
        <div
          v-for="group in lawGroups"
          class="fg-decision-laws"
          :key="group.key">
          <div class="fg-decision-label">
            {{ $t(`panel.faction_government.decision.laws_${group.key}`) }}
          </div>
          <div
            v-for="law in group.laws"
            class="fg-decision-law"
            :class="`is-${group.key}`"
            :key="law">
            <strong>{{ lawText(law, 'name') }}</strong>
            <span>{{ lawText(law, 'description') }}</span>
          </div>
        </div>
        <p v-if="proposedLaws.length === 0">
          {{ $t('panel.faction_government.decision.laws_none') }}
        </p>
      </template>

      <p>{{ $t(`panel.faction_government.decision.${kind}_approved`, params) }}</p>
      <p>{{ $t(`panel.faction_government.decision.${kind}_rejected`, params) }}</p>

      <p
        v-if="ballot.kind === 'approval'"
        class="fg-decision-rule">
        {{ $t(`panel.faction_government.decision.${about.weighted ? 'threshold_weighted' : 'threshold'}`, {
          pct: about.approval_pct || 50,
        }) }}
      </p>
    </div>
  </div>
</template>

<script>
// question (+ ballot kind) → which wording applies
function kindOf(ballot) {
  switch (ballot.question) {
    case 'laws': return 'laws';
    case 'approve': return 'approve';
    case 'dissolve': return 'dissolve';
    // Cardan deposes by pledge (loss of faith), the others by a vote.
    case 'depose': return ballot.kind === 'stake_pledge' ? 'faith' : 'depose';
    default: return null;
  }
}

export default {
  name: 'ballot-decision',
  props: {
    ballot: { type: Object, required: true },
  },
  computed: {
    faction() { return this.$store.state.game.faction; },
    government() { return this.faction.government; },
    kind() { return kindOf(this.ballot); },
    // Server-side description of the vote (Ballot.about/1). Missing on a
    // ballot the server has not re-described yet: the wording then falls
    // back on what the ballot itself says.
    about() { return (this.ballot.public && this.ballot.public.about) || {}; },
    seat() {
      if (this.ballot.seat === 'laws') return this.$t('panel.faction_government.laws_seat');
      return this.$t(`panel.faction_government.seat_names.${this.faction.key}.${this.ballot.seat}`);
    },
    // Laws and nominations are the leader's to propose.
    who() {
      const title = this.$t(`panel.faction_government.seat_names.${this.faction.key}.leader`);

      return this.about.proposed_by
        ? this.$t('panel.faction_government.decision.who_named', { title, name: this.about.proposed_by })
        : this.$t('panel.faction_government.decision.who_title', { title });
    },
    // Who the vote is about: the nominee, or the holder it aims at.
    name() {
      if (this.about.target) return this.about.target;
      const candidate = this.ballot.candidates[0];
      if (candidate) return candidate.name;

      const holder = this.government.seats[this.ballot.seat];
      return holder ? holder.name : this.$t('panel.faction_government.decision.the_holder');
    },
    params() { return { who: this.who, name: this.name, seat: this.seat }; },
    intro() { return this.$t(`panel.faction_government.decision.${this.kind}_intro`, this.params); },
    // The full set of laws the referendum would put in force.
    proposedLaws() { return Array.isArray(this.about.laws) ? this.about.laws : null; },
    // ... read against the laws standing now.
    lawGroups() {
      const proposed = this.proposedLaws || [];
      const active = this.government.active_laws || [];

      return [
        { key: 'enact', laws: proposed.filter((law) => !active.includes(law)) },
        { key: 'repeal', laws: active.filter((law) => !proposed.includes(law)) },
        { key: 'keep', laws: proposed.filter((law) => active.includes(law)) },
      ].filter((group) => group.laws.length > 0);
    },
  },
  methods: {
    lawText(law, field) {
      const key = `data.faction_lex.${law}.${field}`;
      if (this.$te(key)) return this.$t(key);
      return field === 'name' ? law : '';
    },
  },
};
</script>
