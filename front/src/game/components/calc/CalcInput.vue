<template>
  <div class="calc-input-wrap">
    <!-- The sibling blocks below MUST stay keyed: they are same-tag divs
         that appear/disappear as the user types, and Vue's unkeyed diff
         recycles one into another — which recreates the <input>
         mid-keystroke, silently dropping focus to <body> where the next
         letters hit the game hotkey map. The chips row stays visible
         while typing on purpose: new players keep the hint sheet, the
         window doesn't shift, and one fewer block toggles. -->
    <div
      v-if="showChips"
      key="chips"
      class="calc-chips">
      <button
        v-for="chip in chips"
        :key="chip.id"
        v-tooltip="chip.kind === 'function' ? $t(`calc.hint.${chip.id}`) : null"
        class="calc-chip"
        :class="`is-${chip.kind}`"
        type="button"
        @mousedown.prevent="insertChip(chip)">
        <span class="chip-label">{{ chip.insert.trim() }}</span>
        <span
          v-if="chip.value"
          class="chip-value">{{ chip.value }}</span>
      </button>
    </div>

    <div
      key="input-row"
      class="calc-input-row">
      <input
        ref="input"
        v-model="src"
        type="text"
        class="calc-input"
        maxlength="200"
        :placeholder="placeholder || $t('calc.placeholder')"
        autocomplete="off"
        spellcheck="false"
        @keydown.enter.prevent="onEnter"
        @keydown.tab.prevent="onTab"
        @keydown.down.prevent="onDown"
        @keydown.up.prevent="onUp"
        @keydown.esc.prevent.stop="onEsc" />
      <span
        v-if="preview && preview.ok"
        class="calc-input-result">{{ calcFormatResult(preview.value).text }}</span>
    </div>

    <div
      v-if="preview && !preview.ok && srcLooksSettled"
      key="error"
      class="calc-input-error">
      {{ calcFormatError(preview.error) }}
    </div>

    <div
      v-if="activeVerb && !suggestions.length"
      key="hint"
      class="calc-hint">
      <span class="calc-hint-text">{{ $t(`calc.hint.${activeVerb}`) }}</span>
      <button
        class="calc-hint-toggle"
        type="button"
        @mousedown.prevent="showExamples = !showExamples">
        {{ showExamples ? $t('calc.hint.close') : $t('calc.hint.examples') }}
      </button>
    </div>

    <div
      v-if="activeVerb && showExamples"
      key="examples"
      class="calc-examples">
      <div
        v-for="ex in verbExamples"
        :key="ex.src"
        class="calc-example"
        @mousedown.prevent="useExample(ex)">
        <span class="example-src">{{ ex.src }}</span>
        <span class="example-desc">{{ $t(ex.desc) }}</span>
      </div>
    </div>

    <div
      v-if="suggestions.length"
      key="suggestions"
      class="calc-suggestions">
      <div
        v-for="(s, i) in suggestions"
        :key="s.id"
        class="calc-suggestion"
        :class="{ 'is-highlighted': i === highlight }"
        @mouseenter="highlight = i"
        @mousedown.prevent="complete(s)">
        <span class="name">{{ s.insert.trim() }}</span>
        <span class="meta">{{ s.meta }}</span>
      </div>
    </div>
  </div>
</template>

<script>
import CalcMixin from '@/game/mixins/CalcMixin';
import { COMPLETIONS } from '@/game/calc/engine';

