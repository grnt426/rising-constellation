<template>
  <div
    class="card-container"
    :class="[`f-${theme}`, { 'is-pinned': pinned }]">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon :name="icon" />
      </div>
      <div class="card-header-content">
        <div class="title-large">
          {{ $t(`data.${dataKey}.${node.key}.name`) }}
        </div>
      </div>
      <div
        v-if="pinned"
        class="card-close"
        v-tooltip="$t('card.close_hint')"
        @click="$emit('close')">
        <svgicon name="close" />
      </div>
    </div>

    <div class="card-body">
      <div class="card-illustration">
        <img
          v-if="illustration"
          :src="illustration">

        <div
          v-if="enacted"
          class="toast">
          {{ $t('panel.faction_government.enacted') }}
        </div>
      </div>

      <div class="card-information">
        <div class="card-panel-window">
          <div class="card-panel-container">
            <div class="card-panel">
              <p class="card-summary">
                {{ $t(`data.${dataKey}.${node.key}.description`) }}
              </p>

              <card-complex-bonus :bonus="node.bonus || []" />

              <!-- capability patents: the faction building they open -->
              <div
                v-for="building in unlockedBuildings"
                :key="`unlock-${node.key}-${building.key}`"
                class="complex-bonus"
                @mouseover="showChild(building.key)"
                @mouseleave="hideChild()">
                <div v-html="$t('card.patent.unlocks_something', { something: buildingName(building.key) })" />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="!child"
      class="card-action">
      <div class="card-action-button">
        <div
          v-if="node.status === 'locked'"
          class="button disabled">
          <div class="dashed">{{ $t('card.patent.locked') }}</div>
          <div class="dashed icon-value">
            {{ node.cost | integer }}
            <svgicon :name="`resource/${resource}`" />
          </div>
        </div>

        <template v-else-if="node.status === 'available'">
          <!-- only the seat that holds the purse may buy -->
          <div
            v-if="!isBuyer"
            class="button disabled is-two-lines">
            <div class="dashed">{{ $t(`card.faction_tree.requires_${buyerSeat}`) }}</div>
            <div class="dashed icon-value">
              {{ node.cost | integer }}
              <svgicon :name="`resource/${resource}`" />
            </div>
          </div>
          <div
            v-else-if="!affordable"
            class="button disabled is-unaffordable">
            <div class="dashed">{{ $t('card.faction_tree.treasury_short') }}</div>
            <div class="dashed icon-value is-insufficient">
              {{ node.cost | integer }}
              <svgicon :name="`resource/${resource}`" />
            </div>
          </div>
          <div
            v-else
            class="button"
            @click="$emit('purchase', node.key)">
            <div>{{ $t('panel.faction_government.purchase') }}</div>
            <div class="icon-value">
              {{ node.cost | integer }}
              <svgicon :name="`resource/${resource}`" />
            </div>
          </div>
        </template>

        <!-- lexes double as laws: the leader enacts/repeals owned ones
             right here (the Government panel no longer lists laws) -->
        <template v-else-if="kind === 'lex' && canEnact">
          <div
            v-if="enactDisabled"
            class="button disabled">
            <div class="dashed">{{ enactLabel }}</div>
          </div>
          <div
            v-else
            class="button"
            @click="$emit('toggle-law', node.key)">
            <div>{{ enactLabel }}</div>
          </div>
        </template>

        <div
          v-else
          class="button active"
          :class="`f-${theme}`">
          <div>
            {{ enacted ? $t('panel.faction_government.enacted') : $t('card.faction_tree.owned') }}
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="!child && activeChild !== null"
      class="card-child"
      @mouseenter="hoverCardEnter"
      @mouseleave="hoverCardLeave">
      <faction-building-card
        :key="`child-${activeChild}`"
        :child="true"
        :buildingKey="activeChild"
        :theme="theme"
        :showCost="true"
        :pinned="cardPinned"
        @close="hoverCardClose" />
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';
import CardComplexBonus from '@/game/components/card/CardComplexBonus.vue';
import FactionBuildingCard from '@/game/components/card/FactionBuildingCard.vue';

