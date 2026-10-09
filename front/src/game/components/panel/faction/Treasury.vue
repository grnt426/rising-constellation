<template>
  <div class="panel-content is-small">
    <div class="faction-government faction-treasury">
      <v-scrollbar class="has-padding fg-main">
        <h1 class="panel-default-title">
          {{ $t('panel.faction_government.treasury') }}
        </h1>

        <!-- feature disabled for this game -->
        <div
          v-if="!government"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_government.disabled') }}
          </div>
        </div>

        <!-- no treasury before a government forms -->
        <div
          v-else-if="government.phase === 'founding'"
          class="panel-content-text-bloc">
          <div class="body">
            {{ $t('panel.faction_government.founding_hint') }}
          </div>
        </div>

        <template v-else>
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
                +{{ rounded(taxIncome[resource]) }}
              </span>
            </div>
          </div>

          <!-- tyranny banner: every member sees what the prerogative costs -->
          <div
            v-if="tyrannyMalus > 0"
            class="fg-tyranny"
            v-tooltip="$t('panel.faction_government.tyranny_tooltip')">
            <span class="fg-tyranny-text">
              {{ $t('panel.faction_government.tyranny_active', { malus: tyrannyMalus }) }}
            </span>
            <counter
              v-if="tyrannyLongest"
              :current="tyrannyLongest" />
          </div>

          <!-- member flows: open to the whole faction -->
          <div class="fg-treasury-flow">
            <span class="label">{{ $t('panel.faction_government.donate_hint') }}</span>
            <resource-input
              v-for="resource in ['credit', 'technology', 'ideology']"
              v-model="donateAmounts[resource]"
              :resource="resource"
              :label="$t(`panel.faction_government.resources.${resource}`)"
              :key="`don-${resource}`" />
            <button
              :disabled="!hasAmounts(donateAmounts)"
              @click="donate">
              {{ $t('panel.faction_government.donate') }}
            </button>
          </div>

          <div class="fg-treasury-flow">
            <span class="label">
              {{ government.withdraw_cap_pct > 0
                ? $t('panel.faction_government.withdraw_hint', { cap: government.withdraw_cap_pct })
                : $t('panel.faction_government.withdraw_disabled') }}
            </span>
            <template v-if="government.withdraw_cap_pct > 0">
              <resource-input
                v-for="resource in ['credit', 'technology', 'ideology']"
                v-model="withdrawAmounts[resource]"
                :resource="resource"
                :label="$t(`panel.faction_government.resources.${resource}`)"
                :key="`wd-${resource}`" />
              <button
                :disabled="!hasAmounts(withdrawAmounts)"
                @click="withdraw">
                {{ $t('panel.faction_government.withdraw') }}
              </button>
            </template>
          </div>

          <!-- income taxes: everyone sees the rates, the office edits them -->
          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.taxes') }}
            <span>{{ $t('panel.faction_government.taxes_cap', { cap: taxCap }) }}</span>
          </h1>
          <div
            class="fg-taxes"
            :class="{ 'fg-overreach': canOverreach }">
            <div
              v-if="canOverreach"
              class="fg-overreach-hint">
              {{ $t('panel.faction_government.overreach_hint', { malus: overreachMalus }) }}
            </div>
            <div
              v-for="resource in ['credit', 'technology', 'ideology']"
              class="fg-tax-row"
              :key="`tax-${resource}`">
              <span class="label">{{ $t(`panel.faction_government.resources.${resource}`) }}</span>
              <template v-if="canManage">
                <input
                  v-model.number="taxDraft[resource]"
                  type="range"
                  min="0"
                  :max="taxCap"
                  step="1" />
                <span class="fg-pct">{{ taxDraft[resource] }}%</span>
                <span
                  class="fg-tax-estimate"
                  :class="{ 'is-changed': taxDraft[resource] !== taxRates[resource] }">
                  +{{ rounded(taxEstimate(resource)) }}
                </span>
              </template>
              <span
                v-else
                class="fg-pct">
                {{ taxRates[resource] }}%
              </span>
            </div>
            <div
              v-if="canManage"
              class="fg-tax-apply">
              <button
                :disabled="!taxesChanged"
                @click="setTaxes">
                {{ $t('panel.faction_government.set_taxes') }}
              </button>
              <span class="fg-tax-hint">
                {{ taxesChanged
                  ? $t('panel.faction_government.tax_estimate_changed', { change: taxChangeSummary })
                  : $t('panel.faction_government.tax_estimate_hint') }}
              </span>
            </div>
          </div>

          <!-- ledger: what came in and what left, for every member -->
          <h1 class="panel-default-title">
            {{ $t('panel.faction_government.ledger.title') }}
            <span>{{ $t('panel.faction_government.ledger.subtitle') }}</span>
          </h1>
          <div
            v-if="ledger.length === 0"
            class="panel-content-text-bloc">
            <div class="body">
              {{ $t('panel.faction_government.ledger.empty') }}
            </div>
          </div>
          <div
            v-for="line in shownLedger"
            class="fg-ledger-entry"
            :class="`is-${line.direction}`"
            :key="`ledger-${line.id}`">
            <div class="fg-ledger-head">
              <span class="fg-ledger-text">{{ ledgerText(line) }}</span>
              <span class="fg-ledger-time">{{ formatTime(line.at) }}</span>
            </div>
            <div class="fg-ledger-amounts">
              <span
                v-for="resource in movedResources(line)"
                class="fg-ledger-amount"
                v-tooltip="$t(`panel.faction_government.resources.${resource}`)"
                :key="`ledger-${line.id}-${resource}`">
                {{ line.direction === 'in' ? '+' : '−' }}{{ line.amounts[resource] | integer }}
                <svgicon :name="`resource/${resource}`" />
              </span>
              <span
                v-if="ledgerNote(line)"
                class="fg-ledger-note">
                {{ ledgerNote(line) }}
              </span>
            </div>
          </div>
          <button
            v-if="ledger.length > ledgerPreview"
            class="fg-ledger-more"
            @click="ledgerExpanded = !ledgerExpanded">
            {{ ledgerExpanded
              ? $t('panel.faction_government.ledger.show_less')
              : $t('panel.faction_government.ledger.show_all', { count: ledger.length }) }}
          </button>

          <!-- the Quaestor's office: distribution, cap, grants -->
          <template v-if="canManage">
            <h1 class="panel-default-title">
              {{ $t('panel.faction_government.treasury_tools') }}
              <span v-if="canOverreach">
                {{ $t('panel.faction_government.overreach_title') }}
              </span>
            </h1>
            <div :class="{ 'fg-overreach': canOverreach }">
              <div
                v-if="canOverreach"
                class="fg-overreach-hint">
                {{ $t('panel.faction_government.overreach_hint', { malus: overreachMalus }) }}
              </div>

              <div class="fg-distribute">
                <span class="label">{{ $t('panel.faction_government.distribute_hint') }}</span>
                <number-stepper
                  v-model="distributePct"
                  :min="1"
                  :max="100" />
                <span class="fg-pct">%</span>
                <button
                  :disabled="!(distributePct > 0 && distributePct <= 100)"
                  @click="distributeTreasury">
                  {{ $t('panel.faction_government.distribute') }}
                </button>
              </div>

              <div class="fg-treasury-flow">
                <span class="label">{{ $t('panel.faction_government.withdraw_cap_hint') }}</span>
                <number-stepper
                  v-model="withdrawCapDraft"
                  :min="0"
                  :max="100" />
                <span class="fg-pct">%</span>
                <button
                  :disabled="!(withdrawCapDraft >= 0 && withdrawCapDraft <= 100)"
                  @click="setWithdrawCap">
                  {{ $t('panel.faction_government.set_withdraw_cap') }}
                </button>
              </div>

              <div class="fg-treasury-flow">
                <span class="label">{{ $t('panel.faction_government.grant_hint') }}</span>
                <select v-model="grantTarget">
                  <option
                    :value="null"
                    disabled>
                    {{ $t('panel.faction_government.choose_member') }}
                  </option>
                  <option
                    v-for="p in faction.players"
                    :key="`grant-${p.id}`"
                    :value="p.id">
                    {{ p.name }}
                  </option>
                </select>
                <resource-input
                  v-for="resource in ['credit', 'technology', 'ideology']"
                  v-model="grantAmounts[resource]"
                  :resource="resource"
                  :label="$t(`panel.faction_government.resources.${resource}`)"
                  :key="`gr-${resource}`" />
                <button
                  :disabled="!grantTarget || !hasAmounts(grantAmounts)"
                  @click="grant">
                  {{ $t('panel.faction_government.grant') }}
                </button>
              </div>
            </div>
          </template>
        </template>
      </v-scrollbar>
    </div>
  </div>
