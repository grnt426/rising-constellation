<template>
  <div class="card-container">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon class="icon" name="logo/simple" />
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          {{ profile.name }}
        </div>
      </div>
    </div>

    <div class="card-body">
      <div class="card-illustration">
        <img :src="path" />
        <div
          v-if="profile.favorite_icon"
          class="favorite-icon-badge"
          :style="{ color: factionColor, borderColor: factionColor }">
          <svgicon :name="profile.favorite_icon" />
        </div>
      </div>

      <div class="card-information">
        <div class="card-panel-controls">
          <svgicon
            class="card-panel-control"
            name="caret-left"
            @click="movePanelToLeft"
            v-if="leftControl" />
          <div v-else></div>
          <svgicon
            class="card-panel-control"
            name="caret-right"
            @click="movePanelToRight"
            v-if="rightControl" />
          <div v-else></div>
        </div>

        <div class="card-panel-window">
          <div
            ref="panelContainer"
            class="card-panel-container"
            :style="{ left: panelContainerPosition + 'px' }">
            <div class="card-panel">
              <blockquote>
                {{ quote }}
              </blockquote>

              <div
                v-show="profile.full_name"
                class="complex-bonus">
                <div>
                  <strong>{{ profile.full_name }}</strong>
                </div>
              </div>
              <div
                v-if="profile.favorite_faction"
                class="complex-bonus">
                <div>{{ $t('page.profile_detail.favorite_faction') }}</div>
                <div :class="`is-color-${factionTheme}`">
                  <strong>{{ $t(`data.faction.${profile.favorite_faction}.name`) }}</strong>
                </div>
              </div>
            </div>

            <div
              v-if="profile.stats"
              class="card-panel">
              <h2>{{ $t('page.profile_detail.stats_header') }}</h2>
              <div class="complex-bonus">
                <div>{{ $t('page.profile_detail.stats_legacy_wins') }}</div>
                <div><strong>{{ profile.stats.legacy.wins }}</strong> / {{ profile.stats.legacy.participations }}</div>
              </div>
              <div class="complex-bonus">
                <div>{{ $t('page.profile_detail.stats_daily_medals') }}</div>
                <div>
                  🥇{{ profile.stats.daily.gold }}
                  🥈{{ profile.stats.daily.silver }}
                  🥉{{ profile.stats.daily.bronze }}
                </div>
              </div>
              <div class="complex-bonus">
                <div>{{ $t('page.profile_detail.stats_daily_completed') }}</div>
                <div>{{ profile.stats.daily.completed }} / {{ profile.stats.daily.played }}</div>
              </div>
              <div
                v-for="faction in playedFactions"
                :key="`stat-faction-${faction.key}`"
                class="complex-bonus">
                <div>
                  <svgicon
                    class="faction-stat-icon"
                    :name="`faction/${faction.key}-small`" />
                  {{ $t(`data.faction.${faction.key}.name`) }}
                </div>
                <div>{{ faction.count }}</div>
              </div>
            </div>

            <!-- About (long_description) is invisibly suppressed for now:
                 still stored and returned by the API, just not shown —
                 restore this panel if players miss it. -->
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import Path from '@/utils/path';
import { FACTIONS, factionColor, factionTheme } from '@/utils/factions';

export default {
  name: 'player-card',
  mixins: [CardMixin],
  props: {
    profile: Object,
  },
  computed: {
    path() { return Path.relative(`data/avatars/${this.profile.avatar}`); },
    quote() { return this.profile.description ? this.profile.description : '—'; },
    factionColor() { return factionColor(this.profile.favorite_faction); },
    factionTheme() { return factionTheme(this.profile.favorite_faction); },
    playedFactions() {
      const counts = this.profile.stats ? this.profile.stats.factions : {};
      return FACTIONS
        .filter((f) => counts[f.key])
        .map((f) => ({ key: f.key, count: counts[f.key] }));
    },
  },
  watch: {
    // CardMixin snapshots panelCount at mount; the stats panel appears
    // only once the profile fetch lands, so recount when the prop moves.
    profile: {
      deep: true,
      handler() {
        this.$nextTick(() => {
          if (this.$refs.panelContainer) {
            this.panelCount = this.$refs.panelContainer.childElementCount;
          }
        });
      },
    },
  },
};
</script>

<style lang="scss" scoped>
.card-illustration {
  position: relative;
}

/* The favorite icon rides the bottom-LEFT corner of the portrait,
   tinted in the favorite faction's color (neutral grey when no
   faction is set). Left, not right like the Discord card: the card's
   panel-swipe arrows live on the right and were overlapping it. */
.favorite-icon-badge {
  position: absolute;
  left: 6px;
  bottom: 6px;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  background: rgba(14, 16, 19, 0.9);
  border: 2px solid currentColor;
  border-radius: 50%;

  svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
  }
}

.faction-stat-icon {
  width: 14px;
  height: 14px;
  vertical-align: -2px;
}
</style>
