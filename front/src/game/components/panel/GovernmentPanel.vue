<template>
  <div
    class="panel-container is-left"
    :class="theme"
    @click.self="close">
    <div
      class="panel-navbar"
      role="group"
      :aria-label="$t('a11y.panel_tabs')">
      <button
        type="button"
        v-for="panel in panels"
        v-tooltip.right="$t(`panel.faction.${panel}`)"
        :key="panel"
        :class="{
          'is-active': activePanel === panel,
          'has-alert': panel === 'government' && pendingCount > 0,
        }"
        :aria-label="$t(`panel.faction.${panel}`)"
        :aria-pressed="String(activePanel === panel)"
        @click="activePanel = panel">
      </button>
    </div>

    <government
      v-show="activePanel === 'government'"
      ref="government" />
    <treasury
      v-show="activePanel === 'treasury'"
      ref="treasury" />
    <diplomacy v-show="activePanel === 'diplomacy'" />
  </div>
</template>

<script>
import Diplomacy from '@/game/components/panel/faction/Diplomacy.vue';
import Government from '@/game/components/panel/faction/Government.vue';
import Treasury from '@/game/components/panel/faction/Treasury.vue';

// The faction's government: seats and votes, treasury, diplomacy. Opened
// from the top-centre box (GovernmentStatus) and from the "vote opened"
// lines of the chat.
export default {
  name: 'government-panel',
  data() {
    return {
      activePanel: 'government',
      panels: ['government', 'treasury', 'diplomacy'],
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    pendingCount() { return this.$store.getters['game/pendingBallots'].length; },
  },
  watch: {
    // the treasury tab shows a ledger other members add to: read it
    // again each time the tab comes up
    activePanel(panel) {
      if (panel === 'treasury') this.$refs.treasury.refresh();
    },
  },
  methods: {
    // { tab } opens on that section, { ballotId } on that vote.
    open(data) {
      if (data && this.panels.includes(data.tab)) {
        this.activePanel = data.tab;
      }

      if (data && data.ballotId != null) {
        this.activePanel = 'government';
        this.$refs.government.showBallot(data.ballotId);
      }

      // the drawer stays mounted while closed: reopened on the treasury
      // tab, it would still show the ledger of the last visit
      if (this.activePanel === 'treasury') this.$refs.treasury.refresh();
    },
    close() {
      this.$emit('close');
    },
  },
  components: {
    Diplomacy,
    Government,
    Treasury,
  },
};
</script>
