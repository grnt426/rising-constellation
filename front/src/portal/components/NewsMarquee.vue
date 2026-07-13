<template>
  <div
    v-if="items.length > 0"
    class="news-marquee"
    :title="$t('page.instance.news_heading')">
    <span class="news-marquee-label">
      <svgicon class="icon" name="disc" />
    </span>
    <div class="news-marquee-viewport">
      <div
        class="news-marquee-track"
        :style="{ animationDuration: `${scrollSeconds}s` }">
        <span
          v-for="item in items"
          :key="`mq-${item.id}`"
          class="news-marquee-item"
          v-html="renderItem(item)"></span>
        <!-- duplicated run so the loop is seamless -->
        <span
          v-for="item in items"
          :key="`mq2-${item.id}`"
          class="news-marquee-item"
          aria-hidden="true"
          v-html="renderItem(item)"></span>
      </div>
    </div>
  </div>
</template>

<script>
// Scrolling news marquee for the /portal/play/:speed game lists.
//
// Shows the latest 5 public bulletins across all public instances,
// each prefixed with the game's name. Deliberately narrow — the
// design constrains it to roughly the first third of the row on wide
// monitors (a full-width crawler is obnoxious), with a floor so the
// text stays readable on smaller screens. See the .news-marquee
// width clamp below.
import { renderNews } from '@/utils/news';

const POLL_INTERVAL_MS = 60 * 1000;
// Seconds of animation per item — slow enough to read comfortably.
const SECONDS_PER_ITEM = 8;

export default {
  name: 'news-marquee',
  data() {
    return {
      items: [],
      polling: null,
    };
  },
  computed: {
    scrollSeconds() {
      return Math.max(20, this.items.length * SECONDS_PER_ITEM);
    },
  },
  methods: {
    async fetchNews() {
      try {
        const { data } = await this.$axios.get('/news/recent');
        this.items = data.news || [];
      } catch (err) {
        this.items = [];
      }
    },
    renderItem(item) {
      const headline = renderNews(this, item);
      return item.instance_name
        ? `<strong>${this.escapeHtml(item.instance_name)}</strong> — ${headline}`
        : headline;
    },
    escapeHtml(text) {
      const div = document.createElement('div');
      div.textContent = text;
      return div.innerHTML;
    },
  },
  mounted() {
    this.fetchNews();
    this.polling = setInterval(() => this.fetchNews(), POLL_INTERVAL_MS);
  },
  beforeDestroy() {
    if (this.polling) clearInterval(this.polling);
  },
};
</script>

<style lang="scss" scoped>
.news-marquee {
  display: flex;
  align-items: center;
  gap: 8px;
  // Design call: only ~the first third of the row on wide screens,
  // but never narrower than ~48ch so a headline stays readable.
  width: clamp(420px, 33%, 640px);
  padding: 4px 10px;
  overflow: hidden;

  .news-marquee-label .icon {
    width: 10px;
    height: 10px;
    fill: currentColor;
    opacity: 0.6;
    animation: news-pulse 2s ease-in-out infinite;
  }

  .news-marquee-viewport {
    flex: 1 1 auto;
    overflow: hidden;
    white-space: nowrap;
    // fade the clipped edges so items slide in/out gracefully
    mask-image: linear-gradient(to right, transparent, black 24px, black calc(100% - 24px), transparent);
  }

  .news-marquee-track {
    display: inline-block;
    white-space: nowrap;
    animation-name: news-scroll;
    animation-timing-function: linear;
    animation-iteration-count: infinite;

    &:hover {
      animation-play-state: paused;
    }
  }

  .news-marquee-item {
    display: inline-block;
    padding-right: 4em;
    opacity: 0.85;
  }
}

@keyframes news-scroll {
  from { transform: translateX(0); }
  to { transform: translateX(-50%); }
}

@keyframes news-pulse {
  0%, 100% { opacity: 0.35; }
  50% { opacity: 0.9; }
}
</style>
