<template>
  <!-- Confirmation of an agent plan edit (AgentPlan.vue): what was
       removed, which legs were re-routed, and — the confusing case — a
       removed stop the agent still passes through on its way elsewhere. -->
  <div class="plan-change-notif">
    <div class="box-notification-header">
      <svgicon name="action/jump" />
      <div
        class="name"
        v-html="$tmd('notification.box.plan_change.title', { agent: data.agent })">
      </div>
    </div>

    <div class="box-notification-bloc">
      <p
        v-for="(line, i) in data.lines"
        :key="i"
        :class="`plan-change-${line.key}`"
        :data-line="line.key"
        v-html="$tmd(`notification.box.plan_change.${line.key}`, line.data)">
      </p>
      <p
        v-if="!data.lines || data.lines.length === 0"
        v-html="$tmd('notification.box.plan_change.unchanged')">
      </p>
    </div>
  </div>
</template>

<script>
export default {
  name: 'plan-change-notif',
  props: {
    data: Object,
  },
};
</script>

<style scoped>
.plan-change-notif p {
  margin: 0 0 6px;
}

.plan-change-pass_through {
  padding-left: 8px;
  border-left: 2px solid rgba(255, 255, 255, 0.5);
}
</style>