// Example lines are language-neutral calculator syntax; only the
// descriptions go through i18n (calc.examples.*).
const VERB_EXAMPLES = {
  until: [
    { src: 'until 13400 ideo', desc: 'calc.examples.until_target' },
    { src: 'until +5000 c', desc: 'calc.examples.until_gain' },
    { src: 'until 9800 ideo + lex slot buy the lex', desc: 'calc.examples.until_note' },
  ],
  in: [
    { src: 'credits in 8h', desc: 'calc.examples.in_projection' },
    { src: 'in 8h', desc: 'calc.examples.in_all' },
    { src: 'in 2h colony ship arrives', desc: 'calc.examples.in_note' },
  ],
  at: [
    { src: 'ideo at fri 18:00', desc: 'calc.examples.at_projection' },
    { src: 'at 22:00 move the navarch', desc: 'calc.examples.at_note' },
    { src: 'at +2h colony ship arrives', desc: 'calc.examples.at_rel_note' },
  ],
  afford: [
    { src: 'afford 50k c', desc: 'calc.examples.afford_cost' },
    { src: 'afford 9800 ideo + lex slot', desc: 'calc.examples.afford_lex' },
    { src: 'afford 120k c buy the battleship', desc: 'calc.examples.afford_note' },
  ],
};

export default {
  name: 'calc-input',
  mixins: [CalcMixin],
  props: {
    placeholder: { type: String, default: '' },
    showChips: { type: Boolean, default: false },
  },
  data() {
    return {
      src: '',
      highlight: 0,
      navigated: false,
      showExamples: false,
    };
  },
  computed: {
    preview() {
      return this.calcPreview(this.src);
    },
    // Only surface parse errors once the line stops looking like a
    // half-typed fragment, so users aren't scolded mid-keystroke.
    srcLooksSettled() {
      const s = this.src.trim();
      return s.length > 2 && !/[+\-*/(=]\s*$/.test(s);
    },
    // trailing word fragment being typed (possibly multi-word like 'credit in')
    fragment() {
      const match = /(?:^|[^a-zA-Z_])([a-zA-Z][a-zA-Z ]*)$/.exec(this.src);
      return match ? match[1].toLowerCase() : '';
    },
    userNames() {
      const names = new Set();
      this.calcDocLines.forEach((line) => {
        const m = /^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=/.exec(line.src);
        if (m) names.add(m[1].toLowerCase());
      });
      return [...names];
    },
    suggestions() {
      const frag = this.fragment;
      if (!frag || frag.length < 1) return [];
      const fragTrim = frag.trim();

      const out = [];
      COMPLETIONS.forEach((c) => {
        if (c.insert.toLowerCase().startsWith(frag) && c.insert.trim() !== fragTrim) {
          out.push({ ...c, meta: this.suggestionMeta(c) });
        }
      });
      this.userNames.forEach((name) => {
        if (name.startsWith(frag) && name !== fragTrim) {
          out.push({ id: `name-${name}`, insert: name, kind: 'name', meta: this.$t('calc.suggest.user_name') });
        }
      });
      return out.slice(0, 6);
    },
    chips() {
      return COMPLETIONS.map((c) => ({
        ...c,
        value: c.kind === 'variable' ? this.liveValue(c.insert) : null,
      }));
    },
    // The verb the user is working with, for the hint row + examples.
    activeVerb() {
      const low = this.src.toLowerCase();
      const start = /^\s*(until|afford)\b/.exec(low);
      if (start) return start[1];
      const tail = /\b(in|at)\b(?![\w:])/.exec(low);
      return tail ? tail[1] : null;
    },
    verbExamples() {
      return VERB_EXAMPLES[this.activeVerb] || [];
    },
  },
  watch: {
    src() {
      this.highlight = 0;
      this.navigated = false;
    },
    activeVerb(verb) {
      if (!verb) this.showExamples = false;
    },
  },
  methods: {
    focus() {
      this.$nextTick(() => {
        if (this.$refs.input) this.$refs.input.focus();
      });
    },
    liveValue(expr) {
      const r = this.calcPreview(expr);
      return r && r.ok ? this.calcFormatResult(r.value).text : null;
    },
    suggestionMeta(completion) {
      if (completion.kind === 'variable') {
        return this.liveValue(completion.insert) || '';
      }
      return this.$t(`calc.suggest.${completion.id}`);
    },
    insertChip(chip) {
      this.src += chip.insert;
      this.focus();
    },
    useExample(example) {
      this.src = example.src;
      this.showExamples = false;
      this.focus();
    },
    complete(suggestion) {
      const frag = this.fragment;
      this.src = this.src.slice(0, this.src.length - frag.length) + suggestion.insert;
      this.focus();
    },
    onTab() {
      const s = this.suggestions[this.highlight];
      if (s) this.complete(s);
    },
    onDown() {
      if (!this.suggestions.length) return;
      this.highlight = (this.highlight + 1) % this.suggestions.length;
      this.navigated = true;
    },
    onUp() {
      if (!this.suggestions.length) return;
      const n = this.suggestions.length;
      this.highlight = (this.highlight - 1 + n) % n;
      this.navigated = true;
    },
    onEnter() {
      // arrow-key navigation makes Enter complete; otherwise Enter commits
      if (this.navigated && this.suggestions.length) {
        this.complete(this.suggestions[this.highlight]);
        return;
      }
      const src = this.src.trim();
      if (!src) return;
      if (!this.preview || !this.preview.ok) return;
      this.$emit('commit', src);
      this.src = '';
    },
    onEsc() {
      if (this.src) {
        this.src = '';
        return;
      }
      this.$emit('escape');
    },
  },
};
</script>

<style scoped>
.calc-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  padding: 6px 0;
}

