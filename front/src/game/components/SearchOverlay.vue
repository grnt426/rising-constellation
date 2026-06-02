<template>
  <div
    v-if="isOpen"
    class="search-overlay-backdrop"
    @click.self="close">
    <div
      class="search-overlay"
      :class="`f-${theme}`">
      <div class="search-overlay-input-row">
        <svgicon class="search-overlay-icon" name="galaxy" />
        <input
          ref="input"
          v-model="query"
          type="text"
          class="search-overlay-input"
          :placeholder="$t('search.placeholder')"
          autocomplete="off"
          spellcheck="false"
          @keydown.tab.prevent="onTab"
          @keydown.down.prevent="onDown"
          @keydown.up.prevent="onUp"
          @keydown.enter.prevent="onEnter"
          @keydown.esc.prevent.stop="close" />
      </div>
      <div
        v-if="suggestions.length"
        class="search-overlay-suggestions">
        <div
          v-for="(s, i) in suggestions"
          :key="s.id"
          class="search-overlay-suggestion"
          :class="{ 'is-highlighted': i === highlight }"
          @mouseenter="highlight = i"
          @click="pick(s)">
          <span class="name">{{ s.name }}</span>
          <span class="meta">
            {{ s.position.x | integer }}, {{ s.position.y | integer }}
          </span>
        </div>
      </div>
      <div
        v-else-if="query.length > 0"
        class="search-overlay-empty">
        {{ $t('search.no_results') }}
      </div>
    </div>
  </div>
</template>

<script>
const MAX_RESULTS = 8;

export default {
  name: 'search-overlay',
  inject: ['mapData'],
  data() {
    return {
      isOpen: false,
      query: '',
      highlight: 0,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    suggestions() {
      const q = this.query.trim().toLowerCase();
      if (!q) return [];

      const systems = this.mapData.systems || [];
      const starts = [];
      const contains = [];

      systems.forEach((s) => {
        if (!s.name) return;
        const lower = s.name.toLowerCase();
        if (lower.startsWith(q)) {
          starts.push(s);
        } else if (lower.includes(q)) {
          contains.push(s);
        }
      });

      const cmp = (a, b) => a.name.localeCompare(b.name);
      starts.sort(cmp);
      contains.sort(cmp);
      return [...starts, ...contains].slice(0, MAX_RESULTS);
    },
  },
  watch: {
    query() {
      this.highlight = 0;
    },
  },
  methods: {
    open() {
      this.isOpen = true;
      this.query = '';
      this.highlight = 0;
      this.$nextTick(() => {
        if (this.$refs.input) this.$refs.input.focus();
      });
    },
    close() {
      this.isOpen = false;
      this.query = '';
    },
    toggle() {
      if (this.isOpen) this.close();
      else this.open();
    },
    onDown() {
      if (!this.suggestions.length) return;
      this.highlight = (this.highlight + 1) % this.suggestions.length;
    },
    onUp() {
      if (!this.suggestions.length) return;
      const n = this.suggestions.length;
      this.highlight = (this.highlight - 1 + n) % n;
    },
    onTab() {
      const s = this.suggestions[this.highlight];
      if (s) this.query = s.name;
    },
    onEnter() {
      const s = this.suggestions[this.highlight];
      if (s) this.pick(s);
    },
    pick(system) {
      this.$root.$emit('map:centerToSystem', system.id);
      this.close();
    },
  },
  mounted() {
    this.$root.$on('toggleSearch', this.toggle);
    this.$root.$on('closeSearch', this.close);
  },
  beforeDestroy() {
    this.$root.$off('toggleSearch', this.toggle);
    this.$root.$off('closeSearch', this.close);
  },
};
</script>
