<template>
  <div class="wk-sim">
    <div class="wk-sim-bar">
      <button
        type="button"
        class="wk-button is-primary"
        data-tour="simulate"
        :disabled="running"
        @click="$emit('run')">
        {{ running ? $t('page.scenario_workshop.sim_running') : $t('page.scenario_workshop.sim_run') }}
      </button>
      <label class="wk-sim-pace">
        <span>{{ $t('page.scenario_workshop.sim_pace') }}</span>
        <select
          :value="pace"
          @change="$emit('pace', $event.target.value)">
          <option value="slow">{{ $t('page.scenario_workshop.pace_slow') }}</option>
          <option value="typical">{{ $t('page.scenario_workshop.pace_typical') }}</option>
          <option value="strong">{{ $t('page.scenario_workshop.pace_strong') }}</option>
        </select>
      </label>
      <label class="wk-check">
        <input
          type="checkbox"
          :checked="auto"
          @change="$emit('auto', $event.target.checked)">
        <span>{{ $t('page.scenario_workshop.sim_auto') }}</span>
      </label>
    </div>

    <div
      v-if="stale && (report || failure)"
      class="wk-sim-stale">
      <span>{{ $t('page.scenario_workshop.stale') }}</span>
      <button
        type="button"
        class="wk-mini"
        @click="$emit('run')">{{ $t('page.scenario_workshop.rerun') }}</button>
    </div>

    <div
      v-if="failure && failure.length"
      class="wk-sim-errors">
      <button
        v-for="(e, i) in failure"
        :key="`f${i}`"
        type="button"
        class="wk-problem-row is-error"
        @click="e.node_id && $emit('select-node', e.node_id)">{{ e.message }}</button>
    </div>

    <template v-if="report">
      <div
        class="wk-sim-result"
        :class="{ 'is-stale': stale }">
        <div class="wk-sim-score">
          <span class="wk-sim-label">{{ $t('page.scenario_workshop.sim_score') }}</span>
          <strong>{{ race ? raceScore : fmt(report.result.score) }}</strong>
          <span
            v-if="report.result.tiebreak"
            class="wk-sim-tie">{{ $t('page.scenario_workshop.sim_tiebreak') }} {{ fmt(report.result.tiebreak) }}</span>
        </div>
        <p class="wk-sim-end">
          <template v-if="report.result.reason === 'finished'">
            {{ $t('page.scenario_workshop.sim_finished', { time: clock(report.result.ended_at), left: clock(report.result.time_left) }) }}
            <em v-if="report.result.message">“{{ report.result.message }}”</em>
          </template>
          <template v-else>
            {{ $t('page.scenario_workshop.sim_deadline', { time: clock(report.result.ended_at) }) }}
          </template>
        </p>
        <p
          v-if="hasFinish && report.result.reason !== 'finished'"
          class="wk-sim-goal">{{ $t('page.scenario_workshop.sim_no_finish') }}</p>

        <div
          class="wk-sim-series"
          role="radiogroup"
          :aria-label="$t('page.scenario_workshop.sim_chart_series')">
          <button
            v-for="s in ['score', 'credit', 'technology', 'ideology']"
            :key="s"
            type="button"
            role="radio"
            :aria-checked="String(series === s)"
            :class="{ 'is-active': series === s }"
            @click="series = s">{{ $t(`page.scenario_workshop.series_${s}`) }}</button>
        </div>
        <div
          v-if="chart"
          class="wk-sim-plot">
          <div class="wk-sim-y">
            <span>{{ fmt(chart.max) }}</span>
            <span>{{ fmt(chart.min) }}</span>
          </div>
          <div class="wk-sim-canvas">
            <svg
              class="wk-sim-chart"
              viewBox="0 0 300 70"
              preserveAspectRatio="none"
              role="img"
              :aria-label="$t('page.scenario_workshop.sim_chart')">
              <polyline
                :points="chart.points"
                class="wk-sim-line" />
              <line
                v-if="chart.endX !== null"
                :x1="chart.endX"
                :x2="chart.endX"
                y1="0"
                y2="70"
                class="wk-sim-end-mark" />
            </svg>
            <div class="wk-sim-x">
              <span>0:00</span>
              <span>{{ clock(chart.last) }}</span>
            </div>
          </div>
        </div>
      </div>

      <div
        v-if="report.errors.length"
        class="wk-sim-errors">
        <h4>{{ $t('page.scenario_workshop.sim_errors') }}</h4>
        <button
          v-for="(e, i) in report.errors"
          :key="`e${i}`"
          type="button"
          class="wk-problem-row is-error"
          @click="e.node_id && $emit('select-node', e.node_id)">
          <span class="wk-time">{{ clock(e.first_t) }}</span>
          {{ e.message }}
          <span
            v-if="e.count > 1"
            class="wk-count">×{{ e.count }}</span>
        </button>
      </div>

      <h4>{{ $t('page.scenario_workshop.sim_timeline') }}</h4>
      <p
        v-if="!report.timeline.length"
        class="wk-muted">{{ $t('page.scenario_workshop.sim_quiet') }}</p>
      <ol class="wk-timeline">
        <li
          v-for="(entry, i) in report.timeline"
          :key="`t${i}`">
          <button
            type="button"
            @click="entry.fired[0] && $emit('select-node', entry.fired[0].id)">
            <span class="wk-time">{{ clock(entry.t) }}</span>
            <span class="wk-what">
              <template v-for="(part, j) in describe(entry)">
                <span
                  :key="`p${j}`"
                  :class="part.cls">{{ part.text }}</span>
              </template>
            </span>
          </button>
        </li>
      </ol>
      <p
        v-if="report.timeline_dropped"
        class="wk-muted">{{ $t('page.scenario_workshop.sim_dropped', { n: report.timeline_dropped }) }}</p>
    </template>

    <details
      class="wk-pretend"
      :open="pretendOpen"
      @toggle="pretendOpen = $event.target.open">
      <summary>{{ $t('page.scenario_workshop.pretend_title') }} ({{ pretend.length }})</summary>
      <p class="wk-muted">{{ $t('page.scenario_workshop.pretend_hint') }}</p>
      <div
        v-for="(p, i) in pretend"
        :key="`p${i}`"
        class="wk-pretend-row">
        <input
          type="text"
          :value="clock(p.at)"
          :aria-label="$t('page.scenario_workshop.pretend_at')"
          @change="editPretend(i, 'at', $event.target.value)">
        <select
          :value="p.path"
          :aria-label="$t('page.scenario_workshop.pretend_path')"
          @change="editPretend(i, 'path', $event.target.value)">
          <option
            v-for="w in paths"
            :key="w"
            :value="w">{{ w }}</option>
        </select>
        <input
          type="text"
          :value="valueText(p.value)"
          :aria-label="$t('page.scenario_workshop.pretend_value')"
          @change="editPretend(i, 'value', $event.target.value)">
        <button
          type="button"
          class="wk-mini"
          :aria-label="$t('page.scenario_workshop.remove')"
          @click="removePretend(i)">×</button>
      </div>
      <button
        type="button"
        class="wk-mini"
        @click="addPretend">+ {{ $t('page.scenario_workshop.pretend_add') }}</button>
    </details>

    <p
      v-if="assumptions"
      class="wk-muted wk-assumptions">{{ $t('page.scenario_workshop.sim_model', assumptions) }}</p>
  </div>
