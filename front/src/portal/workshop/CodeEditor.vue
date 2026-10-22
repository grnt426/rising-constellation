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
    <div
      ref="area"
      class="wk-code-area">
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
        :aria-autocomplete="assist ? 'list' : null"
        :aria-expanded="popup ? 'true' : 'false'"
        :aria-controls="popup ? 'wk-complete-list' : null"
        :aria-activedescendant="popup ? `wk-complete-${popup.index}` : null"
        @input="onInput"
        @scroll="syncScroll"
        @keydown="onKeydown"
        @click="caret"
        @keyup="onKeyup"
        @blur="onBlur"
        @mousemove="onMouseMove"
        @mouseleave="hideHover" />
      <span
        ref="measure"
        class="wk-measure"
        aria-hidden="true">0000000000</span>

      <!-- suggestions -->
      <div
        v-if="popup"
        class="wk-complete"
        :style="popupStyle"
        @mousedown.prevent>
        <ul
          id="wk-complete-list"
          ref="list"
          role="listbox"
          class="wk-complete-list"
          :aria-label="$t('page.scenario_workshop.suggestions')">
          <li
            v-for="(item, i) in popup.items"
            :id="`wk-complete-${i}`"
            :key="`${item.label}-${i}`"
            role="option"
            class="wk-complete-item"
            :class="{ 'is-active': i === popup.index }"
            :aria-selected="i === popup.index ? 'true' : 'false'"
            @mouseenter="popup.index = i"
            @click="accept(i)">
            <span
              class="wk-complete-kind"
              :class="`kind-${item.kind}`"
              aria-hidden="true">{{ kindMark(item.kind) }}</span>
            <span class="wk-complete-label">{{ item.label }}</span>
            <span class="wk-complete-detail">{{ item.detail }}</span>
          </li>
        </ul>
        <div
          v-if="activeDoc.length"
          class="wk-complete-doc wk-md">
          <template v-for="(b, bi) in activeDoc">
            <pre
              v-if="b.kind === 'code'"
              :key="`d${bi}`"
              class="wk-md-code">{{ b.text }}</pre>
            <p
              v-else
              :key="`d${bi}`"
              :class="{ 'is-li': b.kind === 'li' }"><span
                v-for="(part, pi) in b.parts"
                :key="pi"
                :class="`md-${part.style}`">{{ part.text }}</span></p>
          </template>
        </div>
        <div class="wk-complete-hint">{{ $t('page.scenario_workshop.suggest_hint', { key: acceptLabel }) }}</div>
      </div>

      <!-- docs for the name under the mouse -->
      <div
        v-if="hoverCard"
        class="wk-hover-doc wk-md"
        :style="hoverCard.style"
        role="tooltip">
        <template v-for="(b, bi) in hoverCard.blocks">
          <pre
            v-if="b.kind === 'code'"
            :key="`h${bi}`"
            class="wk-md-code">{{ b.text }}</pre>
          <p
            v-else
            :key="`h${bi}`"
            :class="{ 'is-li': b.kind === 'li' }"><span
              v-for="(part, pi) in b.parts"
              :key="pi"
              :class="`md-${part.style}`">{{ part.text }}</span></p>
        </template>
      </div>
    </div>
  </div>
</template>

<script>
import { blocks } from './md-lite';
import { filterItems, insertion } from './completion';
import { isAcceptKey } from './editor-settings';

// Highlighting runs over the author's own text, escaped first: the overlay
// only ever wraps escaped text in fixed span classes.
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const KEYWORDS = new Set(['setup', 'score', 'tiebreak', 'var', 'shared', 'let', 'fn', 'return', 'if', 'then', 'else', 'for', 'in',
  'while', 'break', 'continue', 'on', 'every', 'at', 'when', 'as', 'from', 'until', 'draft', 'and', 'or', 'not',
  'true', 'false', 'nil']);

const PAD_X = 12;
const PAD_Y = 10;
const LINE = 20;
const WORD = /[A-Za-z0-9_]/;
// typing one of these opens suggestions with nothing typed yet: a field
// after `.`, a choice inside `"`
const TRIGGERS = ['.', '"'];

