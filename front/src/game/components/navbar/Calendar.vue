<template>
  <div
    class="navbar-calendar"
    :class="{ 'is-compact': compact }">
    <div class="date">
      <div class="day">
        {{ date.day + 1 }}
      </div>
      <div class="month">
        {{
          $t(`data.calendar.${calendar.key}.months_prefix[${date.month % 6}]`)
        }}{{
          $t(`data.calendar.${calendar.key}.months_name[${Math.floor(date.month / 6)}]`)
        }}
      </div>
      <div class="year">
        {{ date.year }}
      </div>
    </div>
  </div>
</template>

<script>
import Calendar from '@/utils/calendar';
import TimeMixin from '@/game/mixins/TimeMixin';

// The in-universe date. Drawn by GovernmentStatus, which owns the
// top-centre box: full size when the game has no faction government,
// one small line (`compact`) under the leader's name when it has.
export default {
  name: 'calendar',
  mixins: [TimeMixin],
  props: {
    compact: { type: Boolean, default: false },
  },
  data() {
    return {
      now: 0,
    };
  },
  computed: {
    calendar() {
      return this.$store.state.game.data.calendar.find((i) => i.key === 'tetrarch');
    },
    date() {
      return Calendar.fromUtDays(this.calendar, this.now);
    },
  },
  watch: {
    time(value) {
      this.now = value.now.value;
    },
  },
  methods: {
    updateValue(factor) {
      this.now += (this.time.now.change * factor);
    },
  },
  mounted() {
    this.now = this.time.now.value;
  },
};
</script>
