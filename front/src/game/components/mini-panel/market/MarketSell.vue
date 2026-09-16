<template>
  <div class="mp-content-wrapper">
    <div class="mpc-header is-sparse-x">
      <div>
        <h2>{{ $t(title) }}</h2>
        <p
          v-if="offerType"
          @click="reset"
          class="info">
          {{ $t('minipanel.market.back') }}
        </p>
      </div>
    </div>

    <!-- Landing: Mutual Aid (team support, no price) vs Trade (priced) -->
    <div
      v-if="!offerType"
      class="mpc-market-categories">
      <div
        v-for="category in categories"
        :key="category.key"
        class="mpc-market-category">
        <div class="mpc-market-category-title">
          {{ $t(`minipanel.market.category.${category.key}`) }}
        </div>
        <p class="mpc-market-category-desc">
          {{ $t(`minipanel.market.category.${category.key}_desc`) }}
        </p>
        <div
          v-for="choice in category.choices"
          :key="`${category.key}-${choice}`"
          @click="choose(category.key, choice)"
          class="mpc-offer-item is-header">
          {{ $t(`minipanel.market.types.${category.key === 'aid' ? `aid_${choice}` : choice}`) }}
        </div>
      </div>
    </div>

    <div
      v-if="isAgentType && !agent"
      class="mpc-characters-list">
      <closed-character-card
        v-for="character in characters"
        :key="character.id"
        :character="character"
        :theme="theme"
        @click.native="agent = character" />

      <span v-if="characters.length === 0">
        {{ $t('minipanel.market.characters_empty_state') }}
      </span>
    </div>

    <template v-if="offerType === 'resources' || (!isAgentType && offerType) || (isAgentType && agent)">
      <div class="mpc-form" style="margin-right: 10px;">
        <div class="mpc-form-bloc">
          <!-- Mutual Aid resources: a deliberate Donate / Request switch -->
          <template v-if="offerType === 'resources'">
            <div class="mpc-aid-toggle">
              <button
                v-for="direction in ['donation', 'request']"
                :key="direction"
                type="button"
                class="mpc-aid-toggle-option"
                :class="{ 'is-active': aidDirection === direction }"
                @click="aidDirection = direction">
                {{ $t(`minipanel.market.aid.${direction}`) }}
              </button>
            </div>
            <p class="mpc-aid-explain">
              {{ $t(`minipanel.market.aid.${aidDirection}_explain`) }}
            </p>

            <div class="mpc-aid-resources">
              <button
                v-for="res in ['credit', 'technology', 'ideology']"
                :key="res"
                type="button"
                class="mpc-aid-resource"
                :class="{ 'is-active': resource === res }"
                v-tooltip="$t(`data.bonus_pipeline_in.player_${res}.name`)"
                @click="resource = res">
                <svgicon :name="`resource/${res}`" />
              </button>
            </div>
          </template>

          <div
            class="mpc-h-input"
            v-if="isResourceForm">
            <label for="mpc-quantity">{{ $t('minipanel.market.quantity') }}</label>
            <div class="mpc-h-input-i">
              <input
                id="mpc-quantity"
                v-model.number="amount">
              <svgicon :name="`resource/${resourceType}`" />
            </div>
          </div>

          <div
            class="mpc-character-input"
            v-if="isAgentType && agent">
            <closed-character-card
              :character="agent"
              :theme="theme" />
          </div>

          <div
            v-if="mode === 'trade'"
            class="mpc-h-input">
            <label for="mpc-price">{{ $t('minipanel.market.price') }}</label>
            <div class="mpc-h-input-i">
              <input
                id="mpc-price"
                v-model.number="price">
              <svgicon name="resource/credit" />
            </div>
          </div>
          <p
            v-if="galacticHint"
            class="mpc-trade-hint">
            {{ galacticHint }}
          </p>

          <div class="mpc-h-input">
            <label for="mpc-fees">
              {{ $t('minipanel.market.fees') }}
            </label>
            <div class="mpc-h-input-i">
              <input
                id="mpc-fees"
                disabled="true"
                :value="fees | integer">
              <svgicon name="resource/credit" />
            </div>
          </div>
          <p class="mpc-tax-rule">{{ taxRule }}</p>

          <!-- the tax is always paid by whoever completes the offer -->
          <div class="mpc-h-input">
            <label for="mpc-taker-cost">
              {{ $t(`minipanel.market.taker_pays.${mode}`) }}
            </label>
            <div class="mpc-h-input-i">
              <input
                id="mpc-taker-cost"
                disabled="true"
                :value="takerCredits | integer">
              <svgicon name="resource/credit" />
            </div>
          </div>

          <p class="mpc-aid-explain">
            {{ $t(`minipanel.market.fee_note.${mode}`) }}
          </p>
        </div>
      </div>
      <div class="mpc-form">
        <div class="mpc-form-bloc">
          <div class="mpc-v-input">
            <profile-select
              :key="`players-${audienceLocked}`"
              :label="$t(audienceLocked
                ? 'minipanel.market.allowed_teammates'
                : 'minipanel.market.allowed_players')"
              :instanceId="instanceId"
              :initials="profiles"
              :discardedIds="[profile.id]"
              :factionKey="audienceLocked ? profile.faction : null"
              :multiple="true"
              v-model="allowedPlayers" />
          </div>
          <div class="mpc-v-input">
            <div
              v-if="audienceLocked"
              class="mpc-locked-audience">
              <span class="custom-select-label">{{ $t('minipanel.market.allowed_factions') }}</span>
              <span class="mpc-locked-audience-value">
                {{ $t(`data.faction.${profile.faction}.name`) }}
              </span>
              <span class="mpc-locked-audience-why">
                {{ $t(mode === 'trade'
                  ? 'minipanel.market.faction_locked_two_factions'
                  : 'minipanel.market.faction_locked_aid') }}
              </span>
            </div>
            <faction-select
              v-else-if="allowedPlayers.length === 0"
              :label="$t('minipanel.market.allowed_factions')"
              :factions="factions"
              :multiple="true"
              v-model="allowedFactions" />
          </div>
        </div>

        <div class="mpc-form-bloc">
          <button
            class="mpc-button"
            @click="create">
            <div>{{ $t(`minipanel.market.publish_${mode}`) }}</div>
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<script>
import ProfileSelect from '@/game/components/generic/ProfileSelect.vue';
import FactionSelect from '@/game/components/generic/FactionSelect.vue';
import ClosedCharacterCard from '@/game/components/card/ClosedCharacterCard.vue';

