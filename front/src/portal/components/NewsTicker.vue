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
// row has `{id, key, data, inserted_at}`. The key — e.g.
// `news.colonize.first` — selects a template under the `news.*` tree
// in portal.json. For now every public news event uses the
// `.public` visibility tier; once we wire in-game variants we'll
// pick the tier from the viewer's faction relation to event
// participants.
//
// Polls on a slow cadence — news updates don't need to be real-time
// on the portal page; the toast pipeline (when wired) is what gives
// players the immediate signal in-game.
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
      // Map the backend event key (e.g. "news.colonize.first") to a
      // template key under "news.*" in portal.json. We default to a
      // generic placeholder if we don't have a template — that lets
      // backend ship new event types before the frontend has caught
      // up without rendering a literal i18n key string at the user.
      const tier = 'public';
      const baseKey = item.key.startsWith('news.')
        ? item.key.slice('news.'.length)
        : item.key;
      const templateKey = `news.${baseKey}.${tier}`;

      if (!this.$te(templateKey)) {
        return this.$t('news.unknown_event');
      }

      return this.$t(templateKey, this.buildParams(item.data));
    },
    buildParams(data) {
      // Translate raw payload fields into display-ready substitutions.
      // Faction atom (e.g. "tetrarchy") becomes the localized faction
      // name; pass through other named fields unchanged.
      const params = { ...data };

      if (data && data.faction) {
        const factionKey = `data.faction.${data.faction}.name`;
        if (this.$te(factionKey)) {
          params.faction = this.$t(factionKey);
        }
      }

      return params;
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
