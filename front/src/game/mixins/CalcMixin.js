// Shared plumbing for the calculator surfaces (QuickCalc overlay and the
// Empire → Financials tab): env building, live re-evaluation, and result
// formatting. Results refresh on a 1 s pulse so ETAs count down and
// projections track income between server pushes.

import { evaluateDoc, evaluateLine, CalcError } from '@/game/calc/engine';
import { buildEnv } from '@/game/calc/env';
import { formatValue, formatError } from '@/game/calc/format';
import format, { formatDuration } from '@/utils/format';

const CalcMixin = {
  data() {
    return {
      calcNow: Date.now(),
      calcPulse: undefined,
    };
  },
  computed: {
    calcFeatureEnabled() {
      return this.$store.state.portal.features.calculator === true;
    },
    calcSavedLines() { return this.$store.state.calc.saved; },
    calcRecentLines() { return this.$store.state.calc.recent; },
    // saved first, then recent: names defined in pinned lines are visible
    // to scratch lines, and doc order is stable for the user.
    calcDocLines() { return [...this.calcSavedLines, ...this.calcRecentLines]; },
    calcEnv() {
      const player = this.$store.state.game.player;
      const constant = (this.$store.state.game.data.constant || [])[0];
      return buildEnv({
        now: this.calcNow,
        effectiveSpeedFactor: this.$store.getters['game/effectiveSpeedFactor'] || 1,
        isRunning: !!this.$store.state.game.time.is_running,
        receivedAt: player.receivedAt,
        player,
        constant,
        maxPolicies: player.max_policies,
      });
    },
    // [{ id, src, ok, value|error }] for the whole document
    calcDocResults() {
      const env = this.calcEnv;
      const results = evaluateDoc(
        this.calcDocLines.map((l) => ({ src: l.src, base: l.base, ts: l.ts })),
        env,
      );
      return this.calcDocLines.map((line, i) => ({ ...line, ...results[i] }));
    },
  },
  methods: {
    calcHydrate() {
      this.$store.dispatch('calc/hydrate');
    },
    // Evaluate a candidate line (live preview) against the current doc's
    // names without mutating them. Previews have no creation snapshot yet:
    // relative targets and note anchors read as "from right now".
    calcPreview(src) {
      if (!src || !src.trim()) return null;
      const env = this.calcEnv;
      evaluateDoc(this.calcDocLines.map((l) => ({ src: l.src, base: l.base, ts: l.ts })), env);
      try {
        const names = new Map(env.names);
        return { ok: true, value: evaluateLine(src.trim(), { ...env, names, lineBase: null, lineTs: null }) };
      } catch (e) {
        if (e instanceof CalcError) return { ok: false, error: e };
        return { ok: false, error: new CalcError('PARSE', {}) };
      }
    },
    // Payload for calc/commitLine: stamps the creation instant and the
    // stockpile snapshot that give `until +N` and note reminders their
    // fixed anchors, and classifies the line — reminder-kind lines are
    // routed to the persistent list and fire without pinning. A reminder
    // already satisfied at commit starts acked (no instant pop).
    calcLinePayload(src) {
      const env = this.calcEnv;
      const preview = this.calcPreview(src);
      const state = preview && preview.ok ? this.calcReminderState(preview.value) : null;
      return {
        src,
        ts: Date.now(),
        base: {
          credit: env.resources.credit.value,
          technology: env.resources.technology.value,
          ideology: env.resources.ideology.value,
        },
        reminder: !!state,
        acked: !!(state && state.done),
      };
    },
    calcFormatters() {
      const t = (key, params) => this.$t(key, params);
      return {
        int: (n) => format.integer(n),
        num: (n) => format.mixed(n, 1),
        dur: (s) => formatDuration(s, t),
        time: (ms) => this.calcFormatTime(ms),
        t,
      };
    },
    calcFormatResult(result) {
      return formatValue(result, this.calcFormatters());
    },
    // Reminder classification, shared by the pin-time silent-ack and the
    // firing watcher. `until` (eta), `afford`, and note lines are all
    // threshold events: a "done" boolean plus what crossed. Anything else
    // (plain sums, projections, rates) can't be a reminder → null.
    calcReminderState(value) {
      if (!value) return null;
      if (value.k === 'eta') {
        return { kind: 'until', done: value.reached === true, resource: value.res, amount: value.target, label: value.label || null };
      }
      if (value.k === 'afford') {
        return { kind: 'afford', done: value.ok === true, resource: value.res, amount: value.cost, label: value.label || null };
      }
      if (value.k === 'note') {
        return { kind: 'note', done: value.done === true, resource: null, amount: null, label: value.text };
      }
      return null;
    },
    calcFormatError(error) {
      return formatError(error, this.calcFormatters());
    },
    calcFormatTime(ms) {
      const locale = this.$i18n.locale;
      const delta = ms - this.calcNow;
      const opts = { hour: '2-digit', minute: '2-digit', hour12: false };
      if (delta >= 20 * 3600 * 1000) opts.weekday = 'short';
      if (delta >= 6 * 86400 * 1000) {
        opts.day = 'numeric';
        opts.month = 'short';
      }
      return new Intl.DateTimeFormat(locale, opts).format(new Date(ms));
    },
  },
  mounted() {
    this.calcHydrate();
    this.calcPulse = setInterval(() => { this.calcNow = Date.now(); }, 1000);
  },
  destroyed() {
    clearInterval(this.calcPulse);
  },
};

export default CalcMixin;
