<template>
  <div>
    <div class="box-notification-header">
      <svgicon name="bookmark" />
      <div
        class="name"
        v-html="$tmd('notification.box.calc_reminder.title')">
      </div>
    </div>

    <div class="box-notification-bloc">
      <div class="calc-reminder-src">{{ data.src }}</div>
      <p
        v-html="$tmd('notification.box.calc_reminder.description', {
          target: formattedTarget,
          resource: resourceName,
        })">
      </p>
    </div>

    <div class="calc-reminder-actions">
      <div
        class="button"
        @click="clearReminder">
        {{ $t('notification.box.calc_reminder.clear') }}
      </div>
    </div>
  </div>
</template>

<script>
// Reminder card: a pinned `until` line in the calculator notepad reached
// its target. "Clear reminder" deletes the pinned line (it's served its
// purpose); the generic footer Close keeps it — the acked latch in the
// calc store prevents it from firing again unless it un-reaches first.
import format from '@/utils/format';

export default {
  name: 'calc-reminder-notif',
  props: {
    data: Object,
  },
  computed: {
    formattedTarget() {
      return format.integer(this.data.target);
    },
    resourceName() {
      return this.data.resource ? this.$t(`calc.res_short.${this.data.resource}`) : '';
    },
  },
  methods: {
    clearReminder() {
      this.$store.dispatch('calc/unpinLine', this.data.line_id);
      this.$store.commit('game/discardFirstBoxNotification');
    },
  },
};
</script>

<style scoped>
.calc-reminder-src {
  margin-bottom: 8px;
  padding: 6px 10px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: #fff;
  font-family: Consolas, Menlo, monospace;
  font-size: 1.2rem;
}

.calc-reminder-actions {
  display: flex;
  justify-content: flex-end;
  padding: 0 10px 10px;
}
</style>
