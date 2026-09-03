<template>
  <div
    class="mp-container"
    :class="`f-${theme}`"
    @contextmenu.prevent="panelRightClick">
    <div class="mp-header">
      <div class="mph-title">
        {{ $t('minipanel.patent.title') }}
        <span class="small">
          {{ purchasedPatentsNumber }}/{{ dataPatents.length }}
        </span>
      </div>
      <div
        v-if="purchasedPatentsNumber > 0"
        class="mph-nav">
        <div
          v-for="tab in tabs"
          :key="tab"
          :class="{ 'active': activeTab === tab }"
          class="mph-nav-item"
          @click="switchTab(tab)">
          {{ $t(`data.patent_class.${tab}.name`) }}
        </div>
      </div>
      <div class="mph-close-button" @click="close"></div>
    </div>
    <v-scrollbar
      class="mp-scrollbar"
      :settings="scrollbarSettings">
      <div
        class="mp-content"
        :style="{ height: `${height}px` }">
        <template v-if="purchasedPatentsNumber > 0">
          <div class="mpc-header">
            <div class="info">
              {{ $t(`minipanel.patent.price_factor`) }}
              <strong>+{{ costFactor * 100 | integer }}%</strong>
            </div>
          </div>

          <div class="mpc-tree">
            <div
              class="tree-column"
              v-for="(col, i) in patentsAsGrid"
              :key="`${counter}-col-${i}`">
              <div
                class="tree-row"
                v-for="(row, j) in col"
                :key="`row-${j}`">
                <template v-if="row">
                  <div
                    class="tree-node"
                    :class="[row.status, { 'is-detailed': !isMobileView && detailKey === row.key }]"
                    @mouseenter="nodeEnter(row)"
                    @mouseleave="nodeLeave"
                    @contextmenu.prevent.stop="nodeLock(row)">
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
                      @click="tryPurchasePatent(row)">
                      <svgicon
                        class="main-icon"
                        :name="`patent/${row.key}`" />
                      <svgicon
                        v-if="row.status === 'locked'"
                        class="toast-icon"
                        name="unlock" />
                    </div>
                    <div
                      class="tree-node-label"
                      :class="{ 'shifted': [1, 3].includes(row.children.length) }">
                      {{ $t(`data.patent.${row.key}.name`) }}
                    </div>
                  </div>
                  <div
                    v-if="isMobileView"
                    class="tree-node-card"
                    :class="{ 'is-open': activeCardKey === row.key }">
                    <patent-card
                      :patent="row"
                      :costFactor="costFactor"
                      :theme="theme"
                      @purchase="purchaseFromCard" />
                  </div>
                </template>
              </div>
            </div>
          </div>
        </template>

        <div
          class="mpc-splashscreen"
          v-else>
          <div
            @click="tryPurchasePatent(root)"
            @mouseenter="nodeEnter(root)"
            @mouseleave="nodeLeave"
            @contextmenu.prevent.stop="nodeLock(root)"
            class="tree-node available"
            :class="{ 'is-detailed': !isMobileView && detailKey === root.key }">
            <div class="tree-node-icon">
              <svgicon
                class="main-icon"
                :name="`patent/${root.key}`" />
            </div>
            <div class="tree-node-label">
              {{ $t(`data.patent.${root.key}.name`) }}
            </div>
            <div
              v-if="isMobileView"
              class="tree-node-card"
              :class="{ 'is-open': activeCardKey === root.key }">
              <patent-card
                :patent="root"
                :costFactor="costFactor"
                :theme="theme"
                @purchase="purchaseFromCard" />
            </div>
          </div>
        </div>
      </div>
    </v-scrollbar>

    <!-- desktop detail dock: one sticky card, never auto-closed — the
         tree stays hoverable and the card reachable at any speed.
         Right-click locks it to a patent for pointer-speed-proof travel. -->
    <div
      v-if="!isMobileView && detailPatent"
      class="mpc-patent-dock">
      <patent-card
        :key="`dock-${detailPatent.key}`"
        :patent="detailPatent"
        :costFactor="costFactor"
        :theme="theme"
        :pinned="dockLocked"
        @close="unlockDock"
        @purchase="purchaseFromCard" />
      <div class="dock-hint">
        {{ dockLocked ? $t('minipanel.patent.dock_locked') : $t('minipanel.patent.dock_hint') }}
      </div>
    </div>
  </div>
</template>

<script>
import Tree from '@/utils/tree';
import viewport from '@/utils/viewport';
import MiniPanelMixin from '@/game/mixins/MiniPanelMixin';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';

