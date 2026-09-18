<template>
  <!-- An agent's card beside what they command: the fleet for a
       Navarch, the network for a Siderian / Erased. Shared by the phone
       system-view dock and the selected-agent sheet so both show the
       same thing; the hosts only size it. -->
  <div class="agent-detail-pair">
    <div class="adp-card">
      <character-card
        :key="`adp-${character.id}`"
        :character="character"
        :theme="theme"
        :noAction="noAction" />
    </div>

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
  },
  components: { CharacterCard, Army, Spy, Speaker },
};
</script>
