<template>
  <default-layout>
    <div
      v-if="loaded && scenario"
      class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc forge-detail-head">
          <h1>{{ scenario.game_metadata.name }}</h1>
          <em>
            {{ $t(`map.size.${scenario.game_metadata.size}.toast`) }}
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
            <span
              v-for="mut in mutators"
              :key="mut.key"
              class="toast mutator-chip"
              :title="$t(`data.mutator.${mut.key}.description`)">
              {{ $t(`data.mutator.${mut.key}.name`) }}
            </span>
          </em>
          <p
            v-if="scenario.game_metadata.description"
            class="forge-detail-description">
            {{ scenario.game_metadata.description }}
          </p>
        </div>

        <div class="panel-aside-info">
          <p>
            <strong>{{ $t(`data.speed.${scenario.game_metadata.speed}.name`) }}</strong>
            {{ $t('page.create.scenario_editor.scenario_speed') }}
          </p>
          <p>
            <strong>{{ (scenario.game_metadata.factions || []).length }}</strong>
            {{ $t('page.create.scenario_editor.summary_factions') }}
          </p>
          <p>
            <strong>{{ (scenario.game_data.systems || []).length }}</strong>
            {{ $t('page.create.scenario_editor.summary_systems') }}
          </p>
          <p>
            <strong>{{ (scenario.game_data.sectors || []).length }}</strong>
            {{ $t('page.create.scenario_editor.summary_sectors') }}
          </p>
          <p>
            <strong>{{ scenario.plays || 0 }}</strong>
            {{ $t('page.create.common.plays') }}
          </p>
          <div class="reactions editor-reactions">
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.like')"
              @click="react('likes')">
              <svgicon name="check" />{{ scenario.likes || 0 }}
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.dislike')"
              @click="react('dislikes')">
              <svgicon name="close" />{{ scenario.dislikes || 0 }}
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.favorite')"
              @click="react('favorites')">
              <svgicon name="bookmark" />{{ scenario.favorites || 0 }}
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
            :to="`/create/scenario/edit/${scenario.id}`">
            {{ $t('page.create.scenarios.edit') }}
          </router-link>
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-square">
        <router-link
          class="close-button"
          to="/create/scenarios">
          {{ $t('page.create.common.back') }}
        </router-link>

        <div class="content">
          <galaxy-preview
            :game-data="scenario.game_data"
            :size="scenarioSize"
            :faction-themes="factionThemes" />
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
  name: 'create-scenario-detail',
  mixins: [Loading],
  data() {
    return {
      scenario: null,
      mutatorIndex: {},
    };
  },
  computed: {
    scenarioSize() {
      return this.scenario.game_data.size || this.scenario.game_metadata.size;
    },
    // Sector fill by assigned faction — same theme classes the scenario
    // editor uses, keyed off the portal data store.
    factionThemes() {
      const catalog = (this.$store.state.portal.data || {}).faction || [];
      return catalog.reduce((acc, f) => {
        acc[f.key] = `theme-${f.theme}`;
        return acc;
      }, {});
    },
    mutators() {
      const list = this.scenario.game_metadata.mutators;
      if (!Array.isArray(list)) return [];
      return list.map((m) => this.mutatorIndex[m.key] || { key: m.key, name: m.key });
    },
  },
  methods: {
    async loadData() {
      try {
        const resp = await this.releaseLoading(this.$axios.get(`/scenarios/${this.$route.params.id}`));
        this.scenario = resp.data;
      } catch (err) {
        this.$router.push('/create/scenarios');
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    async share() {
      const copied = await copyToClipboard(`${config.BASE_URL}/forge/scenario/${this.scenario.id}`);
      if (copied) {
        this.$toasted.success(this.$t('page.create.common.share_copied'));
      } else {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    async react(kind) {
      try {
        await this.$axios.post(`/scenarios/${this.scenario.id}/folders/${kind}`);
        this.$set(this.scenario, kind, (this.scenario[kind] || 0) + 1);
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
  },
  mounted() {
    this.loadData();
    this.$axios.get('/data/mutators').then(({ data }) => {
      this.mutatorIndex = data.reduce((acc, m) => { acc[m.key] = m; return acc; }, {});
    }).catch(() => {});
  },
  components: {
    DefaultLayout,
    LoadingMask,
    GalaxyPreview,
  },
};
</script>
