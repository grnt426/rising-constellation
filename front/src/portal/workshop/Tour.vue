<template>
  <div
    v-if="step"
    class="wk-tour"
    role="dialog"
    aria-live="polite"
    :aria-label="$t('page.scenario_workshop.tour.label')">
    <div
      v-if="ring"
      class="wk-tour-ring"
      :style="ring" />
    <div
      class="wk-tour-card"
      :style="cardStyle">
      <div class="wk-tour-count">{{ index + 1 }} / {{ steps.length }}</div>
      <h3>{{ $t(`page.scenario_workshop.tour.${step.key}_title`) }}</h3>
      <p>{{ $t(`page.scenario_workshop.tour.${step.key}_body`) }}</p>
      <p
        v-if="step.task"
        class="wk-tour-task"
        :class="{ 'is-done': step.done }">
        {{ step.done ? $t('page.scenario_workshop.tour.task_done') : $t('page.scenario_workshop.tour.task_todo') }}
      </p>
      <div class="wk-tour-actions">
        <button
          type="button"
          class="wk-button"
          @click="$emit('close')">{{ $t('page.scenario_workshop.tour.skip') }}</button>
        <button
          type="button"
          class="wk-button is-primary"
          data-tour-next="1"
          @click="$emit('next')">
          {{ index === steps.length - 1 ? $t('page.scenario_workshop.tour.finish') : (step.task && !step.done ? $t('page.scenario_workshop.tour.skip_step') : $t('page.scenario_workshop.tour.next')) }}
        </button>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'workshop-tour',
  props: {
    steps: { type: Array, required: true },
    index: { type: Number, required: true },
  },
  data() {
    return { rect: null, timer: null };
  },
  computed: {
    step() { return this.steps[this.index] || null; },
    ring() {
      const r = this.rect;
      if (!r) return null;
      return {
        left: `${r.left - 6}px`, top: `${r.top - 6}px`, width: `${r.width + 12}px`, height: `${r.height + 12}px`,
      };
    },
    cardStyle() {
      const r = this.rect;
      const w = 340;
      if (!r) return { left: `calc(50% - ${w / 2}px)`, top: '30%' };
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      // beside the target if there is room, else below it, else above
      let left = r.right + 16;
      let top = r.top;
      if (left + w > vw - 10) {
        left = Math.min(Math.max(10, r.left), vw - w - 10);
        top = r.bottom + 14;
        if (top + 220 > vh) top = Math.max(10, r.top - 230);
      }
      return { left: `${left}px`, top: `${Math.min(top, vh - 240)}px`, width: `${w}px` };
    },
  },
  watch: {
    index() { this.locate(); },
  },
  mounted() {
    this.locate();
    this.timer = setInterval(this.locate, 500);
  },
  beforeDestroy() { clearInterval(this.timer); },
  methods: {
    locate() {
      const target = this.step && this.step.target ? document.querySelector(this.step.target) : null;
      const r = target ? target.getBoundingClientRect() : null;
      this.rect = r && r.width > 0 ? {
        left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height,
      } : null;
    },
  },
};
</script>
