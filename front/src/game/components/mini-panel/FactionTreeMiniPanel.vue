<template>
  <div
    class="mp-container"
    :class="`f-${theme}`">
    <div class="mp-header">
      <div class="mph-title">
        {{ $t('minipanel.faction_tree.title') }}
        <span class="small">
          {{ ownedCount }}/{{ nodes.length }}
        </span>
      </div>
      <div class="mph-nav">
        <div
          v-for="tab in tabs"
          :key="tab"
          :class="{ 'active': activeTab === tab }"
          class="mph-nav-item"
          @click="switchTab(tab)">
          {{ $t(`minipanel.faction_tree.tabs.${tab}`) }}
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
        :style="{ height: `${height}px` }">
        <div class="mpc-header">
          <div class="info">
            {{ $t('minipanel.faction_tree.treasury') }}
            <strong>{{ Math.floor(treasury[resource] || 0) }}</strong>
            {{ $t(`panel.faction_government.resources.${resource}`) }}
          </div>
          <!-- lexes double as laws: enacted count + change cooldown -->
          <div
            v-if="activeTab === 'lex'"
            class="info">
            {{ $t('minipanel.faction_tree.laws') }}
            <strong>{{ activeLaws.length }}/{{ maxLaws }}</strong>
            <template v-if="lawCooldownLocked">
              — <counter :current="government.law_cooldown.value" />
            </template>
          </div>
          <!-- the Tetrarch buying patents over the Quaestor's head -->
          <div
            v-if="isOverreachBuyer"
            class="info is-overreach">
            {{ $t('minipanel.faction_tree.overreach_hint', { malus: 10 }) }}
          </div>
        </div>

        <div class="mpc-tree">
          <div
            class="tree-column"
            v-for="(col, i) in nodesAsGrid"
            :key="`${counter}-col-${i}`">
            <div
              class="tree-row"
              v-for="(row, j) in col"
              :key="`row-${j}`">
              <template v-if="row">
                <div
                  class="tree-node"
                  :class="row.status">
                  <div class="tree-node-effect"></div>
                  <div class="tree-node-links">
                    <div
                      class="link middle"
                      v-if="[1, 3].includes(row.children.length)">
                    </div>
                    <template v-if="[2, 3].includes(row.children.length)">
                      <div class="link top"></div>
                      <div class="link bottom"></div>
                    </template>
                  </div>
                  <div
                    class="tree-node-icon"
                    @click="tryPurchase(row)">
                    <svgicon
                      class="main-icon"
                      :name="iconFor(row)" />
                    <svgicon
                      v-if="row.status === 'locked'"
                      class="toast-icon"
                      name="unlock" />
                  </div>
                  <div
                    class="tree-node-label"
                    :class="{ 'shifted': [1, 3].includes(row.children.length) }">
                    {{ $t(`data.${dataKey}.${row.key}.name`) }}
                  </div>
                </div>
                <div class="tree-node-card">
                  <faction-tree-card
                    :node="row"
                    :kind="activeTab"
                    :theme="theme"
                    :isBuyer="isBuyer"
                    :treasury="treasury"
                    :enacted="activeLaws.includes(row.key)"
                    :canEnact="isLawmaker"
                    :enactDisabled="lawCooldownLocked
                      || (!activeLaws.includes(row.key) && activeLaws.length >= maxLaws)"
                    @purchase="purchase"
                    @toggle-law="toggleLaw" />
                </div>
              </template>
            </div>
          </div>
        </div>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import Tree from '@/utils/tree';
import MiniPanelMixin from '@/game/mixins/MiniPanelMixin';

import Counter from '@/game/components/generic/Counter.vue';
import FactionTreeCard, { NODE_ICONS } from '@/game/components/card/FactionTreeCard.vue';

export default {
  name: 'faction-tree-mini-panel',
  mixins: [MiniPanelMixin],
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    player() { return this.$store.state.game.player; },
    government() { return this.$store.state.game.faction.government; },
    tabs() { return ['patent', 'lex']; },
    dataKey() { return this.activeTab === 'patent' ? 'faction_patent' : 'faction_lex'; },
    resource() { return this.activeTab === 'patent' ? 'technology' : 'ideology'; },
    dataNodes() {
      return this.$store.state.game.data[this.dataKey] || [];
    },
    owned() {
      if (!this.government) return [];
      const key = this.activeTab === 'patent' ? 'faction_patents' : 'faction_lexes';
      return this.government[key] || [];
    },
    ownedCount() { return this.owned.length; },
    activeLaws() { return (this.government && this.government.active_laws) || []; },
    treasury() {
      return (this.government && this.government.treasury)
        || { credit: 0, technology: 0, ideology: 0 };
    },
    isBuyer() {
      if (!this.government) return false;
      const seat = this.activeTab === 'patent' ? 'economy' : 'leader';
      const holder = this.government.seats[seat];
      return (!!holder && holder.player_id === this.player.id) || this.isOverreachBuyer;
    },
    // Royal prerogative: the Tetrarch may buy patents in the Quaestor's
    // stead — the server bills the faction-wide tyranny malus, the
    // header hint warns up front.
    isOverreachBuyer() {
      if (!this.government || this.activeTab !== 'patent') return false;
      if (this.$store.state.game.faction.key !== 'tetrarchy') return false;
      const leader = this.government.seats.leader;
      const economy = this.government.seats.economy;
      return !!leader && leader.player_id === this.player.id
        && !(economy && economy.player_id === this.player.id);
    },
    isLawmaker() {
      if (!this.government) return false;
      const leader = this.government.seats.leader;
      return !!leader && leader.player_id === this.player.id;
    },
    maxLaws() {
      const list = this.$store.state.game.data.constant || [];
      return (list[0] || {}).government_max_laws || 2;
    },
    lawCooldownLocked() {
      const cd = this.government && this.government.law_cooldown;
      return !!cd && cd.value > 0;
    },
    nodes() {
      return this.dataNodes.map((node) => {
        let status = 'purchased';
        if (!this.owned.includes(node.key)) {
          status = node.ancestor && !this.owned.includes(node.ancestor)
            ? 'locked' : 'available';
        }
        return { status, ...node };
      });
    },
    root() { return this.nodesAsTree[0]; },
    nodesAsTree() { return Tree.fromList(this.nodes); },
    nodesAsGrid() { return Tree.trimGrid(Tree.toGrid(this.root)); },
  },
  methods: {
    iconFor(node) {
      return NODE_ICONS[node.key] || 'doctrine_stamp';
    },
    tryPurchase(node) {
      if (node.status === 'available' && this.isBuyer) {
        this.purchase(node.key);
      }
    },
    purchase(key) {
      const op = this.activeTab === 'patent' ? 'gov_purchase_patent' : 'gov_purchase_lex';

      this.$socket.faction
        .push(op, { key })
        .receive('ok', () => { this.$ambiance.sound('buy-patent'); })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    // Enact/repeal an owned lex. The op takes the FULL desired active
    // set; for Myrmezir the server opens a referendum instead of
    // applying immediately.
    toggleLaw(key) {
      const next = this.activeLaws.includes(key)
        ? this.activeLaws.filter((k) => k !== key)
        : [...this.activeLaws, key];

      this.$socket.faction
        .push('gov_update_laws', { keys: next })
        .receive('ok', () => { this.$ambiance.sound('buy-patent'); })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
  },
  components: {
    Counter,
    FactionTreeCard,
  },
};
</script>
