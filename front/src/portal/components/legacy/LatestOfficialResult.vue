<template>
  <component
    :is="result.archive_id ? 'router-link' : 'div'"
    v-bind="result.archive_id ? { to: `/play/slow/archive/${result.archive_id}` } : {}"
    class="latest-result"
    :class="{ 'is-link': !!result.archive_id }">
    <div class="latest-result-label">
      {{ $t('page.play.slow.latest_result') }}
    </div>

    <div class="latest-result-map">
      {{ result.map_name }}
    </div>

    <div
      v-if="result.winner_faction"
      class="latest-result-winner"
      :class="getTheme(result.winner_faction)">
      <span class="star">★</span>
      {{ $t('page.play.archive.faction_won', { faction: factionName(result.winner_faction) }) }}
    </div>
    <div
      v-else
      class="latest-result-winner">
      {{ $t('page.play.archive.no_winner') }}
    </div>

    <ul class="latest-result-standings">
      <li
        v-for="f in result.factions"
        :key="`latest-${f.key}`"
        :class="{ 'is-winner': f.key === result.winner_faction }">
        <span
          class="bull"
          :class="getTheme(f.key)"></span>
        <span class="name">{{ factionName(f.key) }}</span>
        <strong class="vp">
          <template v-if="f.victory_points !== null">
            {{ $t('page.play.archive.vp_count', { n: f.victory_points }) }}
          </template>
          <template v-else>—</template>
        </strong>
      </li>
    </ul>

    <div class="latest-result-footer">
      <template v-if="result.archive_id">
        {{ $t('page.play.slow.view_stats') }} →
      </template>
      <template v-else>
        {{ $t('page.play.slow.archive_pending') }}
      </template>
    </div>
  </component>
</template>

<script>
export default {
  name: 'latest-official-result',
  props: {
    result: Object,
  },
  computed: {
    factions() { return this.$store.state.portal.data.faction; },
  },
  methods: {
    factionName(key) {
      return this.$t(`data.faction.${key}.name`);
    },
    getTheme(key) {
      const faction = this.factions.find((f) => f.key === key);
      return faction ? `theme-${faction.theme}` : '';
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.latest-result {
  display: block;
  padding: 12px 15px;

  background: rgba(0, 0, 0, .2);
  border: solid 1px rgba(0, 0, 0, .2);
  border-radius: 3px;
  color: $white;

  transition: all linear 250ms;

  &.is-link:hover {
    border-color: $primary;
    background: rgba(0, 0, 0, .3);

    .latest-result-footer {
      color: $primary;
    }
  }
}

.latest-result-label {
  font-size: 1.2rem;
  text-transform: uppercase;
  color: $white-alt-1;
}

.latest-result-map {
  margin-top: 4px;
  font-size: 1.8rem;
  font-weight: bold;
  text-transform: uppercase;
  line-height: 1.2;
}

.latest-result-winner {
  margin-top: 6px;
  font-size: 1.4rem;
  font-weight: bold;
  text-transform: uppercase;

  .star {
    text-shadow: 0 0 5px black;
  }

  @each $class, $color in $themes-list {
    &.theme-#{$class} .star {
      color: $color;
    }
  }
}

.latest-result-standings {
  margin: 10px 0 0;
  padding: 0;
  list-style: none;

  li {
    display: flex;
    align-items: center;
    padding: 3px 0;
    font-size: 1.3rem;
    opacity: .7;

    &.is-winner {
      opacity: 1;
    }
  }

  .bull {
    flex: none;
    width: 10px; height: 10px;
    margin-right: 8px;
    border-radius: 2px;
    background: $white-alt-2;

    @each $class, $color in $themes-list {
      &.theme-#{$class} {
        background: $color;
      }
    }
  }

  .name {
    flex-grow: 1;
  }

  .vp {
    white-space: nowrap;
  }
}

.latest-result-footer {
  margin-top: 10px;
  font-size: 1.2rem;
  text-transform: uppercase;
  color: $white-alt-1;
  transition: color linear 250ms;
}
</style>
