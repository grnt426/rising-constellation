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
                +{{ Math.round(taxIncome[resource] * 100) / 100 }}
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
            <number-stepper
              v-for="resource in ['credit', 'technology', 'ideology']"
              :key="`don-${resource}`"
              v-model="donateAmounts[resource]"
              :min="0"
              :placeholder="$t(`panel.faction_government.resources.${resource}`)" />
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
              <number-stepper
                v-for="resource in ['credit', 'technology', 'ideology']"
                :key="`wd-${resource}`"
                v-model="withdrawAmounts[resource]"
                :min="0"
                :placeholder="$t(`panel.faction_government.resources.${resource}`)" />
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
              </template>
              <span
                v-else
                class="fg-pct">
                {{ taxRates[resource] }}%
              </span>
            </div>
            <button
              v-if="canManage"
              @click="setTaxes">
              {{ $t('panel.faction_government.set_taxes') }}
            </button>
          </div>

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
                <number-stepper
                  v-for="resource in ['credit', 'technology', 'ideology']"
                  :key="`gr-${resource}`"
                  v-model="grantAmounts[resource]"
                  :min="0"
                  :placeholder="$t(`panel.faction_government.resources.${resource}`)" />
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

// The royal-prerogative price, mirroring Rules.Tetrarchy.overreach_malus/0:
// each act the Tetrarch performs in the Quaestor's stead costs the whole
// faction this percent of all income for 24 hours.
const OVERREACH_MALUS = 10;

export default {
  name: 'faction-treasury-panel',
  data() {
    return {
      taxDraft: { credit: 0, technology: 0, ideology: 0 },
      taxIncome: { credit: 0, technology: 0, ideology: 0 },
      distributePct: 25,
      donateAmounts: { credit: null, technology: null, ideology: null },
      withdrawAmounts: { credit: null, technology: null, ideology: null },
      grantAmounts: { credit: null, technology: null, ideology: null },
      grantTarget: null,
      withdrawCapDraft: 0,
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
    taxCap() { return this.constants.government_tax_cap || 10; },
    taxRates() {
      return (this.government && this.government.tax_rates)
        || { credit: 0, technology: 0, ideology: 0 };
    },
  },
  methods: {
    refresh() {
      this.$socket.faction.push('get_government', {})
        .receive('ok', ({ tax_income: taxIncome }) => {
          if (taxIncome) this.taxIncome = taxIncome;
        });
    },
    push(message, payload) {
      this.$socket.faction.push(message, payload)
        .receive('ok', () => this.refresh())
        .receive('error', (err) => this.$toastError(err.reason));
    },
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
  },
};
</script>
