<template>
  <div class="panel-content is-medium">
    <div class="faction-government faction-diplomacy">
      <!-- rival roster: pick whose standing WITH US to inspect -->
      <v-scrollbar class="has-padding fg-main">
        <h1 class="panel-default-title">
          {{ $t('panel.faction_diplomacy.title') }}
        </h1>

        <div
          v-if="!government"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_government.disabled') }}
          </div>
        </div>

        <template v-else>
          <div
            v-for="rival in rivals"
            class="fd-rival"
            :class="{ 'is-active': selectedRivalId === rival.id }"
            :key="`rival-${rival.id}`"
            @click="selectedRivalId = rival.id">
            <div class="large">
              <strong :class="`is-color-${themeByKey(rival.key)}`">
                {{ $t(`data.faction.${rival.key}.name`) }}
              </strong>
              <span>{{ $t(`panel.faction_diplomacy.stances.${stanceWith(rival.id)}`) }}</span>
            </div>
            <span
              v-if="proposalsWith(rival.id).length > 0"
              class="fd-flag">
              {{ $t('panel.faction_diplomacy.pending_proposal') }}
            </span>
          </div>

          <!-- standings are pairwise-private: no third-party matrix -->
          <div class="panel-content-text-bloc">
            <div class="body">
              {{ $t('panel.faction_diplomacy.privacy_hint') }}
            </div>
          </div>
        </template>
      </v-scrollbar>

      <!-- detail: everything we know about the selected pair -->
      <v-scrollbar
        v-if="selectedRival"
        class="has-padding fg-detail">
        <h1 class="panel-default-title">
          <span :class="`is-color-${themeByKey(selectedRival.key)}`">
            {{ $t(`data.faction.${selectedRival.key}.name`) }}
          </span>
          <span>{{ $t(`panel.faction_diplomacy.stances.${selectedStance}`) }}</span>
        </h1>

        <div
          v-if="isLeader"
          class="fd-leader-actions">
          <template v-if="selectedStance === 'cold_war'">
            <button @click="diplomacyPush('gov_diplomacy_declare_war', { faction_id: selectedRival.id })">
              {{ $t('panel.faction_diplomacy.declare_war') }}
            </button>
            <button @click="diplomacyPush('gov_diplomacy_propose', { faction_id: selectedRival.id, kind: 'non_aggression' })">
              {{ $t('panel.faction_diplomacy.propose_pact') }}
            </button>
          </template>
          <template v-else-if="selectedStance === 'war'">
            <button @click="diplomacyPush('gov_diplomacy_propose', { faction_id: selectedRival.id, kind: 'peace' })">
              {{ $t('panel.faction_diplomacy.propose_peace') }}
            </button>
          </template>
          <template v-else-if="selectedStance === 'non_aggression'">
            <button @click="diplomacyPush('gov_diplomacy_break', { faction_id: selectedRival.id })">
              {{ $t('panel.faction_diplomacy.break_pact') }}
            </button>
            <button @click="diplomacyPush('gov_diplomacy_declare_war', { faction_id: selectedRival.id })">
              {{ $t('panel.faction_diplomacy.declare_war') }}
            </button>
          </template>
        </div>

        <!-- what this stance actually does to the game -->
        <h1 class="panel-default-title">
          {{ $t('panel.faction_diplomacy.effects_title') }}
        </h1>
        <div class="panel-content-text-bloc">
          <div class="body">
            <ul class="fd-effects">
              <li
                v-for="i in effectLineCount(selectedStance)"
                :key="`fx-${selectedStance}-${i}`">
                {{ $t(`panel.faction_diplomacy.effects.${selectedStance}.l${i}`) }}
              </li>
            </ul>
          </div>
        </div>

        <!-- cold war / pact: the directed grievance ledger -->
        <template v-if="selectedStance !== 'war'">
          <h1 class="panel-default-title">
            {{ $t('panel.faction_diplomacy.tension_title') }}
          </h1>
          <div class="fd-tension-rows">
            <div
              class="fd-tension-row"
              v-tooltip="$t('panel.faction_diplomacy.tension_ours_tooltip')">
              <span class="label">{{ $t('panel.faction_diplomacy.tension_ours') }}</span>
              <span class="bar"><span class="fill" :style="{ width: `${Math.min(tensionToward(selectedRival.id), 100)}%` }" /></span>
              <span class="value">{{ tensionToward(selectedRival.id) }}</span>
            </div>
            <div
              class="fd-tension-row"
              v-tooltip="$t('panel.faction_diplomacy.tension_theirs_tooltip')">
              <span class="label">{{ $t('panel.faction_diplomacy.tension_theirs') }}</span>
              <span class="bar"><span class="fill" :style="{ width: `${Math.min(tensionFrom(selectedRival.id), 100)}%` }" /></span>
              <span class="value">{{ tensionFrom(selectedRival.id) }}</span>
            </div>
          </div>
        </template>

        <!-- war: both sides' sentiments are known to the belligerents -->
        <template v-if="selectedStance === 'war' && warMeters(selectedRival.id)">
          <h1 class="panel-default-title">
            {{ $t('panel.faction_diplomacy.sentiments_title') }}
          </h1>
          <div class="fg-war-meters">
            <div
              v-for="side in [faction, selectedRival]"
              class="fg-war-side"
              :key="`meters-${side.id}`">
              <div class="fg-war-side-name" :class="`is-color-${themeByKey(side.key)}`">
                {{ $t(`data.faction.${side.key}.name`) }}
              </div>
              <div
                v-for="meter in ['exhaustion', 'momentum', 'frenzy']"
                class="fg-war-meter"
                :key="`meter-${side.id}-${meter}`"
                v-tooltip="$t(`panel.faction_diplomacy.war_meters.${meter}_tooltip`)">
                <span class="label">{{ $t(`panel.faction_diplomacy.war_meters.${meter}`) }}</span>
                <span class="bar"><span :class="`fill is-${meter}`" :style="{ width: `${meterValue(selectedRival.id, side.id, meter)}%` }" /></span>
                <span class="value">{{ meterValue(selectedRival.id, side.id, meter) }}</span>
              </div>
            </div>
          </div>
        </template>

        <!-- open proposals between the two of us -->
        <template v-if="proposalsWith(selectedRival.id).length > 0">
          <h1 class="panel-default-title">
            {{ $t('panel.faction_diplomacy.proposals_title') }}
          </h1>
          <div
            v-for="proposal in proposalsWith(selectedRival.id)"
            class="fg-diplomacy-row is-proposal"
            :key="`prop-${proposal.id}`">
            <div class="large">
              <strong>{{ $t(`panel.faction_diplomacy.kinds.${proposal.kind}`) }}</strong>
              <span v-if="proposal.to === faction.id">
                {{ $t('panel.faction_diplomacy.proposal_from', { name: factionName(proposal.from) }) }}
              </span>
              <span v-else>
                {{ $t('panel.faction_diplomacy.proposal_to', { name: factionName(proposal.to) }) }}
              </span>
            </div>
            <div
              v-if="isLeader && proposal.to === faction.id"
              class="fg-diplomacy-actions">
              <button @click="diplomacyPush('gov_diplomacy_accept', { proposal_id: proposal.id })">
                {{ $t('panel.faction_diplomacy.accept') }}
              </button>
              <button @click="diplomacyPush('gov_diplomacy_reject', { proposal_id: proposal.id })">
                {{ $t('panel.faction_diplomacy.reject_proposal') }}
              </button>
            </div>
          </div>
        </template>

        <!-- the pair's history: stance changes + hostile acts, both sides -->
        <h1 class="panel-default-title">
          {{ $t('panel.faction_diplomacy.log_title') }}
        </h1>
        <div
          v-if="logForRival(selectedRival.id).length === 0"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_diplomacy.log_empty') }}
          </div>
        </div>
        <div
          v-for="entry in logForRival(selectedRival.id)"
          class="fd-log-entry"
          :key="`log-${entry.id}`">
          <span class="fd-log-time">{{ formatTime(entry.inserted_at) }}</span>
          <span class="fd-log-text">{{ logText(entry) }}</span>
        </div>
      </v-scrollbar>
    </div>
  </div>
