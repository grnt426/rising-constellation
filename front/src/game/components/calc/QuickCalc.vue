<template>
  <div
    v-if="isOpen"
    class="quick-calc calc-suppress"
    :class="`f-${theme}`"
    tabindex="-1"
    @keydown.esc.stop="close"
    @click="onSurfaceClick">
    <!-- direct children are keyed: the lines block toggles, and an
         unkeyed diff next to the inputs can recreate them mid-keystroke -->
    <div
      key="header"
      class="quick-calc-header">
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
      key="lines"
      class="quick-calc-lines">
      <calc-line
        v-for="row in tailRows"
        :key="row.id"
        :row="row"
        :actions="rowActions(row)"
        @action="onLineAction" />
    </div>

    <calc-input
      ref="input"
      key="input"
      show-chips
      @commit="commit"
      @escape="close"
      @tab-out="onInputTabOut" />

    <!-- quick targets: "when will I have N <res>" without typing syntax.
         Every node here is always rendered (no v-if next to the inputs);
         an empty result keeps the row height stable. -->
    <div
      key="targets-caption"
      v-tooltip="$t('calc.targets.hint')"
      class="quick-targets-caption">
      {{ $t('calc.targets.caption') }}
      <span class="quick-targets-key">Tab</span>
    </div>
    <div
      key="targets"
      class="quick-targets">
      <div
        v-for="(target, idx) in targets"
        :key="target.res"
        class="quick-target"
        :class="`is-${target.state}`">
        <label
          key="field"
          class="quick-target-field">
          <svgicon
            key="icon"
            class="quick-target-icon"
            :name="`resource/${target.res}`" />
          <input
            :ref="`target-${target.res}`"
            key="box"
            v-model="targetValues[target.res]"
            type="text"
            class="quick-target-input"
            maxlength="24"
            autocomplete="off"
            spellcheck="false"
            :placeholder="target.placeholder"
            :aria-label="$t('calc.targets.aria', { res: $t(`calc.res_short.${target.res}`) })"
            @keydown.enter.prevent="commitTarget(target)"
            @keydown.tab.prevent="onTargetTab($event, idx)"
            @keydown.esc.prevent.stop="onTargetEsc(target)" />
        </label>
        <div
          key="result"
          v-tooltip="target.detail"
          class="quick-target-result">{{ target.text || '\u00a0' }}</div>
      </div>
    </div>
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

// Quick-target boxes: each evaluates `until <amount> <word>` through the
// engine (same number syntax: 80k, 1.5M, +5000) — no ETA math of its own.
const TARGETS = [
  { res: 'credit', word: 'credit', placeholder: '500k' },
  { res: 'technology', word: 'tech', placeholder: '80k' },
  { res: 'ideology', word: 'ideo', placeholder: '150k' },
];
const TARGET_AMOUNT = /^\+?\d+(?:\.\d+)?[kKmM]?$/;

