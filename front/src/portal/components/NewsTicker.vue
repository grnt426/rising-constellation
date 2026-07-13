<template>
  <section class="panel-aside-info news-ticker">
    <h2>{{ $t('page.instance.news_heading') }}</h2>

    <ul
      v-if="items.length > 0"
      class="news-list">
      <li
        v-for="item in items"
        :key="`news-${item.id}`"
        class="news-item">
        <span
          class="news-text"
          v-html="renderItem(item)"></span>
        <span class="news-time">{{ relativeTime(item.inserted_at) }}</span>
      </li>
    </ul>

    <p
      v-else
      class="news-empty">
      {{ $t('page.instance.news_empty') }}
    </p>
  </section>
</template>

<script>
// Public news ticker for the /portal/instance/:iid right rail.
//
// Reads `GET /instances/:iid/news` (last 5 global news rows). Each
// row has `{id, key, data, inserted_at}` and renders through the
// shared utils/news.js renderer (public tier — portal viewers are
// outsiders).
//
// Polls on a slow cadence — news updates don't need to be real-time
// on the portal page; the in-game toast pipeline is what gives
// players the immediate signal.
import { renderNews } from '@/utils/news';

const POLL_INTERVAL_MS = 30 * 1000;

export default {
  name: 'news-ticker',
  props: {
    iid: {
      type: [String, Number],
      required: true,
    },
  },
  data() {
    return {
      items: [],
      polling: null,
    };
  },
  methods: {
    async fetchNews() {
      try {
        const { data } = await this.$axios.get(`/instances/${this.iid}/news`);
        this.items = data.news || [];
      } catch (err) {
        // Silent failure — news is non-critical UI. The empty state
        // is the same as "nothing to show" and looks the same to
        // the user.
        this.items = [];
      }
    },
    renderItem(item) {
      return renderNews(this, item);
    },
    relativeTime(iso) {
      // Lightweight relative-time formatter to avoid pulling in a
      // dayjs/luxon dep just for this. Floor to minutes/hours/days
      // and localize. If the timestamp is malformed, fall back to
      // showing nothing.
      if (!iso) return '';
      const then = new Date(iso).getTime();
      if (Number.isNaN(then)) return '';
      const deltaSec = Math.max(0, Math.floor((Date.now() - then) / 1000));
      if (deltaSec < 60) return `${deltaSec}s`;
      const deltaMin = Math.floor(deltaSec / 60);
      if (deltaMin < 60) return `${deltaMin}m`;
      const deltaHr = Math.floor(deltaMin / 60);
      if (deltaHr < 24) return `${deltaHr}h`;
      const deltaDay = Math.floor(deltaHr / 24);
      return `${deltaDay}d`;
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

<style scoped>
.news-ticker {
  /* Lives under panel-aside-info; inherits its padding + heading
     styles. The list itself is unstyled (no bullets), with each
     item compact and the relative-time floated subtly right. */
}

.news-list {
  list-style: none;
  margin: 0;
  padding: 0;
}

.news-item {
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding: 0.5em 0;
  display: flex;
  justify-content: space-between;
  gap: 0.75em;
  font-size: 0.95em;
  line-height: 1.4;
}

.news-item:first-child {
  border-top: none;
}

.news-text {
  flex: 1 1 auto;
}

.news-time {
  flex: 0 0 auto;
  opacity: 0.5;
  font-size: 0.85em;
  white-space: nowrap;
}

.news-empty {
  opacity: 0.6;
  font-style: italic;
}
</style>
