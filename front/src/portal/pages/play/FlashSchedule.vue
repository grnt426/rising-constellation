<template>
  <div class="panel-fragment">
    <div class="panel-content is-full-sized">
      <div class="panel-header">
        <h1 v-html="$tmd('page.flash_schedule.header')" />

        <router-link
          to="/play/fast"
          class="default-button header-button">
          <svgicon class="icon" name="caret-left" />
          {{ $t('page.flash_schedule.back') }}
        </router-link>

        <button
          v-if="isAdmin && !editing"
          class="default-button"
          @click="edit(null)">
          <svgicon class="icon" name="pencil" />
          {{ $t('page.flash_schedule.new_schedule') }}
        </button>
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <p class="schedule-intro">{{ $t('page.flash_schedule.intro') }}</p>

        <schedule-form
          v-if="editing"
          :key="editing === 'new' ? 'new' : editing.id"
          :schedule="editing === 'new' ? null : editing"
          :scenarios="scenarios"
          :mutators="mutators"
          @saved="onSaved"
          @deleted="onSaved"
          @cancel="editing = null" />

        <p
          v-if="schedules.length === 0"
          class="schedule-empty">
          {{ $t('page.flash_schedule.no_schedule') }}
        </p>

        <div
          v-else
          class="schedule-cards">
          <div
            v-for="s in schedules"
            :key="`schedule-${s.id}`"
            class="schedule-card"
            :class="{ 'is-disabled': !s.enabled }">
            <div class="schedule-card-header">
              <h2>{{ s.name }}</h2>
              <span
                class="toast"
                :class="{ 'is-ranked': s.game_mode_type === 'ranked' }">
                {{ $t(`page.flash_schedule.${s.game_mode_type}`) }}
              </span>
              <span
                v-if="!s.enabled"
                class="toast">{{ $t('page.flash_schedule.paused') }}</span>
              <button
                v-if="isAdmin"
                class="default-button schedule-card-edit"
                @click="edit(s)">
                {{ $t('page.flash_schedule.edit') }}
              </button>
            </div>

            <div class="schedule-card-when">
              <strong>{{ everyLabel(s) }}</strong>
              <span v-if="s.next_starts_at">
                {{ $t('page.flash_schedule.next', { date: longDate(s.next_starts_at) }) }}
              </span>
            </div>

            <p
              v-if="s.description"
              class="schedule-card-description">{{ s.description }}</p>

            <dl class="schedule-card-facts">
              <dt>{{ $t('page.flash_schedule.maps') }}</dt>
              <dd>
                <span
                  v-for="(m, i) in s.maps"
                  :key="`s${s.id}-m${m.id}-${i}`"
                  class="map"
                  :class="{ 'is-next': m.id === s.next_scenario_id }">
                  <template v-if="i > 0"> → </template>{{ m.name }}
                </span>
              </dd>

              <dt>{{ $t('page.flash_schedule.mutators') }}</dt>
              <dd>{{ mutatorLabel(s) }}</dd>

              <dt>{{ $t('page.flash_schedule.players') }}</dt>
              <dd>
                {{ $t('page.flash_schedule.min_players', { n: s.min_players }) }}
                ·
                <template v-if="s.faction_capacity">
                  {{ $t('page.flash_schedule.seats', { n: s.faction_capacity }) }}
                </template>
                <template v-else>{{ $t('page.flash_schedule.seats_default') }}</template>
              </dd>
            </dl>
          </div>
        </div>

        <schedule-calendar
          :month="month"
          :entries="calendar"
          @month="changeMonth" />
      </v-scrollbar>

      <loading-mask v-else />
    </div>

    <v-scrollbar class="panel-aside">
      <div class="panel-aside-bloc">
        <section class="panel-aside-info">
          <h2>{{ $t('page.flash_schedule.how_title') }}</h2>
          <p class="is-large">{{ $t('page.flash_schedule.how_lobby') }}</p>
          <p class="is-large">{{ $t('page.flash_schedule.how_ready') }}</p>
          <p class="is-large">{{ $t('page.flash_schedule.how_close') }}</p>
          <p class="is-large">{{ $t('page.flash_schedule.how_time', { zone: localZone }) }}</p>
        </section>
      </div>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
import LoadingMask from '@/portal/components/LoadingMask.vue';
import ScheduleCalendar from '@/portal/components/flash/ScheduleCalendar.vue';
import ScheduleForm from '@/portal/components/flash/ScheduleForm.vue';

const firstOfMonth = (d) => new Date(d.getFullYear(), d.getMonth(), 1);

