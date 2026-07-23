<template>
  <div
    v-if="isOpen"
    class="quick-calc"
    :class="`f-${theme}`">
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
  methods: {
    toRow(result) {
      if (!result.ok) {
        return { id: result.id, src: result.src, text: this.calcFormatError(result.error), isError: true };
      }
      const formatted = this.calcFormatResult(result.value);
      return { id: result.id, src: result.src, text: formatted.text, detail: formatted.detail, isError: false };
    },
    onLineAction({ key, id }) {
      if (key === 'pin') this.$store.dispatch('calc/pinLine', id);
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
