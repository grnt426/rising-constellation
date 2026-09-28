<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1 v-html="$tmd('page.play.slow.header')" />

        <router-link
          to="/play/slow/archive"
          class="default-button archive-button">
          <svgicon class="icon" name="ranking" />
          {{ $t('page.play.archive.view_archive') }}
        </router-link>

        <router-link
          to="/play/from-scenarios/slow"
          class="default-button">
          <svgicon class="icon" name="bookmark" />
          {{ $t('page.play.new_game') }}
        </router-link>
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <next-official-notice
          v-if="showingOpen && lobby"
          :next-official="lobby.next_official"
          :official-active="lobby.official_active"
          @updated="lobby.next_official = $event" />

        <div
          v-if="instances.length === 0"
          class="full-sized-text">
          {{ $t('page.play.no_game_found') }}
        </div>
        <template v-else>
          <table class="default-table instances-table">
            <template v-for="instance in listedInstances">
              <instance-row
                @open="$router.push(`/instance/${instance.id}`)"
                :key="instance.id"
                :instance="instance"
                :profiles="profiles" />
            </template>
          </table>
        </template>
      </v-scrollbar>

      <loading-mask v-else />

      <news-marquee />
    </div>

    <v-scrollbar class="panel-aside">
      <div class="panel-aside-bloc">
        <div class="radio-input is-horizontal">
          <div class="label">
            {{ $t('page.play.games') }}
          </div>
          <div class="content">
            <div
              v-for="{key, value, label} in availableStates"
              :key="`status-${key}`"
              class="content-item">
              <input
                type="radio"
                :id="`status-${key}`"
                :value="value"
                v-model="state">
              <label :for="`status-${key}`">
                <strong>{{ label }}</strong>
              </label>
            </div>
          </div>
        </div>
      </div>

      <div
        v-if="lobby && lobby.latest_result"
        class="panel-aside-bloc">
        <latest-official-result :result="lobby.latest_result" />
      </div>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
import Loading from '@/portal/mixins/Loading';
import InstanceList from '@/portal/mixins/InstanceList';

import LoadingMask from '@/portal/components/LoadingMask.vue';
import InstanceRow from '@/portal/components/InstanceRow.vue';
import NewsMarquee from '@/portal/components/NewsMarquee.vue';
import LatestOfficialResult from '@/portal/components/legacy/LatestOfficialResult.vue';
import NextOfficialNotice from '@/portal/components/legacy/NextOfficialNotice.vue';

export default {
  name: 'play-legacy',
  mixins: [Loading, InstanceList('slow')],
  data() {
    return {
      lobby: null,
      lobbyPolling: null,
    };
  },
  computed: {
    isAdmin() { return this.$store.state.portal.isAdmin; },
    showingOpen() { return this.state === this.availableStates[0].value; },
    // Official matches lead the Open / Running list (sort is stable, so the
    // newest-first order holds within each group).
    listedInstances() {
      if (!this.showingOpen) { return this.instances; }
      return [...this.instances].sort((a, b) => Number(!!b.official) - Number(!!a.official));
    },
  },
  methods: {
    async loadLobby() {
      try {
        const { data } = await this.$axios.get('/legacy/lobby');
        this.lobby = data;
      } catch (e) {
        // Lobby extras are decorative; the game list still works without them.
      }
    },
  },
  mounted() {
    this.loadLobby();
    this.lobbyPolling = setInterval(() => this.loadLobby(), this.$config.POLLING.LONG);
  },
  beforeDestroy() {
    clearInterval(this.lobbyPolling);
  },
  components: {
    LoadingMask,
    InstanceRow,
    NewsMarquee,
    LatestOfficialResult,
    NextOfficialNotice,
  },
};
</script>

<style lang="scss" scoped>
.archive-button {
  margin-right: 10px;
}
</style>
