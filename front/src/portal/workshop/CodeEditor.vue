<template>
  <div
    class="wk-code"
    :class="{ 'is-readonly': readonly }">
    <div
      ref="gutter"
      class="wk-gutter"
      aria-hidden="true">
      <div
        v-for="n in lineCount"
        :key="n"
        class="wk-gutter-line"
        :class="{
          'has-error': lineProblems[n] && lineProblems[n].severity === 'error',
          'has-warning': lineProblems[n] && lineProblems[n].severity === 'warning',
          'is-active': n === activeLine,
        }"
        :title="lineProblems[n] ? lineProblems[n].message : null"
        @click="$emit('line', n)">{{ n }}</div>
    </div>
    <div class="wk-code-area">
      <pre
        ref="highlight"
        class="wk-highlight"
        aria-hidden="true"><code
          v-for="(line, i) in highlighted"
          :key="i"
          class="wk-hl-line"
          :class="{ 'is-active': i + 1 === activeLine, 'has-error': lineProblems[i + 1] && lineProblems[i + 1].severity === 'error' }"
          v-html="line" /></pre>
      <textarea
        ref="input"
        class="wk-input"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        :readonly="readonly"
        :value="value"
        :aria-label="$t('page.scenario_workshop.code_label')"
        @input="onInput"
        @scroll="syncScroll"
        @keydown.tab.prevent="indent"
        @keydown.enter.exact.prevent="newline"
        @click="caret"
        @keyup="caret" />
    </div>
  </div>
</template>

<script>
// Highlighting runs over the author's own text, escaped first: the overlay
// only ever wraps escaped text in fixed span classes.
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const KEYWORDS = new Set(['setup', 'score', 'tiebreak', 'var', 'let', 'fn', 'return', 'if', 'then', 'else', 'for', 'in',
  'while', 'break', 'continue', 'on', 'every', 'at', 'when', 'as', 'from', 'until', 'draft', 'and', 'or', 'not',
  'true', 'false', 'nil']);

export default {
  name: 'code-editor',
  props: {
    value: { type: String, default: '' },
    diagnostics: { type: Array, default: () => [] },
    activeLine: { type: Number, default: null },
    actions: { type: Array, default: () => [] },
    readonly: { type: Boolean, default: false },
  },
  computed: {
    lines() { return this.value.split('\n'); },
    lineCount() { return Math.max(this.lines.length, 1); },
    lineProblems() {
      const out = {};
      this.diagnostics.forEach((d) => {
        if (!d.at) return;
        const line = d.at[0];
        if (!out[line] || (out[line].severity === 'warning' && d.severity === 'error')) out[line] = d;
      });
      return out;
    },
    highlighted() {
      const actions = new Set(this.actions);
      const token = /(#.*$)|("(?:[^"\\]|\\.)*"?)|(\b\d[\d_]*(?:\.\d+)?(?:[hms%](?:\d[\d_]*(?:\.\d+)?[hms])*)?)|([A-Za-z_][A-Za-z0-9_]*)|(=>|==|!=|<=|>=|[-+*/<>=?])/g;
      return this.lines.map((line) => {
        let out = '';
        let last = 0;
        line.replace(token, (m, comment, str, num, word, op, offset) => {
          out += escapeHtml(line.slice(last, offset));
          let cls = null;
          if (comment) cls = 'c';
          else if (str) cls = 's';
          else if (num) cls = 'n';
          else if (word && KEYWORDS.has(word)) cls = 'k';
          else if (word && actions.has(word)) cls = 'a';
          else if (word && ['player', 'time', 'rival', 'scenario'].includes(word)) cls = 'w';
          else if (op) cls = 'o';
          out += cls ? `<span class="hl-${cls}">${escapeHtml(m)}</span>` : escapeHtml(m);
          last = offset + m.length;
          return m;
        });
        out += escapeHtml(line.slice(last));
        return `${out}\n`;
      });
    },
  },
  watch: {
    activeLine(line) {
      if (!line) return;
      const ta = this.$refs.input;
      const lineHeight = 20;
      const top = (line - 1) * lineHeight;
      if (top < ta.scrollTop || top > ta.scrollTop + ta.clientHeight - 2 * lineHeight) {
        ta.scrollTop = Math.max(0, top - ta.clientHeight / 3);
        this.syncScroll();
      }
    },
  },
  methods: {
    onInput(e) { this.$emit('input', e.target.value); },
    syncScroll() {
      const ta = this.$refs.input;
      this.$refs.highlight.scrollTop = ta.scrollTop;
      this.$refs.highlight.scrollLeft = ta.scrollLeft;
      this.$refs.gutter.scrollTop = ta.scrollTop;
    },
    indent(e) {
      if (this.readonly) return;
      const ta = e.target;
      const { selectionStart: s, selectionEnd: end } = ta;
      const next = `${this.value.slice(0, s)}  ${this.value.slice(end)}`;
      this.$emit('input', next);
      this.$nextTick(() => { ta.selectionStart = s + 2; ta.selectionEnd = s + 2; });
    },
    // Enter keeps the line's indentation, one level more after a `{`.
    newline(e) {
      if (this.readonly) return;
      const ta = e.target;
      const { selectionStart: s, selectionEnd: end } = ta;
      const lineStart = this.value.lastIndexOf('\n', s - 1) + 1;
      const line = this.value.slice(lineStart, s);
      const indent = line.match(/^[ \t]*/)[0] + (line.trimEnd().endsWith('{') ? '  ' : '');
      const next = `${this.value.slice(0, s)}\n${indent}${this.value.slice(end)}`;
      this.$emit('input', next);
      this.$nextTick(() => {
        ta.selectionStart = s + 1 + indent.length;
        ta.selectionEnd = ta.selectionStart;
      });
    },
    caret(e) {
      const pos = e.target.selectionStart;
      const line = this.value.slice(0, pos).split('\n').length;
      this.$emit('caret', line);
    },
    focusLine(line) {
      const ta = this.$refs.input;
      const offset = this.lines.slice(0, line - 1).reduce((n, l) => n + l.length + 1, 0);
      ta.focus();
      ta.selectionStart = offset;
      ta.selectionEnd = offset;
    },
  },
};
</script>