import PatentCard from '@/game/components/card/PatentCard.vue';

export default {
  name: 'patent-mini-panel',
  mixins: [MiniPanelMixin, HoverCardMixin],
  data() {
    return {
      // Mobile tap-to-card state (see tryPurchasePatent).
      activeCardKey: null,
      // Desktop dock state: the patent whose card is docked top-right,
      // and whether a right-click has locked it there (hover retargeting
      // suspended until released).
      detailKey: null,
      dockLocked: false,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    constant() { return this.$store.state.game.data.constant[0]; },
    dataPatents() { return this.$store.state.game.data.patent; },
    purchasedPatents() { return this.$store.state.game.player.patents; },
    purchasedPatentsNumber() { return this.purchasedPatents.length; },
    costFactor() {
      return this.purchasedPatentsNumber * this.constant.patent_level_price_increase;
    },
    tabs() {
      return Array.from(new Set(this.dataPatents.map((d) => d.class)))
        .filter((tab) => tab !== 'root');
    },
    patents() {
      return this.dataPatents
        .filter((patent) => ['root', this.activeTab].includes(patent.class))
        .map((patent) => {
          let status = 'purchased';
          if (this.purchasedPatents.find((p) => p === patent.key) === undefined) {
            status = this.purchasedPatents.find((p) => p === patent.ancestor) === undefined
              ? 'locked' : 'available';

            if (patent.class === 'root') {
              status = 'available';
            }
          }

          return { ...{ status }, ...patent };
        });
    },
    root() {
      return this.patentsAsTree[0];
    },
    patentsAsTree() {
      return Tree.fromList(this.patents);
    },
    patentsAsGrid() {
      return Tree.trimGrid(Tree.toGrid(this.root));
    },
    detailPatent() {
      return this.patents.find((p) => p.key === this.detailKey) || null;
    },
  },
  watch: {
    // covers panel open too: the mixin's mounted() calls switchTab
    activeTab() {
      this.hoverCardClearTimers();
      this.dockLocked = false;
      const fallback = this.patents.find((p) => p.status === 'available')
        || this.patents.find((p) => p.key === this.detailKey)
        || this.patents[0];
      this.detailKey = fallback ? fallback.key : null;
    },
  },
  methods: {
    nodeEnter(patent) {
      if (this.isMobileView || this.dockLocked) return;
      this.hoverCardShow(patent.key);
    },
    // leaving a node must cancel its pending retarget, or a grazed node
    // swaps the dock long after the pointer has moved on — this is what
    // makes the dwell an actual dwell instead of a delayed inevitability
    nodeLeave() {
      if (this.isMobileView) return;
      this.hoverCardClearTimers();
    },
    // right-click a node: lock the dock to it (instantly), making the
    // card reachable at any pointer speed. While locked, ANY right-click
    // releases — this handler for clicks landing on a node (stops
    // propagation), panelRightClick for everywhere else in the panel.
    nodeLock(patent) {
      if (this.isMobileView) return;
      this.hoverCardClearTimers();

      if (this.dockLocked) {
        this.dockLocked = false;
        return;
      }

      this.detailKey = patent.key;
      this.dockLocked = true;
    },
    panelRightClick() {
      if (this.isMobileView) return;
      if (this.dockLocked) {
        this.dockLocked = false;
      }
    },
    unlockDock() {
      this.dockLocked = false;
    },
    // the dock is sticky: hoverCardHide/Close are never wired, a card
    // only ever gets replaced by dwelling on another node
    hoverCardApply(key) {
      if (key !== null) {
        this.detailKey = key;
      }
    },
    hoverCardVisible() {
      return this.detailKey !== null;
    },
    patentsByClass(name) {
      return this.patents.filter((patent) => patent.class === name);
    },
    tryPurchasePatent(patent) {
      // Touch flow: first tap opens the detail card (its Buy button
      // completes the purchase) — a bare icon tap must never spend
      // resources on a fat-finger. Desktop keeps hover-card + 1-click.
      if (viewport.isMobile) {
        this.activeCardKey = this.activeCardKey === patent.key ? null : patent.key;
        return;
      }
      if (patent.status === 'available') {
        this.purchasePatent(patent.key);
      }
    },
    purchaseFromCard(patentKey) {
      this.activeCardKey = null;
      this.purchasePatent(patentKey);
    },
    purchasePatent(patentKey) {
      this.$socket.player
        .push('purchase_patent', { patent_key: patentKey })
        .receive('ok', () => { this.$ambiance.sound('buy-patent'); })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
  },
  components: {
    PatentCard,
  },
};
</script>
