<template>
  <div
    class="mp-container inverted"
    :class="`f-${theme}`">
    <div class="mp-header">
      <div class="mph-title">
        {{ $t('minipanel.contracts.title') }}
      </div>
      <div class="mph-nav">
        <div
          v-for="tab in tabs"
          :key="tab"
          :class="{ active: activeTab === tab }"
          class="mph-nav-item"
          @click="switchTab(tab)">
          {{ $t(`minipanel.contracts.tabs.${tab}`) }}
        </div>
      </div>
      <div class="mph-close-button" @click="close"></div>
    </div>
    <v-scrollbar
      class="mp-scrollbar"
      :settings="{
        wheelPropagation: false,
        suppressScrollY: true,
        useBothWheelAxes: true,
      }">
      <div
        class="mp-content"
        :style="{
          height: `${height}px`,
          padding: '25px',
        }">
        <template v-if="activeTab === 'browse'">
          <div
            v-if="listed.length > 0"
            class="mpc-offers-list">
            <contract-card
              v-for="c in listed"
              :key="c.id"
              :contract="c"
              context="browse"
              @claim="claim" />
          </div>
          <div
            v-else
            class="mpc-empty-state">
            <h2>{{ $t('minipanel.contracts.empty_browse_title') }}</h2>
            <p>{{ $t('minipanel.contracts.empty_browse_desc') }}</p>
          </div>
        </template>

        <template v-else-if="activeTab === 'mine'">
          <div
            v-if="mine.length > 0"
            class="mpc-offers-list">
            <contract-card
              v-for="c in mine"
              :key="c.id"
              :contract="c"
              context="mine"
              @submit-closure="submitClosure"
              @withdraw-closure="withdrawClosure"
              @cancel="cancel" />
          </div>
          <div
            v-else
            class="mpc-empty-state">
            <h2>{{ $t('minipanel.contracts.empty_mine_title') }}</h2>
            <p>{{ $t('minipanel.contracts.empty_mine_desc') }}</p>
          </div>
        </template>

        <contract-create
          v-else-if="activeTab === 'create'"
          @created="created" />
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import MiniPanelMixin from '@/game/mixins/MiniPanelMixin';
import ContractCard from '@/game/components/mini-panel/contracts/ContractCard.vue';
import ContractCreate from '@/game/components/mini-panel/contracts/ContractCreate.vue';

export default {
  name: 'contracts-mini-panel',
  mixins: [MiniPanelMixin],
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    tabs() { return ['browse', 'mine', 'create']; },
    myId() { return this.$store.state.game.player.id; },
    contracts() { return this.$store.state.game.contracts || []; },
    listed() {
      return this.contracts
        .filter((c) => c.status === 'listed' && c.payer_id !== this.myId)
        .sort((a, b) => b.id - a.id);
    },
    mine() {
      return this.contracts
        .filter((c) => c.payer_id === this.myId || c.performer_id === this.myId)
        .sort((a, b) => b.id - a.id);
    },
  },
  methods: {
    // get_contracts is a plain read (no broadcast), so seed the store from its
    // reply; later create/claim/closure broadcasts keep it fresh via game/update.
    fetch() {
      this.$socket.player
        .push('get_contracts', {})
        .receive('ok', ({ contracts }) => {
          this.$store.commit('game/update', { global_contracts: contracts });
        })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    claim(id) {
      this.$socket.player.push('claim_contract', { contract_id: id })
        .receive('ok', () => { this.switchTab('mine'); })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    submitClosure({ id, intent }) {
      this.$socket.player.push('submit_contract_closure', { contract_id: id, intent })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    withdrawClosure(id) {
      this.$socket.player.push('withdraw_contract_closure', { contract_id: id })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    cancel(id) {
      this.$socket.player.push('cancel_contract', { contract_id: id })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    created() { this.switchTab('mine'); },
  },
  mounted() { this.fetch(); },
  components: {
    ContractCard,
    ContractCreate,
  },
};
</script>
