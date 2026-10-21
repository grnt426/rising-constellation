<template>
  <div ref="container">
    <!-- contextual actions of the selected character, inner ring, upper-right -->
    <div
      class="system-actions"
      v-if="actions.length > 0">
      <div
        v-for="(action, i) in actions"
        :key="action.icon"
        class="orbit-item"
        :style="orbitStyle(contextualAngles[i], 'inner')">
        <div
          v-if="action.status === 'available'"
          class="round-icon is-active has-hover"
          @click="doAction(action.icon)"
          @mouseover="hoveredAction = action.name"
          @mouseleave="hoveredAction = null">
          <svgicon :name="`action/${action.icon}_alt`" />
        </div>
        <div
          v-if="action.status === 'unavailable'"
          v-tooltip="{ content: action.reasons, html: true }"
          class="round-icon is-disabled">
          <svgicon :name="`action/${action.icon}_alt`" />
        </div>
        <div
          v-if="action.overview && hoveredAction === action.name"
          class="toolbox-actions">
          <action-overview :data="action.overview" />
        </div>
        <div class="action-label">
          <div class="name">{{ $t(`galaxy.system.actions.${action.name}`) }}</div>
        </div>
      </div>
    </div>

    <div
      ref="fan"
      class="system-actions"
      :class="{ 'is-unfurled': openedCluster !== null }">
      <!-- formation arcs: one band along the inner ring per own armada
           with 2+ members present. viewBox 0 0 100 100 with
           preserveAspectRatio none matches orbitStyle's percentage
           space exactly, so the band hugs the (elliptical) ring on any
           container shape. -->
      <svg
        v-if="armadaArcs.length > 0"
        class="armada-links"
        viewBox="0 0 100 100"
        preserveAspectRatio="none">
        <path
          v-for="arc in armadaArcs"
          :key="arc.key"
          class="armada-band-shape"
          :d="arc.d" />
      </svg>

      <!-- deploy slot + own agents, inner ring, lower-left -->
      <div
        v-if="isOwnSystem"
        class="orbit-item"
        :style="orbitStyle(innerAngles[0], 'inner')">
        <div
          v-if="tutorialStep === 14"
          class="tutorial-pointer is-right">
        </div>
        <div
          @click="prepareAgentAssignment()"
          class="round-icon has-hover">
        </div>
        <div
          @click="prepareAgentAssignment()"
          class="action-label">
          <div class="name">{{ $t('galaxy.system.actions.deploy') }}</div>
        </div>
      </div>

      <div
        v-for="(entry, i) in ownEntries"
        :key="entry.character.id"
        class="orbit-item"
        :style="orbitStyle(innerAngles[(isOwnSystem ? 1 : 0) + i], 'inner')"
        @mouseenter="enterSlot(`own-${entry.character.id}`)">
        <agent-badge
          :character="entry.character"
          :actions="entry.actions"
          :theme="getTheme(entry.character.owner.faction)"
          :system="system"
          small
          @select="clickCharacter" />
      </div>

      <!-- foreign agents and squadrons, outer fan -->
      <div
        v-for="slot in outerSlots"
        :key="slot.key"
        class="orbit-item"
        :class="{ 'is-raised': openedCluster === slot.key }"
        :style="orbitStyle(slot.angle, 'outer')"
        @mouseenter="enterSlot(slot.key)">
        <agent-badge
          v-if="slot.kind === 'single'"
          :character="slot.entry.character"
          :actions="slot.entry.actions"
          :theme="getTheme(slot.entry.character.owner.faction)"
          :system="system"
          :isBesieger="slot.isBesieger"
          :flipped="slot.angle < -30"
          @select="clickCharacter" />

        <div
          v-else
          :ref="`cluster-${slot.key}`"
          class="cluster"
          :class="`force-${slot.theme}`"
          @mouseenter="enterCluster(slot.key)">
          <!-- the open squadron's backdrop, first so it sits under the
               stack and every member -->
          <div
            v-if="openedCluster === slot.key && unfurl"
            ref="tray"
            class="cluster-tray"
            :style="trayStyle"></div>
          <!-- a collapsed stack containing an armada wears the capsule -->
          <div
            v-if="slot.hasArmada"
            class="armada-capsule"></div>
          <div class="cluster-ghost is-far"></div>
          <div class="cluster-ghost is-near"></div>
          <div
            class="round-icon is-active has-hover"
            @click="clickCluster(slot.key)">
            <svgicon :name="`agent/${slot.lead.character.type}`" />
            <span class="number">
              {{ slot.lead.character.level }}
            </span>
          </div>
          <div
            class="cluster-count"
            @click="clickCluster(slot.key)">
            ×{{ slot.entries.length }} · {{ slot.owner.name }}
          </div>
          <!-- members unfurl into a grid of rows toward the system
               center (utils/agent-fan.js) -->
          <div
            v-if="openedCluster === slot.key && unfurl"
            class="cluster-fan">
            <!-- unfurled armada members get the same band, drawn in
                 pixel space around their column -->
            <svg
              v-if="unfurl.bands.length > 0"
              class="armada-links-px">
              <path
                v-for="band in unfurl.bands"
                :key="band.key"
                class="armada-band-shape"
                :d="band.d" />
            </svg>
            <div
              v-for="(entry, mi) in slot.entries"
              :key="entry.character.id"
              class="fan-member"
              :style="{ left: `${unfurl.cells[mi].x}px`, top: `${unfurl.cells[mi].y}px` }">
              <agent-badge
                :character="entry.character"
                :actions="entry.actions"
                :theme="getTheme(entry.character.owner.faction)"
                :system="system"
                :flipped="unfurl.cells[mi].flip"
                :previewRight="unfurl.cells[mi].previewRight"
                @select="clickCharacter" />
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="system.siege !== null"
      class="siege has-hover"
      v-tooltip="$t(`data.character_action_status.${system.siege.type}.name`)"
      @click="openBesieger">
      <svgicon :name="`action/${system.siege.type}_alt`" />
      <counter
        class="counter"
        :current="system.siege.days.value"
        :receivedAt="system.receivedAt" />
      <circle-progress-value
        :current="system.siege.days.value"
        :total="system.siege.duration"
        :increase="system.siege.days.change"
        :size="98"
        :width="4"
        :theme="systemTheme" />
    </div>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import SystemOrdersMixin from '@/game/mixins/SystemOrdersMixin';
