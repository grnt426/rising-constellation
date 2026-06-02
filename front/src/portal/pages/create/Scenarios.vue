<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1>
          <strong>{{ totalScenarios }}</strong> {{ $t('page.create.scenarios.header_unit') }}
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
            v-model="filters.speed"
            @change="onFilterChange">
            <option value="">{{ $t('page.create.scenarios.speed_any') }}</option>
            <option
              v-for="speed in speedChoices"
              :key="speed"
              :value="speed">
              {{ $t(`data.speed.${speed}.name`) }}
            </option>
          </select>

          <select
            class="forge-size-filter"
            v-model="filters.factions"
            @change="onFilterChange">
            <option value="">{{ $t('page.create.scenarios.factions_any') }}</option>
            <option
              v-for="n in factionChoices"
              :key="n"
              :value="n">
              {{ n }}
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
          v-if="scenarios.length === 0"
          class="full-sized-text">
          {{ $t('page.create.scenarios.no_results') }}
        </div>
        <template v-else>
          <table class="default-table scenarios-table">
            <tr
              v-for="scenario in scenarios"
              :key="scenario.id">
              <td>
                <h2>{{ scenario.game_metadata.name }}</h2>
                <em>
                  {{ $t(`map.size.${scenario.game_metadata.size}.toast`) }},
                  {{ scenario.game_metadata.factions.length }} factions,
                  {{ $t(`data.speed.${scenario.game_metadata.speed}.name`) }}
                  <span
                    class="toast"
                    v-if="!scenario.author && scenario.is_official">
                    {{ $t('page.create.scenarios.official') }}
                  </span>
                  <span
                    class="toast"
                    v-else-if="scenario.author">
                    {{ $t('page.create.common.by') }} {{ scenario.author.name }}
                  </span>
                  <span
                    class="toast"
                    v-if="!scenario.published_at">
                    {{ $t('page.create.common.draft') }}
                  </span>
                </em>
              </td>
              <td class="reactions">
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.like')"
                  @click="react(scenario, 'likes')">
                  <svgicon name="check" />
                  <span>{{ scenario.likes || 0 }}</span>
                </button>
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.dislike')"
                  @click="react(scenario, 'dislikes')">
                  <svgicon name="close" />
                  <span>{{ scenario.dislikes || 0 }}</span>
                </button>
                <button
                  class="reaction-button"
                  v-tooltip="$t('page.create.common.favorite')"
                  @click="react(scenario, 'favorites')">
                  <svgicon name="bookmark" />
                  <span>{{ scenario.favorites || 0 }}</span>
                </button>
              </td>
              <td class="actions">
                <router-link
                  class="default-button"
                  :to="`/create/scenario/edit/${scenario.id}`">
                  {{ $t('page.create.scenarios.edit') }}
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

        <hr class="margin">
      </v-scrollbar>
      <loading-mask v-else />
    </div>

    <v-scrollbar class="panel-aside">
      <div class="panel-aside-info">
        <h2>{{ $t('page.create.scenarios.about_heading') }}</h2>
        <p v-html="$t('page.create.scenarios.about_body')"></p>
      </div>
      <div class="panel-aside-info">
        <h2>{{ $t('page.create.scenarios.roadmap_heading') }}</h2>
        <p v-html="$t('page.create.scenarios.roadmap_body')"></p>
      </div>
      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
import Loading from '@/portal/mixins/Loading';

import LoadingMask from '@/portal/components/LoadingMask.vue';

export default {
  name: 'create-scenarios',
  mixins: [Loading],
  data() {
    return {
      scenarios: [],
      totalScenarios: 0,
      totalPages: 1,
      page: 1,
      sizeChoices: [80, 120, 200, 360, 500, 750],
      speedChoices: ['fast', 'medium', 'slow'],
      // Maps wizard caps at 8 factions; surfacing 2-8 covers every
      // valid scenario without dragging in counts the UI can't produce.
      factionChoices: [2, 3, 4, 5, 6, 7, 8],
      sortOptions: ['newest', 'most_liked', 'most_favorited'],
      chipChoices: ['all', 'officials', 'mine', 'favorited', 'drafts'],
      activeChip: 'all',
      filters: {
        name: '',
        size: '',
        speed: '',
        factions: '',
        sort: 'newest',
      },
      debouncedReload: null,
    };
  },
  methods: {
    async loadData() {
      const params = { page: this.page, sort: this.filters.sort };
      if (this.filters.name) params.name = this.filters.name;
      if (this.filters.size) params.size = this.filters.size;
      if (this.filters.speed) params.speed = this.filters.speed;
      if (this.filters.factions) params.factions = this.filters.factions;
      if (this.activeChip !== 'all') params[this.activeChip] = 'true';

      const resp = await this.releaseLoading(this.$axios.get('/scenarios', { params }));
      this.scenarios = resp.data;
      this.totalScenarios = parseInt(resp.headers.total, 10) || 0;
      this.totalPages = parseInt(resp.headers['total-pages'], 10) || 1;
    },
    setChip(chip) {
      this.activeChip = this.activeChip === chip ? 'all' : chip;
      this.page = 1;
      this.loadData();
    },
    onFilterInput() {
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
    async react(scenario, kind) {
      try {
        await this.$axios.post(`/scenarios/${scenario.id}/folders/${kind}`);
        this.$set(scenario, kind, (scenario[kind] || 0) + 1);
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
