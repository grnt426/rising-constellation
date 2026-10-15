<template>
  <!-- The Training panel beside a student's opened card
       (docs/agent-training.md): what it is waiting on (settling in, drawn
       like the running order of an agent's plan, AgentPlan.vue, whose
       styles it borrows), then what its course gives and costs, and when:
       its experience rate, its next level, its next neural rewire, its
       next extra skill point and its way home. The ring around its seat
       keeps to the rewires; the hours are here. -->
  <div
    v-if="view"
    class="selection-actions agent-plan training-queue">
    <div class="header">
      {{ $t('galaxy.school.panel_title') }}
    </div>

    <template v-if="settle">
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
          v-tooltip="countdown(settle.until)"
          class="agent-plan-eta"
          data-training-eta>
          {{ date(settle.until) }}
        </span>
      </div>

      <div class="training-queue-note">
        {{ $t('galaxy.school.settling_hint') }}
      </div>
    </template>

    <dl class="training-facts">
      <div
        class="training-fact"
        data-training-fact="xp">
        <dt>{{ $t('galaxy.school.panel_xp') }}</dt>
        <dd>{{ xpText }}</dd>
      </div>

      <div
        v-for="fact in timedFacts"
        :key="fact.key"
        class="training-fact"
        :data-training-fact="fact.key">
        <dt v-tooltip="fact.hint">{{ fact.label }}</dt>
        <dd v-tooltip="date(fact.until)">{{ countdown(fact.until) }}</dd>
      </div>

      <div
        v-if="cost"
        class="training-fact"
        data-training-fact="fee">
        <dt>{{ $t('galaxy.school.panel_fee') }}</dt>
        <dd>
          {{ $t('galaxy.school.panel_fee_value', {
            amount: $options.filters.integer(cost.amount),
            resource: $t(`galaxy.school.fee_${cost.resource}`),
          }) }}
        </dd>
      </div>

      <div
        class="training-fact"
        data-training-fact="defense">
        <dt>{{ $t('galaxy.school.panel_defense') }}</dt>
        <dd>{{ $t('galaxy.school.panel_defense_value', { percent: defensePercent }) }}</dd>
      </div>

      <div
        class="training-fact"
        data-training-fact="bonuses">
        <dt>{{ $t('galaxy.school.panel_bonuses') }}</dt>
        <dd>{{ bonusText }}</dd>
      </div>
    </dl>
  </div>
</template>

<script>
import { DateTime } from 'luxon';

import format from '@/utils/format';
import { formatCountdown } from '@/game/clock';
import {
  bonusNumber, conditions, defenseFactor, fee, outlook, schoolBuilding,
} from '@/game/training';
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
      // wall clock, ticking each second for the countdowns
      now: Date.now(),
      clock: null,
    };
  },
  computed: {
    constant() { return this.$store.state.game.data.constant[0]; },
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    school() { return schoolBuilding(this.character); },
    view() {
      if (this.character.status !== 'student') return null;
      return outlook(this.character, this.constant, this.$store.state.game.time, this.speedFactor, this.now);
    },
    settle() { return this.view ? this.view.settle : null; },
    // "2.2 an hour, 51.6 a day", once settled in for a university
    xpText() {
      const perHour = (this.view.xpPerUt * 3600000) / this.view.msPerUt;
      const values = { hour: format.float(perHour, 1), day: format.float(perHour * 24, 1) };
      return this.$t(this.settle ? 'galaxy.school.panel_xp_after_settling' : 'galaxy.school.panel_xp_value', values);
    },
    timedFacts() {
      const { level, rewire, extraPoint, courseEnd } = this.view;
      const facts = [];

      if (level.until !== null) {
        facts.push({
          key: 'level',
          label: this.$t('galaxy.school.panel_level', { level: level.next }),
          hint: this.$t('galaxy.school.panel_level_hint'),
          until: level.until,
        });
      }

      if (rewire) {
        facts.push({
          key: 'rewire',
          label: this.$t('galaxy.school.panel_rewire', { count: rewire.next, max: rewire.max }),
          hint: this.$t('galaxy.school.panel_rewire_hint'),
          until: rewire.until,
        });
      }

      if (extraPoint) {
        facts.push({
          key: 'extra-point',
          label: this.$t('galaxy.school.panel_extra_point'),
          hint: this.$t('galaxy.school.panel_extra_point_hint', { count: extraPoint.rewires }),
          until: extraPoint.until,
        });
      }

      if (courseEnd) {
        facts.push({
          key: 'course-end',
          label: this.$t('galaxy.school.panel_course_end'),
          hint: this.$t('galaxy.school.panel_course_end_hint'),
          until: courseEnd,
        });
      }

      return facts;
    },
    cost() { return fee(this.character, this.constant); },
    defensePercent() { return Math.round(defenseFactor(this.character.training, this.constant) * 100); },
    // what the support buildings of its system give its course
    bonusText() {
      const { xpBonus, timeBonus, costBonus } = conditions(this.character.training);
      const parts = [];

      if (xpBonus) parts.push(this.$t('galaxy.school.system_xp', { percent: bonusNumber(xpBonus) }));
      if (timeBonus) parts.push(this.$t('galaxy.school.system_time', { percent: bonusNumber(timeBonus) }));
      if (costBonus) parts.push(this.$t('galaxy.school.system_cost', { percent: bonusNumber(costBonus) }));

      return parts.length > 0 ? parts.join(', ') : this.$t('galaxy.school.panel_no_bonus');
    },
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
  methods: {
    date(at) { return at === null ? '' : DateTime.fromMillis(at).toLocaleString(ETA_FORMAT); },
    countdown(at) { return formatCountdown(at - this.now); },
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
