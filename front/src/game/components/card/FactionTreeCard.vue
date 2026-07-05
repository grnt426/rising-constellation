<template>
  <div
    class="card-container is-small"
    :class="`f-${theme}`">
    <div class="card-header">
      <div class="card-header-icon">
        <svgicon :name="icon" />
      </div>
      <div class="card-header-content">
        <div class="title-large">
          {{ $t(`data.${dataKey}.${node.key}.name`) }}
        </div>
      </div>
    </div>

    <div class="card-body">
      <div class="card-information">
        <div class="card-panel">
          <p>{{ $t(`data.${dataKey}.${node.key}.description`) }}</p>

          <div class="complex-bonus">
            <div>
              {{ $t('card.faction_tree.cost') }}:
              <strong>{{ node.cost }}</strong>
              {{ $t(`panel.faction_government.resources.${resource}`) }}
              <span
                v-if="node.status !== 'purchased' && !affordable"
                class="is-warning">
                — {{ $t('card.faction_tree.treasury_short') }}
              </span>
            </div>
          </div>

          <div
            v-if="enacted"
            class="complex-bonus">
            <div>{{ $t('panel.faction_government.enacted') }}</div>
          </div>
        </div>
      </div>
    </div>

    <div class="card-action">
      <button
        v-if="node.status === 'available' && isBuyer"
        class="card-action-button"
        @click="$emit('purchase', node.key)">
        {{ $t('panel.faction_government.purchase') }}
      </button>
      <div
        v-else-if="node.status === 'purchased'"
        class="card-action-hint">
        {{ $t('card.faction_tree.owned') }}
      </div>
      <div
        v-else-if="node.status === 'available'"
        class="card-action-hint">
        {{ $t(`card.faction_tree.requires_${resource === 'technology' ? 'economy' : 'leader'}`) }}
      </div>
      <div
        v-else
        class="card-action-hint">
        {{ $t('card.faction_tree.locked') }}
      </div>
    </div>
  </div>
</template>

<script>
// Thematic stand-ins from the existing icon set until faction nodes get
// their own art.
const NODE_ICONS = {
  research_compact: 'patent/open_research',
  deep_space_relay: 'patent/orbital_radar',
  counterintel_grid: 'patent/open_intel',
  standardized_freight: 'patent/transport_1',
  chartered_shipyards: 'doctrine/upgrade_repair',
  assembly_charter: 'doctrine/stab_1',
  civic_pride: 'patent/dome_happiness',
  sanctuary_accord: 'patent/dome_defense_1',
  mobilization_act: 'patent/dome_mobility',
  war_footing: 'doctrine/upgrade_invasion',
};

export default {
  name: 'faction-tree-card',
  props: {
    node: Object,
    kind: String, // 'patent' | 'lex'
    theme: String,
    isBuyer: Boolean,
    treasury: Object,
    enacted: Boolean,
  },
  computed: {
    dataKey() { return this.kind === 'patent' ? 'faction_patent' : 'faction_lex'; },
    resource() { return this.kind === 'patent' ? 'technology' : 'ideology'; },
    icon() { return NODE_ICONS[this.node.key] || 'doctrine_stamp'; },
    affordable() {
      return (this.treasury[this.resource] || 0) >= this.node.cost;
    },
  },
};

export { NODE_ICONS };
</script>
