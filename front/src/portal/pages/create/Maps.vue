<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1>
          <strong>{{ totalMaps }}</strong> {{ $t('page.create.maps.header_unit') }}
        </h1>

        <div class="forge-toolbar">
          <input
            type="text"
            class="forge-search"
            :placeholder="$t('page.create.common.search_placeholder')"
            v-model="filters.name"
            @input="onFilterInput" />

          <select
            class="forge-size-filter"
            v-model="filters.size"
            @change="onFilterChange">
            <option value="">{{ $t('page.create.common.size_any') }}</option>
            <option
              v-for="size in sizeChoices"
              :key="size"
              :value="size">
              {{ $t(`map.size.${size}.label`) }}
            </option>
          </select>

          <select
            class="forge-size-filter"
            v-model="filters.sort"
            @change="onFilterChange">
            <option
              v-for="opt in sortOptions"
              :key="opt"
              :value="opt">
              {{ $t(`page.create.common.sort.${opt}`) }}
            </option>
          </select>

          <router-link
            to="/create/map/new"
            class="default-button">
            {{ $t('page.create.maps.new') }}
          </router-link>
        </div>

        <div class="forge-chips">
          <button
            v-for="chip in chipChoices"
            :key="chip"
            class="forge-chip"
            :class="{ 'is-active': activeChip === chip }"
            @click="setChip(chip)">
            {{ $t(`page.create.common.chip.${chip}`) }}
          </button>
        </div>
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <div
          v-if="maps.length === 0"
          class="full-sized-text">
          {{ $t('page.create.maps.no_results') }}
        </div>
        <template v-else>
          <table class="default-table maps-table">
            <tr
              v-for="map in maps"
              :key="map.id">
              <td>
                <h2>{{ map.game_metadata.name }}</h2>
                <em>
                  {{ $t(`map.size.${map.game_metadata.size}.toast`) }}
                  <span
                    class="toast"
                    v-if="!map.author && map.is_official">
                    {{ $t('page.create.maps.official') }}
                  </span>
                  <span
                    class="toast"
                    v-else-if="map.author">
                    {{ $t('page.create.common.by') }} {{ map.author.name }}
                  </span>
                  <span
                    class="toast"
                    v-if="!map.published_at">
                    {{ $t('page.create.common.draft') }}
                  </span>
                </em>
              </td>
              <td class="reactions">
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.like')"
                  @click="react(map, 'likes')">
                  <svgicon name="check" />
                  <span>{{ map.likes || 0 }}</span>
                </button>
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.dislike')"
                  @click="react(map, 'dislikes')">
                  <svgicon name="close" />
                  <span>{{ map.dislikes || 0 }}</span>
                </button>
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.favorite')"
                  @click="react(map, 'favorites')">
                  <svgicon name="bookmark" />
                  <span>{{ map.favorites || 0 }}</span>
                </button>
              </td>
              <td class="actions">
                <router-link
                  class="default-button"
                  :to="`/create/map/${map.id}`">
                  {{ $t('page.create.maps.edit') }}
                </router-link>
                <router-link
                  class="default-button"
                  :to="`/create/scenario/new/${map.id}`">
                  {{ $t('page.create.maps.use_for_scenario') }}
                </router-link>
              </td>
            </tr>
          </table>

          <div
            v-if="totalPages > 1"
            class="forge-pagination">
            <button
              class="default-button"
              :disabled="page <= 1"
              @click="goToPage(page - 1)">
              <svgicon name="caret-left" /> {{ $t('page.create.common.previous') }}
            </button>
            <span class="forge-pagination-info">
              {{ $t('page.create.common.page_of', { current: page, total: totalPages }) }}
            </span>
            <button
              class="default-button"
              :disabled="page >= totalPages"
              @click="goToPage(page + 1)">
              {{ $t('page.create.common.next') }} <svgicon name="caret-right" />
            </button>
          </div>
        </template>
      </v-scrollbar>
      <loading-mask v-else />
    </div>

    <v-scrollbar class="panel-aside">
      <div class="panel-aside-info">
        <h2>{{ $t('page.create.maps.about_heading') }}</h2>
        <p v-html="$t('page.create.maps.about_body')"></p>
      </div>
      <div class="panel-aside-info">
        <h2>{{ $t('page.create.maps.roadmap_heading') }}</h2>
        <p v-html="$t('page.create.maps.roadmap_body')"></p>
      </div>
      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
import Loading from '@/portal/mixins/Loading';
import LoadingMask from '@/portal/components/LoadingMask.vue';

export default {
  name: 'create-maps',
  mixins: [Loading],
  data() {
    return {
      maps: [],
      totalMaps: 0,
      totalPages: 1,
      page: 1,
      // Mirrors the wizard's choices in Map.vue:582. Kept literal here so
      // the dropdown doesn't depend on having a Map open first.
      sizeChoices: [80, 120, 200, 360, 500, 750],
      sortOptions: ['newest', 'most_liked', 'most_favorited'],
      chipChoices: ['all', 'officials', 'mine', 'favorited', 'drafts'],
      activeChip: 'all',
      filters: {
        name: '',
        size: '',
        sort: 'newest',
      },
      // Debounced reloader, created in `created()` so each component
      // instance gets its own cancelable timer.
      debouncedReload: null,
    };
  },
  methods: {
    async loadData() {
      // Build params, dropping any blank values so the backend doesn't
      // try to filter on an empty string (game_metadata->>'name' like '%')
      // would still match every row, but `size: ""` would crash
      // String.to_integer/1 on the server.
      const params = { page: this.page, sort: this.filters.sort };
      if (this.filters.name) params.name = this.filters.name;
      if (this.filters.size) params.size = this.filters.size;
      // Chip filter — only one is active at a time. 'all' sends nothing.
      if (this.activeChip !== 'all') params[this.activeChip] = 'true';

      const resp = await this.releaseLoading(this.$axios.get('/maps', { params }));
      this.maps = resp.data;
      this.totalMaps = parseInt(resp.headers.total, 10) || 0;
      this.totalPages = parseInt(resp.headers['total-pages'], 10) || 1;
    },
    setChip(chip) {
      // Toggle off if you click the active chip — Vue chip components
      // usually behave this way, and "All" is the off-state anyway.
      this.activeChip = this.activeChip === chip ? 'all' : chip;
      this.page = 1;
      this.loadData();
    },
    onFilterInput() {
      // Reset to page 1 on every change — staying on page 5 of a filter
      // that only has 2 pages of results just shows an empty list.
      this.page = 1;
      this.debouncedReload();
    },
    onFilterChange() {
      this.page = 1;
      this.loadData();
    },
    goToPage(target) {
      if (target < 1 || target > this.totalPages) return;
      this.page = target;
      this.loadData();
    },
    async react(map, kind) {
      try {
        await this.$axios.post(`/maps/${map.id}/folders/${kind}`);
        // Optimistic UI — bump the count locally so the user sees
        // immediate feedback. Backend is the source of truth on reload.
        this.$set(map, kind, (map[kind] || 0) + 1);
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
  },
  created() {
    this.debouncedReload = this._.debounce(this.loadData, 300);
  },
  mounted() {
    this.loadData();
  },
  components: {
    LoadingMask,
  },
};
</script>
