<template>
  <div
    class="panel-content"
    :class="selectedBallot || selectedResult ? 'is-medium' : 'is-small'">
    <div class="faction-government">
      <v-scrollbar class="has-padding fg-main">
        <h1 class="panel-default-title">
          {{ $t('panel.faction_government.title') }}
        </h1>

        <!-- feature disabled for this game -->
        <div
          v-if="!government"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_government.disabled') }}
          </div>
        </div>

        <!-- founding period -->
        <template v-else-if="government.phase === 'founding'">
          <div class="panel-content-number-bloc">
            <div class="label">
              {{ $t('panel.faction_government.founding') }}
            </div>
            <div class="value">
              <counter :current="government.founding.value" />
            </div>
          </div>
          <div class="panel-content-text-bloc">
            <div class="body">
              {{ $t('panel.faction_government.founding_hint') }}
            </div>
          </div>
        </template>

        <!-- running government -->
        <template v-else>
          <div
            v-for="seat in seatKeys"
            class="fg-seat"
            :key="seat">
            <div class="fg-seat-title">
              {{ seatName(seat) }}
            </div>
            <div class="fg-seat-holder">
              <strong
                v-if="government.seats[seat]"
                class="is-clickable"
                @click="openPlayer(government.seats[seat].player_id)">
                {{ government.seats[seat].name }}
              </strong>
              <em v-else>
                {{ $t('panel.faction_government.vacant') }}
              </em>
            </div>
            <div class="fg-seat-actions">
              <button
                v-if="canCallByElection(seat)"
                @click="callByElection(seat)">
                {{ $t('panel.faction_government.call_by_election') }}
              </button>
              <template v-if="canAppoint(seat)">
                <select v-model="appointees[seat]">
                  <option
                    :value="null"
                    disabled>
                    {{ $t('panel.faction_government.choose_member') }}
                  </option>
                  <option
                    v-for="p in appointableMembers"
                    :key="p.id"
                    :value="p.id">
                    {{ p.name }}
                  </option>
                </select>
                <button
                  :disabled="!appointees[seat]"
                  @click="appoint(seat)">
                  {{ appointMode === 'proposal'
                    ? $t('panel.faction_government.propose')
                    : $t('panel.faction_government.appoint') }}
                </button>
              </template>
            </div>
          </div>

          <div
            v-if="government.term"
            class="panel-content-number-bloc">
            <div class="label">
              {{ $t('panel.faction_government.next_term') }}
            </div>
            <div class="value">
              <counter :current="government.term.value" />
            </div>
          </div>

          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.treasury') }}
          </h1>
          <div class="fg-treasury">
            <div
              v-for="resource in ['credit', 'technology', 'ideology']"
              class="fg-treasury-resource"
              :key="resource">
              <span class="label">{{ $t(`panel.faction_government.resources.${resource}`) }}</span>
              <span class="value">{{ Math.floor(government.treasury[resource]) }}</span>
              <span
                v-if="taxIncome[resource] > 0"
                class="income">
                +{{ Math.round(taxIncome[resource] * 100) / 100 }}
              </span>
            </div>
          </div>
          <div
            v-if="isEconomyHead"
            class="fg-distribute">
            <span class="label">{{ $t('panel.faction_government.distribute_hint') }}</span>
            <input
              v-model.number="distributePct"
              type="number"
              min="1"
              max="100"
              step="1" />
            <span class="fg-pct">%</span>
            <button
              :disabled="!(distributePct > 0 && distributePct <= 100)"
              @click="distributeTreasury">
              {{ $t('panel.faction_government.distribute') }}
            </button>
          </div>

          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.taxes') }}
            <span>{{ $t('panel.faction_government.taxes_cap', { cap: taxCap }) }}</span>
          </h1>
          <div class="fg-taxes">
            <div
              v-for="resource in ['credit', 'technology', 'ideology']"
              class="fg-tax-row"
              :key="`tax-${resource}`">
              <span class="label">{{ $t(`panel.faction_government.resources.${resource}`) }}</span>
              <template v-if="isEconomyHead">
                <input
                  v-model.number="taxDraft[resource]"
                  type="range"
                  min="0"
                  :max="taxCap"
                  step="1" />
                <span class="fg-pct">{{ taxDraft[resource] }}%</span>
              </template>
              <span
                v-else
                class="fg-pct">
                {{ taxRates[resource] }}%
              </span>
            </div>
            <button
              v-if="isEconomyHead"
              @click="setTaxes">
              {{ $t('panel.faction_government.set_taxes') }}
            </button>
          </div>

          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.laws') }}
            <span>
              {{ activeLaws.length }}/{{ maxLaws }}
              <template v-if="lawCooldownLocked">
                — <counter :current="government.law_cooldown.value" />
              </template>
            </span>
          </h1>
          <div
            v-if="activeLaws.length === 0"
            class="panel-content-text-bloc">
            <div class="body">
              {{ $t('panel.faction_government.no_laws') }}
            </div>
          </div>
          <div
            v-for="law in activeLaws"
            class="fg-node is-owned"
            :key="`law-${law}`">
            <div class="fg-node-header">
              <strong>{{ $t(`data.faction_lex.${law}.name`) }}</strong>
              <span>{{ $t('panel.faction_government.enacted') }}</span>
            </div>
          </div>
          <div
            v-if="isLeader && ownedLexes.length > 0"
            class="fg-nominate">
            <select
              v-model="lawDraft"
              multiple
              :size="Math.min(ownedLexes.length, 4)">
              <option
                v-for="lex in ownedLexes"
                :key="`opt-${lex}`"
                :value="lex">
                {{ $t(`data.faction_lex.${lex}.name`) }}
              </option>
            </select>
            <button
              :disabled="lawCooldownLocked || lawDraft.length > maxLaws"
              @click="enactLaws">
              {{ $t('panel.faction_government.enact') }}
            </button>
          </div>

          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.trees') }}
          </h1>
          <div class="fg-tree-buttons">
            <button @click="openTree('faction-patent')">
              {{ $t('panel.faction_government.research') }}
            </button>
            <button @click="openTree('faction-lex')">
              {{ $t('panel.faction_government.lexes') }}
            </button>
          </div>

          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.diplomacy') }}
          </h1>
          <div
            v-for="rival in rivals"
            class="fg-diplomacy-row"
            :key="`dip-${rival.id}`">
            <div class="large">
              <strong :class="`is-color-${themeByKey(rival.key)}`">
                {{ $t(`data.faction.${rival.key}.name`) }}
              </strong>
              <span>{{ $t(`panel.faction_government.stances.${stanceWith(rival.id)}`) }}</span>
            </div>
            <div
              v-if="isLeader"
              class="fg-diplomacy-actions">
              <template v-if="stanceWith(rival.id) === 'cold_war'">
                <button @click="diplomacy_push('gov_diplomacy_declare_war', { faction_id: rival.id })">
                  {{ $t('panel.faction_government.declare_war') }}
                </button>
                <button @click="diplomacy_push('gov_diplomacy_propose', { faction_id: rival.id, kind: 'non_aggression' })">
                  {{ $t('panel.faction_government.propose_pact') }}
                </button>
              </template>
              <template v-else-if="stanceWith(rival.id) === 'war'">
                <button @click="diplomacy_push('gov_diplomacy_propose', { faction_id: rival.id, kind: 'peace' })">
                  {{ $t('panel.faction_government.propose_peace') }}
                </button>
              </template>
              <template v-else-if="stanceWith(rival.id) === 'non_aggression'">
                <button @click="diplomacy_push('gov_diplomacy_break', { faction_id: rival.id })">
                  {{ $t('panel.faction_government.break_pact') }}
                </button>
                <button @click="diplomacy_push('gov_diplomacy_declare_war', { faction_id: rival.id })">
                  {{ $t('panel.faction_government.declare_war') }}
                </button>
              </template>
            </div>
            <!-- cold war / pact: the harm ledger, who has been hitting whom -->
            <div
              v-if="stanceWith(rival.id) !== 'war' && (tensionToward(rival.id) > 0 || tensionFrom(rival.id) > 0)"
              class="fg-tension">
              <span
                v-if="tensionToward(rival.id) > 0"
                v-tooltip="$t('panel.faction_government.tension_ours_tooltip')">
                {{ $t('panel.faction_government.tension_ours', { value: tensionToward(rival.id) }) }}
              </span>
              <span
                v-if="tensionFrom(rival.id) > 0"
                v-tooltip="$t('panel.faction_government.tension_theirs_tooltip')">
                {{ $t('panel.faction_government.tension_theirs', { value: tensionFrom(rival.id) }) }}
              </span>
            </div>
            <!-- war: both sides' sentiments are public knowledge -->
            <div
              v-if="stanceWith(rival.id) === 'war' && warMeters(rival.id)"
              class="fg-war-meters">
              <div
                v-for="side in [faction, rival]"
                class="fg-war-side"
                :key="`meters-${rival.id}-${side.id}`">
                <div class="fg-war-side-name" :class="`is-color-${themeByKey(side.key)}`">
                  {{ $t(`data.faction.${side.key}.name`) }}
                </div>
                <div
                  v-for="meter in ['exhaustion', 'momentum', 'frenzy']"
                  class="fg-war-meter"
                  :key="`meter-${side.id}-${meter}`"
                  v-tooltip="$t(`panel.faction_government.war_meters.${meter}_tooltip`)">
                  <span class="label">{{ $t(`panel.faction_government.war_meters.${meter}`) }}</span>
                  <span class="bar"><span :class="`fill is-${meter}`" :style="{ width: `${meterValue(rival.id, side.id, meter)}%` }" /></span>
                  <span class="value">{{ meterValue(rival.id, side.id, meter) }}</span>
                </div>
              </div>
            </div>
          </div>
          <div
            v-for="proposal in myProposals"
            class="fg-diplomacy-row is-proposal"
            :key="`prop-${proposal.id}`">
            <div class="large">
              <strong>{{ $t(`panel.faction_government.kinds_diplomacy.${proposal.kind}`) }}</strong>
              <span v-if="proposal.to === faction.id">
                {{ $t('panel.faction_government.proposal_from', { name: factionName(proposal.from) }) }}
              </span>
              <span v-else>
                {{ $t('panel.faction_government.proposal_to', { name: factionName(proposal.to) }) }}
              </span>
            </div>
            <div
              v-if="isLeader && proposal.to === faction.id"
              class="fg-diplomacy-actions">
              <button @click="diplomacy_push('gov_diplomacy_accept', { proposal_id: proposal.id })">
                {{ $t('panel.faction_government.accept') }}
              </button>
              <button @click="diplomacy_push('gov_diplomacy_reject', { proposal_id: proposal.id })">
                {{ $t('panel.faction_government.reject_proposal') }}
              </button>
            </div>
          </div>
        </template>
      </v-scrollbar>

      <!-- ballot detail: an open election -->
      <v-scrollbar
        v-if="selectedBallot"
        class="has-padding fg-detail">
        <h1 class="panel-default-title">
          {{ seatName(selectedBallot.seat) }}
          <span>{{ $t(`panel.faction_government.kinds.${selectedBallot.kind}`) }}</span>
        </h1>

        <div class="panel-content-number-bloc">
          <div class="label">
            {{ $t('panel.faction_government.ends_in') }}
          </div>
          <div class="value">
            <counter :current="selectedBallot.cooldown.value" />
          </div>
        </div>

        <!-- Cardan quorum: a staged candle — the only signal while the
             vote runs. Dark below a third, half-lit to two thirds,
             guttering until met, aflame when the offering suffices. -->
        <div
          v-if="selectedBallot.kind === 'stake_pledge' && quorumStage !== null"
          class="fg-quorum-indicator"
          v-tooltip="$t(`panel.faction_government.quorum_stages.${quorumStage}`)">
          <div class="fg-quorum-icon">
            <svgicon
              name="building/defense_local_dome"
              class="base" />
            <svgicon
              name="building/defense_local_dome"
              class="lit"
              :style="{ clipPath: `inset(${100 - quorumFillPct}% 0 0 0)` }" />
            <svg
              class="flame"
              :class="{ 'is-lit': quorumStage === 3 }"
              viewBox="0 0 32 32">
              <path d="M16 4.5c-1.9 2.6-2.6 3.9-2.6 5.2 0 1.6 1.2 2.8 2.6 2.8s2.6-1.2 2.6-2.8c0-1.3-.7-2.6-2.6-5.2z" />
            </svg>
          </div>
        </div>

        <!-- candidacy -->
        <template v-if="selectedBallot.open_candidacy === 'self_only'">
          <button
            v-if="!isCandidate(selectedBallot, player.id)"
            class="fg-wide-button"
            @click="nominate(selectedBallot.id, player.id)">
            {{ $t('panel.faction_government.stand') }}
          </button>
        </template>
        <template v-else-if="['anyone', 'others_only'].includes(selectedBallot.open_candidacy)">
          <div class="fg-nominate">
            <select v-model="nomineeId">
              <option
                :value="null"
                disabled>
                {{ $t('panel.faction_government.choose_member') }}
              </option>
              <option
                v-for="p in nominatableMembers(selectedBallot)"
                :key="p.id"
                :value="p.id">
                {{ p.name }}
              </option>
            </select>
            <button
              :disabled="!nomineeId"
              @click="nominate(selectedBallot.id, nomineeId)">
              {{ $t('panel.faction_government.nominate') }}
            </button>
          </div>
        </template>

        <!-- candidates + voting -->
        <h1 class="panel-default-title">
          {{ $t('panel.faction_government.candidates') }}
          <span>{{ selectedBallot.public.vote_count }} {{ $t('panel.faction_government.votes_cast') }}</span>
        </h1>

        <div
          v-if="selectedBallot.candidates.length === 0"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_government.no_candidates') }}
          </div>
        </div>

        <!-- approval: single appointee, approve / reject -->
        <template v-if="selectedBallot.kind === 'approval'">
          <div
            v-for="candidate in selectedBallot.candidates"
            class="fg-candidate"
            :key="candidate.player_id">
            <strong
              class="is-clickable"
              @click="openPlayer(candidate.player_id)">
              {{ candidate.name }}
            </strong>
          </div>
          <div class="fg-approval-buttons">
            <button
              :class="{ 'is-chosen': myChoice(selectedBallot) === 'approve' }"
              @click="vote(selectedBallot.id, { choice: 'approve' })">
              {{ $t('panel.faction_government.approve') }}
            </button>
            <button
              :class="{ 'is-chosen': myChoice(selectedBallot) === 'reject' }"
              @click="vote(selectedBallot.id, { choice: 'reject' })">
              {{ $t('panel.faction_government.reject') }}
            </button>
          </div>
        </template>

        <!-- every other kind: candidate list -->
        <template v-else>
          <div
            v-for="candidate in selectedBallot.candidates"
            class="fg-candidate"
            :class="{ 'is-chosen': myChoice(selectedBallot) === candidate.player_id,
                      'is-selected': pickedCandidateId === candidate.player_id }"
            :key="candidate.player_id"
            @click="pickedCandidateId = candidate.player_id">
            <strong
              class="is-clickable"
              @click.stop="openPlayer(candidate.player_id)">
              {{ candidate.name }}
            </strong>
            <span v-if="selectedBallot.kind === 'stake_bid'">
              {{ bidTotal(selectedBallot, candidate.player_id) }}
              {{ $t('panel.faction_government.resources.credit') }}
            </span>
            <button
              v-if="selectedBallot.kind === 'plurality'"
              @click.stop="vote(selectedBallot.id, { candidate_id: candidate.player_id })">
              {{ $t('panel.faction_government.vote') }}
            </button>
          </div>

          <!-- Cardan: pledge a share of own ideology income, secretly -->
          <div
            v-if="selectedBallot.kind === 'stake_pledge'"
            class="fg-stake-controls">
            <div class="fg-my-vote">
              {{ $t('panel.faction_government.my_pledge') }}:
              <strong>{{ myPledgePct(selectedBallot) }}%</strong>
            </div>
            <input
              v-model.number="pledgePct"
              type="range"
              min="0"
              max="100"
              step="1" />
            <span class="fg-pct">{{ pledgePct }}%</span>
            <button
              :disabled="!pickedCandidateId"
              @click="vote(selectedBallot.id, { candidate_id: pickedCandidateId, pct: pledgePct })">
              {{ $t('panel.faction_government.pledge') }}
            </button>
          </div>

          <!-- ARK: escrowed credit bid; bidding on anyone nominates them -->
          <div
            v-if="selectedBallot.kind === 'stake_bid'"
            class="fg-stake-controls">
            <div class="fg-my-vote">
              {{ $t('panel.faction_government.my_bid') }}:
              <strong>{{ myBid(selectedBallot) }}</strong>
            </div>
            <select v-model="bidCandidateId">
              <option
                :value="null"
                disabled>
                {{ $t('panel.faction_government.choose_member') }}
              </option>
              <option
                v-for="p in faction.players"
                :key="p.id"
                :value="p.id">
                {{ p.name }}
              </option>
            </select>
            <input
              v-model.number="bidAmount"
              type="number"
              min="1"
              step="1" />
            <button
              :disabled="!bidCandidateId || !(bidAmount > 0)"
              @click="vote(selectedBallot.id, { candidate_id: bidCandidateId, amount: Math.floor(bidAmount) })">
              {{ $t('panel.faction_government.bid') }}
            </button>
          </div>
        </template>
      </v-scrollbar>

      <!-- result detail: a closed election from the history -->
      <v-scrollbar
        v-else-if="selectedResult"
        class="has-padding fg-detail">
        <h1 class="panel-default-title">
          {{ seatName(selectedResult.seat) }}
          <span>{{ $t(`panel.faction_government.outcomes.${selectedResult.outcome}`) }}</span>
        </h1>

        <div
          v-for="total in resultTotals(selectedResult)"
          class="fg-result-row"
          :class="{ 'is-winner': selectedResult.winner && selectedResult.winner.player_id === total.player_id }"
          :key="`${selectedResult.ballot_id}-${total.player_id || total.choice}`">
          <div class="fg-result-label">
            {{ total.name || $t(`panel.faction_government.${total.choice}`) }}
          </div>
          <div class="fg-result-bar">
            <div
              class="fg-result-fill"
              :style="{ width: `${total.share || 0}%` }">
            </div>
          </div>
          <div class="fg-result-amount">
            {{ Math.round(total.amount * 10) / 10 }}
            <span v-if="total.share !== undefined">({{ total.share }}%)</span>
          </div>
        </div>
      </v-scrollbar>
    </div>
  </div>
