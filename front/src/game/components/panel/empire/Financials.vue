<template>
  <div
    class="panel-content is-small calc-suppress"
    tabindex="-1"
    @click="onSurfaceClick">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.empire.financials_title') }}
      </h1>

      <!-- live rates strip -->
      <section class="fin-rates">
        <div
          v-for="entry in rateEntries"
          :key="entry.res"
          class="fin-rate">
          <svgicon
            class="fin-rate-icon"
            :name="`resource/${entry.res}`" />
          <div class="fin-rate-values">
            <span class="fin-rate-value">{{ entry.value }}</span>
            <span class="fin-rate-sub">{{ entry.perHour }} · {{ entry.perDay }}</span>
          </div>
        </div>
      </section>

      <!-- notepad input -->
      <section class="fin-section">
        <calc-input
          ref="input"
          show-chips
          @commit="commit"
          @escape="closeAndRelease" />
      </section>

      <!-- reminders: lines with a completion moment — they notify -->
      <section class="fin-section">
        <h2 class="fin-subtitle">{{ $t('calc.reminders_title') }}</h2>
        <template v-if="reminderRows.length">
          <calc-line
            v-for="row in reminderRows"
            :key="row.id"
            :row="row"
            :actions="removeOnlyActions"
            @action="onRemoveAction" />
        </template>
        <p
          v-else
          class="fin-empty">{{ $t('calc.reminders_empty') }}</p>
      </section>

      <!-- projections & pinned calculations: live math, never notifies -->
      <section class="fin-section">
        <h2 class="fin-subtitle">{{ $t('calc.projections_title') }}</h2>
        <template v-if="projectionRows.length">
          <calc-line
            v-for="row in projectionRows"
            :key="row.id"
            :row="row"
            :actions="removeOnlyActions"
            @action="onRemoveAction" />
        </template>
        <p
          v-else
          class="fin-empty">{{ $t('calc.projections_empty') }}</p>
      </section>

      <!-- scratch history -->
      <section class="fin-section">
        <div class="fin-subtitle-row">
          <h2 class="fin-subtitle">{{ $t('calc.recent_title') }}</h2>
          <button
            v-if="recentRows.length"
            class="fin-clear-button"
            type="button"
            @click="clearRecent">
            {{ $t('calc.clear_recent') }}
          </button>
        </div>
        <template v-if="recentRows.length">
          <calc-line
            v-for="row in recentRows"
            :key="row.id"
            :row="row"
            :actions="recentActions"
            @action="onRecentAction" />
        </template>
        <p
          v-else
          class="fin-empty">{{ $t('calc.recent_empty') }}</p>
      </section>

      <p class="fin-hint">{{ $t('calc.help_hint') }}</p>
    </v-scrollbar>
  </div>
</template>

<script>
// Empire → Financials: the full notepad view over the same shared document
// the QuickCalc overlay appends to. Pinned lines live at the top of the doc
// (their names are visible to scratch lines); recent is the capped history.
import CalcMixin from '@/game/mixins/CalcMixin';
import CalcInput from '@/game/components/calc/CalcInput.vue';
import CalcLine from '@/game/components/calc/CalcLine.vue';
import format from '@/utils/format';

