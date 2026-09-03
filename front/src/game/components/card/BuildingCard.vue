<template>
  <div
    class="card-container"
    :class="[`f-${theme}`, { 'is-pinned': pinned }]">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon :name="`building/${buildingKey}`" />
        <span
          class="level"
          :class="{ 'is-preview': isPreviewing }">{{ displayLevel }}</span>
      </div>
      <div class="card-header-content">
        <div class="title-large nowrap">
          {{ $t(`data.building.${buildingKey}.name`) }}
        </div>
        <div
          v-show="buildingData.workforce > 0"
          class="title-small">
          {{ buildingData.workforce }}
          <svgicon
            class="text-icon"
            v-tooltip="$t('card.building.mobilized_hint')"
            name="resource/population" />
          {{ $t('card.building.mobilized') }}
        </div>
      </div>
      <div
        v-if="pinned"
        class="card-close"
        v-tooltip="$t('card.close_hint')"
        @click="$emit('close')">
        <svgicon name="close" />
      </div>
    </div>

    <div class="card-body">
      <div class="card-illustration">
        <img
          v-if="!disabled"
          :src="`data/buildings/${buildingData.illustration}`" />
        <div
          v-else
          class="locked-item">
          <svgicon
            class="locked-icon"
            name="unlock" />
          <div
            v-html="disabled"
            class="locked-reason">
          </div>
        </div>

        <div
          class="toast"
          v-tooltip="$t('card.building.limited_hint')"
          v-if="buildingData.limitation === 'unique_body'">
          {{ $t('card.building.limited') }}
        </div>
        <div
          class="toast"
          v-tooltip="$t('card.building.unique_hint')"
          v-if="buildingData.limitation === 'unique_system'">
          {{ $t('card.building.unique') }}
        </div>
      </div>

      <div class="card-information">
        <div class="card-panel-controls">
          <div
            v-if="maxLevel > 1"
            class="card-level-pips">
            <div
              v-for="n in maxLevel"
              :key="`level-pip-${n}`"
              class="card-level-pip"
              :class="{
                'is-active': n === displayLevel,
                'is-built': n === level,
              }"
              v-tooltip="levelTooltip(n)"
              @click.stop="previewLevel = n">
              {{ n }}
            </div>
          </div>
        </div>

        <div class="card-panel-window">
          <div
            ref="panelContainer"
            class="card-panel-container">
            <div class="card-panel">
              <blockquote>
                {{ $t(`data.building.${buildingKey}.quote`) }}
              </blockquote>

              <card-complex-bonus
                :bonus="levelData.bonus"
                :body="body"
                :system="system" />
            </div>
          </div>
        </div>
      </div>
    </div>
    <div
      v-if="showCost || isPreviewing"
      class="card-cost">
      <div
        class="icon-value"
        v-tooltip="$t('card.cost.production')">
        {{ levelData.production | integer }}
        <svgicon name="resource/production" />
        <template v-if="system">
          ({{ (levelData.production / system.production.value) * tickToSecondFactor | counter }})
        </template>
      </div>
      <div
        class="icon-value"
        v-tooltip="$t('card.cost.credit')">
        {{ levelData.credit | integer }}
        <svgicon name="resource/credit" />
      </div>
    </div>
  </div>
</template>

<script>
import CardMixin from '@/game/mixins/CardMixin';
import CardComplexBonus from '@/game/components/card/CardComplexBonus.vue';

export default {
  name: 'building-card',
  mixins: [CardMixin],
  data() {
    return {
      previewLevel: null,
    };
  },
  props: {
    buildingKey: String,
    level: Number,
    body: {
      type: Object,
      required: false,
    },
    system: {
      type: Object,
      required: false,
    },
    showCost: {
      type: Boolean,
      default: false,
    },
    disabled: {
      type: String,
      required: false,
    },
    pinned: {
      type: Boolean,
      default: false,
    },
    // what the card's anchor level means: a 'built' building's actual
    // level, the 'blueprint' level about to be queued (build menu and
    // the upgrade caret), or a plain 'preview' (patents, tutorial)
    context: {
      type: String,
      default: 'preview',
    },
  },
  computed: {
    buildingData() { return this.$store.state.game.data.building.find((b) => b.key === this.buildingKey); },
    maxLevel() { return this.buildingData.levels.length; },
    displayLevel() { return this.previewLevel === null ? this.level : this.previewLevel; },
    isPreviewing() { return this.previewLevel !== null && this.previewLevel !== this.level; },
    levelData() { return this.buildingData.levels[this.displayLevel - 1]; },
    playerPatents() { return this.$store.state.game.player ? this.$store.state.game.player.patents : null; },
    tickToSecondFactor() { return this.$store.getters['game/tickToSecondFactor']; },
  },
  watch: {
    buildingKey() { this.previewLevel = null; },
    level() { this.previewLevel = null; },
    // previewing another level reveals the cost row, growing the card —
    // hosts that anchor the card to a screen edge listen to reposition
    isPreviewing(value) { this.$emit('preview', value); },
  },
  methods: {
    // mirrors buildingValidation.upgradeBuildingStatus: the level's
    // patent, plus the body's tile-1 infrastructure at or above that
    // level (asteroids, moons and the infra building itself exempt)
    levelRequirementsUnmet(n) {
      if (this.playerPatents) {
        const { patent } = this.buildingData.levels[n - 1];
        if (patent !== null && !this.playerPatents.some((p) => p === patent)) return true;
      }

      if (this.body
        && !['asteroid', 'moon'].includes(this.body.type)
        && this.buildingData.type !== 'infrastructure') {
        const infra = this.body.tiles && this.body.tiles[0];
        const infraLevel = infra && typeof infra.building_level === 'number' ? infra.building_level : 0;
        if (n > infraLevel) return true;
      }

      return false;
    },
    levelTooltip(n) {
      if (n === this.level) {
        if (this.context === 'built') return this.$t('card.building.level_current', { n });
        if (this.context === 'blueprint') return this.$t('card.building.level_selected', { n });
      }

      if (n > this.level && this.levelRequirementsUnmet(n)) {
        return this.$t('card.building.level_requirements', { n });
      }

      return this.$t('card.building.level_preview', { n });
    },
  },
  components: {
    CardComplexBonus,
  },
};
</script>