</template>

<script>
import Counter from '@/game/components/generic/Counter.vue';
import '@/icons/building/defense_local_dome';

// Which seats are filled by vote (per faction) vs appointed by the
// leader; mirrors the GovernmentRules modules server-side. In an
// oligarchy every chair is bought, not gifted — all ARK seats auction.
const ELECTED_SEATS = {
  tetrarchy: ['leader'],
  myrmezir: ['leader', 'economy', 'military'],
  synelle: ['leader'],
  cardan: ['leader', 'economy', 'military'],
  ark: ['leader', 'economy', 'military'],
};

const APPOINT_MODE = {
  tetrarchy: 'direct',
  ark: null,
  synelle: 'proposal',
  myrmezir: null,
  cardan: null,
};

// Candle fill per quorum stage: dark, half, guttering, aflame.
const QUORUM_FILL = [0, 50, 75, 100];

export default {
  name: 'faction-government-panel',
  data() {
    return {
      myVotes: {},
      selectedBallotId: null,
      selectedResultId: null,
      nomineeId: null,
      pickedCandidateId: null,
      pledgePct: 10,
      bidCandidateId: null,
      bidAmount: null,
      appointees: { economy: null, military: null },
      taxDraft: { credit: 0, technology: 0, ideology: 0 },
      lawDraft: [],
      taxIncome: { credit: 0, technology: 0, ideology: 0 },
      distributePct: 25,
    };
  },
  computed: {
    faction() { return this.$store.state.game.faction; },
    player() { return this.$store.state.game.player; },
    government() { return this.faction.government; },
    seatKeys() { return ['leader', 'economy', 'military']; },
    appointMode() { return APPOINT_MODE[this.faction.key]; },
    isLeader() {
      const leader = this.government && this.government.seats.leader;
      return leader && leader.player_id === this.player.id;
    },
    selectedBallot() {
      if (!this.government || this.selectedBallotId === null) return null;
      return this.government.ballots.find((b) => b.id === this.selectedBallotId) || null;
    },
    selectedResult() {
      if (!this.government || this.selectedResultId === null) return null;
      return this.government.history.find((h) => h.ballot_id === this.selectedResultId) || null;
    },
    quorumStage() {
      const stage = this.selectedBallot && this.selectedBallot.public.quorum_stage;
      return typeof stage === 'number' ? stage : null;
    },
    quorumFillPct() {
      return this.quorumStage === null ? 0 : QUORUM_FILL[this.quorumStage];
    },
    isEconomyHead() {
      const economy = this.government && this.government.seats.economy;
      return !!economy && economy.player_id === this.player.id;
    },
    constants() {
      const list = this.$store.state.game.data.constant || [];
      return list[0] || {};
    },
    taxCap() { return this.constants.government_tax_cap || 10; },
    maxLaws() { return this.constants.government_max_laws || 2; },
    taxRates() {
      return (this.government && this.government.tax_rates)
        || { credit: 0, technology: 0, ideology: 0 };
    },
    activeLaws() { return (this.government && this.government.active_laws) || []; },
    ownedLexes() { return (this.government && this.government.faction_lexes) || []; },
    ownedPatents() { return (this.government && this.government.faction_patents) || []; },
    lawCooldownLocked() {
      const cd = this.government && this.government.law_cooldown;
      return !!cd && cd.value > 0;
    },
    factionPatents() { return this.$store.state.game.data.faction_patent || []; },
    factionLexes() { return this.$store.state.game.data.faction_lex || []; },
    diplomacy() { return this.$store.state.game.diplomacy; },
    rivals() {
      if (!this.diplomacy) return [];
      return this.diplomacy.factions.filter((f) => f.id !== this.faction.id);
    },
    myProposals() {
      if (!this.diplomacy) return [];
      return this.diplomacy.proposals.filter(
        (p) => p.from === this.faction.id || p.to === this.faction.id,
      );
    },
    appointableMembers() {
      const seated = this.seatKeys
        .map((seat) => this.government.seats[seat])
        .filter(Boolean)
        .map((holder) => holder.player_id);
      return this.faction.players.filter((p) => !seated.includes(p.id));
    },
  },
  watch: {
    // a ballot that just closed moves from ballots to history: follow it
    government(gov) {
      if (this.selectedBallotId !== null && gov
          && !gov.ballots.some((b) => b.id === this.selectedBallotId)) {
        this.selectedResultId = this.selectedBallotId;
        this.selectedBallotId = null;
      }
    },
  },
  methods: {
    refresh() {
      this.$socket.faction.push('get_government', {})
        .receive('ok', ({ my_votes: myVotes, tax_income: taxIncome }) => {
          this.myVotes = myVotes || {};
          if (taxIncome) this.taxIncome = taxIncome;
        });
      this.$socket.faction.push('get_diplomacy', {})
        .receive('ok', ({ diplomacy }) => { this.$store.commit('game/setDiplomacy', diplomacy); });
    },
    themeByKey(key) {
      return this.$store.getters['game/themeByKey'](key);
    },
    stanceWith(factionId) {
      if (!this.diplomacy) return 'cold_war';
      const pair = [Math.min(this.faction.id, factionId), Math.max(this.faction.id, factionId)].join(':');
      return this.diplomacy.relations[pair] || 'cold_war';
    },
    // tension is directed: "victim>aggressor". `toward` = our grievance
    // against them (they harmed us), `from` = theirs against us.
    tensionToward(rivalId) {
      const tension = (this.diplomacy && this.diplomacy.tension) || {};
      return Math.round(tension[`${this.faction.id}>${rivalId}`] || 0);
    },
    tensionFrom(rivalId) {
      const tension = (this.diplomacy && this.diplomacy.tension) || {};
      return Math.round(tension[`${rivalId}>${this.faction.id}`] || 0);
    },
    warMeters(rivalId) {
      const wars = (this.diplomacy && this.diplomacy.wars) || {};
      const pair = [Math.min(this.faction.id, rivalId), Math.max(this.faction.id, rivalId)].join(':');
      return wars[pair] || null;
    },
    meterValue(rivalId, factionId, meter) {
      const meters = this.warMeters(rivalId);
      const side = meters ? meters[String(factionId)] : null;
      return side ? Math.round(side[meter]) : 0;
    },
    factionName(factionId) {
      const rival = (this.diplomacy ? this.diplomacy.factions : []).find((f) => f.id === factionId);
      return rival ? this.$t(`data.faction.${rival.key}.name`) : '?';
    },
    openTree(name) {
      this.$root.$emit('openBottomMiniPanel', name);
    },
    diplomacy_push(op, payload) {
      this.push(op, payload);
    },
    distributeTreasury() {
      this.push('gov_distribute_treasury', { pct: Math.floor(this.distributePct) });
    },
    seatName(seat) {
      return this.$t(`panel.faction_government.seat_names.${this.faction.key}.${seat}`);
    },
    isCandidate(ballot, playerId) {
      return ballot.candidates.some((c) => c.player_id === playerId);
    },
    myVote(ballot) { return this.myVotes[String(ballot.id)] || null; },
    myChoice(ballot) {
      const vote = this.myVote(ballot);
      return vote ? vote.choice : null;
    },
    myPledgePct(ballot) {
      const vote = this.myVote(ballot);
      return vote && vote.pct !== undefined ? vote.pct : 0;
    },
    myBid(ballot) {
      const vote = this.myVote(ballot);
      return vote && vote.stake ? vote.stake : 0;
    },
    bidTotal(ballot, candidateId) {
      const totals = ballot.public.totals || [];
      const entry = totals.find((t) => t.player_id === candidateId);
      return entry ? entry.amount : 0;
    },
    resultTotals(entry) {
      return [...entry.totals].sort((a, b) => b.amount - a.amount);
    },
    nominatableMembers(ballot) {
      return this.faction.players.filter((p) => {
        if (this.isCandidate(ballot, p.id)) return false;
        if (ballot.open_candidacy === 'others_only' && p.id === this.player.id) return false;
        return true;
      });
    },
    canCallByElection(seat) {
      return this.government.phase === 'running'
        && !this.government.seats[seat]
        && ELECTED_SEATS[this.faction.key].includes(seat)
        && !this.government.ballots.some((b) => b.seat === seat);
    },
    canAppoint(seat) {
      return seat !== 'leader'
        && this.appointMode
        && this.isLeader
        && !this.government.ballots.some((b) => b.seat === seat);
    },
    selectBallot(ballotId) {
      this.selectedResultId = null;
      this.selectedBallotId = ballotId;
      this.pickedCandidateId = null;
      this.nomineeId = null;
    },
    selectResult(ballotId) {
      this.selectedBallotId = null;
      this.selectedResultId = ballotId;
    },
    openPlayer(playerId) {
      this.$store.dispatch('game/openPlayer', { vm: this, id: playerId });
    },
    push(message, payload) {
      this.$socket.faction.push(message, payload)
        .receive('ok', () => this.refresh())
        .receive('error', (err) => this.$toastError(err.reason));
    },
    nominate(ballotId, candidateId) {
      this.push('gov_nominate', { ballot_id: ballotId, candidate_id: candidateId });
      this.nomineeId = null;
    },
    vote(ballotId, payload) {
      this.push('gov_vote', { ballot_id: ballotId, ...payload });
    },
    appoint(seat) {
      this.push('gov_appoint', { seat, appointee_id: this.appointees[seat] });
      this.appointees[seat] = null;
    },
    callByElection(seat) {
      this.push('gov_by_election', { seat });
    },
    setTaxes() {
      this.push('gov_set_taxes', {
        rates: {
          credit: this.taxDraft.credit,
          technology: this.taxDraft.technology,
          ideology: this.taxDraft.ideology,
        },
      });
    },
    enactLaws() {
      this.push('gov_update_laws', { keys: this.lawDraft });
    },
    ownedIn(node, ownedKey) {
      const owned = ownedKey === 'faction_patents' ? this.ownedPatents : this.ownedLexes;
      return owned.includes(node.key);
    },
    nodeClass(node, ownedKey) {
      if (this.ownedIn(node, ownedKey)) return 'is-owned';
      if (!node.ancestor || this.ownedIn({ key: node.ancestor }, ownedKey)) return 'is-available';
      return 'is-locked';
    },
    nodeDepth(node, list) {
      let depth = 0;
      let current = node;
      while (current && current.ancestor) {
        depth += 1;
        current = list.find((n) => n.key === current.ancestor);
      }
      return depth;
    },
    canPurchase(node, ownedKey, seat) {
      const holder = this.government.seats[seat];
      if (!holder || holder.player_id !== this.player.id) return false;
      if (this.ownedIn(node, ownedKey)) return false;
      return !node.ancestor || this.ownedIn({ key: node.ancestor }, ownedKey);
    },
  },
  mounted() {
    if (this.government) {
      this.refresh();
      this.taxDraft = { ...this.taxRates };
    }
  },
  components: {
    Counter,
  },
};
</script>
