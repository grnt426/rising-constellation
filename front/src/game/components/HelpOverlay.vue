<template>
  <div
    v-if="isOpen"
    class="help-overlay"
    :class="`f-${theme}`"
    tabindex="-1"
    ref="root"
    @keydown.esc.stop="close">
    <div class="help-overlay-header">
      <button
        v-if="history.length > 1"
        v-tooltip="$t('help.back')"
        class="help-overlay-button"
        type="button"
        @click="back">
        <svgicon name="caret-left" />
      </button>
      <span class="help-overlay-kicker">{{ $t('help.title') }}</span>
      <span class="help-overlay-spacer"></span>
      <button
        v-if="page"
        v-tooltip="copied ? $t('help.copied') : $t('help.copy_link')"
        class="help-overlay-button"
        type="button"
        @click="copyLink">
        <svgicon name="share" />
      </button>
      <button
        v-if="page"
        v-tooltip="$t('help.expand')"
        class="help-overlay-button"
        type="button"
        @click="expand">
        <svgicon name="layers" />
      </button>
      <button
        v-tooltip="$t('help.close')"
        class="help-overlay-button"
        type="button"
        @click="close">
        <svgicon name="close" />
      </button>
    </div>

    <div class="help-overlay-body">
      <template v-if="loading">
        <p class="help-overlay-note">{{ $t('help.loading') }}</p>
      </template>
      <template v-else-if="error">
        <p class="help-overlay-note">{{ $t('help.error') }}</p>
      </template>
      <template v-else-if="!page">
        <p class="help-overlay-note">{{ $t('help.unavailable') }}</p>
      </template>
      <template v-else>
        <h1 class="help-overlay-title">
          <svgicon
            v-if="page.icon"
            class="help-overlay-title-icon"
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
            @click="navigate(r.slug)">
            {{ r.title }}
          </button>
        </div>

        <p class="help-speed">
          <template v-if="page.speed_sensitive">
            {{ $t('help.numbers_for', [speedName]) }}
          </template>
          <template v-else>
            {{ $t('help.same_all_speeds') }}
          </template>
        </p>
      </template>
    </div>
  </div>
</template>

<script>
// "What is this?" modal for the help manual, opened by the "?" buttons
// (HelpButton) and by deep links. Same root-bus pattern as SearchOverlay /
// QuickCalc: `openHelp({ page })`, `toggleHelp`, `closeHelp`. The Expand
// button hands the page to the Help drawer's Manual tab.
import svgicon from 'vue-svgicon';
import config from '@/config';
import { copyToClipboard } from '@/utils/clipboard';
import { renderHelpHtml, makeIconLookup, publicHelpUrl } from '@/game/help/render';

const lookupIcon = makeIconLookup(svgicon.icons);
// Origin that serves Phoenix static files (/img/help/...): the prod site in
// production and Steam builds, the page's own origin in dev (Phoenix, or the
// vue dev server, which proxies /img to Phoenix).
const helpOrigin = () => config.BASE_URL || window.location.origin;

export default {
  name: 'help-overlay',
  data() {
    return {
      isOpen: false,
      history: [], // slugs, current last
      copied: false,
    };
  },
  computed: {
    theme() { return this.$store.getters['game/theme']; },
    loading() { return this.$store.state.help.loading; },
    error() { return this.$store.state.help.error; },
    slug() { return this.history[this.history.length - 1] || null; },
    page() { return this.slug ? this.$store.getters['help/page'](this.slug) : null; },
    rendered() { return this.page ? renderHelpHtml(this.page.html, lookupIcon, { origin: helpOrigin() }) : ''; },
    // Account setting (Settings > income per hour), followed at every speed:
    // the compiled page carries both variants, CSS picks one.
    unitsPerHour() { return this.$store.state.portal.settings.incomePerHour === true; },
    related() {
      if (!this.page) return [];
      return (this.page.related || [])
        .map((slug) => this.$store.getters['help/page'](slug))
        .filter(Boolean)
        .map((p) => ({ slug: p.slug, title: p.title }));
    },
    speedName() {
      const speed = this.$store.getters['help/speed'];
      return this.$t(`data.speed.${speed}.name`);
    },
  },
  methods: {
    open({ page } = {}) {
      if (!page) return;
      this.$store.dispatch('help/load');
      if (!this.isOpen) this.history = [];
      // Open first: navigate's $nextTick queries the rendered modal, and
      // while v-if is still false $el is only a comment node.
      this.isOpen = true;
      this.navigate(page);
      this.$nextTick(() => { if (this.$refs.root) this.$refs.root.focus(); });
    },
    toggle(data) {
      if (this.isOpen) this.close();
      else this.open(data);
    },
    close() {
      this.isOpen = false;
      this.history = [];
      this.copied = false;
    },
    navigate(slug) {
      const canonical = this.$store.getters['help/resolve'](slug) || slug;
      if (this.slug !== canonical) this.history = [...this.history, canonical];
      this.copied = false;
      this.$nextTick(() => {
        const body = this.$refs.root && this.$refs.root.querySelector('.help-overlay-body');
        if (body) body.scrollTop = 0;
      });
    },
    back() {
      if (this.history.length > 1) this.history = this.history.slice(0, -1);
    },
    onContentClick(event) {
      const link = event.target.closest && event.target.closest('a[data-help]');
      if (!link) return;
      event.preventDefault();
      this.navigate(link.dataset.help);
      this.scrollToAnchor(link.dataset.anchor);
    },
    // Section links ([[alias]] of a guide section) carry data-anchor. Runs
    // after navigate's own scroll-to-top, once the new page is rendered.
    scrollToAnchor(anchor) {
      if (!anchor) return;
      this.$nextTick(() => {
        const target = this.$refs.root && this.$refs.root.querySelector(`[id="${anchor}"]`);
        if (target) target.scrollIntoView({ block: 'start' });
      });
    },
    expand() {
      const { slug } = this;
      this.close();
      this.$root.$emit('togglePanel', 'help', { page: slug });
    },
    async copyLink() {
      const ok = await copyToClipboard(publicHelpUrl(helpOrigin(), this.slug, this.$store.getters['help/speed']));
      this.copied = ok;
    },
  },
  mounted() {
    this.$root.$on('openHelp', this.open);
    this.$root.$on('toggleHelp', this.toggle);
    this.$root.$on('closeHelp', this.close);
  },
  beforeDestroy() {
    this.$root.$off('openHelp', this.open);
    this.$root.$off('toggleHelp', this.toggle);
    this.$root.$off('closeHelp', this.close);
  },
};
</script>
