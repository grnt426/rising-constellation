<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1 v-html="$tmd('page.play.archive.header')" />

        <router-link
          to="/play/slow"
          class="default-button">
          <svgicon class="icon" name="caret-left" />
          {{ $t('page.play.archive.back_to_games') }}
        </router-link>
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <div
          v-if="matches.length === 0"
          class="full-sized-text">
          {{ $t('page.play.archive.no_match') }}
        </div>

        <template v-else>
          <p class="archive-intro">{{ $t('page.play.archive.intro') }}</p>

          <table class="default-table instances-table archive-table">
            <tr
              v-for="m in matches"
              :key="m.id"
              @click="$router.push(`/play/slow/archive/${m.id}`)">
              <td>
                <svgicon
                  class="icon archive-winner-icon"
                  name="victory"
                  :style="{ color: factionColor(m.winner_faction) }"
                  v-tooltip="winnerLabel(m)" />
              </td>

              <td>
                <div class="header">
                  <h2>{{ m.name }}</h2>
                  <em>#{{ m.instance_id }}</em>
                  <span
                    v-if="!m.published"
                    class="toast is-draft">{{ $t('page.play.archive.draft') }}</span>
                  <span
                    v-if="m.map_name"
                    class="toast">{{ m.map_name }}</span>
                  <span class="toast">{{ $t('page.play.archive.days_count', { n: durationDays(m) }) }}</span>
                  <span class="toast">{{ $t('page.play.archive.players_count', { n: m.player_count }) }}</span>
                </div>

                <em>
                  <span
                    v-for="(f, i) in m.factions"
                    :key="`m${m.id}-${f.key}`">
                    <template v-if="i > 0"> vs </template>
                    <strong>
                      <span
                        class="bull"
                        :class="`theme-${factionTheme(f.key)}`" />
                      {{ $t(`data.faction.${f.key}.name`) }}
                      <template v-if="f.victory_points !== null && f.victory_points !== undefined">
                        · {{ $t('page.play.archive.vp_count', { n: f.victory_points }) }}
                      </template>
                    </strong>
                  </span>
                  <span class="archive-dates">{{ dateRange(m) }}</span>
                </em>
              </td>

              <td class="actions">
                <button class="default-button">
                  {{ $t('page.play.archive.view') }}
                </button>
              </td>
            </tr>
          </table>

          <div
            v-if="totalPages > 1"
            class="forge-pagination">
            <button
              class="default-button"
              :class="{ disabled: page <= 1 }"
              @click="goToPage(page - 1)">
              <svgicon class="icon" name="caret-left" />
            </button>
            <span>{{ $t('page.create.common.page_of', { current: page, total: totalPages }) }}</span>
            <button
              class="default-button"
              :class="{ disabled: page >= totalPages }"
              @click="goToPage(page + 1)">
              <svgicon class="icon" name="caret-right" />
            </button>
          </div>
        </template>
      </v-scrollbar>

      <loading-mask v-else />
    </div>
  </div>
</template>

<script>
import LoadingMask from '@/portal/components/LoadingMask.vue';
import { factionColor, factionTheme } from '@/utils/factions';

export default {
  name: 'play-archive',
  data() {
    return {
      loaded: false,
      matches: [],
      page: 1,
      totalPages: 1,
    };
  },
  methods: {
    factionColor,
    factionTheme,
    fetch() {
      this.$axios.get('/archive/matches', { params: { page: this.page } }).then((resp) => {
        this.matches = Object.freeze(resp.data);
        this.totalPages = parseInt(resp.headers['total-pages'], 10) || 1;
        this.loaded = true;
      }).catch(() => {
        this.matches = [];
        this.loaded = true;
      });
    },
    goToPage(page) {
      if (page < 1 || page > this.totalPages) return;
      this.page = page;
      this.fetch();
    },
    durationDays(m) {
      return Math.max(1, Math.round((new Date(m.ended_at) - new Date(m.started_at)) / 86400000));
    },
    dateRange(m) {
      const opts = { year: 'numeric', month: 'short', day: 'numeric' };
      const start = new Date(m.started_at).toLocaleDateString(this.$i18n.locale, opts);
      const end = new Date(m.ended_at).toLocaleDateString(this.$i18n.locale, opts);
      return `${start} – ${end}`;
    },
    winnerLabel(m) {
      if (!m.winner_faction) return this.$t('page.play.archive.no_winner');
      return this.$t('page.play.archive.faction_won', { faction: this.$t(`data.faction.${m.winner_faction}.name`) });
    },
  },
  mounted() {
    this.fetch();
  },
  components: {
    LoadingMask,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.archive-intro {
  margin-bottom: 16px;
  color: $white-alt-1;
}

.archive-table {
  tr { cursor: pointer; }

  .archive-winner-icon {
    width: 30px;
    height: 30px;
  }

  .toast.is-draft {
    background: $color-alert;
    color: $grey-darker;
    opacity: 1;
  }

  .archive-dates {
    margin-left: 14px;
  }
}

.forge-pagination {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  margin-top: 16px;
}
</style>