export default {
  name: 'play-flash-schedule',
  data() {
    return {
      loaded: false,
      schedules: [],
      calendar: [],
      month: firstOfMonth(new Date()),
      editing: null,
      scenarios: [],
      mutators: [],
      polling: null,
    };
  },
  computed: {
    isAdmin() { return this.$store.state.portal.isAdmin; },
    localZone() {
      return new Date().toLocaleTimeString(this.$i18n.locale, { timeZoneName: 'short' }).split(' ').pop();
    },
  },
  methods: {
    async load() {
      // Same Monday-first 6-week window the calendar draws.
      const offset = (this.month.getDay() + 6) % 7;
      const from = new Date(this.month.getFullYear(), this.month.getMonth(), 1 - offset);
      const to = new Date(from.getFullYear(), from.getMonth(), from.getDate() + 42);

      try {
        const { data } = await this.$axios.get('/flash/schedules', {
          params: { from: from.toISOString(), to: to.toISOString() },
        });
        this.schedules = data.schedules;
        this.calendar = data.calendar;
      } catch (err) {
        this.$toastError(err.response ? err.response.data.message : err.message);
      }

      this.loaded = true;
    },
    changeMonth(delta) {
      this.month = new Date(this.month.getFullYear(), this.month.getMonth() + delta, 1);
      this.load();
    },
    async edit(schedule) {
      if (this.scenarios.length === 0) {
        const [scenarios, mutators] = await Promise.all([
          this.$axios.get('/scenarios', { params: { speed: 'fast', page_size: 200 } }),
          this.$axios.get('/data/mutators'),
        ]);
        this.scenarios = scenarios.data;
        this.mutators = mutators.data;
      }

      this.editing = schedule || 'new';
    },
    onSaved() {
      this.editing = null;
      this.load();
    },
    everyLabel(s) {
      const [h, m] = s.start_time.split(':').map(Number);
      const day = new Date(Date.UTC(2024, 0, s.weekday))
        .toLocaleDateString(this.$i18n.locale, { weekday: 'long', timeZone: 'UTC' });
      const time = new Date(Date.UTC(2024, 0, 1, h, m))
        .toLocaleTimeString(this.$i18n.locale, { hour: 'numeric', minute: '2-digit', timeZone: 'UTC' });

      return this.$t('page.flash_schedule.every', { day, time });
    },
    longDate(iso) {
      return new Date(iso).toLocaleString(this.$i18n.locale, {
        weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
      });
    },
    mutatorLabel(s) {
      if (s.mutator_keys === null) { return this.$t('page.flash_schedule.mutators_map'); }
      if (s.mutator_keys.length === 0) { return this.$t('page.flash_schedule.mutators_none'); }
      return s.mutator_keys.map((k) => this.$t(`data.mutator.${k}.name`)).join(', ');
    },
  },
  mounted() {
    this.load();
    this.polling = setInterval(() => { if (!this.editing) { this.load(); } }, this.$config.POLLING.LONG);
  },
  beforeDestroy() {
    clearInterval(this.polling);
  },
  components: {
    LoadingMask,
    ScheduleCalendar,
    ScheduleForm,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.header-button {
  margin-right: 10px;
}

.schedule-intro {
  margin-bottom: 16px;
  color: $white-alt-1;
}

.schedule-empty {
  margin-bottom: 25px;
  padding: 20px;
  text-align: center;
  text-transform: uppercase;
  font-weight: bold;
  color: $white-alt-2;
  background: rgba(0, 0, 0, .15);
  border-radius: 3px;
}

.schedule-cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 12px;
  margin-bottom: 30px;
}

.schedule-card {
  padding: 12px 15px;
  background: rgba(0, 0, 0, .2);
  border: solid 1px rgba(0, 0, 0, .2);
  border-left: solid 3px $primary;
  border-radius: 3px;

  &.is-disabled {
    opacity: .55;
  }
}

.schedule-card-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;

  h2 {
    margin-right: 4px;
    font-size: 1.8rem;
    font-weight: bold;
    text-transform: uppercase;
  }

  .toast {
    padding: 0 6px;
    border-radius: 3px;
    background: $grey-default;
    font-size: 1.2rem;
    text-transform: uppercase;

    &.is-ranked {
      background: $theme-orange;
      color: $black;
      font-weight: bold;
    }
  }
}

.schedule-card-edit {
  margin-left: auto;
}

.schedule-card-when {
  display: flex;
  flex-direction: column;
  gap: 2px;
  margin-top: 8px;

  strong {
    font-size: 1.5rem;
  }

  span {
    font-size: 1.3rem;
    color: $white-alt-1;
  }
}

.schedule-card-description {
  margin-top: 8px;
  font-size: 1.3rem;
  color: $white-alt-1;
  white-space: pre-line;
}

.schedule-card-facts {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 4px 12px;
  margin: 10px 0 0;
  font-size: 1.3rem;

  dt {
    color: $white-alt-2;
    text-transform: uppercase;
    font-size: 1.1rem;
    line-height: 1.8rem;
  }

  dd {
    margin: 0;
  }

  .map.is-next {
    color: $primary;
    font-weight: bold;
  }
}
</style>
