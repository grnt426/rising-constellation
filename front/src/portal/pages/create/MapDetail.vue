<template>
  <default-layout>
    <div
      v-if="loaded && map"
      class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc forge-detail-head">
          <h1>{{ map.game_metadata.name }}</h1>
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
          <p
            v-if="map.game_metadata.description"
            class="forge-detail-description">
            {{ map.game_metadata.description }}
          </p>
        </div>

        <div class="panel-aside-info">
          <p>
            <strong>{{ systemCount }}</strong>
            {{ $t('page.create.scenario_editor.summary_systems') }}
          </p>
          <p>
            <strong>{{ sectorCount }}</strong>
            {{ $t('page.create.scenario_editor.summary_sectors') }}
          </p>
          <p>
            <strong>{{ map.plays || 0 }}</strong>
            {{ $t('page.create.common.plays') }}
          </p>
          <div class="reactions editor-reactions">
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.like')"
              @click="react('likes')">
              <svgicon name="check" />{{ map.likes || 0 }}
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.dislike')"
              @click="react('dislikes')">
              <svgicon name="close" />{{ map.dislikes || 0 }}
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.favorite')"
              @click="react('favorites')">
              <svgicon name="bookmark" />{{ map.favorites || 0 }}
            </button>
          </div>
        </div>

        <hr class="separator">

        <div class="panel-aside-bloc">
          <button
            class="default-button fullsized"
            @click="share">
            {{ $t('page.create.common.share') }}
          </button>
          <router-link
            class="default-button fullsized"
            :to="`/create/map/${map.id}`">
            {{ $t('page.create.maps.edit') }}
          </router-link>
          <router-link
            class="default-button fullsized"
            :to="`/create/scenario/new/${map.id}`">
            {{ $t('page.create.maps.use_for_scenario') }}
          </router-link>
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-square">
        <router-link
          class="close-button"
          to="/create/maps">
          {{ $t('page.create.common.back') }}
        </router-link>

        <div class="content">
          <galaxy-preview
            :game-data="map.game_data"
            :size="mapSize" />
        </div>
      </div>
    </div>
    <loading-mask v-else />
  </default-layout>
</template>

<script>
import config from '@/config';
import { copyToClipboard } from '@/utils/clipboard';

import Loading from '@/portal/mixins/Loading';
import DefaultLayout from '@/portal/layouts/Default.vue';
import LoadingMask from '@/portal/components/LoadingMask.vue';
import GalaxyPreview from '@/portal/components/GalaxyPreview.vue';

export default {
  name: 'create-map-detail',
  mixins: [Loading],
  data() {
    return {
      map: null,
    };
  },
  computed: {
    mapSize() {
      return this.map.game_data.size || this.map.game_metadata.size;
    },
    // Older rows can miss the denormalized metadata counters — fall back
    // to counting game_data directly.
    systemCount() {
      return this.map.game_metadata.system_number || (this.map.game_data.systems || []).length;
    },
    sectorCount() {
      return this.map.game_metadata.sector_number || (this.map.game_data.sectors || []).length;
    },
  },
  methods: {
    async loadData() {
      try {
        const resp = await this.releaseLoading(this.$axios.get(`/maps/${this.$route.params.id}`));
        this.map = resp.data;
      } catch (err) {
        this.$router.push('/create/maps');
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    async share() {
      const copied = await copyToClipboard(`${config.BASE_URL}/forge/map/${this.map.id}`);
      if (copied) {
        this.$toasted.success(this.$t('page.create.common.share_copied'));
      } else {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    async react(kind) {
      try {
        await this.$axios.post(`/maps/${this.map.id}/folders/${kind}`);
        this.$set(this.map, kind, (this.map[kind] || 0) + 1);
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
  },
  mounted() {
    this.loadData();
  },
  components: {
    DefaultLayout,
    LoadingMask,
    GalaxyPreview,
  },
};
</script>