import { canReportAgent, reportAgent } from '@/game/components/chat/reportSighting';
import armadaUtil from '@/utils/armada';
import { unfurlLayout, unfurlBandPaths } from '@/utils/agent-fan';

import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';
import AgentBadge from '@/game/components/galaxy/system/AgentBadge.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'system-actions',
  mixins: [SystemOrdersMixin],
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
      openedCluster: null,
      clusterPinned: false,
      docListenersAttached: false,
      // where the open squadron's stack sits in the visible part of the
      // view and where its grid may go, measured when it opens:
      // { origin, areas } in px (see measureFan)
      fanView: null,
    };
  },
  computed: {
    tutorialStep() { return this.$store.state.game.tutorialStep; },
    besiegerId() {
      return this.system.siege ? this.system.siege.besieger_id : null;
    },
    besiegerEntry() {
      return this.systemCharacters
        .find((entry) => entry.character.id === this.besiegerId) || null;
    },
    // own agents (minus a besieging one, which stays on the outer fan);
    // armada members are grouped adjacent so their ring positions form
    // one contiguous block under the formation arc
    ownEntries() {
      const entries = this.systemCharacters.filter((entry) => entry.character.owner.id === this.player.id
        && entry.character.id !== this.besiegerId);

      return armadaUtil.groupAdjacent(entries);
    },
    foreignEntries() {
      return this.systemCharacters.filter((entry) => entry.character.owner.id !== this.player.id
        && entry.character.id !== this.besiegerId);
    },
    // deploy slot + own agents on the inner ring, lower-left arc
    innerAngles() {
      const count = this.ownEntries.length + (this.isOwnSystem ? 1 : 0);
      const step = Math.min(20, 124 / Math.max(count - 1, 1));
      return Array.from({ length: count }, (_, i) => 134 + i * step);
    },
    // one arc per own armada with 2+ members on the inner ring, spanning
    // the (adjacent, thanks to ownEntries' grouping) member angles with
    // a little padding — the proposal's "shared arced oval". A besieging
    // member sits on the outer fan and is excluded; its badge carries
    // the membership signal there.
    armadaArcs() {
      const offset = this.isOwnSystem ? 1 : 0;
      // tight horizontal extension: barely past the end icons — the
      // rounded end caps supply the soft overhang
      const pad = 4;
      const r = 21;

      return armadaUtil.bands(this.ownEntries).map((band) => {
        const angles = band.indexes.map((i) => this.innerAngles[offset + i]);

        return {
          key: `armada-${band.groupId}`,
          d: armadaUtil.capsulePath(
            50, 50, r + 2.7, r - 2.7,
            Math.min(...angles) - pad,
            Math.max(...angles) + pad,
          ),
        };
      });
    },
    // selected-character actions on the inner ring, upper-right arc
    contextualAngles() {
      const n = this.actions.length;
      const step = 13;
      return this.actions.map((_, i) => -46 - (((n - 1) / 2) * step) + (i * step));
    },
    // foreign agents: one slot per owner (cluster when an owner has several),
    // besieger pinned on top, faction mates at the bottom end
    outerSlots() {
      const groups = [];
      const byOwner = {};

      this.foreignEntries.forEach((entry) => {
        const ownerId = entry.character.owner.id;
        if (!byOwner[ownerId]) {
          byOwner[ownerId] = { owner: entry.character.owner, entries: [] };
          groups.push(byOwner[ownerId]);
        }
        byOwner[ownerId].entries.push(entry);
      });

      const slots = groups.map((group) => {
        // rank/level order, then armada members pulled adjacent so the
        // unfurl can band them
        const entries = armadaUtil.groupAdjacent(group.entries.slice()
          .sort((a, b) => this.characterRank(a.character) - this.characterRank(b.character)
            || b.character.level - a.character.level));
        const lead = entries[0];

        return {
          key: `owner-${group.owner.id}`,
          kind: entries.length > 1 ? 'cluster' : 'single',
          entry: lead,
          entries,
          lead,
          owner: group.owner,
          theme: this.getTheme(group.owner.faction),
          isBesieger: false,
          hasArmada: entries.some((e) => armadaUtil.groupId(e.character) != null),
          rank: this.characterRank(lead.character),
          maxLevel: lead.character.level,
        };
      });

      slots.sort((a, b) => a.rank - b.rank
        || b.maxLevel - a.maxLevel
        || a.owner.name.localeCompare(b.owner.name));

      if (this.besiegerEntry) {
        slots.unshift({
          key: `besieger-${this.besiegerEntry.character.id}`,
          kind: 'single',
          entry: this.besiegerEntry,
          entries: [this.besiegerEntry],
          lead: this.besiegerEntry,
          owner: this.besiegerEntry.character.owner,
          theme: this.getTheme(this.besiegerEntry.character.owner.faction),
          isBesieger: true,
          rank: -1,
          maxLevel: this.besiegerEntry.character.level,
        });
      }

      const n = slots.length;
      const step = n > 1 ? Math.min(13.5, Math.max(9, 116 / (n - 1))) : 0;
      const start = -((n - 1) / 2) * step;
      slots.forEach((slot, i) => {
        slot.angle = start + (i * step);
      });
      if (n > 0 && slots[0].isBesieger) {
        slots[0].angle -= 6;
      }

      return slots;
    },
    // the open squadron's grid: member cells, the tray behind them and
    // the formation bands, all relative to the stack
    unfurl() {
      const slot = this.outerSlots.find((s) => s.key === this.openedCluster);
      if (!slot || slot.kind !== 'cluster') {
        return null;
      }

      const members = slot.entries.map((entry) => ({
        actions: entry.actions.length,
        group: armadaUtil.groupId(entry.character),
      }));
      const { cells, tray } = unfurlLayout(members, {
        angle: slot.angle,
        origin: this.fanView ? this.fanView.origin : null,
        areas: this.fanView ? this.fanView.areas : [],
      });

      return {
        cells,
        tray,
        bands: unfurlBandPaths(armadaUtil.bands(slot.entries), cells),
      };
    },
    trayStyle() {
      const { tray } = this.unfurl;
      return {
        left: `${tray.left}px`,
        top: `${tray.top}px`,
        width: `${tray.width}px`,
        height: `${tray.height}px`,
      };
    },
  },
  watch: {
    'system.id': function systemChanged() {
      this.closeCluster();
    },
  },
  methods: {
    characterRank(character) {
      if (character.owner.faction === this.player.faction) {
        return 3;
      }
      return character.type === 'admiral' ? 1 : 2;
    },
    // percentages resolve against .system-content (left → width, top →
    // height), so the ring scales with the view container on any screen
    orbitStyle(angle, ring) {
      const rad = (angle * Math.PI) / 180;
      const radius = ring === 'inner' ? 21 : 40;
      return {
        left: `calc(50% + ${(Math.cos(rad) * radius).toFixed(2)}%)`,
        top: `calc(50% + ${(Math.sin(rad) * radius).toFixed(2)}%)`,
      };
    },
    // Where the grid may go, in px from the on-screen part of the view:
    // preferably clear of the two panels that paint over the system view
    // (the system's info on the left, the selected agent at the bottom
    // right), else anywhere in the view. The stack's element is a 0x0
    // anchor on its slot point.
    measureFan(key) {
      const refs = this.$refs[`cluster-${key}`];
      const root = Array.isArray(refs) ? refs[0] : refs;
      const view = this.$refs.fan;
      if (!root || !view) {
        this.fanView = null;
        return;
      }

      const v = view.getBoundingClientRect();
      const left = Math.max(v.left, 0);
      const top = Math.max(v.top, 0);
      const whole = {
        left: 0,
        top: 0,
        right: Math.min(v.right, window.innerWidth) - left,
        bottom: Math.min(v.bottom, window.innerHeight) - top,
      };
      const r = root.getBoundingClientRect();
      const free = { ...whole };

      const info = document.querySelector('.system-info');
      if (info) {
        const p = info.getBoundingClientRect();
        // its tab strip hangs 26px past its right edge
        const right = Math.max(p.right, ...[...info.querySelectorAll('.system-content-menu')]
          .map((menu) => menu.getBoundingClientRect().right));
        if (p.width > 0 && right > left && p.left < r.left) {
          free.left = Math.max(free.left, right - left);
        }
      }
      const selection = document.querySelector('.selection-view-container');
      if (selection) {
        const p = selection.getBoundingClientRect();
        if (p.width > 0 && p.left < r.left && p.top > r.top + 25) {
          free.bottom = Math.min(free.bottom, p.top - top);
        }
      }

      this.fanView = {
        origin: { x: r.left - left, y: r.top - top },
        areas: [free, whole],
      };
    },
    onResize() {
      if (this.openedCluster) {
        this.measureFan(this.openedCluster);
      }
    },
    // Hovering any top-level agent slot dismisses another slot's open fan
    // (even a pinned one — moving to a different agent is a deliberate shift
    // of attention). Members of the open fan and its tray sit inside their
    // cluster's own slot, so pointing at them never triggers this; and the
    // tray takes the hover over any neighbouring badge it covers, so the
    // fan doesn't close underneath it.
    enterSlot(key) {
      if (this.openedCluster && this.openedCluster !== key) {
        this.closeCluster();
      }
    },
    enterCluster(key) {
      this.enterSlot(key);
      this.openCluster(key);
    },
    clickCluster(key) {
      if (this.openedCluster === key && this.clusterPinned) {
        this.closeCluster();
        return;
      }
      this.openCluster(key);
      this.clusterPinned = true;
    },
    openCluster(key) {
      if (this.openedCluster !== key) {
        this.measureFan(key);
      }
      this.openedCluster = key;
      this.attachDocListeners();
    },
    closeCluster() {
      this.openedCluster = null;
      this.clusterPinned = false;
      this.detachDocListeners();
    },
    clusterRoot() {
      const refs = this.$refs[`cluster-${this.openedCluster}`];
      return Array.isArray(refs) ? refs[0] : refs;
    },
    // The open squadron closes once the pointer strays past its tray and
    // its stack (a pinned one tolerates a wider margin).
    onDocMove(event) {
      if (!this.openedCluster) {
        return;
      }
      const root = this.clusterRoot();
      if (!root || !this.unfurl) {
        this.closeCluster();
        return;
      }
      const refs = this.$refs.tray;
      const tray = Array.isArray(refs) ? refs[0] : refs;
      const stack = root.querySelector(':scope > .round-icon');
      if (!tray || !stack) {
        // opened on this very move: the tray renders on the next tick
        return;
      }
      const t = tray.getBoundingClientRect();
      const s = stack.getBoundingClientRect();
      const buffer = this.clusterPinned ? 120 : 40;

      if (event.clientX < Math.min(t.left, s.left) - buffer
        || event.clientX > Math.max(t.right, s.right) + buffer
        || event.clientY < Math.min(t.top, s.top) - buffer
        || event.clientY > Math.max(t.bottom, s.bottom) + buffer) {
        this.closeCluster();
      }
    },
    onDocClick(event) {
      if (!this.openedCluster || !this.clusterPinned) {
        return;
      }
      const root = this.clusterRoot();
      if (!root || !root.contains(event.target)) {
        this.closeCluster();
      }
    },
    attachDocListeners() {
      if (this.docListenersAttached) {
        return;
      }
      document.addEventListener('mousemove', this.onDocMove);
      document.addEventListener('click', this.onDocClick);
      this.docListenersAttached = true;
    },
    detachDocListeners() {
      if (!this.docListenersAttached) {
        return;
      }
      document.removeEventListener('mousemove', this.onDocMove);
      document.removeEventListener('click', this.onDocClick);
      this.docListenersAttached = false;
    },
    // Shift+click on another faction's agent reports it in the faction's
    // Spotted chat channel instead of opening its card.
    clickCharacter(character, event) {
      if (event && event.shiftKey && canReportAgent(this, character)) {
        reportAgent(this, this.system.id, character.id);
        return;
      }

      if (this.characters.find((c) => c.id === character.id)) {
        if (this.selectedCharacter && this.selectedCharacter.id === character.id) {
          this.$store.dispatch('game/unselectCharacter');
        } else {
          this.$store.dispatch('game/selectCharacter', { vm: this, id: character.id });
        }
      } else {
        this.$store.dispatch('game/openCharacter', { vm: this, id: character.id });
      }
    },
    openBesieger() {
      if (this.besiegerId) {
        this.$store.dispatch('game/openCharacter', { vm: this, id: this.besiegerId });
      }
    },
    doAction(action) {
      this.hoveredAction = null;
      this.orderOnSystem(action);
    },
    prepareAgentAssignment() {
      const mode = 'on_board';
      const systemId = this.system.id;

      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', { systemId, mode });
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { css: { opacity: 0 } })
      .to(this.$refs.container, { css: { opacity: 1 }, ease: Expo.linear, duration: 1 }, 0);

    window.addEventListener('resize', this.onResize);
  },
  beforeDestroy() {
    this.detachDocListeners();
    window.removeEventListener('resize', this.onResize);
  },
  components: {
    ActionOverview,
    AgentBadge,
    CircleProgressValue,
    Counter,
  },
};
</script>