</template>

<script>
import Counter from '@/game/components/generic/Counter.vue';
import NumberStepper from '@/game/components/generic/NumberStepper.vue';
import ResourceInput from '@/game/components/generic/ResourceInput.vue';
import { RESOURCES, ledgerLines } from '@/game/treasury/ledger';

// The royal-prerogative price, mirroring Rules.Tetrarchy.overreach_malus/0:
// each act the Tetrarch performs in the Quaestor's stead costs the whole
// faction this percent of all income for 24 hours.
const OVERREACH_MALUS = 10;

// Ledger lines shown before "show all".
const LEDGER_PREVIEW = 8;

export default {
  name: 'faction-treasury-panel',
  data() {
    return {
      taxDraft: { credit: 0, technology: 0, ideology: 0 },
      taxIncome: { credit: 0, technology: 0, ideology: 0 },
      // the members' income before tax, per resource (get_government):
      // what a rate is estimated against while its slider is dragged
      taxBase: { credit: 0, technology: 0, ideology: 0 },
      distributePct: 25,
      donateAmounts: { credit: null, technology: null, ideology: null },
      withdrawAmounts: { credit: null, technology: null, ideology: null },
      grantAmounts: { credit: null, technology: null, ideology: null },
      grantTarget: null,
      withdrawCapDraft: 0,
      ledger: [],
      ledgerExpanded: false,
    };
  },
  computed: {
    faction() { return this.$store.state.game.faction; },
    player() { return this.$store.state.game.player; },
    government() { return this.faction.government; },
    isLeader() {
      const leader = this.government && this.government.seats.leader;
      return !!leader && leader.player_id === this.player.id;
    },
    isEconomyHead() {
      const economy = this.government && this.government.seats.economy;
      return !!economy && economy.player_id === this.player.id;
    },
    // The Tetrarch may work the Quaestor's desk — at the faction's
    // expense. Server-enforced (Rules.Tetrarchy.overreach_malus); this
    // only decides whether to OFFER the controls, with warnings on.
    canOverreach() {
      return this.faction.key === 'tetrarchy' && this.isLeader && !this.isEconomyHead;
    },
    canManage() { return this.isEconomyHead || this.canOverreach; },
    overreachMalus() { return OVERREACH_MALUS; },
    overreachEntries() { return (this.government && this.government.overreach) || []; },
    tyrannyMalus() {
      const total = this.overreachEntries.reduce((sum, e) => sum + (e.malus || 0), 0);
      return Math.min(total, 100);
    },
    tyrannyLongest() {
      const values = this.overreachEntries
        .map((e) => e.cooldown && e.cooldown.value)
        .filter((v) => typeof v === 'number');
      return values.length > 0 ? Math.max(...values) : null;
    },
    constants() {
      const list = this.$store.state.game.data.constant || [];
      return list[0] || {};
    },
    ledgerPreview() { return LEDGER_PREVIEW; },
    shownLedger() {
      return this.ledgerExpanded ? this.ledger : this.ledger.slice(0, LEDGER_PREVIEW);
    },
    taxRatesKey() { return RESOURCES.map((r) => this.taxRates[r]).join('/'); },
    taxesChanged() {
      return RESOURCES.some((r) => this.taxDraft[r] !== this.taxRates[r]);
    },
    // "Credits +120, Technology −3": what setting the drafted rates
    // would change in the treasury's income, resource by resource.
    taxChangeSummary() {
      return RESOURCES
        .filter((r) => this.taxDraft[r] !== this.taxRates[r])
        .map((r) => {
          const change = this.taxEstimate(r) - this.taxEstimate(r, this.taxRates[r]);
          const sign = change < 0 ? '−' : '+';
          return `${this.$t(`panel.faction_government.resources.${r}`)} ${sign}${this.rounded(Math.abs(change))}`;
        })
        .join(', ');
    },
    taxCap() { return this.constants.government_tax_cap || 10; },
    taxRates() {
      return (this.government && this.government.tax_rates)
        || { credit: 0, technology: 0, ideology: 0 };
    },
  },
  watch: {
    // The rates in force changed (set here or by someone else, or the
    // government only just arrived): the sliders start from them again.
    // Watched as a string: the rates object itself is replaced by every
    // faction push, which must not reset a slider being dragged.
    taxRatesKey() { this.taxDraft = { ...this.taxRates }; },
  },
  methods: {
    // Also called by the drawer each time this tab comes up (the panel is
    // mounted with the game, often before the government has arrived).
    refresh() {
      if (!this.government) return;
      this.$socket.faction.push('get_government', {})
        .receive('ok', ({ tax_income: taxIncome, tax_base: taxBase }) => {
          if (taxIncome) this.taxIncome = taxIncome;
          if (taxBase) this.taxBase = taxBase;
        });
      this.refreshLedger();
    },
    refreshLedger() {
      this.$socket.faction.push('get_treasury_log', {})
        .receive('ok', ({ entries }) => { this.ledger = ledgerLines(entries); });
    },
    memberName(id) {
      const member = id && this.faction.players.find((p) => p.id === id);
      return member ? member.name : this.$t('panel.faction_government.ledger.former_member');
    },
    // Content names, with the raw key as a fallback for content this
    // client's locale files do not know.
    dataName(group, key) {
      const path = `data.${group}.${key}.name`;
      return this.$te(path) ? this.$t(path) : key;
    },
    ledgerText(line) {
      const { params } = line;
      const system = params.systemName
        || this.$t('panel.faction_government.ledger.unknown_system');

      return this.$t(`panel.faction_government.ledger.kinds.${line.kind}`, {
        // a forfeit is logged with nobody acting: its payload names the challenger
        name: line.kind === 'challenge_forfeit' ? params.name : this.memberName(line.actorId),
        target: this.memberName(line.targetId),
        pct: params.pct,
        members: params.members,
        level: params.level,
        system,
        item: line.kind === 'lex'
          ? this.dataName('faction_lex', params.key)
          : this.dataName(line.kind === 'patent' ? 'faction_patent' : 'faction_building', params.key),
      });
    },
    // What a withdrawal paid out once the market tax was taken.
    ledgerNote(line) {
      if (line.kind !== 'withdrawn') return null;
      const { net } = line.params;
      const taxed = RESOURCES.some((r) => net[r] > 0 && net[r] < line.amounts[r]);
      if (!taxed) return null;

      const received = RESOURCES
        .filter((r) => net[r] > 0)
        .map((r) => `${this.$options.filters.integer(net[r])} ${this.$t(`panel.faction_government.resources.${r}`)}`)
        .join(', ');
      return this.$t('panel.faction_government.ledger.received', { amounts: received });
    },
    movedResources(line) {
      return RESOURCES.filter((r) => line.amounts[r] > 0);
    },
    formatTime(iso) {
      const date = new Date(iso);
      return `${date.toLocaleDateString()} ${date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    },
    push(message, payload) {
      this.$socket.faction.push(message, payload)
        .receive('ok', () => this.refresh())
        .receive('error', (err) => this.$toastError(err.reason));
    },
    // What a rate would bring the treasury per tick: that share of the
    // members' income before tax. An estimate: incomes move, and a member
    // whose income turns negative stops paying.
    taxEstimate(resource, rate = this.taxDraft[resource]) {
      return ((this.taxBase[resource] || 0) * (rate || 0)) / 100;
    },
    rounded(value) { return Math.round(value * 100) / 100; },
    hasAmounts(amounts) {
      return ['credit', 'technology', 'ideology'].some((r) => amounts[r] > 0);
    },
    packAmounts(amounts) {
      const packed = {};
      ['credit', 'technology', 'ideology'].forEach((r) => {
        packed[r] = amounts[r] > 0 ? Math.floor(amounts[r]) : 0;
      });
      return packed;
    },
    clearAmounts(amounts) {
      ['credit', 'technology', 'ideology'].forEach((r) => { amounts[r] = null; });
    },
    donate() {
      this.push('gov_donate', { amounts: this.packAmounts(this.donateAmounts) });
      this.clearAmounts(this.donateAmounts);
    },
    withdraw() {
      this.push('gov_withdraw', { amounts: this.packAmounts(this.withdrawAmounts) });
      this.clearAmounts(this.withdrawAmounts);
    },
    grant() {
      this.push('gov_grant', { player_id: this.grantTarget, amounts: this.packAmounts(this.grantAmounts) });
      this.clearAmounts(this.grantAmounts);
      this.grantTarget = null;
    },
    setWithdrawCap() {
      this.push('gov_set_withdraw_cap', { pct: Math.floor(this.withdrawCapDraft) });
    },
    distributeTreasury() {
      this.push('gov_distribute_treasury', { pct: Math.floor(this.distributePct) });
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
  },
  mounted() {
    if (this.government) {
      this.refresh();
      this.taxDraft = { ...this.taxRates };
      this.withdrawCapDraft = this.government.withdraw_cap_pct || 0;
    }
  },
  components: {
    Counter,
    NumberStepper,
    ResourceInput,
  },
};
</script>
