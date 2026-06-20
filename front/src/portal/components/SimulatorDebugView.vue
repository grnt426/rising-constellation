<template>
  <div class="simulator-debug">
    <div class="debug-nav">
      <button
        class="default-button is-small"
        :disabled="round <= 0"
        @click="round -= 1">
        ‹
      </button>
      <span class="debug-round-label">
        {{ $t('page.fight_simulator.round') }} {{ round + 1 }} / {{ roundStates.length }}
      </span>
      <button
        class="default-button is-small"
        :disabled="round >= roundStates.length - 1"
        @click="round += 1">
        ›
      </button>
    </div>

    <div class="debug-sides">
      <div
        v-for="side in ['attackers', 'defenders']"
        :key="`debug-${side}`"
        class="debug-side">
        <h3>{{ $t(`page.fight_simulator.results_${side}`) }}</h3>

        <div class="debug-damage">
          <div class="debug-damage-title">{{ $t('page.fight_simulator.damage_by_type') }}</div>
          <template v-if="current.damage[side] && current.damage[side].length">
            <div
              v-for="d in current.damage[side]"
              :key="`dmg-${d.ship_key}`"
              class="debug-damage-row">
              <span>{{ $t(`data.ship.${d.ship_key}.name`) }}</span>
              <span class="debug-damage-val">{{ d.total }}</span>
            </div>
          </template>
          <div
            v-else
            class="debug-damage-none">
            —
          </div>
        </div>

        <div class="debug-ships">
          <div
            v-for="t in current[side]"
            :key="t.key"
            class="debug-ship"
            :class="`is-${statusOf(t)}`">
            <svgicon
              class="debug-ship-icon is-rotated"
              :name="`ship/${t.ship_key}`" />
            <div class="debug-ship-main">
              <div class="debug-ship-name">
                {{ $t(`data.ship.${t.ship_key}.name`) }}
                <span
                  v-if="t.level > 0"
                  class="debug-ship-level">L{{ t.level + 1 }}</span>
              </div>
              <div class="debug-ship-hpbar">
                <div
                  class="debug-ship-hpfill"
                  :style="{ width: hpPct(t) + '%' }"></div>
              </div>
            </div>
            <div class="debug-ship-meta">
              <span class="debug-ship-hp">{{ Math.round(t.hp) }}/{{ t.maxHp }}</span>
              <span class="debug-ship-status">{{ statusLabel(t) }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="fight-report">
      <div class="title">
        {{ $t('panel.operations.fight_course') }} — {{ $t('page.fight_simulator.round') }} {{ round + 1 }}
      </div>
      <div class="round-content">
        <simulator-round-log
          :round="logs[round] || []"
          :get-ship="getShip"
          :compute-strikes="computeStrikes" />
      </div>
    </div>
  </div>
</template>

<script>
import SimulatorRoundLog from '@/portal/components/SimulatorRoundLog.vue';

export default {
  name: 'simulator-debug-view',
  components: { SimulatorRoundLog },
  props: {
    // Precomputed per-round snapshots from FightSimulator.roundStates.
    roundStates: {
      type: Array,
      default: () => [],
    },
    logs: {
      type: Array,
      default: () => [],
    },
    getShip: {
      type: Function,
      required: true,
    },
    computeStrikes: {
      type: Function,
      required: true,
    },
  },
  data() {
    return { round: 0 };
  },
  computed: {
    current() {
      return this.roundStates[this.round] || {
        attackers: [],
        defenders: [],
        damage: { attackers: [], defenders: [] },
      };
    },
  },
  watch: {
    // A new fight result -> jump back to the first round.
    roundStates() {
      this.round = 0;
    },
  },
  methods: {
    hpPct(t) {
      return t.maxHp > 0 ? Math.max(0, Math.min(100, (t.hp / t.maxHp) * 100)) : 0;
    },
    // Per-round lifecycle state of a ship:
    //   routed    — morale broke and it's STILL on the field (fleeing, can take fire)
    //   withdrawn — it fled to safety (routed, now off-field) OR stood down at battle's end
    //   field     — deployed and fighting
    //   reserve   — not yet deployed
    statusOf(t) {
      if (t.destroyed) return 'destroyed';
      if (t.escaped && t.onField) return 'routed';
      if (t.escaped || t.withdrawn) return 'withdrawn';
      if (t.onField) return 'field';
      return 'reserve';
    },
    statusLabel(t) {
      return this.$t(`page.fight_simulator.status_${this.statusOf(t)}`);
    },
  },
};
</script>

<style lang="scss" scoped>
.simulator-debug {
  padding: 20px;
}

.debug-nav {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  margin-bottom: 16px;
}

.debug-round-label {
  font-weight: bold;
  min-width: 120px;
  text-align: center;
}

.debug-sides {
  display: flex;
  gap: 20px;
  margin-bottom: 16px;
}

.debug-side {
  flex: 1;
  min-width: 0;

  h3 {
    margin: 0 0 8px 0;
  }
}

.debug-damage {
  margin-bottom: 12px;
  font-size: 0.9rem;
}

.debug-damage-title {
  opacity: 0.6;
  margin-bottom: 4px;
}

.debug-damage-row {
  display: flex;
  justify-content: space-between;
  padding: 1px 0;
}

.debug-damage-val {
  font-weight: bold;
}

.debug-damage-none {
  opacity: 0.4;
}

.debug-ships {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.debug-ship {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 8px;
  border-radius: 4px;
  border: solid 1px rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.02);

  &.is-field {
    border-color: rgba(111, 207, 151, 0.6);
    background: rgba(111, 207, 151, 0.08);
  }

  &.is-routed {
    border-color: rgba(224, 179, 65, 0.7);
    background: rgba(224, 179, 65, 0.1);

    .debug-ship-status {
      color: #e0b341;
      opacity: 1;
    }
  }

  &.is-withdrawn {
    border-color: rgba(63, 102, 223, 0.5);
    background: rgba(63, 102, 223, 0.07);

    .debug-ship-status {
      color: #6f8fe0;
      opacity: 1;
    }
  }

  &.is-destroyed {
    opacity: 0.4;

    .debug-ship-name {
      text-decoration: line-through;
    }

    .debug-ship-hpfill {
      background: #bc2433;
    }
  }
}

.debug-ship-icon {
  width: 32px;
  height: 32px;
  flex: 0 0 32px;
}

.debug-ship-main {
  flex: 1;
  min-width: 0;
}

.debug-ship-name {
  font-size: 0.9rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.debug-ship-level {
  opacity: 0.6;
  font-size: 0.8rem;
  margin-left: 4px;
}

.debug-ship-hpbar {
  margin-top: 3px;
  height: 6px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.1);
  overflow: hidden;
}

.debug-ship-hpfill {
  height: 100%;
  background: #6fcf97;
  transition: width 0.15s;
}

.debug-ship-meta {
  flex: 0 0 auto;
  text-align: right;
  font-size: 0.78rem;
}

.debug-ship-hp {
  display: block;
  font-weight: bold;
}

.debug-ship-status {
  display: block;
  opacity: 0.6;
}
</style>
