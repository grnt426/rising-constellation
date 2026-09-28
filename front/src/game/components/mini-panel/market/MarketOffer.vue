<template>
  <div
    class="mpc-offer-item"
    :class="[`theme-${theme}`, `is-mode-${mode}`]">
    <div class="mpc-oi-header">
      <span class="mpc-oi-name">
        #{{ offer.id }}
        <span
          v-html="`<span class='is-color-${theme}'>${offer.profile.name}</span>`"
          @click="openPlayer(offer.profile.id)">
        </span>
      </span>
      <span class="mpc-oi-badges">
        <!-- agents: listed from the deck (no fleet, no location) or from
             the field (with its fleet, somewhere on the map) -->
        <span
          v-if="isAgent"
          v-tooltip="originTooltip"
          class="mpc-oi-badge is-origin"
          :class="{ 'is-unavailable': !isAvailable }">
          {{ $t(`minipanel.market.origin.${offer.type}`) }}
        </span>
        <span
          v-if="mode !== 'trade'"
          class="mpc-oi-badge"
          :class="`is-${mode}`">
          {{ $t(`minipanel.market.badge.${mode}`) }}
        </span>
        <span
          v-if="mode === 'trade' && !isAgent"
          class="mpc-oi-date">{{ offer.inserted_at | date-short }}</span>
      </span>
    </div>

    <div
      v-if="isAgent"
      class="flying"
      :class="{ 'is-pinned': previewOpen }">
      <div class="fl-content">
        <character-card
          :character="character"
          :theme="theme"
          :noAction="true" />

        <div
          class="fl-side-content"
          v-if="offer.type === 'board_character'">
          <army
            v-if="character.type === 'admiral'"
            :theme="theme"
            :valign="'top'"
            :halign="'right'"
            :context="'display'"
            :character="character" />

          <spy
            v-if="character.type === 'spy'"
            :character="character" />

          <speaker
            v-if="character.type === 'speaker'"
            :character="character" />
        </div>
      </div>
    </div>

    <div
      class="card-container closed"
      v-if="!isAgent">
      <div class="card-header">
        <div class="card-header-icon">
          <svgicon :name="`resource/${offer.type}`" />
        </div>
        <div class="card-header-content">
          <div class="title-large nowrap">
            {{ offer.data.amount | integer }}
            <svgicon
              :name="`resource/${offer.type}`"
              class="has-no-background" />
          </div>
          <div class="title-small nowrap">
            {{ $t(`data.bonus_pipeline_in.player_${offer.type}.name`) }}
          </div>
        </div>
      </div>
    </div>

    <closed-character-card
      v-else
      :character="character"
      :theme="theme" />

    <div class="mpc-oi-actions">
      <button
        v-if="button === 'buy'"
        @click="handelClick('buy')"
        v-tooltip="isAvailable ? buyTooltip : $t('minipanel.market.agent_unavailable')"
        class="default-button"
        :disabled="clicked || !isAvailable">
        <div>{{ $t(`minipanel.market.take.${takeKey}`) }}</div>

        <!-- a credit donation: received whole, tax on top -->
        <div
          v-if="takeKey === 'claim_credit'"
          class="icon-value">
          +{{ offer.data.amount | integer }}
          −{{ fees | integer }}
          <svgicon name="resource/credit" />
        </div>

        <!-- a request: the resource sent plus the fee -->
        <div
          v-else-if="mode === 'request'"
          class="icon-value">
          <template v-if="offer.type !== 'credit'">
            {{ offer.data.amount | integer }}
            <svgicon :name="`resource/${offer.type}`" />
          </template>
          {{ requestCreditCost | integer }}
          <svgicon name="resource/credit" />
        </div>

        <div
          v-else
          class="icon-value">
          {{ finalPrice | integer }}
          <svgicon name="resource/credit" />
        </div>
      </button>
      <button
        v-if="button === 'cancel'"
        @click="handelClick('cancel')"
        class="default-button"
        :disabled="clicked">
        <div>{{ $t('minipanel.market.cancel') }}</div>
      </button>

      <!-- agents: pin the card preview (with the fleet for field agents);
           field agents: fly the camera to where they are now -->
      <button
        v-if="isAgent"
        v-tooltip="$t(previewOpen ? 'minipanel.market.preview_close' : 'minipanel.market.preview')"
        class="mpc-oi-icon-button"
        :class="{ 'is-active': previewOpen }"
        type="button"
        @click="previewOpen = !previewOpen">
        <svgicon name="eye" />
      </button>
      <button
        v-if="offer.type === 'board_character' && isAvailable"
        v-tooltip="locateTooltip"
        class="mpc-oi-icon-button"
        type="button"
        @click="locate">
        <svgicon name="marker/flag" />
      </button>
    </div>
  </div>