// Thematic stand-ins from the existing icon and illustration sets until
// faction nodes get their own art.
const NODE_ICONS = {
  research_compact: 'patent/open_research',
  deep_space_relay: 'patent/orbital_radar',
  counterintel_grid: 'patent/open_intel',
  standardized_freight: 'patent/transport_1',
  chartered_shipyards: 'doctrine/upgrade_repair',
  orbital_engineering: 'patent/infra_orbital_2',
  gateway_theory: 'patent/orbital_hypergate',
  cyber_warfare_program: 'patent/dome_academy',
  assembly_charter: 'doctrine/stab_1',
  civic_pride: 'patent/dome_happiness',
  sanctuary_accord: 'patent/dome_defense_1',
  mobilization_act: 'patent/dome_mobility',
  war_footing: 'doctrine/upgrade_invasion',
};

const NODE_ILLUSTRATIONS = {
  research_compact: 'patents/open_research.jpg',
  deep_space_relay: 'patents/orbital_radar.jpg',
  counterintel_grid: 'patents/open_intel.jpg',
  standardized_freight: 'patents/transport_1.jpg',
  chartered_shipyards: 'doctrines/upgrade_repair.jpg',
  orbital_engineering: 'patents/infra_orbital.jpg',
  gateway_theory: 'patents/orbital_hypergate.jpg',
  cyber_warfare_program: 'patents/dome_academy.jpg',
  assembly_charter: 'doctrines/stab_1.jpg',
  civic_pride: 'patents/dome_happiness.jpg',
  sanctuary_accord: 'patents/dome_defense_1.jpg',
  mobilization_act: 'patents/dome_mobility.jpg',
  war_footing: 'doctrines/upgrade_invasion.jpg',
};

export default {
  name: 'faction-tree-card',
  mixins: [CardMixin, HoverCardMixin],
  props: {
    node: Object,
    kind: String, // 'patent' | 'lex'
    isBuyer: Boolean,
    treasury: Object,
    enacted: Boolean,
    canEnact: Boolean,
    // true while the law-change cooldown runs or the enacted-law slots
    // are full (repeal stays possible only via the cooldown)
    enactDisabled: Boolean,
    pinned: {
      type: Boolean,
      default: false,
    },
  },
  computed: {
    dataKey() { return this.kind === 'patent' ? 'faction_patent' : 'faction_lex'; },
    resource() { return this.kind === 'patent' ? 'technology' : 'ideology'; },
    // patents are bought by the economy seat, lexes by the leader
    buyerSeat() { return this.kind === 'patent' ? 'economy' : 'leader'; },
    icon() { return NODE_ICONS[this.node.key] || 'doctrine_stamp'; },
    illustration() {
      const file = NODE_ILLUSTRATIONS[this.node.key];
      return file ? `data/${file}` : null;
    },
    affordable() {
      return (this.treasury[this.resource] || 0) >= this.node.cost;
    },
    enactLabel() {
      return this.enacted
        ? this.$t('panel.faction_government.repeal')
        : this.$t('panel.faction_government.enact');
    },
    unlockedBuildings() {
      if (this.kind !== 'patent') return [];
      return (this.$store.state.game.data.faction_building || [])
        .filter((building) => building.patent === this.node.key);
    },
  },
  methods: {
    buildingName(key) {
      return this.$t(`data.faction_building.${key}.name`);
    },
    // reroute CardMixin's plain show/hide through the hover-intent timers
    // so the child card can be reached and pinned like the system cards
    showChild(child) {
      this.hoverCardShow(child);
    },
    hideChild() {
      this.hoverCardHide();
    },
    hoverCardApply(payload) {
      this.activeChild = payload;
    },
    hoverCardVisible() {
      return this.activeChild !== null;
    },
  },
  components: {
    CardComplexBonus,
    FactionBuildingCard,
  },
};

export { NODE_ICONS };
</script>