export default {
  name: 'quick-calc',
  mixins: [CalcMixin],
  data() {
    return {
      isOpen: false,
      targetValues: { credit: '', technology: '', ideology: '' },
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    recentIds() {
      return new Set(this.calcRecentLines.map((l) => l.id));
    },
    // [{ res, word, placeholder, src, state, text, detail }]
    // state: empty | invalid | pending | reached | never
    targets() {
      const f = this.calcFormatters();
      return TARGETS.map((t) => {
        const raw = (this.targetValues[t.res] || '').replace(/\s+/g, '');
        if (!raw || !this.isOpen) return { ...t, state: 'empty', text: '', detail: null };
        const src = `until ${raw} ${t.word}`;
        const preview = TARGET_AMOUNT.test(raw) ? this.calcPreview(src) : null;
        const value = preview && preview.ok ? preview.value : null;
        if (!value || value.k !== 'eta') {
          return { ...t, state: 'invalid', text: this.$t('calc.targets.invalid'), detail: null };
        }
        const missing = value.need != null
          ? f.t('calc.result.missing', { amount: `${f.int(value.need)} ${f.t(`calc.res_short.${t.res}`)}` })
          : null;
        if (value.reached) {
          return { ...t, src, state: 'reached', text: f.t('calc.result.reached_now'), detail: null };
        }
        if (value.never) {
          return { ...t, src, state: 'never', text: f.t('calc.targets.never'), detail: missing };
        }
        return {
          ...t, src, state: 'pending', text: `${f.dur(value.s)} · ${f.time(value.when)}`, detail: missing,
        };
      });
    },
    // last few committed lines regardless of which list they routed to
    // (reminders auto-save, calcs go to recent — the quick view shows
    // "what I just typed" either way)
    tailRows() {
      return this.calcDocResults
        .slice()
        .sort((a, b) => (a.ts || 0) - (b.ts || 0) || a.id - b.id)
        .slice(-TAIL)
        .map((r) => this.toRow(r));
    },
  },
  watch: {
    // Reminder engine: this component is always mounted in a game
    // (independent of the overlay being open), so it owns the watch.
    // A pinned reminder line (`until` or `afford`) firing means: done &&
    // not yet acked — ack it (persisted, so it won't re-fire on the next
    // login) and pop a box notification. That first evaluation after login
    // is also how targets completed while offline get presented, queued
    // all at once. Falling back below the threshold (resource spent, cost
    // risen) clears the ack, re-arming the reminder.
    calcDocResults(results) {
      if (!this.$store.state.calc.hydrated) return;
      // reminders fire wherever they live — including legacy blobs that
      // still hold reminder lines in the scratch list
      const lineById = new Map(this.calcDocLines.map((l) => [l.id, l]));
      results.forEach((r) => {
        const line = lineById.get(r.id);
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
              label: state.label,
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
    rowActions(row) {
      const actions = [];
      // pin only makes sense for scratch calcs; reminders self-save
      if (this.recentIds.has(row.id)) {
        actions.push({ key: 'pin', icon: 'bookmark', title: this.$t('calc.pin') });
      }
      actions.push({ key: 'remove', icon: 'close', title: this.$t('calc.remove') });
      return actions;
    },
    onLineAction({ key, id }) {
      if (key === 'pin') this.$store.dispatch('calc/pinLine', id);
      if (key === 'remove') this.$store.dispatch('calc/removeLine', id);
      this.focusInput();
    },
    focusInput() {
      if (this.$refs.input) this.$refs.input.focus();
    },
    // stray clicks inside the overlay park focus back in the input so
    // the next keystroke is calculator text, not a game hotkey (a click
    // on a quick-target label forwards to its own box natively)
    onSurfaceClick(event) {
      if (!event.target.closest('input, button, label')) this.focusInput();
    },
    focusTarget(idx) {
      const refs = this.$refs[`target-${TARGETS[idx].res}`];
      const el = Array.isArray(refs) ? refs[0] : refs;
      if (el) el.focus();
    },
    // The Tab cycle stays inside the overlay: input -> credit -> tech ->
    // ideo -> input (Shift+Tab reverses). Letting Tab escape would park
    // focus outside .calc-suppress and leak keystrokes to game hotkeys.
    onInputTabOut({ backward }) {
      this.focusTarget(backward ? TARGETS.length - 1 : 0);
    },
    onTargetTab(event, idx) {
      const next = idx + (event.shiftKey ? -1 : 1);
      if (next < 0 || next >= TARGETS.length) this.focusInput();
      else this.focusTarget(next);
    },
    // Esc clears a filled box first; Esc in an empty box closes.
    onTargetEsc(target) {
      if (this.targetValues[target.res]) this.targetValues[target.res] = '';
      else this.close();
    },
    // Enter saves the box as a regular `until` line, so it becomes a
    // reminder like any typed one.
    commitTarget(target) {
      const current = this.targets.find((t) => t.res === target.res);
      if (!current || !current.src) return;
      this.commit(current.src);
      this.targetValues[target.res] = '';
    },
    commit(src) {
      this.$store.dispatch('calc/commitLine', this.calcLinePayload(src));
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

.quick-targets-caption {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 0 4px;
  color: rgba(255, 255, 255, 0.45);
  font-size: 1.05rem;
}

.quick-targets-key {
  padding: 0 4px;
  border: 1px solid rgba(255, 255, 255, 0.25);
  border-radius: 2px;
  font-size: 0.95rem;
  line-height: 1.4;
}

.quick-targets {
  display: flex;
  gap: 8px;
}

.quick-target {
  flex: 1;
  min-width: 0;
}

.quick-target-field {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 3px 6px;
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.15);
  cursor: text;
}

.quick-target-field:focus-within {
  border-color: rgba(255, 255, 255, 0.45);
  background: rgba(255, 255, 255, 0.08);
}

.quick-target-icon {
  width: 14px;
  height: 14px;
  flex-shrink: 0;
  fill: rgba(255, 255, 255, 0.7);
}

.quick-target-input {
  flex: 1;
  min-width: 0;
  background: transparent;
  border: none;
  outline: none;
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.2rem;
}

.quick-target-input::placeholder {
  color: rgba(255, 255, 255, 0.25);
}

.quick-target-result {
  padding: 3px 1px 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.05rem;
  font-variant-numeric: tabular-nums;
}

.quick-target.is-reached .quick-target-result {
  color: rgba(150, 220, 150, 0.9);
}

.quick-target.is-never .quick-target-result,
.quick-target.is-invalid .quick-target-result {
  color: rgba(255, 255, 255, 0.45);
}
</style>