</template>

<script>
import ClosedCharacterCard from '@/game/components/card/ClosedCharacterCard.vue';
import CharacterCard from '@/game/components/card/CharacterCard.vue';
import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

export default {
  name: 'market-mini-panel-offer',
  props: {
    offer: {
      type: Object,
      required: true,
    },
    button: {
      type: String,
      required: true,
    },
  },
  data() {
    return {
      clicked: false,
      previewOpen: false,
    };
  },
  computed: {
    // 'trade' | 'donation' | 'request' — offers from before Mutual Aid have
    // no mode and are trades (Instance.Player.Market.offer_mode/1)
    mode() {
      const { mode } = this.offer.data || {};
      return ['donation', 'request'].includes(mode) ? mode : 'trade';
    },
    isAgent() { return ['character_deck', 'board_character'].includes(this.offer.type); },
    // Field agents come with their live state (Instance.Player.Market
    // .with_live_agents/2); the listing's data.character is a snapshot from
    // posting time.
    live() { return this.offer.type === 'board_character' ? this.offer.live : null; },
    isAvailable() { return !this.live || this.live.available; },
    character() { return (this.live && this.live.character) || this.offer.data.character; },
    systemName() {
      const id = this.live && this.live.system_id;
      if (!id) return null;
      const system = (this.$store.state.game.galaxy.stellar_systems || []).find((s) => s.id === id);
      return system ? system.name : null;
    },
    originTooltip() {
      if (this.offer.type === 'character_deck') return this.$t('minipanel.market.origin_tooltip.character_deck');
      if (!this.isAvailable) return this.$t('minipanel.market.agent_unavailable');
      return this.systemName
        ? this.$t('minipanel.market.origin_tooltip.board_character_at', { system: this.systemName })
        : this.$t('minipanel.market.origin_tooltip.board_character');
    },
    locateTooltip() {
      return this.systemName
        ? this.$t('minipanel.market.locate_at', { system: this.systemName })
        : this.$t('minipanel.market.locate');
    },
    takeKey() {
      if (this.mode === 'request') return 'fulfill';
      if (this.mode === 'donation') return this.offer.type === 'credit' ? 'claim_credit' : 'claim';
      return 'buy';
    },
    marketTaxe() { return this.$store.state.game.data.constant[0].market_taxe; },
    // Instance.Player.Market.tax/2 — paid by whoever takes the offer
    fees() {
      if (['technology', 'ideology'].includes(this.offer.type)) {
        return Math.max(this.offer.data.amount, (this.offer.price || 0) * this.marketTaxe);
      }
      if (this.offer.type === 'credit') return this.offer.data.amount * this.marketTaxe;
      return this.offer.value * this.marketTaxe;
    },
    taxRule() {
      const percent = this.$options.filters.float(this.marketTaxe * 100, 0);
      if (this.isAgent) return this.$t('minipanel.market.tax_rule.agent', { percent });
      if (this.offer.type === 'credit') return this.$t('minipanel.market.tax_rule.credit', { percent });
      return this.$t(`minipanel.market.tax_rule.${this.offer.type}`, { percent });
    },
    finalPrice() { return this.offer.price + this.fees; },
    requestCreditCost() {
      return this.fees + (this.offer.type === 'credit' ? this.offer.data.amount : 0);
    },
    buyTooltip() {
      const { integer } = this.$options.filters;
      const params = {
        fees: integer(this.fees),
        rule: this.taxRule,
        price: integer(this.offer.price),
        amount: integer((this.offer.data || {}).amount || 0),
      };
      if (this.mode === 'trade') return this.$t('minipanel.market.tooltip', params);
      return this.$t(`minipanel.market.tooltip_${this.takeKey}`, params);
    },
    theme() {
      const player = this.$store.state.game.galaxy.players[this.offer.profile.id];
      return this.$store.getters['game/themeByKey'](player.faction);
    },
  },
  methods: {
    // Close the market and fly the camera to the agent (its system, or its
    // position along a route).
    locate() {
      this.$root.$emit('closeTopMiniPanel');
      if (this.$store.state.game.selectedSystem) {
        this.$store.dispatch('game/closeSystem', this);
      }
      this.$root.$emit('map:centerToCharacter', this.character);
    },
    openPlayer(playerId) {
      this.$store.dispatch('game/openPlayer', { vm: this, id: playerId });
    },
    handelClick(mode) {
      if (!this.clicked) {
        this.clicked = true;
        this.$emit(mode, this.offer.id);
      }
    },
  },
  components: {
    ClosedCharacterCard,
    CharacterCard,
    Army,
    Spy,
    Speaker,
  },
};
</script>
