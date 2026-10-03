<template>
  <!-- Governor: any agent type, governor skills set freely (0-12 each).
       Only skills 3-5 act on the system they govern, so those are the
       ones shown; an imported governor's agent skills ride along. -->
  <div class="planner-governor">
    <div
      class="planner-governor-types"
      role="radiogroup"
      :aria-label="$t('page.system_planner.governor')">
      <button
        v-for="type in types"
        :key="type || 'none'"
        type="button"
        role="radio"
        class="planner-governor-type"
        :class="{ 'is-active': currentType === type }"
        :aria-checked="currentType === type ? 'true' : 'false'"
        @click="setType(type)">
        <svgicon :name="type ? `agent/${type}` : 'close'" />
        <span>{{ type ? $tc(`data.character.${type}.name`, 1) : $t('page.system_planner.no_governor') }}</span>
      </button>
    </div>

    <template v-if="governor">
      <div
        v-for="i in skillIndexes"
        :key="i"
        class="planner-skill">
        <div class="planner-skill-head">
          <span v-tooltip="$t(`data.character.${governor.type}.skills[${i}].description`)">
            {{ $t(`data.character.${governor.type}.skills[${i}].name`) }}
          </span>
          <span class="planner-skill-value">{{ governor.skills[i] }}</span>
        </div>
        <div
          class="planner-skill-points"
          role="slider"
          tabindex="0"
          :aria-label="$t(`data.character.${governor.type}.skills[${i}].name`)"
          aria-valuemin="0"
          :aria-valuemax="maxSkill"
          :aria-valuenow="governor.skills[i]"
          @keydown.left.prevent="setSkill(i, governor.skills[i] - 1)"
          @keydown.down.prevent="setSkill(i, governor.skills[i] - 1)"
          @keydown.right.prevent="setSkill(i, governor.skills[i] + 1)"
          @keydown.up.prevent="setSkill(i, governor.skills[i] + 1)">
          <span
            v-for="s in maxSkill"
            :key="s"
            class="planner-skill-point"
            :class="{ 'is-active': s <= governor.skills[i], 'is-strong': s === governor.skills[i] }"
            @click="setSkill(i, s === governor.skills[i] ? s - 1 : s)" />
        </div>
        <div
          v-if="effect(i)"
          class="planner-skill-effect">
          {{ effect(i) }}
        </div>
      </div>
    </template>
  </div>
</template>

<script>
import { GOVERNOR_SKILLS, MAX_SKILL, SKILL_COUNT } from '@/portal/planner/plan';

export default {
  name: 'planner-governor',
  props: {
    governor: { type: Object, default: null },
    data: { type: Object, required: true },
  },
  data() {
    return {
      skillIndexes: GOVERNOR_SKILLS,
      maxSkill: MAX_SKILL,
    };
  },
  computed: {
    types() {
      return [null, ...this.data.character.map((c) => c.key)];
    },
    currentType() { return this.governor ? this.governor.type : null; },
    characterData() {
      return this.governor ? this.data.character.find((c) => c.key === this.governor.type) : null;
    },
  },
  methods: {
    setType(type) {
      if (type === this.currentType) return;
      if (!type) {
        this.$emit('update', null);
        return;
      }
      // switching type keeps the skill points where they are
      const skills = this.governor ? [...this.governor.skills] : Array(SKILL_COUNT).fill(0);
      this.$emit('update', { type, name: this.governor ? this.governor.name : null, skills });
    },
    setSkill(index, value) {
      const next = Math.max(0, Math.min(MAX_SKILL, value));
      if (next === this.governor.skills[index]) return;
      const skills = [...this.governor.skills];
      skills[index] = next;
      this.$emit('update', { ...this.governor, skills });
    },
    // "+18 Stability": the skill's bonus at its current points
    effect(index) {
      const spec = this.characterData && this.characterData.specializations.find((s) => s.index === index);
      const points = this.governor.skills[index];
      if (!spec || !spec.bonus.length) return '';
      return spec.bonus.map((b) => {
        const total = b.value * points;
        const amount = b.type === 'mul'
          ? `+${Math.round(total * 100)}%`
          : `+${Math.round(total * 10) / 10}`;
        return `${amount} ${this.$t(`data.bonus_pipeline_out.${b.to}.name`)}`;
      }).join(' · ');
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-governor-types {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 4px;
  margin-bottom: 12px;
}

.planner-governor-type {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 8px;
  border: solid 1px rgba(255, 255, 255, .12);
  background: rgba(0, 0, 0, .25);
  color: $white-alt-2;
  font: inherit;
  font-size: 1.2rem;
  text-transform: uppercase;
  cursor: pointer;

  .svg-icon {
    flex: 0 0 auto;
    width: 18px;
    height: 18px;
  }

  &:hover { color: $white; }

  &.is-active {
    color: $white;
    border-color: $white;
    background: rgba(255, 255, 255, .08);
    font-weight: bold;
  }
}

.planner-skill {
  margin-bottom: 10px;
}

.planner-skill-head {
  display: flex;
  justify-content: space-between;
  font-size: 1.3rem;
  text-transform: uppercase;

  .planner-skill-value {
    font-weight: bold;
    font-variant-numeric: tabular-nums;
  }
}

// the character card's thin skill bars, with a tall enough hit area
.planner-skill-points {
  display: flex;
  align-items: center;
  height: 18px;
  cursor: pointer;

  &:focus-visible {
    outline: solid 1px $white;
    outline-offset: 2px;
  }
}

.planner-skill-point {
  flex: 1 1 0;
  height: 100%;
  margin-left: 2px;
  position: relative;

  &::before {
    content: '';
    position: absolute;
    left: 0;
    right: 0;
    top: 6px;
    height: 6px;
    background: rgba(255, 255, 255, .12);
  }

  &.is-active::before { background: $light-grey; }
  &.is-strong::before { background: $white; }
  &:hover::before { box-shadow: 0 0 0 1px rgba(255, 255, 255, .6); }
}

.planner-skill-effect {
  font-size: 1.2rem;
  opacity: .7;
}

// the faction's color, like the character card's skill bars
@each $class, $color in $themes-list {
  .f-#{$class} .planner-skill-point {
    &.is-active::before { background: $color; }
    &.is-strong::before { background: lighten($color, $color-variant-4); }
  }
}
</style>
