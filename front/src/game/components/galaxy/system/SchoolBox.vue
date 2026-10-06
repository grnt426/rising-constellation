<template>
  <!-- The system's schools (docs/agent-training.md): the Delta Polytech
       and the university of each agent type, with the agents seated in
       them. A school is its building's icon (the name and the rules are in
       its tooltip) followed by its seats. An empty seat sends a deck agent
       there; a seated agent opens its card, and can be targeted like a
       governor. -->
  <div
    v-if="schools.length > 0"
    class="school-box system-content-group">
    <div class="system-content-group-header">
      <div class="main">{{ $t('galaxy.school.title') }}</div>

      <div class="school-list">
        <div
          v-for="school in schools"
          :key="school.key"
          :data-school="school.key"
          class="school">
          <div
            v-tooltip="school.hint"
            class="school-building"
            tabindex="0"
            :aria-label="school.label">
            <svgicon
              :name="`building/${school.building}`"
              class="school-icon" />
          </div>

          <div class="school-seats">
            <div
              v-for="student in school.students"
              :key="student.id"
              class="school-seat is-taken"
              :class="[`force-${themeOf(student)}`, { 'is-waiting': !inClass(student), 'has-ring': school.school === 'university' }]">
              <!-- one segment per rewire a course can earn, filled as
                   each is earned -->
              <svg
                v-if="school.school === 'university'"
                class="seat-ring"
                viewBox="0 0 44 44"
                aria-hidden="true">
                <path
                  v-for="(segment, i) in ringSegments"
                  :key="i"
                  :d="segment"
                  :class="{ 'is-earned': i < earned(student) }" />
              </svg>
              <div
                v-tooltip="studentTooltip(student)"
                class="round-icon is-small is-active has-hover"
                role="button"
                tabindex="0"
                :aria-label="studentLabel(student)"
                @click="openCharacter(student)"
                @keydown.enter.prevent="openCharacter(student)">
                <svgicon :name="`agent/${student.type}`" />
                <span class="number">{{ student.level }}</span>
              </div>

              <div
                v-for="action in targetActions(student)"
                :key="`${student.id}-${action.name}`"
                class="school-target">
                <div
                  v-if="action.status === 'available'"
                  v-tooltip="action.tooltip"
                  class="actions-item is-active has-hover"
                  @click="doCharacterAction(action.icon, student.id)"
                  @mouseover="hoveredAction = `${student.id}-${action.name}`"
                  @mouseleave="hoveredAction = null">
                  <svgicon :name="`action/${action.icon}_alt`" />
                </div>
                <div
                  v-else
                  v-tooltip="action.reasons"
                  class="actions-item is-disabled">
                  <svgicon :name="`action/${action.icon}_alt`" />
                </div>
                <action-overview
                  v-if="action.overview && hoveredAction === `${student.id}-${action.name}`"
                  class="is-top-shifted"
                  :data="action.overview" />
              </div>
            </div>

            <div
              v-for="n in school.free"
              :key="`free-${n}`"
              v-tooltip="school.enrollHint"
              class="school-seat is-empty"
              :class="{ 'is-clickable': school.canEnroll }"
              :role="school.canEnroll ? 'button' : null"
              :tabindex="school.canEnroll ? 0 : null"
              :aria-label="school.canEnroll ? school.enrollHint : null"
              @click="enroll(school)"
              @keydown.enter.prevent="enroll(school)">
              <span class="seat-plus">+</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import actionValidation from '@/utils/actionValidation';
import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';
import { SCHOOL_BUILDINGS, inClass, trainingStatus } from '@/game/training';

const TYPES = ['admiral', 'spy', 'speaker'];

