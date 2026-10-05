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
          :class="{ 'help-units-hour': unitsPerHour }"
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
          <nav
            v-if="featured.pages.length"
            class="help-featured"
            :aria-label="featured.title">
            <h2 class="help-manual-section">{{ featured.title }}</h2>
            <ol>
              <li
                v-for="(p, index) in featured.pages"
                :key="p.slug">
                <button
                  type="button"
                  class="help-featured-card"
                  @click="show(p.slug)">
                  <span
                    class="help-featured-step"
                    aria-hidden="true">{{ index + 1 }}</span>
                  <span class="help-featured-name">{{ p.title }}</span>
                  <span class="help-featured-summary">{{ p.summary }}</span>
                </button>
              </li>
            </ol>
          </nav>

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
import config from '@/config';
import {
  renderHelpHtml, makeIconLookup, searchPages, applyHelpAnchor,
} from '@/game/help/render';

const lookupIcon = makeIconLookup(svgicon.icons);

export default {
  name: 'help-manual-panel',
  data() {
    return {
      slug: null,
      query: '',
      anchor: null, // anchor still to open the current page at
    };
  },
  watch: {
    // An anchor asked for before the manual has loaded waits for the page.
    rendered() { this.$nextTick(this.applyAnchor); },
  },
  computed: {
    bundle() { return this.$store.state.help.bundle; },
    error() { return this.$store.state.help.error; },
    page() { return this.slug ? this.$store.getters['help/page'](this.slug) : null; },
    rendered() {
      return this.page
        ? renderHelpHtml(this.page.html, lookupIcon, { origin: config.BASE_URL || window.location.origin })
        : '';
    },
    // Account setting (Settings > income per hour), followed at every speed.
    unitsPerHour() { return this.$store.state.portal.settings.incomePerHour === true; },
    related() {
      if (!this.page) return [];
      return (this.page.related || [])
        .map((s) => this.$store.getters['help/page'](s))
        .filter(Boolean)
        .map((p) => ({ slug: p.slug, title: p.title }));
    },
    // The Basics of Play pages: cards above the list, in reading order.
    featured() {
      return (this.bundle && this.bundle.featured) || { title: '', pages: [] };
    },
    categories() {
      if (!this.bundle) return [];
      const bySlug = {};
      this.bundle.pages.forEach((p) => { bySlug[p.slug] = p; });
      const carded = this.featured.pages.map((p) => p.slug);
      return this.bundle.categories.map((cat) => ({
        key: cat.key,
        title: this.categoryTitle(cat.key),
        pages: cat.slugs.filter((s) => !carded.includes(s)).map((s) => bySlug[s]).filter(Boolean)
          .sort((a, b) => a.title.localeCompare(b.title)),
      })).filter((cat) => cat.pages.length);
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
    // An alias can name a part of its page (a guide's section, one level of
    // a patent): the page opens there.
    show(slug, anchor) {
      this.$store.dispatch('help/load');
      this.slug = slug ? (this.$store.getters['help/resolve'](slug) || slug) : null;
      this.anchor = (slug && (anchor || this.$store.getters['help/anchor'](slug))) || null;
      this.$nextTick(this.applyAnchor);
    },
    applyAnchor() {
      if (this.anchor && applyHelpAnchor(this.$el, this.anchor)) this.anchor = null;
    },
    categoryTitle(key) {
      const cat = this.bundle && this.bundle.categories.find((c) => c.key === key);
      return cat ? cat.title : key;
    },
    onContentClick(event) {
      const link = event.target.closest && event.target.closest('a[data-help]');
      if (!link) return;
      event.preventDefault();
      // Section links ([[alias]] of a guide section) and links to one level
      // of a patent carry data-anchor.
      this.show(link.dataset.help, link.dataset.anchor);
    },
  },
  mounted() {
    this.$store.dispatch('help/load');
  },
};
</script>
