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

      const out = [];
      COMPLETIONS.forEach((c) => {
        if (c.insert.toLowerCase().startsWith(frag) && c.insert.trim() !== frag) {
          out.push({ ...c, meta: this.suggestionMeta(c) });
        }
      });
      this.userNames.forEach((name) => {
        if (name.startsWith(frag) && name !== frag) {
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
  },
  watch: {
    src() {
      this.highlight = 0;
      this.navigated = false;
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