.calc-chip {
  display: inline-flex;
  align-items: baseline;
  gap: 6px;
  padding: 3px 8px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: rgba(255, 255, 255, 0.85);
  font-size: 1.1rem;
  cursor: pointer;
}

.calc-chip:hover {
  background: rgba(255, 255, 255, 0.12);
}

.calc-chip.is-function {
  font-style: italic;
}

.chip-value {
  color: rgba(255, 255, 255, 0.5);
  font-variant-numeric: tabular-nums;
}

.calc-input-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 0;
  border-bottom: solid 1px rgba(255, 255, 255, 0.15);
}

.calc-input {
  flex: 1;
  min-width: 0;
  background: transparent;
  border: none;
  outline: none;
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.3rem;
}

.calc-input::placeholder {
  color: rgba(255, 255, 255, 0.35);
  font-family: inherit;
}

.calc-input-result {
  flex-shrink: 0;
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.3rem;
  font-variant-numeric: tabular-nums;
}

.calc-input-error {
  padding: 4px 0;
  color: rgba(255, 160, 140, 0.9);
  font-size: 1.1rem;
}

.calc-hint {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  padding: 4px 0;
  font-size: 1.05rem;
  color: rgba(255, 255, 255, 0.45);
}

.calc-hint-toggle {
  flex-shrink: 0;
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.6);
  font-size: 1.05rem;
  text-decoration: underline;
  cursor: pointer;
}

.calc-hint-toggle:hover {
  color: #fff;
}

.calc-examples {
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(0, 0, 0, 0.55);
}

.calc-example {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 12px;
  padding: 5px 10px;
  cursor: pointer;
}

.calc-example:hover {
  background: rgba(255, 255, 255, 0.08);
}

.calc-example .example-src {
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.15rem;
  white-space: nowrap;
}

.calc-example .example-desc {
  color: rgba(255, 255, 255, 0.45);
  font-size: 1.05rem;
  text-align: right;
}

.calc-suggestions {
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-top: none;
  background: rgba(0, 0, 0, 0.55);
}

.calc-suggestion {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 5px 10px;
  font-size: 1.2rem;
  color: rgba(255, 255, 255, 0.8);
  cursor: pointer;
}

.calc-suggestion .name {
  font-family: Consolas, Menlo, monospace;
}

.calc-suggestion .meta {
  color: rgba(255, 255, 255, 0.45);
  font-size: 1.05rem;
  font-variant-numeric: tabular-nums;
}

.calc-suggestion.is-highlighted {
  background: rgba(255, 255, 255, 0.08);
}
</style>