</template>

<script>
function clock(seconds) {
  const s = Math.max(0, Math.round(seconds || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function parseClock(text) {
  const m = String(text).trim().match(/^(\d+)(?::(\d{1,2}))?$/);
  if (!m) return null;
  return m[2] === undefined ? Number(m[1]) * 60 : Number(m[1]) * 60 + Number(m[2]);
}

const TONE_MARK = { warning: '⚠ ', good: '✓ ', info: '' };

export default {
  name: 'sim-panel',
  props: {
    report: { type: Object, default: null },
    failure: { type: Array, default: null },
    running: { type: Boolean, default: false },
    stale: { type: Boolean, default: false },
    race: { type: Boolean, default: false },
    hasFinish: { type: Boolean, default: false },
    pace: { type: String, default: 'typical' },
    auto: { type: Boolean, default: false },
    pretend: { type: Array, default: () => [] },
    // a what-if worth starting from: what the scenario's `when` reads
    pretendDefault: { type: Object, default: null },
    paths: { type: Array, default: () => [] },
    catalog: { type: Object, default: null },
  },
  data() {
    return { series: 'score', pretendOpen: false };
  },
  computed: {
    chart() {
      const samples = this.report && this.report.samples;
      if (!samples || samples.length < 2) return null;
      const values = samples.map((s) => s[this.series]);
      const min = Math.min(...values);
      const max = Math.max(...values);
      const span = max - min || 1;
      const last = samples[samples.length - 1].t || 1;
      const points = samples.map((s) => `${(s.t / last) * 300},${68 - ((s[this.series] - min) / span) * 64}`).join(' ');
      const ended = this.report.result.reason === 'finished' ? (this.report.result.ended_at / last) * 300 : null;
      return {
        points, min, max, last, endX: ended,
      };
    },
    // a race's score is the time left at finish(): show it as time
    raceScore() {
      const s = this.report.result.score;
      return s > 0 ? this.$t('page.scenario_workshop.sim_race_score', { time: clock(s) }) : this.$t('page.scenario_workshop.sim_race_none');
    },
    // the model's numbers for the economy picked
    assumptions() {
      if (!this.catalog || !this.catalog.simulator) return null;
      const { economy: e, stock, paces } = this.catalog.simulator;
      const k = paces[this.pace] || 1;
      const n = (v) => Math.round(v * k).toLocaleString('en-US');
      return {
        c0: n(e.credit[0]),
        c1: n(e.credit[1]),
        t0: n(e.technology[0]),
        t1: n(e.technology[1]),
        i0: n(e.ideology[0]),
        i1: n(e.ideology[1]),
        start: Math.round(stock.credit).toLocaleString('en-US'),
      };
    },
  },
  methods: {
    clock,
    fmt(n) {
      if (typeof n !== 'number') return '–';
      if (Math.abs(n) >= 1000) return Math.round(n).toLocaleString('en-US');
      return Math.round(n * 100) / 100;
    },
    // A timeline entry as parts: which handler fired (named as written,
    // so two timers can be told apart) and what it did.
    describe(entry) {
      const parts = [];
      entry.fired.forEach((f) => parts.push({ text: f.kind === 'every' || f.kind === 'when' ? `${f.label || f.kind} #${f.n}` : (f.label || f.kind), cls: 'wk-tl-handler' }));
      entry.effects.forEach((e) => {
        const a = e.args || {};
        switch (e.action) {
          case 'give': parts.push({ text: `+${this.fmt(a.amount)} ${a.resource}` }); break;
          case 'take': parts.push({ text: `−${this.fmt(a.amount)} ${a.resource}` }); break;
          case 'notify': parts.push({ text: `${TONE_MARK[a.tone] || ''}“${a.message}”`, cls: `wk-tl-${a.tone || 'info'}` }); break;
          case 'finish': parts.push({ text: `finish${a.message ? ` “${a.message}”` : ''}` }); break;
          case 'destabilize': parts.push({ text: `stability −${this.fmt(a.amount)}` }); break;
          case 'send_agent': parts.push({ text: `agent sent (level ${a.level || 1})` }); break;
          default: parts.push({ text: e.action });
        }
      });
      entry.logs.forEach((l) => parts.push({ text: `log ${JSON.stringify(l.value)}`, cls: 'wk-tl-log' }));
      (entry.errors || []).forEach((e) => parts.push({ text: `error: ${e.message}`, cls: 'wk-tl-warning' }));
      return parts.flatMap((p, i) => (i ? [{ text: ' · ' }, p] : [p]));
    },
    valueText(v) {
      return Array.isArray(v) ? v.join(', ') : String(v);
    },
    readValue(text) {
      const raw = text.trim();
      if (raw.includes(',')) return raw.split(',').map((s) => s.trim()).filter(Boolean).map((s) => (Number.isFinite(Number(s)) ? Number(s) : s));
      if (raw === 'true' || raw === 'false') return raw === 'true';
      if (raw !== '' && Number.isFinite(Number(raw.replace(/_/g, '')))) return Number(raw.replace(/_/g, ''));
      return raw;
    },
    editPretend(i, key, text) {
      const list = this.pretend.map((p) => ({ ...p }));
      if (key === 'at') {
        const at = parseClock(text);
        if (at === null) return;
        list[i].at = at;
      } else if (key === 'value') {
        list[i].value = this.readValue(text);
      } else {
        list[i][key] = text;
      }
      this.$emit('pretend', list);
    },
    addPretend() {
      this.pretendOpen = true;
      const entry = this.pretendDefault || { at: 600, path: 'player.credit', value: 1000000 };
      this.$emit('pretend', [...this.pretend, { ...entry }]);
    },
    removePretend(i) {
      this.$emit('pretend', this.pretend.filter((_, j) => j !== i));
    },
  },
};
</script>