export default {
  name: 'school-box',
  props: {
    system: Object,
    isOwnSystem: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
    };
  },
  computed: {
    player() { return this.$store.state.game.player; },
    constant() { return this.$store.state.game.data.constant[0]; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    students() { return Array.isArray(this.system.students) ? this.system.students : []; },
    // The ring around a university student: as many arcs as a course earns
    // rewires, drawn clockwise from the top with a gap between them.
    ringSegments() {
      const count = this.constant.university_max_reallocations || 0;
      const center = 22;
      const radius = 19.5;
      const gap = 16; // degrees
      const point = (degrees) => {
        const angle = ((degrees - 90) * Math.PI) / 180;
        return `${(center + radius * Math.cos(angle)).toFixed(2)} ${(center + radius * Math.sin(angle)).toFixed(2)}`;
      };

      return Array.from({ length: count }, (_, i) => {
        const from = (360 / count) * i + gap / 2;
        const to = (360 / count) * (i + 1) - gap / 2;
        return `M ${point(from)} A ${radius} ${radius} 0 0 1 ${point(to)}`;
      });
    },
    // Seats are only sent to the faction that owns the system.
    isFactionSystem() {
      return this.system.status === 'inhabited_player'
        && this.system.owner && this.system.owner.faction === this.player.faction;
    },
    schools() {
      const seats = this.system.schools || null;

      const list = [{
        key: 'polytech',
        school: 'polytech',
        type: null,
        building: SCHOOL_BUILDINGS.polytech,
        students: this.students.filter((s) => s.training && s.training.school === 'polytech'),
        seats: seats && seats.polytech,
      }].concat(TYPES.map((type) => ({
        key: type,
        school: 'university',
        type,
        building: SCHOOL_BUILDINGS[type],
        students: this.students.filter((s) => s.training && s.training.school === 'university' && s.type === type),
        seats: seats && seats[type],
      })));

      return list
        .filter((entry) => entry.students.length > 0 || (entry.seats && entry.seats.slots > 0))
        .map((entry) => {
          const slots = entry.seats ? entry.seats.slots : null;
          const used = entry.seats ? entry.seats.used : null;
          const canEnroll = this.canEnroll(entry);

          const name = this.$t(`data.building.${entry.building}.name`);
          const seats = slots === null ? '' : ` ${used}/${slots}`;
          const rules = this.schoolHint(entry);

          return {
            ...entry,
            slots,
            used,
            free: slots === null ? 0 : Math.max(slots - used, 0),
            canEnroll,
            label: `${name}${seats}. ${rules}`,
            hint: { content: `<strong>${name}</strong>${seats}<br>${rules}`, html: true },
            enrollHint: this.enrollHint(entry, canEnroll),
          };
        });
    },
  },
  methods: {
    inClass(student) { return inClass(student.training); },
    // rewires earned so far; hidden from a faction without full visibility
    earned(student) { return student.reallocations || 0; },
    rewiresLine(student) {
      if (student.training.school !== 'university' || typeof student.reallocations !== 'number') return '';

      return `, ${this.$t('galaxy.school.rewires_earned', {
        count: student.reallocations,
        max: this.constant.university_max_reallocations,
      })}`;
    },
    themeOf(student) { return this.$store.getters['game/themeByKey'](student.owner.faction); },
    canEnroll(entry) {
      if (!this.isFactionSystem || this.system.siege) return false;
      // a Polytech is its owner's alone; a university also takes faction-mates
      return entry.school === 'university' || this.isOwnSystem;
    },
    schoolHint(entry) {
      if (entry.school === 'polytech') return this.$t('galaxy.school.polytech_hint');

      return this.$t('galaxy.school.university_hint', {
        agents: this.$tc(`data.character.${entry.type}.name`, 2),
        fee: this.feePerLevel(entry.type),
        resource: this.$t(`galaxy.school.fee_${this.feeResource(entry.type)}`),
      });
    },
    enrollHint(entry, canEnroll) {
      if (!canEnroll) {
        if (this.system.siege && this.isFactionSystem) return this.$t('galaxy.school.no_enroll_siege');
        if (entry.school === 'polytech' && this.isFactionSystem) return this.$t('galaxy.school.owner_only');
        return this.$t('galaxy.school.free_seat');
      }

      if (entry.school === 'polytech') return this.$t('galaxy.school.enroll_polytech');

      return this.isOwnSystem
        ? this.$t('galaxy.school.enroll_university', { agent: this.$tc(`data.character.${entry.type}.name`, 1) })
        : this.$t('galaxy.school.enroll_university_guest', {
          agent: this.$tc(`data.character.${entry.type}.name`, 1),
          level: this.constant.university_guest_min_level,
        });
    },
    feeResource(type) {
      return { admiral: 'technology', spy: 'credit', speaker: 'ideology' }[type];
    },
    feePerLevel(type) {
      return this.constant[`university_fee_${this.feeResource(type)}`];
    },
    studentLabel(student) {
      return `${this.$tc(`data.character.${student.type}.name`, 1)} ${student.name}, `
        + `${trainingStatus(this, student)}${this.rewiresLine(student)}`;
    },
    studentTooltip(student) {
      const owner = student.owner.id === this.player.id ? '' : ` (${student.owner.name})`;
      return `${student.name}${owner}: ${trainingStatus(this, student)}${this.rewiresLine(student)}`;
    },
    // A student is a target like a governor: an Erased can remove it, a
    // Siderian can win it over.
    targetActions(student) {
      const actions = { character: student, actions: [] };
      const selected = this.selectedCharacter;

      if (!selected || student.owner.id === this.player.id) return actions.actions;

      const context = {
        vm: this,
        selectedCharacter: selected,
        system: this.system,
        characterTheme: this.$store.getters['game/themeByKey'](selected.owner.faction),
      };
      const targetTheme = this.themeOf(student);

      if (selected.type === 'spy') {
        actionValidation.assassination(actions, context, student, targetTheme);
      }

      if (selected.type === 'speaker') {
        actionValidation.conversion(actions, context, student, this.player, targetTheme);
      }

      return actions.actions;
    },
    doCharacterAction(action, targetId) {
      this.hoveredAction = null;
      this.$root.$emit('map:addAction', action, { character: targetId, system: this.system });
    },
    openCharacter(student) {
      this.$store.dispatch('game/openCharacter', { vm: this, id: student.id });
    },
    enroll(school) {
      if (!school.canEnroll) return;

      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', {
        systemId: this.system.id,
        mode: 'student',
        school: school.school,
        type: school.type,
        guest: !this.isOwnSystem,
      });
    },
  },
  components: {
    ActionOverview,
  },
};
</script>
