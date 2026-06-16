<template>
  <div
    class="mpc-offer-item mpc-contract-item"
    :class="`theme-${cardTheme}`">
    <div class="mpc-oi-header">
      <span class="mpc-oi-name">
        #{{ contract.id }}
        <span class="mpc-oi-cat">{{ $t(`minipanel.contracts.category.${contract.action_category}`) }}</span>
      </span>
      <span
        class="mpc-oi-status"
        :class="`is-${contract.status}`">
        {{ $t(`minipanel.contracts.status.${contract.status}`) }}
      </span>
    </div>

    <div class="mpc-contract-body">
      <div v-if="contract.action_type" class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.action') }}</label>
        <span>{{ contract.action_type }}</span>
      </div>
      <div v-if="contract.target_system_id" class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.target_system') }}</label>
        <span>#{{ contract.target_system_id }}</span>
      </div>
      <div class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.payer') }}</label>
        <span>{{ payerName }}</span>
      </div>
      <div v-if="contract.performer_id" class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.performer') }}</label>
        <span>{{ performerName }}</span>
      </div>
      <div class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.bounty') }}</label>
        <span class="icon-value">{{ contract.bounty | integer }} <svgicon name="resource/credit" /></span>
      </div>
      <div
        v-if="contract.status !== 'listed' && contract.listing_fee !== null"
        class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.payout') }}</label>
        <span class="icon-value">{{ payout | integer }} <svgicon name="resource/credit" /></span>
      </div>
      <div class="mpc-contract-line">
        <label>{{ $t('minipanel.contracts.max_strikes') }}</label>
        <span>{{ contract.max_claimant_strikes }}</span>
      </div>
      <p v-if="contract.note" class="mpc-contract-note">{{ contract.note }}</p>
    </div>

    <!-- BROWSE: claim an open bounty -->
    <button
      v-if="context === 'browse'"
      class="default-button"
      :disabled="clicked"
      @click="oneShot('claim')">
      <div>{{ $t('minipanel.contracts.claim') }}</div>
    </button>

    <!-- MINE: issuer can void a still-unclaimed listing -->
    <button
      v-if="context === 'mine' && contract.status === 'listed' && isPayer"
      class="default-button"
      :disabled="clicked"
      @click="oneShot('cancel')">
      <div>{{ $t('minipanel.contracts.cancel') }}</div>
    </button>

    <!-- MINE: active contract -> two-sided closure controls -->
    <div
      v-if="context === 'mine' && contract.status === 'active'"
      class="mpc-closure">
      <div class="mpc-closure-state">
        <span>{{ $t('minipanel.contracts.you_chose') }}:
          <b>{{ myClosure ? $t(`minipanel.contracts.intent.${myClosure}`) : $t('minipanel.contracts.no_choice') }}</b></span>
        <span>{{ $t('minipanel.contracts.they_chose') }}:
          <b>{{ theirClosure ? $t(`minipanel.contracts.intent.${theirClosure}`) : $t('minipanel.contracts.no_choice') }}</b></span>
      </div>
      <div class="mpc-closure-buttons">
        <button
          v-for="intent in myIntents"
          :key="intent"
          class="default-button"
          :class="{ 'is-active': myClosure === intent }"
          @click="closure(intent)">
          <div>{{ $t(`minipanel.contracts.intent.${intent}`) }}</div>
        </button>
        <button
          v-if="myClosure"
          class="default-button is-ghost"
          @click="retract">
          <div>{{ $t('minipanel.contracts.withdraw') }}</div>
        </button>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'contract-card',
  props: {
    contract: { type: Object, required: true },
    context: { type: String, required: true }, // 'browse' | 'mine'
  },
  data() {
    return { clicked: false };
  },
  computed: {
    myId() { return this.$store.state.game.player.id; },
    isPayer() { return this.contract.payer_id === this.myId; },
    players() { return this.$store.state.game.galaxy.players || {}; },
    payerName() {
      const p = this.players[this.contract.payer_id];
      return p ? p.name : `#${this.contract.payer_id}`;
    },
    performerName() {
      const p = this.players[this.contract.performer_id];
      return p ? p.name : `#${this.contract.performer_id}`;
    },
    payout() {
      return this.contract.bounty - (this.contract.listing_fee || 0) - (this.contract.closing_fee || 0);
    },
    myIntents() {
      return this.isPayer ? ['pay', 'terminate', 'dispute'] : ['claim', 'withdraw', 'dispute'];
    },
    myClosure() {
      return this.isPayer ? this.contract.payer_closure : this.contract.performer_closure;
    },
    theirClosure() {
      return this.isPayer ? this.contract.performer_closure : this.contract.payer_closure;
    },
    cardTheme() {
      const p = this.players[this.contract.payer_id];
      return p ? this.$store.getters['game/themeByKey'](p.faction) : '';
    },
  },
  methods: {
    // one-shot terminal actions (claim / cancel) lock the button to avoid double-fire
    oneShot(event) {
      if (this.clicked) return;
      this.clicked = true;
      this.$emit(event, this.contract.id);
    },
    // closure intents are mutable until resolution, so no lock
    closure(intent) {
      this.$emit('submit-closure', { id: this.contract.id, intent });
    },
    retract() {
      this.$emit('withdraw-closure', this.contract.id);
    },
  },
};
</script>
