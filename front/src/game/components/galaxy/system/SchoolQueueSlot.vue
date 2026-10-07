<template>
  <!-- The queue behind a seated student (docs/agent-training.md): the deck
       agent waiting for its seat, or the place to take when nobody waits.
       Shown above the seat in a popover, which renders in <body>, outside
       .game-context: its styles are top-level (shared/school-queue.scss)
       and it borrows nothing from the system view. -->
  <div
    class="school-queue"
    :class="`force-${theme}`">
    <div
      v-if="entry"
      v-tooltip="tooltip"
      class="queue-agent"
      :class="{ 'has-hover': !!action }"
      :role="action ? 'button' : null"
      tabindex="0"
      :aria-label="label"
      @click="act"
      @keydown.enter.prevent="act">
      <svgicon :name="`agent/${entry.type}`" />
      <span class="number">{{ entry.level }}</span>
    </div>
    <div
      v-else
      v-tooltip="$t('galaxy.school.queue_join', { name: student.name })"
      class="queue-place"
      role="button"
      tabindex="0"
      :aria-label="$t('galaxy.school.queue_join', { name: student.name })"
      @click="$emit('join')"
      @keydown.enter.prevent="$emit('join')">
      <span class="seat-plus">+</span>
    </div>
  </div>
</template>

<script>
export default {
  name: 'school-queue-slot',
  props: {
    // the seated student the queue is behind
    student: Object,
    // the agent waiting behind it, if any
    entry: Object,
    // what a click on the waiting agent does: 'leave' (its owner takes it
    // out), 'eject' (the owner of the system sends it out) or null
    action: String,
  },
  computed: {
    player() { return this.$store.state.game.player; },
    theme() {
      return this.$store.getters['game/themeByKey']((this.entry || this.student).owner.faction);
    },
    label() {
      const owner = this.entry.owner.id === this.player.id ? '' : ` (${this.entry.owner.name})`;
      return this.$t('galaxy.school.queue_waiting', { name: `${this.entry.name}${owner}` });
    },
    tooltip() {
      const hint = this.action ? `<br>${this.$t(`galaxy.school.queue_${this.action}`)}` : '';
      return { content: `${this.label}${hint}`, html: true };
    },
  },
  methods: {
    act() {
      if (this.action) this.$emit(this.action);
    },
  },
};
</script>
