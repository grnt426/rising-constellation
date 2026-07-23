<template>
  <div
    v-if="isOpen"
    class="quick-calc calc-suppress"
    :class="`f-${theme}`"
    tabindex="-1"
    @keydown.esc.stop="close">
    <div class="quick-calc-header">
      <span class="quick-calc-title">{{ $t('calc.title') }}</span>
      <button
        v-tooltip="$t('calc.open_financials')"
        class="quick-calc-header-button"
        type="button"
        @click="expand">
        <svgicon name="empire" />
      </button>
      <button
        v-tooltip="$t('calc.close')"
        class="quick-calc-header-button"
        type="button"
        @click="close">
        <svgicon name="close" />
      </button>
    </div>

    <div
      v-if="tailRows.length"
      class="quick-calc-lines">
      <calc-line
        v-for="row in tailRows"
        :key="row.id"
        :row="row"
        :actions="rowActions"
        @action="onLineAction" />
    </div>

    <calc-input
      ref="input"
      show-chips
      @commit="commit"
      @escape="close" />
  </div>
</template>

<script>
// Non-modal floating calculator, toggled by the X hotkey. Shows the tail of
// the shared notepad; everything typed here lands in the same document the
// Empire → Financials tab manages, so "pivot to permanent" is one pin click.
import CalcMixin from '@/game/mixins/CalcMixin';
import CalcInput from '@/game/components/calc/CalcInput.vue';
import CalcLine from '@/game/components/calc/CalcLine.vue';

const TAIL = 3;

export default {
  name: 'quick-calc',
  mixins: [CalcMixin],
  data() {
    return {
      isOpen: false,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    rowActions() {
      return [
        { key: 'pin', icon: 'bookmark', title: this.$t('calc.pin') },
        { key: 'remove', icon: 'close', title: this.$t('calc.remove') },
      ];
    },
    recentIds() {
      return new Set(this.calcRecentLines.map((l) => l.id));
    },
    tailRows() {
      return this.calcDocResults
        .filter((r) => this.recentIds.has(r.id))
        .slice(-TAIL)
        .map((r) => this.toRow(r));
    },
  },
  watch: {
    // Reminder engine: this component is mounted whenever the feature is
    // on (independent of the overlay being open), so it owns the watch.
    // A pinned reminder line (`until` or `afford`) firing means: done &&
    // not yet acked — ack it (persisted, so it won't re-fire on the next
    // login) and pop a box notification. That first evaluation after login
    // is also how targets completed while offline get presented, queued
    // all at once. Falling back below the threshold (resource spent, cost
    // risen) clears the ack, re-arming the reminder.
    calcDocResults(results) {
      if (!this.$store.state.calc.hydrated) return;
      const savedById = new Map(this.calcSavedLines.map((l) => [l.id, l]));
      results.forEach((r) => {
        const line = savedById.get(r.id);
        if (!line || !r.ok) return;
        const state = this.calcReminderState(r.value);
        if (!state) return;
        if (state.done && !line.acked) {
          this.$store.dispatch('calc/ackLine', { id: line.id, acked: true });
          this.$store.commit('game/setNotifications', [{
            type: 'box',
            key: 'calc_reminder',
            data: {
              line_id: line.id,
              src: line.src,
              kind: state.kind,
              resource: state.resource,
              target: state.amount,
            },
          }]);
        } else if (!state.done && line.acked) {
          this.$store.dispatch('calc/ackLine', { id: line.id, acked: false });
        }
      });
    },
  },
  methods: {
    toRow(result) {
      if (!result.ok) {
        return { id: result.id, src: result.src, text: this.calcFormatError(result.error), isError: true };
      }
      const formatted = this.calcFormatResult(result.value);
      const state = this.calcReminderState(result.value);
      return {
        id: result.id,
        src: result.src,
        text: formatted.text,
        detail: formatted.detail,
        isError: false,
        reached: !!(state && state.done),
      };
    },
    onLineAction({ key, id }) {
      if (key === 'pin') {
        const row = this.tailRows.find((r) => r.id === id);
        this.$store.dispatch('calc/pinLine', { id, acked: !!(row && row.reached) });
      }
      if (key === 'remove') this.$store.dispatch('calc/removeRecentLine', id);
    },
    commit(src) {
      this.$store.dispatch('calc/commitLine', src);
    },
    open() {
      this.isOpen = true;
      this.$nextTick(() => { if (this.$refs.input) this.$refs.input.focus(); });
    },
    close() {
      this.isOpen = false;
    },
    toggle() {
      if (this.isOpen) this.close();
      else this.open();
    },
    expand() {
      this.close();
      this.$root.$emit('togglePanel', 'empire', { tab: 'financials' });
    },
  },
  mounted() {
    this.$root.$on('toggleCalc', this.toggle);
    this.$root.$on('closeCalc', this.close);
  },
  beforeDestroy() {
    this.$root.$off('toggleCalc', this.toggle);
    this.$root.$off('closeCalc', this.close);
  },
  components: {
    CalcInput,
    CalcLine,
  },
};
</script>

<style scoped>
.quick-calc {
  outline: none; /* tabindex="-1" container — no focus ring */
  position: fixed;
  top: 64px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 560; /* above side panels (500), below the navbars (600) */
  width: 540px;
  max-width: 92vw;
  padding: 8px 14px 10px;
  background: rgba(8, 10, 16, 0.92);
  border: solid 1px rgba(255, 255, 255, 0.12);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.6);
}

.quick-calc-header {
  display: flex;
  align-items: center;
  gap: 6px;
  padding-bottom: 4px;
}

.quick-calc-title {
  flex: 1;
  color: rgba(255, 255, 255, 0.6);
  font-size: 1.1rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.quick-calc-header-button {
  width: 22px;
  height: 22px;
  padding: 3px;
  background: transparent;
  border: none;
  cursor: pointer;
}

.quick-calc-header-button svg {
  width: 15px;
  height: 15px;
  fill: rgba(255, 255, 255, 0.5);
}

.quick-calc-header-button:hover svg {
  fill: #fff;
}

.quick-calc-lines {
  padding-bottom: 2px;
}
</style>