// Value per unit for the market fee (Instance.Player.Market @unit_value).
// Offer valuation (Instance.Player.Market @unit_value): suggested trade price.
const UNIT_VALUE = { credit: 1, technology: 10, ideology: 10 };

export default {
  name: 'market-sell',
  data() {
    return {
      categories: [
        { key: 'aid', choices: ['resources', 'character_deck', 'board_character'] },
        { key: 'trade', choices: ['technology', 'ideology', 'character_deck', 'board_character'] },
      ],
      // 'aid' | 'trade'
      category: null,
      // 'resources' (aid only), 'technology', 'ideology', 'character_deck', 'board_character'
      offerType: null,
      aidDirection: 'donation',
      resource: 'credit',
      allowedPlayers: [],
      allowedFactions: [],
      agent: null,
      amount: 1000,
      price: 0,
      // Galactic value index (MarketValue tab), for the trade price hint
      galactic: null,
    };
  },
  computed: {
    instanceId() { return parseInt(this.$store.state.game.auth.instance, 10); },
    theme() { return this.$store.getters['game/theme']; },
    marketTaxe() { return this.$store.state.game.data.constant[0].market_taxe; },
    profile() { return this.$store.state.game.player; },
    title() {
      if (this.category === 'aid') return 'minipanel.market.category.aid';
      if (this.category === 'trade') return 'minipanel.market.category.trade';
      return 'minipanel.market.sell';
    },
    // offer mode sent to the server
    mode() {
      if (this.category !== 'aid') return 'trade';
      return this.offerType === 'resources' ? this.aidDirection : 'donation';
    },
    isAgentType() { return ['character_deck', 'board_character'].includes(this.offerType); },
    isResourceForm() { return this.offerType === 'resources' || ['technology', 'ideology'].includes(this.offerType); },
    // the resource the form is about (server offer type for resources)
    resourceType() { return this.offerType === 'resources' ? this.resource : this.offerType; },
    // Mutual Aid is always faction-only; trades too when the match has two
    // factions or fewer (the server enforces the same rule).
    audienceLocked() { return this.mode !== 'trade' || this.factions.length <= 2; },
    profiles() {
      const players = this.$store.state.game.galaxy.players;
      return Object.keys(players)
        .filter((key) => !this.audienceLocked || players[key].faction === this.profile.faction)
        .map((key) => ({ label: players[key].name, id: players[key].id }));
    },
    factions() {
      return this.$store.state.game.victory
        .factions.map((f) => ({ label: this.$t(`data.faction.${f.key}.name`), id: f.id }));
    },
    defaultAllowedFactions() {
      return this.factions.filter((f) => f.id === this.profile.faction_id);
    },
    characters() {
      if (this.offerType === 'character_deck') {
        return this.$store.state.game.player.character_deck
          .filter(({ cooldown }) => !cooldown || cooldown.value === 0)
          .map(({ character }) => character)
          .filter((character) => !character.on_sold);
      }

      if (this.offerType === 'board_character') {
        return this.$store.state.game.player.characters
          .filter((character) => character.action_status === 'idle' && !character.on_sold);
      }

      return [];
    },
    offerValue() {
      if (this.isResourceForm) {
        const amount = Number.isInteger(this.amount) && this.amount > 0 ? this.amount : 0;
        return amount * UNIT_VALUE[this.resourceType];
      }

      if (this.offerType === 'character_deck' && this.agent) {
        return this.agent.level * 50_000;
      }

      if (this.offerType === 'board_character' && this.agent) {
        return this.agent.level * 50_000 + this.agent.army_maintenance * 250;
      }

      return 0;
    },
    galacticHint() {
      if (this.mode !== 'trade' || !['technology', 'ideology'].includes(this.offerType)) return null;
      const perPoint = this.galactic && this.galactic.prices[this.offerType];
      if (!perPoint) return null;
      return this.$t('minipanel.market.value.trade_hint', {
        price: this.$options.filters.float(perPoint, 2),
        total: this.$options.filters.integer(perPoint * this.validAmount),
      });
    },
    validAmount() { return Number.isInteger(this.amount) && this.amount > 0 ? this.amount : 0; },
    // Instance.Player.Market.tax/2: 1 credit per technology/ideology point
    // whatever the price, market_taxe of credits exchanged, market_taxe of
    // an agent's valuation. Always paid by whoever completes the offer.
    fees() {
      if (this.isResourceForm) {
        if (this.resourceType === 'credit') return this.validAmount * this.marketTaxe;
        const price = this.mode === 'trade' && Number.isFinite(this.price) ? Math.max(this.price, 0) : 0;
        return Math.max(this.validAmount, price * this.marketTaxe);
      }
      return this.offerValue * this.marketTaxe;
    },
    taxRule() {
      const percent = this.$options.filters.float(this.marketTaxe * 100, 0);
      if (this.isAgentType) return this.$t('minipanel.market.tax_rule.agent', { percent });
      if (this.resourceType === 'credit') return this.$t('minipanel.market.tax_rule.credit', { percent });
      return this.$t(`minipanel.market.tax_rule.${this.resourceType}`, { percent });
    },
    // credits the buyer / claimer / fulfiller hands over
    takerCredits() {
      if (this.mode === 'trade') return this.price + this.fees;
      if (this.mode === 'request' && this.resourceType === 'credit') return this.validAmount + this.fees;
      return this.fees;
    },
  },
  watch: {
    offerValue(val) {
      if (this.mode === 'trade') this.price = val;
    },
    allowedPlayers(players) {
      if (players.length > 0) {
        // player-targeted offers take precedence over faction visibility
        if (this.allowedFactions.length > 0) this.allowedFactions = [];
      } else if (this.allowedFactions.length === 0) {
        this.allowedFactions = this.defaultAllowedFactions;
      }
    },
  },
  methods: {
    choose(category, choice) {
      this.category = category;
      this.offerType = choice;
      if (category === 'trade' && !this.galactic) this.fetchGalactic();
      this.allowedPlayers = [];
      this.allowedFactions = this.defaultAllowedFactions;
    },
    fetchGalactic() {
      this.$socket.player
        .push('get_resource_market', {})
        .receive('ok', ({ market }) => { this.galactic = market; });
    },
    create() {
      if (this.mode === 'trade'
        && (!Number.isInteger(this.price) || this.price < 0 || this.price > 10000000000)) {
        this.$toastError('wrong_market_price');
        return;
      }

      const payload = {};

      if (this.isResourceForm) {
        payload.amount = Number.isInteger(this.amount) && this.amount > 0 ? this.amount : 0;
      } else if (this.isAgentType) {
        payload.character_id = this.agent.id;
      }

      this.$socket.player.push('create_offer', {
        mode: this.mode,
        type: this.isResourceForm ? this.resourceType : this.offerType,
        data: payload,
        price: this.mode === 'trade' ? this.price : 0,
        allowed_players: this.allowedPlayers.map((p) => p.id),
        allowed_factions: this.audienceLocked ? [] : this.allowedFactions.map((f) => f.id),
      }).receive('ok', () => {
        this.reset();
        this.$emit('created');
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    reset() {
      this.allowedPlayers = [];
      this.allowedFactions = this.defaultAllowedFactions;
      this.category = null;
      this.offerType = null;
      this.aidDirection = 'donation';
      this.resource = 'credit';
      this.agent = null;
      this.amount = 1000;
      this.price = 0;
    },
  },
  created() {
    this.allowedFactions = this.defaultAllowedFactions;
  },
  components: {
    ProfileSelect,
    FactionSelect,
    ClosedCharacterCard,
  },
};
</script>
