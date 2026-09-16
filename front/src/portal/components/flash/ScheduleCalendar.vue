<template>
  <div class="schedule-calendar">
    <div class="schedule-calendar-nav">
      <button
        class="default-button"
        @click="$emit('month', -1)">
        <svgicon class="icon" name="caret-left" />
      </button>
      <h2>{{ monthLabel }}</h2>
      <button
        class="default-button"
        @click="$emit('month', 1)">
        <svgicon class="icon" name="caret-right" />
      </button>
    </div>

    <div class="schedule-calendar-scroll">
      <div class="schedule-calendar-grid">
        <div
          v-for="name in weekdayNames"
          :key="`wd-${name}`"
          class="schedule-calendar-weekday">
          {{ name }}
        </div>

        <div
          v-for="day in days"
          :key="day.key"
          class="schedule-calendar-day"
          :class="{ 'is-other-month': !day.inMonth, 'is-today': day.today }">
          <span class="date">{{ day.date.getDate() }}</span>

          <component
            :is="e.instance_id ? 'router-link' : 'div'"
            v-for="e in day.entries"
            :key="`${e.schedule_id}-${e.starts_at}`"
            v-bind="e.instance_id ? { to: `/instance/${e.instance_id}` } : {}"
            class="schedule-calendar-entry"
            :class="[`is-${e.status || 'upcoming'}`, { 'is-ranked': e.game_mode_type === 'ranked' }]"
            v-tooltip="entryTooltip(e)">
            <strong>{{ time(e.starts_at) }}</strong>
            <span class="name">{{ e.name }}</span>
            <span class="map">{{ e.scenario_name }}</span>
          </component>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
const sameDay = (a, b) => a.getFullYear() === b.getFullYear()
  && a.getMonth() === b.getMonth()
  && a.getDate() === b.getDate();

export default {
  name: 'schedule-calendar',
  props: {
    // First day of the displayed month (local time).
    month: Date,
    entries: Array,
  },
  computed: {
    // Monday-first 6-week grid in the viewer's local time.
    gridStart() {
      const first = new Date(this.month.getFullYear(), this.month.getMonth(), 1);
      const offset = (first.getDay() + 6) % 7;
      return new Date(first.getFullYear(), first.getMonth(), 1 - offset);
    },
    days() {
      const today = new Date();

      return Array.from({ length: 42 }, (_, i) => {
        const date = new Date(this.gridStart.getFullYear(), this.gridStart.getMonth(), this.gridStart.getDate() + i);

        return {
          key: `d-${i}`,
          date,
          inMonth: date.getMonth() === this.month.getMonth(),
          today: sameDay(date, today),
          entries: this.entries.filter((e) => sameDay(new Date(e.starts_at), date)),
        };
      });
    },
    weekdayNames() {
      // 2024-01-01 was a Monday.
      return Array.from({ length: 7 }, (_, i) => new Date(2024, 0, 1 + i)
        .toLocaleDateString(this.$i18n.locale, { weekday: 'short' }));
    },
    monthLabel() {
      return this.month.toLocaleDateString(this.$i18n.locale, { month: 'long', year: 'numeric' });
    },
  },
  methods: {
    time(iso) {
      return new Date(iso).toLocaleTimeString(this.$i18n.locale, { hour: 'numeric', minute: '2-digit' });
    },
    entryTooltip(e) {
      const mode = this.$t(`page.flash_schedule.${e.game_mode_type === 'ranked' ? 'ranked' : 'casual'}`);
      const status = this.$t(`page.flash_schedule.entry_status.${e.status || 'upcoming'}`);
      return `${e.name} · ${e.scenario_name || ''} · ${mode} · ${status}`;
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.schedule-calendar-nav {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 12px;

  h2 {
    min-width: 180px;
    text-align: center;
    font-size: 1.8rem;
    text-transform: uppercase;
  }
}

.schedule-calendar-scroll {
  overflow-x: auto;
}

.schedule-calendar-grid {
  display: grid;
  grid-template-columns: repeat(7, minmax(92px, 1fr));
  gap: 4px;
  min-width: 680px;
}

.schedule-calendar-weekday {
  padding: 4px 6px;
  font-size: 1.2rem;
  text-transform: uppercase;
  color: $white-alt-1;
}

.schedule-calendar-day {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-height: 86px;
  padding: 5px;
  background: rgba(0, 0, 0, .15);
  border: solid 1px rgba(0, 0, 0, .2);
  border-radius: 3px;

  .date {
    font-size: 1.2rem;
    color: $white-alt-1;
  }

  &.is-other-month {
    opacity: .4;
  }

  &.is-today {
    border-color: $primary;

    .date {
      color: $primary;
      font-weight: bold;
    }
  }
}

.schedule-calendar-entry {
  display: flex;
  flex-direction: column;
  padding: 4px 6px;
  border-left: solid 3px $theme-light-blue;
  border-radius: 2px;
  background: rgba(0, 0, 0, .25);
  color: $white;
  font-size: 1.2rem;
  line-height: 1.3;

  &.is-ranked {
    border-left-color: $theme-orange;
  }

  &.is-open,
  &.is-starting {
    background: rgba($primary, .2);
  }

  &.is-expired {
    opacity: .5;
    text-decoration: line-through;
  }

  .name {
    font-weight: bold;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .map {
    color: $white-alt-1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

a.schedule-calendar-entry:hover {
  background: rgba($primary, .35);
}
</style>