</template>

<script>
// How many explanation lines each stance has in the locale files; the
// template loops l1..lN so translators can't accidentally break the
// panel by adding a line without touching this map.
const EFFECT_LINES = { cold_war: 3, war: 4, non_aggression: 3 };

export default {
  name: 'faction-diplomacy-panel',
  data() {
    return {
      selectedRivalId: null,
      log: [],
    };
  },
  computed: {
    faction() { return this.$store.state.game.faction; },
    player() { return this.$store.state.game.player; },
    government() { return this.faction.government; },
    diplomacy() { return this.$store.state.game.diplomacy; },
    isLeader() {
      const leader = this.government && this.government.seats.leader;
      return !!leader && leader.player_id === this.player.id;
    },
    rivals() {
      if (!this.diplomacy) return [];
      return this.diplomacy.factions.filter((f) => f.id !== this.faction.id);
    },
    selectedRival() {
      return this.rivals.find((f) => f.id === this.selectedRivalId) || null;
    },
    selectedStance() {
      return this.selectedRival ? this.stanceWith(this.selectedRival.id) : 'cold_war';
    },
  },
  watch: {
    // rivals arrive async (get_diplomacy / faction_diplomacy push):
    // auto-focus the first one so the detail pane is never blank
    rivals: {
      immediate: true,
      handler(list) {
        if (this.selectedRivalId === null && list.length > 0) {
          this.selectedRivalId = list[0].id;
        }
      },
    },
    // any standing change may come with fresh audit rows
    diplomacy() { this.refreshLog(); },
  },
  methods: {
    refresh() {
      this.$socket.faction.push('get_diplomacy', {})
        .receive('ok', ({ diplomacy }) => { this.$store.commit('game/setDiplomacy', diplomacy); });
      this.refreshLog();
    },
    refreshLog() {
      this.$socket.faction.push('get_diplomacy_log', {})
        .receive('ok', ({ entries }) => {
          this.log = (entries || []).map((e) => ({
            ...e,
            payload: typeof e.payload === 'string' ? JSON.parse(e.payload) : e.payload,
          }));
        });
    },
    themeByKey(key) {
      return this.$store.getters['game/themeByKey'](key);
    },
    stanceWith(factionId) {
      if (!this.diplomacy) return 'cold_war';
      const pair = [Math.min(this.faction.id, factionId), Math.max(this.faction.id, factionId)].join(':');
      return this.diplomacy.relations[pair] || 'cold_war';
    },
    // tension is directed, keyed "victim>aggressor": `toward` = our
    // grievance against them, `from` = theirs against us
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
      const found = (this.diplomacy ? this.diplomacy.factions : []).find((f) => f.id === factionId);
      return found ? this.$t(`data.faction.${found.key}.name`) : '?';
    },
    proposalsWith(rivalId) {
      if (!this.diplomacy) return [];
      return this.diplomacy.proposals.filter(
        (p) => (p.from === this.faction.id && p.to === rivalId)
          || (p.from === rivalId && p.to === this.faction.id),
      );
    },
    effectLineCount(stance) {
      return EFFECT_LINES[stance] || 0;
    },
    logForRival(rivalId) {
      return this.log.filter((entry) => {
        const p = entry.payload || {};
        return [p.from, p.to, p.aggressor, p.victim].includes(rivalId);
      });
    },
    logText(entry) {
      const p = entry.payload || {};
      if (entry.event_type === 'diplomacy_action') {
        const key = p.success === false ? 'action_failed' : 'action';
        return this.$t(`panel.faction_diplomacy.log.${key}`, {
          aggressor: this.factionName(p.aggressor),
          victim: this.factionName(p.victim),
          action: this.$t(`panel.faction_diplomacy.action_kinds.${p.kind}`),
        });
      }
      return this.$t(`panel.faction_diplomacy.log.${p.event}`, {
        from: this.factionName(p.from),
        to: this.factionName(p.to),
        kind: p.kind ? this.$t(`panel.faction_diplomacy.kinds.${p.kind}`) : '',
      });
    },
    formatTime(iso) {
      const date = new Date(iso);
      return `${date.toLocaleDateString()} ${date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    },
    diplomacyPush(op, payload) {
      this.$socket.faction.push(op, payload)
        .receive('ok', () => this.refresh())
        .receive('error', (err) => this.$toastError(err.reason));
    },
  },
  mounted() {
    if (this.government) this.refresh();
  },
};
</script>
