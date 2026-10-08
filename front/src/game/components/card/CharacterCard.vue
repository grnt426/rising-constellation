<template>
  <div
    class="card-container"
    :class="[`f-${theme}`, { 'is-mobile-card': isMobileView }]"
    ref="card"
    role="group"
    :aria-label="ariaName"
    @click="select">
    <!-- Screen readers get the card as one summary (stats, skills, and
         whether a fleet exists); the visual blocks below are hidden from
         them. Views that open a card focus this paragraph so it is read
         out right away (focusSummary). -->
    <p
      ref="srSummary"
      class="sr-only"
      tabindex="-1">{{ ariaSummary }}</p>

    <div class="card-header">
      <div
        class="card-header-icon"
        aria-hidden="true">
        <svgicon :name="`agent/${character.type}`" />
        <span class="level">
          <template v-if="diff">
            {{ diff.level | obfuscate(diff.level, '?') }}
          </template>
          <template v-else>
            {{ character.level | obfuscate(character.level, '?') }}
          </template>
        </span>
        <span
          v-show="group"
          class="group">
          {{ group }}
        </span>
        <span
          v-if="armadaSize"
          class="armada">
          <svgicon name="layers" />
        </span>
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          <span aria-hidden="true">
            <span v-if="isDead">(&#x271d;)</span>
            {{ character.name }}
          </span>
          <help-button :page="`agent/${character.type}`" />
        </div>
        <div
          class="title-small nowrap"
          aria-hidden="true">
          {{ $t(specialization(character)) }}
        </div>
      </div>
    </div>

    <div
      class="card-body"
      aria-hidden="true">
      <div class="card-illustration">
        <img
          :src="`data/agents/${character.illustration}`"
          alt="">
        <div
          v-if="trainingRibbon"
          v-tooltip="trainingRibbon.hint"
          class="card-ribbon">
          {{ trainingRibbon.text }}
        </div>
        <!-- waiting for a seat at a school: the longest it can take -->
        <div
          v-if="seatWait"
          v-tooltip="seatWaitHint"
          class="card-ribbon is-queued">
          {{ seatWaitText }}
        </div>
        <div
          v-if="reallocationsHeld > 0"
          v-tooltip="$t('card.character.reallocation_hint')"
          class="card-ribbon is-reallocations"
          :class="{ 'is-clickable': canReallocate, 'is-open': reallocating }"
          @click.stop="toggleReallocation">
          <template v-if="reallocating">
            {{ $t('card.character.reallocation_progress', { moved: reallocationMoved, total: reallocationsHeld }) }}
          </template>
          <template v-else>
            {{ $tc('card.character.reallocations', reallocationsHeld, { count: reallocationsHeld }) }}
          </template>
        </div>
      </div>

      <div class="card-information">
        <div class="card-panel-controls">
          <svgicon
            class="card-panel-control"
            name="caret-left"
            @click="movePanelToLeft"
            v-if="leftControl" />
          <div v-else></div>
          <svgicon
            class="card-panel-control"
            name="caret-right"
            @click="movePanelToRight"
            v-if="rightControl" />
          <div v-else></div>
        </div>

        <div class="card-panel-window">
          <div
            ref="panelContainer"
            class="card-panel-container"
            :style="{ left: panelContainerPosition + 'px' }">
            <div class="card-panel">
              <div class="is-sparse-y">
                <div v-if="character.experience === null">
                  ░░░ ░░░░░░░
                </div>
                <div v-else>
                  <dynamic-value
                    v-if="character.status === 'governor'"
                    :initial="character.experience" />
                  <dynamic-value
                    v-else-if="studentExperience"
                    :initial="studentExperience" />
                  <span v-else>
                    {{ character.experience.value | integer }}
                  </span>
                  <span class="card-diff" v-if="diff && diff.experience.value - character.experience.value > 0">
                    +{{ diff.experience.value - character.experience.value | integer }}
                  </span>
                  / {{ nextLevelExperience | integer }}
                  <strong>XP</strong>
                </div>
                <div>
                  {{ $t(`data.culture.${character.culture}.kind`) }}
                </div>
              </div>

              <div class="is-sparse-y">
                <div>
                  <div
                    v-tooltip="defenseTooltip('protection')"
                    class="simple-bonus"
                    :class="{ 'is-cut': isInClass }">
                    {{ character.protection | obfuscate(effective(character.protection), '░░') }}
                    <span class="card-diff" v-if="diff && diff.protection - character.protection > 0">
                      +{{ diff.protection - character.protection | integer }}
                    </span>
                    <svgicon name="agent/protection" />
                  </div>
                  <div
                    v-tooltip="defenseTooltip('determination')"
                    class="simple-bonus"
                    :class="{ 'is-cut': isInClass }">
                    {{ character.determination | obfuscate(effective(character.determination), '░░') }}
                    <span class="card-diff" v-if="diff && diff.determination - character.determination > 0">
                      +{{ diff.determination - character.determination | integer }}
                    </span>
                    <svgicon name="agent/determination" />
                  </div>
                </div>
                <div>
                  <div
                    v-tooltip="$t('card.character.salary')"
                    class="simple-bonus">
                    {{ character.level * constant.character_level_wages | income(0) }}
                    <span class="card-diff" v-if="diff && (diff.level - character.level) * constant.character_level_wages > 0">
                      +{{ (diff.level - character.level) * constant.character_level_wages | income(0) }}
                    </span>
                    <svgicon name="resource/credit" />
                  </div>
                </div>
              </div>

              <hr>

              <!-- .card-skills is layout-inert on desktop; on mobile it
                   becomes a split bar chart (agent | governor) -->
              <div class="card-skills">
                <template v-if="character.skills">
                  <div
                    v-for="(skill, i) in shownSkills"
                    :key="i"
                    class="card-skill-block">
                    <h2 v-if="i === 0">{{ $t('card.character.agent') }}</h2>
                    <h2 v-if="i === 3">{{ $t('card.character.governor') }}</h2>
                    <div
                      v-tooltip.left="skillTooltip(i)"
                      :class="{ 'character-skill-active': data.specializations[i].key === character.specialization }"
                      class="is-sparse-y">
                      <div class="skill-name">{{ $t(`data.character.${character.type}.skills[${i}].name`) }}</div>
                      <div
                        v-if="reallocating"
                        class="skill-reallocation">
                        <button
                          type="button"
                          :disabled="!canTake(i)"
                          :aria-label="$t('card.character.reallocation_take', { skill: skillName(i) })"
                          @click.stop="take(i)">&minus;</button>
                        <button
                          type="button"
                          :disabled="!canGive(i)"
                          :aria-label="$t('card.character.reallocation_give', { skill: skillName(i) })"
                          @click.stop="give(i)">+</button>
                      </div>
                      <span
                        v-if="isMobileView"
                        class="skill-value">{{ skill }}</span>
                      <div class="character-skill-points">
                        <template v-if="diff && skill !== diff.skills[i]">
                          <span
                            v-for="s in 12"
                            :key="s"
                            :class="{
                              'active': s <= skill,
                              'strong': s === skill,
                              'lvlup': s === skill + 1,
                              'inactive': s > skill + 1,
                            }">
                          </span>
                        </template>
                        <template v-else>
                          <span
                            v-for="s in 12"
                            :key="s"
                            :class="{
                              'active': s <= skill,
                              'strong': s === skill,
                              'inactive': s > skill,
                              'gained': reallocating && s > character.skills[i] && s <= skill,
                              'lost': reallocating && s > skill && s <= character.skills[i],
                            }">
                          </span>
                        </template>
                      </div>
                    </div>
                  </div>
                </template>
                <template v-else>
                  <div
                    v-for="i in [0, 1, 2, 3, 4, 5]"
                    :key="i"
                    class="card-skill-block">
                    <h2 v-if="i === 0">{{ $t('card.character.agent') }}</h2>
                    <h2 v-if="i === 3">{{ $t('card.character.governor') }}</h2>
                    <div
                      v-tooltip.left="skillTooltip(i)"
                      class="is-sparse-y">
                      <div class="skill-name">{{ $t(`data.character.${character.type}.skills[${i}].name`) }}</div>
                      <span
                        v-if="isMobileView"
                        class="skill-value">&#9617;</span>
                      <div class="character-skill-points">
                        <span
                          v-for="s in 12"
                          :key="s"
                          class="hidden">
                        </span>
                      </div>
                    </div>
                  </div>
                </template>
              </div>
            </div>

            <div class="card-panel">
              <h2>{{ $t('card.character.about') }}</h2>
              <p>{{ $t('card.character.gender_age', {
                gender: character.gender === null || character.gender === 'hidden' ? '░░░░' : $t(`card.character.gender_${character.gender}`),
                age: character.age === null || character.age === 'hidden' ? '░░' : character.age,
              }) }}</p>
              <p>{{ $t('card.character.origin', {
                culture: $t(`data.culture.${character.culture}.name`),
              }) }}</p>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      class="card-action"
      v-if="!child && !noAction">
      <div class="card-action-button">
        <div
          v-if="character.on_sold"
          v-press="{ disabled: true }"
          class="button disabled">
          <div class="dashed">
            {{ $t('card.character.on_sold') }}
          </div>
        </div>
        <div
          v-else-if="character.status === 'for_hire'"
          v-press
          class="button"
          :class="{ 'is-unaffordable': !canAfford }"
          @click="hire">
          <div>{{ $t('card.character.hire') }}</div>
          <div
            class="icon-value"
            :class="{ 'is-insufficient': !affordability.credit }"
            v-if="character.credit_cost > 0">
            {{ formatCost(character.credit_cost) }}
            <svgicon name="resource/credit" aria-hidden="true" />
            <span class="sr-only">{{ $t('a11y.resource.credit') }}</span>
          </div>
          <div
            class="icon-value"
            :class="{ 'is-insufficient': !affordability.technology }"
            v-if="character.technology_cost > 0">
            {{ formatCost(character.technology_cost) }}
            <svgicon name="resource/technology" aria-hidden="true" />
            <span class="sr-only">{{ $t('a11y.resource.technology') }}</span>
          </div>
          <div
            class="icon-value"
            :class="{ 'is-insufficient': !affordability.ideology }"
            v-if="character.ideology_cost > 0">
            {{ formatCost(character.ideology_cost) }}
            <svgicon name="resource/ideology" aria-hidden="true" />
            <span class="sr-only">{{ $t('a11y.resource.ideology') }}</span>
          </div>
        </div>
        <!-- nothing moved yet: the same button gives the rewires up
             instead, and asks twice -->
        <div
          v-else-if="reallocating && reallocationProblem === 'nothing'"
          v-press
          v-tooltip="$t('card.character.reallocation_discard_hint')"
          class="button"
          :class="{ 'is-armed': discardArmed }"
          @click="discardReallocations">
          <div>
            <template v-if="discardArmed">{{ $t('card.character.reallocation_discard_confirm') }}</template>
            <template v-else>
              {{ $tc('card.character.reallocation_discard', reallocationsHeld, { count: reallocationsHeld }) }}
            </template>
          </div>
        </div>
        <div
          v-else-if="reallocating"
          v-press="{ disabled: !!reallocationProblem }"
          v-tooltip="reallocationProblem ? $t(`card.character.reallocation_problem.${reallocationProblem}`) : null"
          class="button"
          :class="{ 'disabled': !!reallocationProblem }"
          @click="confirmReallocation">
          <div :class="{ 'dashed': !!reallocationProblem }">{{ $t('card.character.reallocation_confirm') }}</div>
        </div>
        <template v-else-if="character.status === 'in_deck' && assignment">
          <!-- rewires first: they can be spent while the agent rests -->
          <div
            v-if="reallocationsHeld > 0"
            v-press="{ disabled: true }"
            v-tooltip="$t('card.character.reallocation_hint')"
            class="button disabled">
            <div class="dashed">{{ $t('card.character.reallocations_unspent') }}</div>
          </div>
          <div
            v-else-if="queue"
            v-press="{ disabled: true }"
            class="button disabled">
            <div class="dashed">{{ $t('card.character.queued') }}</div>
          </div>
          <div
            v-else-if="cooldown && cooldown.value != 0"
            v-press="{ disabled: true }"
            class="button disabled">
            <div class="dashed">
              <template v-if="receivedAt && speed !== 'fast'">
                {{ $t(
                  'card.character.locked_character_date',
                  { date: $options.filters['luxon-std'](receivedAt + (cooldown.value * tickToMilisecondFactor)) }
                ) }}
              </template>
              <template v-else>
                {{ $t('card.character.locked_character') }}
              </template>
            </div>
          </div>
          <div
            v-else-if="schoolRefusal"
            v-press="{ disabled: true }"
            class="button disabled is-two-lines">
            <div class="dashed">{{ schoolRefusal }}</div>
          </div>
          <div
            v-else-if="charactersLimit.current < charactersLimit.max"
            v-press
            class="button"
            @click="activate">
            <div>{{ $t(`card.character.${assignmentAction}`) }}</div>
          </div>
          <div
            v-else
            v-press="{ disabled: true }"
            class="button disabled">
            <div class="dashed">{{ $t(`card.character.${character.type}_limit_reached`) }}</div>
          </div>
        </template>
        <!-- waiting for a seat: out of the queue, or out for good -->
        <!-- keyed: patched in place, it would inherit the aria-disabled
             that v-press left on the button it replaces -->
        <div
          v-else-if="character.status === 'in_deck' && queue"
          key="queue-buttons"
          class="button-container">
          <div
            v-press
            class="button"
            @click="leaveQueue">
            <div>{{ $t('card.character.queue_leave') }}</div>
          </div>
          <div
            v-press
            v-tooltip="$t('card.character.fire')"
            class="button is-icon"
            :aria-label="$t('card.character.fire')"
            @click="dismiss">
            <div><svgicon name="close" /></div>
          </div>
        </div>
        <div
          v-else-if="character.status === 'in_deck' && !assignment"
          v-press
          class="button"
          @click="dismiss">
          <div>{{ $t('card.character.fire') }}</div>
        </div>
        <div
          v-else-if="['governor', 'student'].includes(character.status) && character.owner.id === playerId"
          v-press
          class="button"
          @click="deactivate">
          <div>{{ $t('card.character.recall') }}</div>
        </div>
        <!-- a faction-mate's student in one of the player's schools -->
        <div
          v-else-if="hostsStudent"
          v-press
          v-tooltip="$t('card.character.eject_hint')"
          class="button"
          @click="eject">
          <div>{{ $t('card.character.eject') }}</div>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import HelpButton from '@/game/components/generic/HelpButton.vue';
