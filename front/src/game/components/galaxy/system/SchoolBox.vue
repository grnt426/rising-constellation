<template>
  <!-- The system's schools (docs/agent-training.md): the Delta Polytech
       and the university of each agent type, with the agents seated in
       them. A school is its building's icon (the name and the rules are in
       its tooltip) followed by its seats. An empty seat sends a deck agent
       there; a seated agent opens its card, and can be targeted like a
       governor. One deck agent may wait in the queue behind each seated
       student: hovering the student shows it, or the place to take, above
       the seat. Only the faction that owns the system is sent the queue. -->
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
              :class="[`force-${themeOf(student)}`, {
                'has-ring': school.school === 'university',
                'has-queue': !!queuedBehind(student),
              }]">
              <!-- settling in: one ring that fills until the course
                   starts. Then one segment per rewire the course can
                   earn, filled as each is earned -->
              <svg
                v-if="school.school === 'university'"
                class="seat-ring"
                :class="{ 'is-settling': !!settlingOf(student) }"
                viewBox="0 0 44 44"
                aria-hidden="true">
                <template v-if="settlingOf(student)">
                  <circle
                    class="settle-track"
                    cx="22"
                    cy="22"
                    :r="ringRadius" />
                  <circle
                    class="settle-fill"
                    cx="22"
                    cy="22"
                    :r="ringRadius"
                    transform="rotate(-90 22 22)"
                    :stroke-dasharray="settleDash(student)" />
                </template>
                <template v-else>
                  <path
                    v-for="(segment, i) in ringSegments"
                    :key="i"
                    :d="segment"
                    :class="{ 'is-earned': i < earned(student) }" />
                </template>
              </svg>
              <!-- the queue behind this student pops up above its icon;
                   the student's own tooltip then goes below -->
              <hover-popover
                class="seat-popover"
                placement="top"
                popover-class="school-queue-popover"
                :disabled="isMobileView || !hasQueuePlace(school, student)">
                <div
                  v-tooltip="studentTooltip(school, student)"
                  class="round-icon is-small is-active has-hover"
                  role="button"
                  tabindex="0"
                  :aria-label="studentLabel(student)"
                  @click="openCharacter(student)"
                  @keydown.enter.prevent="openCharacter(student)">
                  <svgicon :name="`agent/${student.type}`" />
                  <span class="number">{{ student.level }}</span>
                </div>
                <school-queue-slot
                  slot="popover"
                  :student="student"
                  :entry="queuedBehind(student)"
                  :action="queuedAction(queuedBehind(student))"
                  @join="enroll(school, student)"
                  @leave="leaveQueue(queuedBehind(student))"
                  @eject="leaveQueue(queuedBehind(student))" />
              </hover-popover>
              <span
                v-if="queuedBehind(student)"
                class="queue-pip"
                aria-hidden="true"></span>
              <!-- the popover is out of the tab order: the place in the
                   queue is also a button of its own for the keyboard -->
              <button
                v-if="!isMobileView && canQueue(school) && !queuedBehind(student)"
                type="button"
                class="sr-only"
                @click="enroll(school, student)">
                {{ $t('galaxy.school.queue_join', { name: student.name }) }}
              </button>
              <!-- phones have no hover: the queue sits next to the seat -->
              <school-queue-slot
                v-if="isMobileView && hasQueuePlace(school, student)"
                class="is-inline"
                :student="student"
                :entry="queuedBehind(student)"
                :action="queuedAction(queuedBehind(student))"
                @join="enroll(school, student)"
                @leave="leaveQueue(queuedBehind(student))"
                @eject="leaveQueue(queuedBehind(student))" />

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
import viewport from '@/utils/viewport';
import ActionOverview from '@/game/components/galaxy/system/ActionOverview.vue';
import HoverPopover from '@/game/components/generic/HoverPopover.vue';
import SchoolQueueSlot from '@/game/components/galaxy/system/SchoolQueueSlot.vue';
import { formatCountdown } from '@/game/clock';
import {
  SCHOOL_BUILDINGS, inClass, settling, trainingStatus,
} from '@/game/training';

const TYPES = ['admiral', 'spy', 'speaker'];
// the ring around a university student, in the 44 x 44 box of its svg
const RING_RADIUS = 19.5;

