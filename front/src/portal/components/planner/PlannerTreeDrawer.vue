<template>
  <!-- Patents or lexes, in the in-game mini panel's look (same tree
       layout, node states and card dock; game/components/mini-panels
       styles are imported by the page). Clicking a node toggles it:
       nothing is bought, nothing is limited. -->
  <div
    class="planner-drawer-root"
    @keydown.esc="$emit('close')">
    <div
      class="planner-drawer-backdrop"
      @click="$emit('close')" />

    <div
      ref="panel"
      class="mp-container planner-drawer"
      :class="`f-${theme}`"
      role="dialog"
      :aria-label="title"
      tabindex="-1">
      <div class="mp-header">
        <div class="mph-title">
          {{ title }}
          <span class="small">{{ countLabel }}</span>
        </div>
        <div class="mph-nav">
          <div
            v-for="tab in tabs"
            :key="tab"
            :class="{ active: activeTab === tab }"
            class="mph-nav-item"
            role="tab"
            tabindex="0"
            :aria-selected="activeTab === tab ? 'true' : 'false'"
            @click="activeTab = tab"
            @keydown.enter="activeTab = tab">
            {{ $t(`data.${kind === 'patents' ? 'patent' : 'doctrine'}_class.${tab}.name`) }}
          </div>
        </div>
        <div class="planner-drawer-tools">
          <button
            v-if="canReset"
            type="button"
            class="default-button is-small"
            @click="$emit('reset')">
            {{ $t('page.system_planner.drawer_reset') }}
          </button>
          <button
            type="button"
            class="default-button is-small"
            :disabled="selected.length === 0"
            @click="$emit('set', [])">
            {{ $t('page.system_planner.drawer_clear') }}
          </button>
        </div>
        <div
          class="mph-close-button"
          role="button"
          tabindex="0"
          :aria-label="$t('page.system_planner.close')"
          @click="$emit('close')"
          @keydown.enter="$emit('close')"></div>
      </div>

      <v-scrollbar
        class="mp-scrollbar"
        :settings="scrollbarSettings">
        <div class="mp-content planner-drawer-content">
          <div class="mpc-header">
            <div class="info">
              {{ summaryLabel }}
              <strong>{{ summaryValue }}</strong>
            </div>
            <p class="planner-drawer-note">{{ note }}</p>
          </div>

          <!-- phones: a plain list, the tree needs a wide screen -->
          <div
            v-if="isMobileView"
            class="planner-drawer-list">
            <button
              v-for="node in nodes"
              :key="node.key"
              type="button"
              class="planner-drawer-list-item"
              :class="node.status"
              :aria-pressed="isOn(node.key) ? 'true' : 'false'"
              @click="toggle(node)">
              <svgicon
                class="planner-drawer-list-icon"
                :name="`${iconPrefix}/${node.key}`" />
              <span>{{ $t(`data.${dataKey}.${node.key}.name`) }}</span>
              <svgicon
                v-if="isOn(node.key)"
                class="planner-drawer-list-check"
                name="check" />
            </button>
          </div>

          <div
            v-else-if="grid"
            class="mpc-tree">
            <div
              class="tree-column"
              v-for="(col, i) in grid"
              :key="`${activeTab}-col-${i}`">
              <div
                class="tree-row"
                v-for="(row, j) in col"
                :key="`row-${j}`">
                <div
                  v-if="row"
                  class="tree-node"
                  :class="[row.status, { 'is-detailed': detailKey === row.key }]"
                  @mouseenter="hoverCardShow(row.key)"
                  @mouseleave="hoverCardClearTimers()">
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
                    role="button"
                    tabindex="0"
                    :aria-pressed="isOn(row.key) ? 'true' : 'false'"
                    :aria-label="$t(`data.${dataKey}.${row.key}.name`)"
                    @click="toggle(row)"
                    @keydown.enter.prevent="toggle(row)"
                    @focus="detailKey = row.key">
                    <svgicon
                      class="main-icon"
                      :name="`${iconPrefix}/${row.key}`" />
                    <svgicon
                      v-if="row.status === 'locked'"
                      class="toast-icon"
                      name="unlock" />
                    <svgicon
                      v-if="row.status === 'chosen'"
                      class="toast-icon colored"
                      name="bookmark" />
                  </div>
                  <div
                    class="tree-node-label"
                    :class="{ shifted: [1, 3].includes(row.children.length) }">
                    {{ $t(`data.${dataKey}.${row.key}.name`) }}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </v-scrollbar>

      <div
        v-if="!isMobileView && detailNode"
        class="mpc-patent-dock planner-drawer-dock">
        <patent-card
          v-if="kind === 'patents'"
          :key="`dock-${detailNode.key}`"
          child
          :patent="detailNode"
          :theme="theme" />
        <doctrine-card
          v-else
          :key="`dock-${detailNode.key}`"
          child
          :doctrine="detailNode"
          :theme="theme" />
        <button
          type="button"
          class="default-button planner-drawer-dock-button"
          @click="toggle(detailNode)">
          {{ dockAction }}
        </button>
      </div>
    </div>
  </div>