const KIND_MARKS = {
  function: 'ƒ', action: '!', keyword: 'k', snippet: '{}', field: '.', variable: 'x', module: 'w', property: '=', enum: '"', event: '⏱',
};

export default {
  name: 'code-editor',
  props: {
    value: { type: String, default: '' },
    diagnostics: { type: Array, default: () => [] },
    activeLine: { type: Number, default: null },
    actions: { type: Array, default: () => [] },
    readonly: { type: Boolean, default: false },
    // the language engine (createEdict): suggestions and docs; none, no help
    assist: { type: Object, default: null },
    // Settings → Scenario editor: {accept, suggest}
    settings: { type: Object, default: () => ({ accept: 'tab', suggest: true }) },
  },
  data() {
    return {
      popup: null,
      hoverCard: null,
      hoverTimer: null,
      charWidth: 7.8,
    };
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
    popupStyle() {
      return { left: `${this.popup.x}px`, top: `${this.popup.y}px` };
    },
    activeDoc() {
      const item = this.popup && this.popup.items[this.popup.index];
      return item && item.doc ? blocks(item.doc) : [];
    },
    acceptLabel() {
      return this.$t(`page.settings.scenario_editor.accept.${this.settings.accept.replace('+', '_')}`);
    },
  },
  watch: {
    activeLine(line) {
      if (!line) return;
      const ta = this.$refs.input;
      const top = (line - 1) * LINE;
      if (top < ta.scrollTop || top > ta.scrollTop + ta.clientHeight - 2 * LINE) {
        ta.scrollTop = Math.max(0, top - ta.clientHeight / 3);
        this.syncScroll();
      }
    },
  },
  mounted() {
    const w = this.$refs.measure.getBoundingClientRect().width / 10;
    if (w > 0) this.charWidth = w;
  },
  beforeDestroy() {
    clearTimeout(this.hoverTimer);
  },
  methods: {
    onInput(e) {
      const ta = e.target;
      this.$emit('input', ta.value);
      this.hideHover();
      if (!this.assist) return;
      const typed = e.data;
      if (this.popup) this.suggest(false);
      else if (this.settings.suggest && typed && typed.length === 1 && (WORD.test(typed) || TRIGGERS.includes(typed))) {
        this.suggest(false);
      }
    },
    onKeydown(e) {
      this.hideHover();
      if (this.popup) {
        const n = this.popup.items.length;
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          this.popup.index = (this.popup.index + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
          this.$nextTick(this.scrollActive);
          return;
        }
        if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          this.popup = null;
          return;
        }
        if (isAcceptKey(e, this.settings.accept)) {
          e.preventDefault();
          this.accept(this.popup.index);
          return;
        }
      }
      if (e.key === ' ' && e.ctrlKey) {
        e.preventDefault();
        this.suggest(true);
        return;
      }
      if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
        e.preventDefault();
        this.indent(e);
        return;
      }
      if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {
        e.preventDefault();
        this.newline(e);
      }
    },
    onKeyup(e) {
      // moving the caret off the word closes the suggestions
      if (this.popup && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) this.suggest(false);
      this.caret(e);
    },
    onBlur() {
      this.popup = null;
    },

    // --- suggestions ----------------------------------------------------------
    // What fits at the caret, narrowed to what's typed. `asked`: Ctrl+Space,
    // which shows the list even with nothing typed.
    suggest(asked) {
      const ta = this.$refs.input;
      if (!this.assist || !ta || this.readonly) return;
      const text = ta.value;
      const at = ta.selectionStart;
      if (ta.selectionEnd !== at) {
        this.popup = null;
        return;
      }
      const result = this.assist.complete(text, at);
      const prefix = text.slice(result.range.start, at);
      const trigger = TRIGGERS.includes(text[result.range.start - 1]);
      const items = filterItems(result.items, prefix).slice(0, 60);
      if (!items.length || (!asked && !prefix && !trigger && !(this.popup && this.popup.asked))) {
        this.popup = null;
        return;
      }
      const where = this.pointAt(text, result.range.start);
      const keep = this.popup && this.popup.start === result.range.start ? Math.min(this.popup.index, items.length - 1) : 0;
      this.popup = {
        items, index: keep, start: result.range.start, asked: asked || (this.popup && this.popup.asked), ...where,
      };
      this.$nextTick(this.scrollActive);
    },
    accept(i) {
      const item = this.popup && this.popup.items[i];
      if (!item) return;
      const ta = this.$refs.input;
      const text = ta.value;
      const { start } = this.popup;
      // replace the whole word under the caret, not just what's before it
      let end = ta.selectionStart;
      while (end < text.length && WORD.test(text[end])) end += 1;
      const lineStart = text.lastIndexOf('\n', start - 1) + 1;
      const indent = text.slice(lineStart).match(/^[ \t]*/)[0];
      const piece = insertion(item, indent);
      const next = text.slice(0, start) + piece.text + text.slice(end);
      this.popup = null;
      this.$emit('input', next);
      this.$nextTick(() => {
        ta.focus();
        ta.selectionStart = start + piece.select[0];
        ta.selectionEnd = start + piece.select[1];
        this.$emit('caret', next.slice(0, start).split('\n').length);
      });
    },
    // where the popup goes for a text offset: under its line, or above it
    // when there's no room below
    pointAt(text, offset) {
      const ta = this.$refs.input;
      const before = text.slice(0, offset);
      const line = before.split('\n').length - 1;
      const col = offset - (before.lastIndexOf('\n') + 1);
      const x = Math.max(0, PAD_X + col * this.charWidth - ta.scrollLeft);
      const below = PAD_Y + (line + 1) * LINE - ta.scrollTop;
      const room = this.$refs.area.clientHeight - below;
      return room > 240 ? { x, y: below + 2 } : { x, y: Math.max(0, below - LINE - 244) };
    },
    scrollActive() {
      const list = this.$refs.list;
      const el = list && list.children[this.popup ? this.popup.index : 0];
      if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
    },
    kindMark(kind) {
      return KIND_MARKS[kind] || '·';
    },

    // --- docs on hover ------------------------------------------------------------
    onMouseMove(e) {
      if (!this.assist || this.popup) return;
      clearTimeout(this.hoverTimer);
      const ta = this.$refs.input;
      const rect = ta.getBoundingClientRect();
      const line = Math.floor((e.clientY - rect.top + ta.scrollTop - PAD_Y) / LINE);
      const col = Math.floor((e.clientX - rect.left + ta.scrollLeft - PAD_X) / this.charWidth);
      const lines = this.value.split('\n');
      if (line < 0 || line >= lines.length || col < 0 || col >= lines[line].length || !/[A-Za-z0-9_+\-*/<>=!]/.test(lines[line][col])) {
        this.hideHover();
        return;
      }
      const offset = lines.slice(0, line).reduce((n, l) => n + l.length + 1, 0) + col;
      // still over the word its card is for
      if (this.hoverCard && offset >= this.hoverCard.from && offset < this.hoverCard.to) return;
      this.hoverTimer = setTimeout(() => this.showHover(offset, e.clientX - rect.left, (line + 1) * LINE + PAD_Y - ta.scrollTop), 450);
    },
    showHover(offset, x, y) {
      const h = this.assist.hover(this.value, offset);
      if (!h) {
        this.hideHover();
        return;
      }
      const room = this.$refs.area.clientHeight - y;
      this.hoverCard = {
        blocks: blocks(h.md),
        offset,
        from: h.range.start,
        to: h.range.end,
        style: room > 200 ? { left: `${x}px`, top: `${y + 4}px` } : { left: `${x}px`, bottom: `${this.$refs.area.clientHeight - y + LINE + 4}px` },
      };
    },
    hideHover() {
      clearTimeout(this.hoverTimer);
      this.hoverCard = null;
    },

    // --- editing --------------------------------------------------------------------
    syncScroll() {
      const ta = this.$refs.input;
      this.$refs.highlight.scrollTop = ta.scrollTop;
      this.$refs.highlight.scrollLeft = ta.scrollLeft;
      this.$refs.gutter.scrollTop = ta.scrollTop;
      this.popup = null;
      this.hideHover();
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
      // the docs for what the caret is on, for the Help tab
      if (this.assist) this.$emit('doc', this.assist.docKey(e.target.value, pos));
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
