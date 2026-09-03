<template>
  <div>
    <div
      v-for="bonus in bonuses"
      :key="bonus.key"
      class="complex-bonus">
      <!-- bonus DIRECT -->
      <template v-if="bonus.bonusIn.from === 'none'">
        <div>
          {{ $t(`data.bonus_pipeline_out.${bonus.to}.name`) }}
        </div>
        <div>
          <strong>{{ fmtDirect(bonus) }}</strong>
          <svgicon
            v-show="bonus.bonusOut.icon !== 'resource/resource'"
            v-tooltip="$t(`data.bonus_pipeline_out.${bonus.to}.name`)"
            :name="bonus.bonusOut.icon" />
        </div>
      </template>

      <!-- bonus FROM stellar_body -->
      <template v-else-if="bonus.bonusIn.from === 'stellar_body'">
        <div>
          {{ $t(`data.bonus_pipeline_out.${bonus.to}.name`) }}
          (<strong>
            {{ fmtUnit(bonus) }} ×
            <template v-if="body">{{ body[bonus.bonusIn.from_key] }}</template>
            <svgicon
              v-tooltip="$t(`data.bonus_pipeline_in.${bonus.from}.name`)"
              :name="bonus.bonusIn.icon" />
          </strong>)
        </div>
        <div>
          <strong v-if="body">{{ mul(bonus, body[bonus.bonusIn.from_key]) }}</strong>
          <strong v-else>?</strong>
          <svgicon
            v-show="bonus.bonusOut.icon !== 'resource/resource'"
            v-tooltip="$t(`data.bonus_pipeline_out.${bonus.to}.name`)"
            :name="bonus.bonusOut.icon" />
        </div>
      </template>

      <!-- bonus FROM outside  -->
      <template v-else-if="['stellar_system', 'player', 'army', 'spy', 'speaker'].includes(bonus.bonusIn.from)">
        <template v-if="bonus.from === bonus.to">
          <div>
            {{ $t(`data.bonus_pipeline_out.${bonus.to}.name`) }}
          </div>
          <div>
            <strong>
              {{ bonus.value * 100 | signed }}%
            </strong>
            <svgicon
              v-show="bonus.bonusOut.icon !== 'resource/resource'"
              v-tooltip="$t(`data.bonus_pipeline_out.${bonus.to}.name`)"
              :name="bonus.bonusOut.icon" />
          </div>
        </template>
        <template v-else>
          <div>
            {{ $t(`data.bonus_pipeline_out.${bonus.to}.name`) }}
            (<strong>
              {{ fmtUnit(bonus) }} ×
              <template v-if="system">{{ systemValue(bonus.bonusIn.from_key) }}</template>
              <svgicon
                v-tooltip="$t(`data.bonus_pipeline_in.${bonus.from}.name`)"
                :name="bonus.bonusIn.icon" />
            </strong>)
          </div>
          <div>
            <strong v-if="system">{{ mul(bonus, systemValue(bonus.bonusIn.from_key)) }}</strong>
            <strong v-else>?</strong>
            <svgicon
              v-show="bonus.bonusOut.icon !== 'resource/resource'"
              v-tooltip="$t(`data.bonus_pipeline_out.${bonus.to}.name`)"
              :name="bonus.bonusOut.icon" />
          </div>
        </template>
      </template>

      <!-- bonus FROM  -->
      <template v-else>
        {{ $t('card.complex_bonus.not_implemented') }}
      </template>
    </div>
  </div>
</template>

<script>
import format from '@/utils/format';

export default {
  name: 'card-complex-bonus',
  props: {
    bonus: Array,
    // stellar system
    body: {
      type: Object,
      required: false,
    },
    system: {
      type: Object,
      required: false,
    },
    // player
    player: {
      type: Object,
      required: false,
    },
  },
  computed: {
    bonuses() {
      return this.bonus.map((bonus) => {
        const bonusIn = this.bonusIn.find((b) => bonus.from === b.key);
        const bonusOut = this.bonusOut.find((b) => bonus.to === b.key);

        return { ...bonus, ...{ bonusIn, bonusOut } };
      });
    },
    bonusIn() { return this.$store.state.game.data.bonus_pipeline_in; },
    bonusOut() { return this.$store.state.game.data.bonus_pipeline_out; },
  },
  methods: {
    systemValue(key) {
      const prop = this.system?.[key];
      if (prop == null) return '?';
      return typeof prop === 'object' ? prop.value : prop;
    },
    // Flat bonuses to these pipeline-out targets are per-tick resource
    // rates, so the income-per-hour display setting applies. Everything
    // else (caps, coefficients, states) stays untouched.
    isIncomeBonus(bonus) {
      return [
        'sys_production', 'sys_technology', 'sys_ideology', 'sys_credit',
        'player_credit', 'player_technology', 'player_ideology',
        'army_maintenance',
      ].includes(bonus.to);
    },
    fmtDirect(bonus) {
      return this.isIncomeBonus(bonus)
        ? format.income(bonus.value, 1, true)
        : format.mixed(bonus.value, 1, true);
    },
    fmtUnit(bonus) {
      return this.isIncomeBonus(bonus)
        ? format.income(bonus.value, 1)
        : format.mixed(bonus.value);
    },
    mul(bonus, prop) {
      if (prop !== '?') {
        const result = bonus.value * prop;
        return this.isIncomeBonus(bonus)
          ? format.income(result, 1, true)
          : format.mixed(result, 1, true);
      }

      return '?';
    },
    formatMixedOrString(val) {
      if (typeof val === 'string') {
        return val;
      }
      return format.mixed(val, 1, true);
    },
  },
};
</script>
