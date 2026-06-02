<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1>
          <strong>{{ totalMaps }}</strong> {{ $t('page.create.maps.header_unit') }}
        </h1>

        <router-link
          to="/create/map/new"
          class="default-button">
          {{ $t('page.create.maps.new') }}
        </router-link>
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
              <td>
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
    };
  },
  methods: {
    async loadData() {
      const resp = await this.releaseLoading(this.$axios.get('/maps'));
      this.maps = resp.data;
      this.totalMaps = resp.headers.total;
    },
  },
  mounted() {
    this.loadData();
  },
  components: {
    LoadingMask,
  },
};
</script>
