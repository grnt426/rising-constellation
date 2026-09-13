<template>
  <div class="panel-content is-medium">
    <v-scrollbar class="has-padding">
      <template v-if="!bundle">
        <h1 class="panel-default-title">{{ $t('panel.help.manual_title') }}</h1>
        <p class="help-manual-note">{{ error ? $t('help.error') : $t('help.loading') }}</p>
      </template>

      <template v-else-if="page">
        <a
          class="help-manual-back"
          @click="show(null)">‹ {{ $t('help.title') }}</a>
        <h1 class="panel-default-title help-manual-title">
          <svgicon
            v-if="page.icon"
            class="help-manual-title-icon"
            :name="page.icon" />
          <span>{{ page.title }}</span>
          <span
            v-if="page.status === 'draft'"
            class="help-badge">{{ $t('help.draft') }}</span>
        </h1>

        <div
          class="help-content"
          v-html="rendered"
          @click="onContentClick"></div>

        <div
          v-if="related.length"
          class="help-related">
          <span class="help-related-label">{{ $t('help.related') }}</span>
          <button
            v-for="r in related"
            :key="r.slug"
            type="button"
            class="help-related-chip"
            @click="show(r.slug)">
            {{ r.title }}
          </button>
        </div>

        <p class="help-speed">
          <template v-if="page.speed_sensitive">{{ $t('help.numbers_for', [speedName]) }}</template>
          <template v-else>{{ $t('help.same_all_speeds') }}</template>
        </p>
      </template>

      <template v-else>
        <h1 class="panel-default-title">{{ $t('panel.help.manual_title') }}</h1>

        <input
          v-model="query"
          type="search"
          class="help-manual-search"
          :placeholder="$t('help.search')"
          autocomplete="off"
          spellcheck="false" />

        <template v-if="query.trim()">
          <h2 class="help-manual-section">{{ $t('help.results_for', [query.trim()]) }}</h2>
          <p
            v-if="results.length === 0"
            class="help-manual-note">{{ $t('help.no_results') }}</p>
          <ul
            v-else
            class="help-manual-list">
            <li
              v-for="p in results"
              :key="p.slug">
              <a @click="show(p.slug)">{{ p.title }}</a>
              <span class="help-manual-muted">{{ categoryTitle(p.category) }}</span>
            </li>
          </ul>
        </template>

        <template v-else>
          <div
            v-for="cat in categories"
            :key="cat.key">
            <h2 class="help-manual-section">{{ cat.title }}</h2>
            <ul class="help-manual-list is-columns">
              <li
                v-for="p in cat.pages"
                :key="p.slug">
                <a @click="show(p.slug)">{{ p.title }}</a>
              </li>
            </ul>
          </div>

          <h2 class="help-manual-section">{{ $t('help.glossary') }}</h2>
          <dl class="help-manual-glossary">
            <template v-for="entry in bundle.glossary">
              <dt :key="`t-${entry.term}-${entry.slug}`">{{ entry.term }}</dt>
              <dd :key="`d-${entry.term}-${entry.slug}`"><a @click="show(entry.slug)">{{ entry.title }}</a></dd>
            </template>
          </dl>
        </template>
      </template>
    </v-scrollbar>
  </div>
</template>

<script>
// Full manual inside the Help drawer: search, table of contents, glossary,
// page view. Same bundle and renderer as the help modal.
import svgicon from 'vue-svgicon';
import { renderHelpHtml, makeIconLookup, searchPages } from '@/game/help/render';

const lookupIcon = makeIconLookup(svgicon.icons);

export default {
  name: 'help-manual-panel',
  data() {
    return {
      slug: null,
      query: '',
    };
  },
  computed: {
    bundle() { return this.$store.state.help.bundle; },
    error() { return this.$store.state.help.error; },
    page() { return this.slug ? this.$store.getters['help/page'](this.slug) : null; },
    rendered() { return this.page ? renderHelpHtml(this.page.html, lookupIcon) : ''; },
    related() {
      if (!this.page) return [];
      return (this.page.related || [])
        .map((s) => this.$store.getters['help/page'](s))
        .filter(Boolean)
        .map((p) => ({ slug: p.slug, title: p.title }));
    },
    categories() {
      if (!this.bundle) return [];
      const bySlug = {};
      this.bundle.pages.forEach((p) => { bySlug[p.slug] = p; });
      return this.bundle.categories.map((cat) => ({
        key: cat.key,
        title: this.categoryTitle(cat.key),
        pages: cat.slugs.map((s) => bySlug[s]).filter(Boolean)
          .sort((a, b) => a.title.localeCompare(b.title)),
      }));
    },
    results() {
      return this.bundle ? searchPages(this.bundle.pages, this.query) : [];
    },
    speedName() {
      return this.$t(`data.speed.${this.$store.getters['help/speed']}.name`);
    },
  },
  methods: {
    // Called by HelpPanel.open({ page }) for deep links and the modal's Expand.
    show(slug) {
      this.$store.dispatch('help/load');
      this.slug = slug ? (this.$store.getters['help/resolve'](slug) || slug) : null;
    },
    categoryTitle(key) {
      const cat = this.bundle && this.bundle.categories.find((c) => c.key === key);
      return cat ? cat.title : key;
    },
    onContentClick(event) {
      const link = event.target.closest && event.target.closest('a[data-help]');
      if (!link) return;
      event.preventDefault();
      this.show(link.dataset.help);
    },
  },
  mounted() {
    this.$store.dispatch('help/load');
  },
};
</script>
