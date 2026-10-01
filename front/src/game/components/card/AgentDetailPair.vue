<template>
  <!-- An agent's card beside what they command: the fleet for a
       Navarch, the network for a Siderian / Erased. Shared by the phone
       system-view dock and the selected-agent sheet so both show the
       same thing; the hosts only size it. -->
  <div
    class="agent-detail-pair"
    :class="{ 'has-plan': showPlan }">
    <!-- Orders first: "what is this agent doing" is the question the
         card is usually opened to answer. Absent on a foreign agent,
         whose redacted payload carries no action queue. A host with room
         beside the card (`plan`) gets the editable plan there instead of
         this strip. -->
    <agent-action-queue
      v-if="character.actions && !showPlan"
      class="adp-queue"
      :character="character"
      :theme="theme"
      :can-clear="canClear" />

    <!-- the host's own controls, above the card -->
    <div
      v-if="$slots.top"
      class="adp-top">
      <slot name="top" />
    </div>

    <div class="adp-card">
      <character-card
        :key="`adp-${character.id}`"
        :character="character"
        :theme="theme"
        :noAction="noAction" />
    </div>

    <agent-plan
      v-if="showPlan"
      class="adp-plan"
      compact
      :character="character"
      :theme="theme" />

    <div
      v-if="character.status === 'on_board'"
      class="adp-aside">
      <army
        v-if="character.type === 'admiral' && character.army"
        :theme="theme"
        valign="top"
        halign="right"
        context="display"
        :character="character" />
      <spy
        v-else-if="character.type === 'spy'"
        :character="character" />
      <speaker
        v-else-if="character.type === 'speaker'"
        :character="character" />
    </div>
  </div>
</template>

<script>
import CharacterCard from '@/game/components/card/CharacterCard.vue';
import AgentActionQueue from '@/game/components/galaxy/selection/ActionQueue.vue';
import AgentPlan from '@/game/components/galaxy/selection/AgentPlan.vue';
import Army from '@/game/components/galaxy/selection/Army.vue';
import Spy from '@/game/components/galaxy/selection/Spy.vue';
import Speaker from '@/game/components/galaxy/selection/Speaker.vue';

export default {
  name: 'agent-detail-pair',
  props: {
    // A FULL character (get_character), not a system.characters summary:
    // the card reads skills, xp and bonus pipelines a summary lacks.
    character: { type: Object, required: true },
    theme: { type: String, default: 'none' },
    noAction: { type: Boolean, default: false },
    // Show the orders as the editable plan (AgentPlan) beside the card,
    // not as the icon strip above it.
    plan: { type: Boolean, default: false },
  },
  computed: {
    // Only the owner may cancel queued orders.
    canClear() {
      return this.character.owner
        && this.character.owner.id === this.$store.state.game.player.id;
    },
    // The plan edits: it is for the owner's agents (anyone else's orders,
    // when visible at all, stay the read-only strip).
    showPlan() { return this.plan && !!this.character.actions && !!this.canClear; },
  },
  components: {
    CharacterCard, AgentActionQueue, AgentPlan, Army, Spy, Speaker,
  },
};
</script>
