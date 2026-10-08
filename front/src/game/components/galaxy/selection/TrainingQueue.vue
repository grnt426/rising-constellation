<template>
  <!-- What a student is waiting on (docs/agent-training.md): settling in,
       with the moment it is over. The course itself is not an order and is
       not listed. Drawn like the running order of an agent's plan
       (AgentPlan.vue), whose styles it borrows. -->
  <div
    v-if="settle"
    class="selection-actions agent-plan training-queue">
    <div class="header">
      {{ $t('galaxy.selection.view.actions') }}
    </div>

    <div
      class="agent-plan-row is-head"
      data-training-row="settling">
      <span class="agent-plan-icon">
        <circle-progress-value
          :current="settle.elapsed"
          :total="settle.total"
          :increase="1"
          :size="20"
          :width="3"
          :theme="theme" />
        <svgicon :name="`building/${school}`" />
      </span>
      <span class="agent-plan-name">{{ $t('galaxy.school.action_settling') }}</span>
      <span class="agent-plan-via">{{ $t(`data.building.${school}.name`) }}</span>
      <span class="agent-plan-spacer" />
      <span
        v-if="settle.until !== null"
        class="agent-plan-eta"
        data-training-eta
        v-tooltip="countdown">
        {{ eta }}
      </span>
    </div>

    <div class="training-queue-note">
      {{ $t('galaxy.school.settling_hint') }}
    </div>
  </div>
</template>

<script>
import { DateTime } from 'luxon';

import { formatCountdown } from '@/game/clock';
import { schoolBuilding, settling } from '@/game/training';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

// "Sep 29, 2:32:05 PM", as the plan's own ETAs
const ETA_FORMAT = {
  month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', second: '2-digit',
};

export default {
  name: 'training-queue',
  props: {
    character: { type: Object, required: true },
    theme: { type: String, default: 'none' },
  },
  data() {
    return {
      // wall clock, ticking each second for the countdown
      now: Date.now(),
      clock: null,
    };
  },
  computed: {
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    school() { return schoolBuilding(this.character); },
    settle() {
      if (this.character.status !== 'student') return null;

      const constant = this.$store.state.game.data.constant[0];
      return settling(this.character.training, constant, this.$store.state.game.time, this.speedFactor, this.now);
    },
    eta() { return DateTime.fromMillis(this.settle.until).toLocaleString(ETA_FORMAT); },
    countdown() { return formatCountdown(this.settle.until - this.now); },
    remaining() { return this.settle ? this.settle.remaining : null; },
  },
  watch: {
    // The time is up: the copy this draws from still says "settling in"
    // (a card opened once is not kept up to date), so its host is asked
    // for a new one. Once only: a copy that comes back still settling in
    // (a paused game) has the countdown start again from what is left.
    remaining(left, before) {
      if (left !== null && left <= 0 && before > 0) this.$emit('over');
    },
  },
  mounted() {
    this.clock = setInterval(() => { this.now = Date.now(); }, 1000);
  },
  beforeDestroy() {
    clearInterval(this.clock);
  },
  components: { CircleProgressValue },
};
</script>