export default {
  name: 'empire-financials',
  mixins: [CalcMixin],
  computed: {
    // Sections are classification-driven, not storage-driven: a line
    // with a completion moment (until / afford / note) is a reminder no
    // matter which list it lives in (legacy blobs may still hold them
    // in recent); everything else splits into pinned projections vs
    // scratch history.
    classifiedRows() {
      const recentIds = new Set(this.calcRecentLines.map((l) => l.id));
      const reminders = [];
      const projections = [];
      const recent = [];
      this.calcDocResults.forEach((r) => {
        const state = r.ok ? this.calcReminderState(r.value) : null;
        if (state) reminders.push(this.toRow(r));
        else if (recentIds.has(r.id)) recent.push(this.toRow(r));
        else projections.push(this.toRow(r));
      });
      return { reminders, projections, recent };
    },
    reminderRows() { return this.classifiedRows.reminders; },
    projectionRows() { return this.classifiedRows.projections; },
    recentRows() { return this.classifiedRows.recent; },
    removeOnlyActions() {
      return [
        { key: 'remove', icon: 'close', title: this.$t('calc.remove') },
      ];
    },
    recentActions() {
      return [
        { key: 'pin', icon: 'bookmark', title: this.$t('calc.pin') },
        { key: 'remove', icon: 'close', title: this.$t('calc.remove') },
      ];
    },
    rateEntries() {
      const env = this.calcEnv;
      return ['credit', 'technology', 'ideology'].map((res) => {
        const perHour = env.resources[res].changePerUt * env.perHour;
        return {
          res,
          value: format.integer(env.resources[res].value),
          perHour: `${format.integer(perHour, true)}/${this.$t('calc.result.hour_abbr')}`,
          perDay: `${format.integer(perHour * 24, true)}/${this.$t('calc.result.day_abbr')}`,
        };
      });
    },
  },
  methods: {
    focusInput() {
      if (this.$refs.input) this.$refs.input.focus();
    },
    // Esc in an empty input closes the panel. The blur matters: this tab
    // is v-show'd, so without it focus would stay parked on the hidden
    // input and keep suppressing game hotkeys after the panel is gone.
    closeAndRelease() {
      if (document.activeElement) document.activeElement.blur();
      this.$root.$emit('closePanel');
    },
    // Any click on non-interactive parts of the tab parks focus in the
    // input, so the next thing the player types is calculator text —
    // never a stray game hotkey (the input matches the vue-shortkey
    // prevent list; <body> does not).
    onSurfaceClick(event) {
      if (!event.target.closest('input, button, a, select, textarea')) {
        this.focusInput();
      }
    },
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
    commit(src) {
      this.$store.dispatch('calc/commitLine', this.calcLinePayload(src));
    },
    onRemoveAction({ key, id }) {
      if (key === 'remove') this.$store.dispatch('calc/removeLine', id);
      this.focusInput();
    },
    onRecentAction({ key, id }) {
      if (key === 'pin') this.$store.dispatch('calc/pinLine', id);
      if (key === 'remove') this.$store.dispatch('calc/removeLine', id);
      this.focusInput();
    },
    clearRecent() {
      this.$store.dispatch('calc/clearRecentLines');
      this.focusInput();
    },
  },
  components: {
    CalcInput,
    CalcLine,
  },
};
</script>

<style scoped>
.fin-rates {
  display: flex;
  gap: 12px;
  margin-bottom: 1.5rem;
}

.fin-rate {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.12);
}

.fin-rate-icon {
  width: 22px;
  height: 22px;
  flex-shrink: 0;
  fill: rgba(255, 255, 255, 0.8);
}

.fin-rate-values {
  min-width: 0;
}

.fin-rate-value {
  display: block;
  color: #fff;
  font-size: 1.4rem;
  font-variant-numeric: tabular-nums;
}

.fin-rate-sub {
  display: block;
  color: rgba(255, 255, 255, 0.5);
  font-size: 1.05rem;
  font-variant-numeric: tabular-nums;
}

.fin-section {
  margin-bottom: 1.5rem;
}

.fin-subtitle {
  margin: 0 0 0.5rem;
  color: rgba(255, 255, 255, 0.6);
  font-size: 1.1rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.fin-subtitle-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}

.fin-clear-button {
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.4);
  font-size: 1.05rem;
  cursor: pointer;
}

.fin-clear-button:hover {
  color: #fff;
}

.fin-empty {
  color: rgba(255, 255, 255, 0.35);
  font-size: 1.15rem;
  font-style: italic;
}

.fin-hint {
  color: rgba(255, 255, 255, 0.35);
  font-size: 1.05rem;
  line-height: 1.5;
}
</style>