import { agentCardSummary, agentTypeName, fleetStats } from '@/game/a11y/describe';
import viewport from '@/utils/viewport';

import DynamicValue from '@/game/components/generic/DynamicValue.vue';
import { formatCountdown } from '@/game/clock';
import {
  fee, inClass, reallocationProblem, schoolBuilding, seatWait, settling, trainingStatus, xpFactor,
} from '@/game/training';

export default {
  name: 'character-card',
  mixins: [CardMixin],
  props: {
    character: Object,
    diff: {
      type: Object,
      required: false,
    },
    isDead: {
      type: Boolean,
      default: false,
    },
    cooldown: {
      type: Object,
      required: false,
    },
    receivedAt: {
      type: Number,
      required: false,
    },
    // the deck entry's place in a school's queue, if it waits in one
    queue: {
      type: Object,
      required: false,
    },
    noAction: {
      type: Boolean,
      default: false,
    },
  },
  data() {
    return {
      // skill points being moved with the agent's neural rewires (the whole
      // new list), null when the card is not in that mode
      draftSkills: null,
      // the Discard button was clicked once and now asks "are you sure?"
      discardArmed: false,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    // Agent training (docs/agent-training.md)
    isInClass() { return this.character.status === 'student' && inClass(this.character.training); },
    studentExperience() {
      if (this.character.status !== 'student' || !this.character.experience) return null;

      const factor = xpFactor(this.character.training, this.constant);
      return { ...this.character.experience, change: this.character.experience.change * factor };
    },
    trainingRibbon() {
      if (this.character.status !== 'student' || !this.character.training) return null;

      const building = this.$t(`data.building.${schoolBuilding(this.character)}.name`);
      const hasHint = !!fee(this.character, this.constant) || this.character.training.phase === 'settling';

      return {
        text: `${building} · ${trainingStatus(this, this.character)}`,
        // a function: the time left is read when the tooltip opens
        hint: hasHint ? { content: () => this.trainingHint(), html: true } : null,
      };
    },
    // The queue of a school (docs/agent-training.md): how long this deck
    // agent can have to wait for its seat, at the longest.
    seatWait() {
      if (this.character.status !== 'in_deck' || !this.queue) return null;
      return seatWait(this.queue, this.receivedAt, this.tickToMilisecondFactor);
    },
    seatWaitText() {
      const { until, hours, minutes } = this.seatWait;

      if (until === null) return this.$t('card.character.queue_wait_open');
      if (minutes <= 0) return this.$t('card.character.queue_wait_due');
      if (minutes < 120) return this.$t('card.character.queue_wait_minutes', { count: minutes });
      return this.$t('card.character.queue_wait_hours', { count: hours });
    },
    seatWaitHint() {
      return this.seatWait.until === null
        ? this.$t('card.character.queue_open_hint')
        : this.$t('card.character.queue_latest', { date: this.$options.filters['luxon-std'](this.seatWait.until) });
    },
    // a student of another player seated in one of this player's systems
    hostsStudent() {
      return this.character.status === 'student' && this.character.owner
        && this.character.owner.id !== this.playerId
        && this.$store.state.game.player.stellar_systems.some((s) => s.id === this.character.system);
    },
    // what the button does with the seat or the post being filled
    assignmentAction() {
      if (this.assignment.mode !== 'student') return 'deploy';
      return this.assignment.behind ? 'queue_join' : 'enroll';
    },
    reallocationsHeld() { return this.character.reallocations || 0; },
    // In the deck, and also while a seat or a post is being filled: an
    // agent takes no duty until its rewires are spent, so the card that
    // says so is where they get spent.
    canReallocate() {
      return this.character.status === 'in_deck' && !this.character.on_sold
        && !this.child && !this.noAction && Array.isArray(this.character.skills);
    },
    reallocating() { return this.draftSkills !== null; },
    shownSkills() { return this.draftSkills || this.character.skills; },
    mainSkillIndex() { return this.data.specializations.findIndex((s) => s.key === this.character.specialization); },
    reallocationMoved() {
      if (!this.draftSkills) return 0;
      return this.draftSkills.reduce((sum, value, i) => sum + Math.max(value - this.character.skills[i], 0), 0);
    },
    // points taken that are not placed yet
    reallocationPool() {
      if (!this.draftSkills) return 0;
      const total = (list) => list.reduce((sum, value) => sum + value, 0);
      return total(this.character.skills) - total(this.draftSkills);
    },
    reallocationProblem() {
      if (!this.draftSkills) return null;
      return reallocationProblem(this.character.skills, this.draftSkills, this.mainSkillIndex, this.reallocationsHeld);
    },
    // why this deck agent cannot take the seat being filled, if it cannot
    schoolRefusal() {
      const seat = this.assignment;
      if (!seat || seat.mode !== 'student') return null;

      if (seat.type && seat.type !== this.character.type) {
        return this.$t('card.character.school_wrong_type', { agents: this.$tc(`data.character.${seat.type}.name`, 2) });
      }

      if (seat.school === 'university' && this.character.level < this.constant.university_min_level) {
        return this.$t('card.character.school_level', { level: this.constant.university_min_level });
      }

      return null;
    },
    tickToMilisecondFactor() { return this.$store.getters['game/tickToMilisecondFactor']; },
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    speed() { return this.$store.state.game.time.speed; },
    assignment() { return this.$store.state.game.assignment; },
    constant() { return this.$store.state.game.data.constant[0]; },
    playerId() { return this.$store.state.game.player.id; },
    charactersLimit() {
      const bonusName = {
        admiral: 'max_admirals',
        spy: 'max_spies',
        speaker: 'max_speakers',
      };

      const { player } = this.$store.state.game;
      const max = player[bonusName[this.character.type]].value;
      // an agent waiting for a seat holds its slot already
      const queued = player.character_deck.filter((entry) => entry.queue && entry.character.type === this.character.type).length;
      const current = player.characters.filter((c) => c.type === this.character.type).length + queued;

      return { current, max };
    },
    data() { return this.$store.state.game.data.character.find((c) => c.key === this.character.type); },
    nextLevelExperience() {
      return Math.round((10 * (this.character.level + 1)) + (((this.character.level + 1) / 2) ** 2.5));
    },
    ariaName() {
      return `${agentTypeName(this, this.character.type)} ${this.character.name}`;
    },
    ariaSummary() {
      return agentCardSummary(this, this.character, {
        fleet: this.character.type === 'admiral' ? fleetStats(this, this.character) : null,
        nextXp: this.nextLevelExperience,
      });
    },
    armadaSize() {
      return this.character.armada && Array.isArray(this.character.armada.member_ids)
        ? this.character.armada.member_ids.length
        : 0;
    },
    group() {
      if (this.character.status === 'on_board') {
        return Object.keys(this.$store.state.game.charactersGroup)
          .find((key) => this.$store.state.game.charactersGroup[key] === this.character.id);
      }
      return null;
    },
    // Per-resource affordability for the hire button. Snapshot values
    // (not tick-interpolated) — the server is the validator; this only
    // drives the can't-afford shading.
    affordability() {
      const p = this.$store.state.game.player;
      const has = (res, cost) => !cost || cost <= 0 || !p || !p[res] || p[res].value >= cost;
      return {
        credit: has('credit', this.character.credit_cost),
        technology: has('technology', this.character.technology_cost),
        ideology: has('ideology', this.character.ideology_cost),
      };
    },
    canAfford() {
      const a = this.affordability;
      return a.credit && a.technology && a.ideology;
    },
  },
  watch: {
    // another agent in the same card, or the points were spent
    'character.id': function onCharacterChanged() { this.draftSkills = null; },
    // any change of plan takes the question back
    draftSkills() { this.disarmDiscard(); },
    reallocationsHeld(held) { if (held === 0) this.draftSkills = null; },
  },
  beforeDestroy() {
    clearTimeout(this.discardTimer);
  },
  methods: {
    // Protection or Determination as an attacker meets it: cut while the
    // agent is in class (the server's Character.effective_protection/1).
    // In the template it is the obfuscate filter's argument, which is what
    // that filter prints for a visible stat.
    effective(value) {
      if (!this.isInClass || typeof value !== 'number') return value;
      return Math.trunc(value * this.constant.training_defense_factor);
    },
    // What the ribbon of a student leaves unsaid: settling in earns nothing
    // yet (and until when), and what the course costs.
    trainingHint() {
      const lines = [];
      const settle = settling(this.character.training, this.constant, this.$store.state.game.time, this.speedFactor);

      if (settle) {
        lines.push(this.$t('card.character.training_settling'));

        if (settle.until !== null) {
          const left = this.$t('card.character.training_settling_left', {
            time: formatCountdown(settle.until - Date.now()),
          });
          const date = this.speed === 'fast' ? '' : ` (${this.$options.filters['luxon-std'](settle.until)})`;
          lines.push(`${left}${date}`);
        }
      }

      const cost = fee(this.character, this.constant);
      if (cost) {
        lines.push(this.$t('card.character.training_fee', {
          amount: this.$options.filters.integer(cost.amount),
          resource: this.$t(`galaxy.school.fee_${cost.resource}`),
        }));
      }

      return lines.join('<br>');
    },
    // In class the card shows the cut value: the tooltip says what it was
    // cut from, and by how much ("Protection, base 80: -50% (training)").
    defenseTooltip(stat) {
      const label = this.$t(`card.character.${stat}`);
      if (!this.isInClass) return label;

      const base = this.character[stat];
      if (typeof base !== 'number') return `${label} (${this.$t('card.character.training_penalty')})`;

      return this.$t('card.character.training_defense', {
        stat: label,
        base: this.$options.filters.integer(base),
        percent: Math.round((1 - this.constant.training_defense_factor) * 100),
      });
    },
    skillName(i) { return this.$t(`data.character.${this.character.type}.skills[${i}].name`); },
    toggleReallocation() {
      if (!this.canReallocate) return;
      this.draftSkills = this.reallocating ? null : [...this.character.skills];
    },
    // a point comes off a skill before it goes onto another
    canTake(i) {
      return this.draftSkills[i] > 0
        && (this.draftSkills[i] > this.character.skills[i]
          || this.reallocationMoved + this.reallocationPool < this.reallocationsHeld);
    },
    canGive(i) {
      if (this.reallocationPool <= 0 || this.draftSkills[i] >= 12) return false;
      // giving back a point that was taken is always fine
      if (this.draftSkills[i] < this.character.skills[i]) return true;
      return i === this.mainSkillIndex || this.draftSkills[i] < this.draftSkills[this.mainSkillIndex];
    },
    take(i) { this.$set(this.draftSkills, i, this.draftSkills[i] - 1); },
    give(i) { this.$set(this.draftSkills, i, this.draftSkills[i] + 1); },
    disarmDiscard() {
      this.discardArmed = false;
      clearTimeout(this.discardTimer);
    },
    // First click asks, second click (within a few seconds) discards.
    discardReallocations() {
      if (!this.discardArmed) {
        this.discardArmed = true;
        clearTimeout(this.discardTimer);
        this.discardTimer = setTimeout(() => { this.discardArmed = false; }, 5000);
        return;
      }

      this.disarmDiscard();
      this.$socket.player.push('discard_reallocations', {
        character_id: this.character.id,
      }).receive('ok', () => {
        this.draftSkills = null;
      }).receive('error', (err) => {
        this.$toastError(err.reason);
      });
    },
    confirmReallocation() {
      if (this.reallocationProblem) return;

      this.$socket.player.push('reallocate_skills', {
        character_id: this.character.id,
        skills: this.draftSkills,
      }).receive('ok', () => {
        this.draftSkills = null;
      }).receive('error', (err) => {
        this.$toastError(err.reason);
      });
    },
    // Called by the views that open a card (selection, opened character):
    // moves focus to the spoken summary so a screen reader reads it.
    focusSummary() {
      if (this.$refs.srSummary) this.$refs.srSummary.focus({ preventScroll: true });
    },
    formatCost(value) {
      // Mobile beta: 3-significant-digit rounding above 100k so hire
      // prices fit the narrow card (the shading covers affordability).
      if (this.isMobileView && value > 100000) {
        const k = Math.round(value / 1000);
        if (k >= 1000) {
          const m = value / 1e6;
          const digits = m >= 100 ? Math.round(m) : m >= 10 ? m.toFixed(1) : m.toFixed(2);
          return `${digits}M`;
        }
        return `${k}k`;
      }
      return this.$options.filters.integer(value);
    },
    hire() {
      if (this.character.status === 'for_hire') {
        this.$socket.player.push('hire_character', {
          character: this.character,
        }).receive('ok', () => {
          this.$emit('hired', this.character);
        }).receive('error', (err) => {
          this.$toastError(err.reason);
        });
      }
    },
    activate() {
      if (this.assignment) {
        const boundingBox = this.$refs.card.getBoundingClientRect();

        this.$emit('assign', {
          systemId: this.assignment.systemId,
          character: this.character,
          mode: this.assignment.mode,
          school: this.assignment.school,
          behind: this.assignment.behind,
          box: boundingBox,
        });
      }
    },
    manage() {
      if (this.character.status === 'governor' || this.character.status === 'on_board') {
        this.$emit('manage', this.character);
      }
    },
    select() {
      if (this.character.status === 'governor' || this.character.status === 'on_board') {
        this.$emit('select', this.character);
      }
    },
    deactivate() {
      if (['governor', 'on_board', 'student'].includes(this.character.status)) {
        this.$socket.player.push('deactivate_character', {
          character_id: this.character.id,
        }).receive('ok', () => {
          this.$emit('deactivated', this.character);
        }).receive('error', (err) => {
          this.$toastError(err.reason);
        });
      }
    },
    leaveQueue() {
      this.$socket.player.push('leave_school_queue', {
        character_id: this.character.id,
      }).receive('ok', () => {
        this.$store.dispatch('game/reloadSystem', this.$socket);
      }).receive('error', (err) => {
        this.$toastError(err.reason);
      });
    },
    // the owner of a school sends a faction-mate's student home
    eject() {
      this.$socket.player.push('eject_student', {
        system_id: this.character.system,
        character_id: this.character.id,
      }).receive('ok', () => {
        this.$emit('deactivated', this.character);
        this.$store.dispatch('game/reloadSystem', this.$socket);
      }).receive('error', (err) => {
        this.$toastError(err.reason);
      });
    },
    dismiss() {
      if (this.character.status === 'in_deck') {
        const boundingBox = this.$refs.card.getBoundingClientRect();

        this.$emit('dismiss', {
          character: this.character,
          box: boundingBox,
        });
      }
    },
    specialization(character) {
      return `data.character.${character.type}.specializations.${character.specialization}`;
    },
    skillEffectLabel(i) {
      const spec = this.data && this.data.specializations && this.data.specializations[i];
      if (!spec || !Array.isArray(spec.bonus) || spec.bonus.length === 0) return '';

      const groups = new Map();
      spec.bonus.forEach((b) => {
        const key = `${b.value}|${b.type}`;
        if (!groups.has(key)) groups.set(key, { value: b.value, type: b.type, tos: [] });
        groups.get(key).tos.push(b.to);
      });

      const parts = Array.from(groups.values()).map((g) => {
        const amount = g.type === 'mul'
          ? `+${Math.round(g.value * 100)}%`
          : `+${g.value}`;
        const targets = g.tos
          .map((to) => this.$t(`data.bonus_pipeline_out.${to}.name`))
          .join(', ');
        return `${amount} ${targets}`;
      });

      return this.$t('card.character.skill_effect', { effect: parts.join(' · ') });
    },
    skillTooltip(i) {
      const description = this.$t(`data.character.${this.character.type}.skills[${i}].description`);
      const effect = this.skillEffectLabel(i);
      if (!effect) return description;
      return {
        content: `${description}<div class="skill-effect-tip">${effect}</div>`,
        html: true,
      };
    },
  },
  components: {
    HelpButton,
    DynamicValue,
  },
};
</script>
