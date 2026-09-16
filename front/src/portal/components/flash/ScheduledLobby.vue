<template>
  <section class="panel-aside-info scheduled-lobby">
    <h2>
      {{ $t('page.instance.scheduled.title') }}
      <span
        v-if="ranked"
        class="toast">{{ $t('page.flash_schedule.ranked') }}</span>
    </h2>

    <div class="scheduled-lobby-body">
      <div class="scheduled-lobby-time">
        <strong>{{ startLabel }}</strong>
        <span>{{ relativeStart }}</span>
      </div>

      <template v-if="scheduled.status === 'open'">
        <div class="scheduled-lobby-ready">
          <span class="count">
            {{ $t('page.instance.scheduled.ready_count', {
              ready: scheduled.ready_count,
              joined: scheduled.joined_count,
            }) }}
          </span>
          <span class="gauge-container">
            <span
              class="gauge-content"
              :style="`width: ${readyPercent}%`" />
          </span>
          <span class="needed">
            {{ $t('page.instance.scheduled.needed', { n: scheduled.required_ready }) }}
          </span>
        </div>

        <ul
          v-if="blockers.length"
          class="scheduled-lobby-blockers">
          <li
            v-for="b in blockers"
            :key="b">
            {{ blockerLabel(b) }}
          </li>
        </ul>

        <div class="instance-action">
          <template v-if="registered">
            <button
              class="default-button"
              :class="{ 'is-ready': isReady }"
              @click="setReady(!isReady)">
              <template v-if="busy">...</template>
              <template v-else-if="isReady">{{ $t('page.instance.scheduled.unready') }}</template>
              <template v-else>{{ $t('page.instance.scheduled.ready_up') }}</template>
            </button>

            <button
              class="default-button instance-play-button"
              :class="{ disabled: !scheduled.can_start || !isReady }"
              v-tooltip="startTooltip"
              @click="start">
              {{ $t('page.instance.scheduled.start') }}
            </button>
          </template>
          <p
            v-else
            class="scheduled-lobby-hint">
            {{ $t('page.instance.scheduled.join_hint') }}
          </p>
        </div>
      </template>

      <p
        v-else
        class="scheduled-lobby-status">
        {{ $t(`page.instance.scheduled.status.${scheduled.status}`) }}
      </p>
    </div>
  </section>
</template>

<script>
export default {
  name: 'scheduled-lobby',
  props: {
    instance: Object,
    registered: Object,
  },
  data() {
    return {
      busy: false,
      now: Date.now(),
      clock: null,
    };
  },
  computed: {
    scheduled() { return this.instance.scheduled; },
    ranked() { return this.instance.game_data.game_mode_type === 'ranked'; },
    isReady() { return !!(this.registered && this.registered.ready); },
    startsAt() { return new Date(this.scheduled.scheduled_start_at); },
    readyPercent() {
      const needed = Math.max(this.scheduled.required_ready, 1);
      return Math.min(100, (this.scheduled.ready_count / needed) * 100);
    },
    // The server's blockers come from the last poll; the start-time one is
    // re-derived from the local clock so the Start button unlocks on time.
    blockers() {
      return this.scheduled.blockers.filter((b) => b !== 'before_start_time' || this.now < this.startsAt.getTime());
    },
    startLabel() {
      return this.startsAt.toLocaleString(this.$i18n.locale, {
        weekday: 'long', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      });
    },
    relativeStart() {
      const minutes = Math.round((this.startsAt.getTime() - this.now) / 60000);
      if (Math.abs(minutes) < 1) { return this.$t('page.instance.scheduled.now'); }

      const abs = Math.abs(minutes);
      const span = abs >= 60
        ? this.$t('page.instance.scheduled.hours_minutes', { h: Math.floor(abs / 60), m: abs % 60 })
        : this.$t('page.instance.scheduled.minutes', { m: abs });

      return minutes > 0
        ? this.$t('page.instance.scheduled.in', { span })
        : this.$t('page.instance.scheduled.ago', { span });
    },
    startTooltip() {
      if (!this.isReady) { return this.$t('page.instance.scheduled.blocker.not_ready'); }
      return this.blockers.length ? this.blockerLabel(this.blockers[0]) : '';
    },
  },
  methods: {
    blockerLabel(blocker) {
      return this.$t(`page.instance.scheduled.blocker.${blocker}`, {
        ready: this.scheduled.ready_count,
        needed: this.scheduled.required_ready,
      });
    },
    async setReady(ready) {
      if (this.busy) { return; }
      this.busy = true;

      try {
        await this.$axios.put(`/flash/matches/${this.instance.id}/ready`, { ready });
        this.$emit('changed');
      } catch (err) {
        this.$toastError(err.response ? err.response.data.message : err.message);
      } finally {
        this.busy = false;
      }
    },
    async start() {
      if (this.busy || !this.scheduled.can_start || !this.isReady) { return; }
      this.busy = true;

      try {
        await this.$axios.post(`/flash/matches/${this.instance.id}/start`);
        this.$emit('changed');
      } catch (err) {
        this.$toastError(err.response ? err.response.data.message : err.message);
      } finally {
        this.busy = false;
      }
    },
  },
  mounted() {
    this.clock = setInterval(() => { this.now = Date.now(); }, 15000);
  },
  beforeDestroy() {
    clearInterval(this.clock);
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.scheduled-lobby {
  border-color: $primary;
}

.scheduled-lobby-body {
  padding: 10px 15px 12px;
}

.scheduled-lobby-time {
  display: flex;
  flex-direction: column;
  gap: 2px;

  strong {
    font-size: 1.6rem;
    text-transform: uppercase;
  }

  span {
    font-size: 1.3rem;
    color: $white-alt-1;
  }
}

.scheduled-lobby-ready {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 10px;
  margin-top: 12px;
  font-size: 1.3rem;

  .gauge-container {
    flex: 1 1 100%;
    height: 6px;
    background: rgba(0, 0, 0, .3);
    border-radius: 3px;
    overflow: hidden;
    order: 3;
  }

  .gauge-content {
    display: block;
    height: 100%;
    background: $primary;
    transition: width linear 250ms;
  }

  .needed {
    margin-left: auto;
    color: $white-alt-1;
  }
}

.scheduled-lobby-blockers {
  margin: 10px 0 0;
  padding: 0;
  list-style: none;
  font-size: 1.2rem;
  color: $white-alt-1;

  li:before {
    content: '· ';
  }
}

.instance-action {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 12px;

  .default-button {
    flex: 1 1 auto;
  }

  .is-ready {
    background: $primary;
    color: $black;
  }
}

.scheduled-lobby .scheduled-lobby-hint {
  margin-top: 10px;
  padding: 0;
  font-size: 1.2rem;
  text-transform: none;
  color: $white-alt-2;
}

.scheduled-lobby .scheduled-lobby-status {
  margin-top: 10px;
  padding: 0;
  font-size: 1.4rem;
  text-transform: none;
}
</style>