export default {
  name: 'school-box',
  props: {
    system: Object,
    isOwnSystem: Boolean,
  },
  data() {
    return {
      hoveredAction: null,
      // wall clock, ticking while the box is shown: a settling-in ring fills
      now: Date.now(),
      clock: null,
    };
  },
  mounted() {
    this.clock = setInterval(() => { this.now = Date.now(); }, 1000);
  },
  beforeDestroy() {
    clearInterval(this.clock);
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    player() { return this.$store.state.game.player; },
    constant() { return this.$store.state.game.data.constant[0]; },
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    ringRadius() { return RING_RADIUS; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    students() { return Array.isArray(this.system.students) ? this.system.students : []; },
    // deck agents waiting for a seat; only sent to the owner's faction
    queue() { return Array.isArray(this.system.school_queue) ? this.system.school_queue : []; },
    // The ring around a university student: as many arcs as a course earns
    // rewires, drawn clockwise from the top with a gap between them.
    ringSegments() {
      const count = this.constant.university_max_reallocations || 0;
      const center = 22;
      const radius = RING_RADIUS;
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
    // where a student stands in its settling in right now, null once on
    // its course (see training.js)
    settlingOf(student) {
      return settling(student.training, this.constant, this.$store.state.game.time, this.speedFactor, this.now);
    },
    settleDash(student) {
      const around = 2 * Math.PI * RING_RADIUS;
      return `${(this.settlingOf(student).progress * around).toFixed(2)} ${around.toFixed(2)}`;
    },
    // ", 3 H 12 M left. XP and neural rewires are earned after settling in"
    settlingLine(student) {
      const settle = settling(student.training, this.constant, this.$store.state.game.time, this.speedFactor);
      if (!settle) return '';

      const left = settle.until === null
        ? ''
        : `, ${this.$t('galaxy.school.settling_left', { time: formatCountdown(settle.until - Date.now()) })}`;

      return `${left}. ${this.$t('galaxy.school.settling_hint')}`;
    },
    queuedBehind(student) { return this.queue.find((entry) => entry.behind === student.id) || null; },
    // A place in the queue is for a school with no free seat, under the
    // rules of a seat: no siege, and a Polytech is its owner's alone.
    canQueue(school) { return school.canEnroll && school.free === 0 && school.slots !== null; },
    // something to show above the seat: who waits, or the place to take
    hasQueuePlace(school, student) { return !!this.queuedBehind(student) || this.canQueue(school); },
    // what a click on a queued agent does: its owner takes it out of the
    // queue, the owner of the system sends it out
    queuedAction(entry) {
      if (!entry) return null;
      if (entry.owner.id === this.player.id) return 'leave';
      return this.isOwnSystem ? 'eject' : null;
    },
    leaveQueue(entry) {
      const action = this.queuedAction(entry);
      if (!action) return;

      const push = action === 'leave'
        ? this.$socket.player.push('leave_school_queue', { character_id: entry.id })
        : this.$socket.player.push('eject_student', { system_id: this.system.id, character_id: entry.id });

      push.receive('ok', () => {
        this.$store.dispatch('game/reloadSystem', this.$socket);
      }).receive('error', (err) => {
        this.$toastError(err.reason);
      });
    },
    // rewires earned so far; hidden from a faction without full visibility
    earned(student) { return student.reallocations || 0; },
    rewiresLine(student) {
      if (student.training.school !== 'university' || typeof student.reallocations !== 'number') return '';

      return `, ${this.$t('galaxy.school.rewires_earned', {
        count: student.reallocations,
        max: this.constant.university_max_reallocations,
      })}`;
    },
    // how far along: the time left to settle in, then the rewires earned
    progressLine(student) { return this.settlingLine(student) || this.rewiresLine(student); },
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
        level: this.constant.university_min_level,
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

      return this.$t('galaxy.school.enroll_university', {
        agent: this.$tc(`data.character.${entry.type}.name`, 1),
        level: this.constant.university_min_level,
      });
    },
    feeResource(type) {
      return { admiral: 'technology', spy: 'credit', speaker: 'ideology' }[type];
    },
    feePerLevel(type) {
      return this.constant[`university_fee_${this.feeResource(type)}`];
    },
    queuedLine(student) {
      const entry = this.queuedBehind(student);
      return entry ? `. ${this.$t('galaxy.school.queue_waiting', { name: entry.name })}` : '';
    },
    studentLabel(student) {
      return `${this.$tc(`data.character.${student.type}.name`, 1)} ${student.name}, `
        + `${trainingStatus(this, student)}${this.progressLine(student)}${this.queuedLine(student)}`;
    },
    // below the seat when the queue pops up above it
    studentTooltip(school, student) {
      const owner = student.owner.id === this.player.id ? '' : ` (${student.owner.name})`;

      return {
        // a function: the time left is read when the tooltip opens
        content: () => `${student.name}${owner}: ${trainingStatus(this, student)}${this.progressLine(student)}`,
        placement: this.hasQueuePlace(school, student) && !this.isMobileView ? 'bottom' : 'top',
      };
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
    // `behind`: the student to wait for, when the seat is not free
    enroll(school, behind = null) {
      if (!school.canEnroll) return;

      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', {
        systemId: this.system.id,
        mode: 'student',
        school: school.school,
        type: school.type,
        guest: !this.isOwnSystem,
        behind: behind ? behind.id : null,
      });
    },
  },
  components: {
    ActionOverview,
    HoverPopover,
    SchoolQueueSlot,
  },
};
</script>