</template>

<script>
import Tree from '@/utils/tree';
import viewport from '@/utils/viewport';
import { HORIZONTAL_SCROLL_SETTINGS, BOTH_AXES_SCROLL_SETTINGS } from '@/utils/scrollbar';
import HoverCardMixin from '@/game/mixins/HoverCardMixin';
import PatentCard from '@/game/components/card/PatentCard.vue';
import DoctrineCard from '@/game/components/card/DoctrineCard.vue';

export default {
  name: 'planner-tree-drawer',
  mixins: [HoverCardMixin],
  props: {
    kind: { type: String, required: true }, // 'patents' | 'lexes'
    data: { type: Object, required: true },
    // owned patents, or active lexes
    selected: { type: Array, required: true },
    // lexes: the imported owned set (shown like in-game "purchased")
    owned: { type: Array, default: null },
    lexSlots: { type: Number, default: null },
    // patents: whether buildings are currently limited to them
    limiting: { type: Boolean, default: false },
    canReset: { type: Boolean, default: false },
    theme: { type: String, default: 'none' },
  },
  data() {
    return {
      activeTab: null,
      detailKey: null,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    scrollbarSettings() { return this.isMobileView ? BOTH_AXES_SCROLL_SETTINGS : HORIZONTAL_SCROLL_SETTINGS; },
    dataKey() { return this.kind === 'patents' ? 'patent' : 'doctrine'; },
    iconPrefix() { return this.dataKey; },
    list() { return this.data[this.dataKey]; },
    tabs() {
      return Array.from(new Set(this.list.map((d) => d.class))).filter((tab) => tab !== 'root');
    },
    title() { return this.$t(`page.system_planner.drawer_${this.kind}`); },
    countLabel() {
      return this.kind === 'patents'
        ? `${this.selected.length}/${this.list.length}`
        : this.$t('page.system_planner.lexes_active_count', { n: this.selected.length });
    },
    summaryLabel() {
      return this.kind === 'patents'
        ? this.$t('page.system_planner.patents_owned')
        : this.$t('page.system_planner.lexes_active');
    },
    summaryValue() {
      if (this.kind === 'patents') return this.selected.length;
      return this.lexSlots === null ? this.selected.length : `${this.selected.length}/${this.lexSlots}`;
    },
    note() {
      if (this.kind === 'lexes') return this.$t('page.system_planner.lexes_note');
      return this.limiting
        ? this.$t('page.system_planner.patents_note_on')
        : this.$t('page.system_planner.patents_note_off');
    },
    statusOf() {
      const on = new Set(this.selected);
      const owned = new Set(this.owned || []);
      return (item) => {
        if (this.kind === 'lexes') {
          if (on.has(item.key)) return 'chosen';
          return owned.has(item.key) ? 'purchased' : 'available';
        }
        if (on.has(item.key)) return 'purchased';
        return item.class === 'root' || on.has(item.ancestor) ? 'available' : 'locked';
      };
    },
    nodes() {
      return this.list
        .filter((item) => ['root', this.activeTab].includes(item.class))
        .map((item) => ({ ...item, status: this.statusOf(item) }));
    },
    grid() {
      const [root] = Tree.fromList(this.nodes);
      return root ? Tree.trimGrid(Tree.toGrid(root)) : null;
    },
    detailNode() {
      return this.nodes.find((n) => n.key === this.detailKey) || null;
    },
    dockAction() {
      const on = this.isOn(this.detailNode.key);
      if (this.kind === 'lexes') {
        return on ? this.$t('page.system_planner.lex_deactivate') : this.$t('page.system_planner.lex_activate');
      }
      return on ? this.$t('page.system_planner.patent_remove') : this.$t('page.system_planner.patent_add');
    },
  },
  watch: {
    activeTab() {
      this.hoverCardClearTimers();
      const first = this.nodes.find((n) => n.class !== 'root') || this.nodes[0];
      this.detailKey = first ? first.key : null;
    },
  },
  mounted() {
    [this.activeTab] = this.tabs;
    this.$nextTick(() => this.$refs.panel && this.$refs.panel.focus());
  },
  methods: {
    isOn(key) { return this.selected.includes(key); },
    toggle(node) {
      this.detailKey = node.key;
      this.$emit('toggle', node.key);
    },
    // the dock is sticky: a card only ever gets replaced by dwelling on
    // another node (see PatentMiniPanel)
    hoverCardApply(key) {
      if (key !== null) this.detailKey = key;
    },
    hoverCardVisible() {
      return this.detailKey !== null;
    },
  },
  components: {
    PatentCard,
    DoctrineCard,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-drawer-root {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  z-index: 350;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
}

.planner-drawer-backdrop {
  flex: 1 1 auto;
  background: rgba(0, 0, 0, .35);
}

.planner-drawer {
  flex: 0 0 auto;
  outline: none;
}

.planner-drawer-content {
  height: min(500px, calc(100vh - 160px));
}

.planner-drawer-tools {
  display: flex;
  gap: 8px;
  margin-left: auto;
  margin-right: 70px;
}

.planner-drawer-note {
  padding: 0 20px 0 70px;
  font-size: 1.2rem;
  line-height: 1.5;
  opacity: .7;
}

.planner-drawer-dock {
  top: 12px;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  width: 300px;
}

// below the card's cost row, which hangs under its fixed 418px box
.planner-drawer-dock-button {
  margin-top: 16px;
  justify-content: center;
}

// room to scroll the tree's right end out from under the dock
.planner-drawer ::v-deep .mpc-tree {
  padding-right: 340px;
}

.planner-drawer-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 0 10px 20px;
  width: 100%;
}

.planner-drawer-list-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 8px;
  border: solid 1px rgba(255, 255, 255, .08);
  background: rgba(0, 0, 0, .25);
  color: $white;
  font: inherit;
  font-size: 1.3rem;
  text-align: left;

  &.chosen,
  &.purchased {
    border-color: rgba(255, 255, 255, .5);
  }

  &.locked {
    opacity: .6;
  }
}

.planner-drawer-list-icon {
  flex: 0 0 auto;
  width: 28px;
  height: 28px;
}

.planner-drawer-list-check {
  margin-left: auto;
  width: 14px;
  height: 14px;
}

@media screen and (max-width: $mobile-breakpoint) {
  .planner-drawer-content {
    flex-direction: column;
    height: min(62vh, calc(100vh - 180px));
  }

  // the title, tabs and tools don't fit one row on a phone: the header
  // sits on top of the panel and wraps, tabs on their own scrolling row
  // (the root class out-ranks the page's imported mini panel styles)
  .planner-drawer-root .planner-drawer ::v-deep {
    .mp-header {
      position: relative;
      top: 0;
      height: auto;
      flex-wrap: wrap;
    }

    .mph-title {
      flex: 1 1 auto;
      padding: 8px 12px;
      font-size: 1.6rem;
      line-height: 26px;
    }

    .mph-nav {
      order: 3;
      flex: 1 1 100%;
      padding: 6px 10px;
      overflow-x: auto;
      border-right: none;
    }

    .mph-close-button {
      height: 42px;
      width: 42px;
    }

    .mpc-header {
      width: 100%;
      height: auto;
      text-align: left;

      .info {
        width: auto;
        padding: 12px 12px 4px;
      }
    }
  }

  .planner-drawer-tools {
    margin: 0 50px 0 auto;
  }

  .planner-drawer-note {
    padding: 0 12px;
  }
}
</style>
