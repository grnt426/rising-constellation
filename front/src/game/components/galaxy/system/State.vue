<template>
  <div>
    <div class="system-content-group">
      <div class="system-content-group-header">
        <div class="main">
          {{ $t('system.system_owner_title') }}
        </div>
      </div>

      <div
        v-if="isOwnProperty"
        class="system-content-group-info"
        v-html="$tmd(`system.status.own_${system.status}`)">
      </div>
      <div
        v-else
        class="system-content-group-info"
        v-html="$tmd(`system.status.${system.status}`, { player: ownerName })">
      </div>
    </div>

    <system-population-status
      v-if="!['uninhabitable', 'uninhabited'].includes(system.status)"
      :system="system"
      :color="color" />

    <div
      class="system-content-group"
      v-if="isOwnProperty">
      <div class="system-content-group-header">
        <div class="main">
          {{ $t('system.system_state_title') }}
        </div>
      </div>

      <template v-if="system.status === 'inhabited_player'">
        <div
          @click="pushAction('transform_system_to_dominion')"
          :class="{ 'disabled': isLastSystem }"
          class="button">
          <div :class="{ 'dashed': isLastSystem }">
            {{ $t('system.transform_to_dominion') }}
          </div>
          <div class="icon-value">
            {{ transformCost | integer }}
            <svgicon name="resource/ideology" />
          </div>
        </div>
        <div
          @click="pushAction('abandon_system')"
          :class="{ 'disabled': isLastSystem }"
          class="button">
          <div :class="{ 'dashed': isLastSystem }">
            {{ $t('system.abandon_system') }}
          </div>
          <div class="icon-value">
            {{ abandonmentCost | integer }}
            <svgicon name="resource/ideology" />
          </div>
        </div>
      </template>
      <template v-if="system.status === 'inhabited_dominion'">
        <div
          @click="pushAction('transform_dominion_to_system')"
          class="button">
          <div>{{ $t('system.transform_to_system') }}</div>
          <div class="icon-value">
            {{ transformCost | integer }}
            <svgicon name="resource/ideology" />
          </div>
        </div>
        <div
          @click="pushAction('abandon_dominion')"
          class="button">
          <div>{{ $t('system.abandon_dominion') }}</div>
          <div class="icon-value">
            {{ abandonmentCost | integer }}
            <svgicon name="resource/ideology" />
          </div>
        </div>
      </template>
    </div>

    <!-- System planner (portal page): this system's bodies, buildings,
         population and governor, plus the player's patents and lexes,
         either opened in a new planner tab or copied as JSON. -->
    <div
      v-if="canPlan"
      class="system-content-group">
      <div class="system-content-group-header">
        <div class="main">
          {{ $t('system.planner_title') }}
        </div>
      </div>
      <div class="system-content-group-info">
        {{ $t('system.planner_info') }}
      </div>
      <div
        class="button"
        role="button"
        tabindex="0"
        @click="openPlanner"
        @keydown.enter="openPlanner">
        <div>{{ $t('system.planner_open') }}</div>
        <div class="icon-value">
          <svgicon name="share" />
        </div>
      </div>
      <div
        class="button"
        role="button"
        tabindex="0"
        v-tooltip="$t('system.planner_export_hint')"
        @click="exportPlan"
        @keydown.enter="exportPlan">
        <div>{{ $t('system.planner_export') }}</div>
        <div class="icon-value">
          <svgicon name="layers" />
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import SystemPopulationStatus from '@/game/components/galaxy/system/PopulationStatus.vue';
import { planFromGame, stashPlan } from '@/portal/planner/plan';
import { copyOrDownloadJson, planFilename } from '@/utils/json-export';

export default {
  name: 'system-state',
  props: {
    system: Object,
    isOwnProperty: Boolean,
    color: String,
  },
  data() {
    return {
      // the governor's full character (its skills aren't part of the
      // system payload), fetched ahead so the planner opens on the click
      governor: null,
    };
  },
  computed: {
    // anything colonizable whose bodies we can see
    canPlan() {
      const { bodies } = this.system;
      return this.system.status !== 'uninhabitable'
        && Array.isArray(bodies) && bodies.length > 0
        && bodies.every((b) => typeof b.industrial_factor === 'number');
    },
    governorId() {
      return this.isOwnProperty && this.system.governor ? this.system.governor.id : null;
    },
    constant() { return this.$store.state.game.data.constant[0]; },
    player() { return this.$store.state.game.player; },
    isLastSystem() { return this.player.stellar_systems.length <= 1; },
    ownerName() {
      return this.system.owner ? this.system.owner.name : '';
    },
    abandonmentCost() { return this.constant.abandonment_cost; },
    transformCost() {
      return this.constant.transform_initial_cost
        + (this.player.transformed_system_count * this.constant.transform_additional_cost);
    },
  },
  watch: {
    governorId: { immediate: true, handler: 'fetchGovernor' },
  },
  methods: {
    fetchGovernor(id) {
      this.governor = null;
      if (!id) return;
      this.$socket.player.push('get_character', { character_id: id })
        .receive('ok', ({ character }) => {
          if (this.governorId === id && character && typeof character === 'object') this.governor = character;
        });
    },
    plan() {
      const game = this.$store.state.game;
      const sector = (game.galaxy.sectors || []).find((s) => s.id === this.system.sector_id);
      return planFromGame({
        system: this.system,
        speed: game.time.speed,
        faction: this.player.faction,
        constant: this.constant,
        governor: this.governor,
        patents: this.player.patents,
        ownedLexes: this.player.doctrines,
        activeLexes: this.player.policies,
        lexSlots: this.player.max_policies,
        sectorName: sector ? sector.name : null,
        instanceId: game.auth.instance || null,
      });
    },
    // A new tab, so the game keeps running here. The plan rides through
    // localStorage (see stashPlan); the URL only carries its key.
    openPlanner() {
      let key;
      try {
        key = stashPlan(window.localStorage, this.plan());
      } catch (e) {
        this.$toasted.error(this.$t('system.planner_failed'));
        return;
      }
      const { href } = this.$router.resolve({ path: '/system-planner', query: { import: key } });
      window.open(href, '_blank', 'noopener');
    },
    async exportPlan() {
      const plan = this.plan();
      const outcome = await copyOrDownloadJson(JSON.stringify(plan, null, 2), planFilename(plan.name));
      if (outcome === 'copied') this.$toasted.success(this.$t('system.planner_copied'));
      else this.$toasted.info(this.$t('system.planner_downloaded'));
    },
    pushAction(action) {
      this.$socket.player.push(action, {
        system_id: this.system.id,
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
  },
  components: {
    SystemPopulationStatus,
  },
};
</script>
