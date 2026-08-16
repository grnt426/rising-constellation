<template>
  <section class="panel-aside-info foresight-panel">
    <h2>{{ $t('page.instance.foresight.heading') }}</h2>

    <!-- The crowd's lean: committed tokens per faction -->
    <div class="foresight-lean">
      <div
        v-for="faction in factions"
        :key="`lean-${faction.id}`"
        class="foresight-faction">
        <div class="foresight-faction-label">
          <svgicon
            class="icon"
            :class="getTheme(faction.faction_ref)"
            :name="`faction/${faction.faction_ref}`" />
          <span class="name">{{ $t(`data.faction.${faction.faction_ref}.name`) }}</span>
          <span class="tokens">{{ factionTokens(faction.id) | integer }} {{ $t('page.instance.foresight.tokens') }}</span>
        </div>
        <div class="gauge-container">
          <div
            class="gauge-content"
            :class="getTheme(faction.faction_ref)"
            :style="{ width: `${leanPercent(faction.id)}%` }" />
        </div>
      </div>
      <p
        v-if="totalTokens === 0"
        class="foresight-empty">
        {{ $t('page.instance.foresight.no_tokens_yet') }}
      </p>
    </div>

    <!-- Your predictions on this match -->
    <div
      v-if="mine.length > 0"
      class="foresight-mine">
      <h3>{{ $t('page.instance.foresight.your_calls') }}</h3>
      <ul>
        <li
          v-for="prediction in mine"
          :key="`mine-${prediction.id}`">
          <span>
            {{ prediction.tokens | integer }} {{ $t('page.instance.foresight.tokens') }}
            → {{ $t(`data.faction.${prediction.faction_ref}.name`) }}
          </span>
          <span
            class="status"
            :class="`is-${prediction.status}`">
            {{ $t(`page.instance.foresight.status_${prediction.status}`) }}
            <template v-if="prediction.status === 'correct'">
              (+{{ (prediction.tokens_recovered + prediction.bonus_tokens) | integer }}
              {{ $t('page.instance.foresight.tokens') }},
              +{{ prediction.points_awarded | integer }}
              {{ $t('page.instance.foresight.points') }})
            </template>
          </span>
        </li>
      </ul>
    </div>

    <!-- Commit form -->
    <div
      v-if="open"
      class="foresight-form">
      <p
        v-if="registeredFactionId"
        class="hint">
        {{ $t('page.instance.foresight.own_faction_note') }}
      </p>
      <div class="default-input">
        <label for="foresight-faction">{{ $t('page.instance.foresight.pick_faction') }}</label>
        <select
          id="foresight-faction"
          v-model.number="selectedFaction"
          :disabled="lockedFactionId !== null">
          <option
            v-for="faction in selectableFactions"
            :key="`opt-${faction.id}`"
            :value="faction.id">
            {{ $t(`data.faction.${faction.faction_ref}.name`) }}
          </option>
        </select>
      </div>
      <div class="default-input">
        <label for="foresight-tokens">
          {{ $t('page.instance.foresight.amount', { balance: balance }) }}
        </label>
        <input
          id="foresight-tokens"
          v-model.number="tokens"
          type="number"
          min="1"
          step="1" />
      </div>
      <button
        class="default-button fullsized"
        :class="{ disabled: !canCommit }"
        @click="commit">
        <template v-if="waiting">...</template>
        <template v-else>{{ $t('page.instance.foresight.commit') }}</template>
      </button>
    </div>
    <p
      v-else
      class="foresight-empty">
      {{ $t('page.instance.foresight.window_closed') }}
    </p>
  </section>
</template>

<script>
// Foresight panel for the /portal/instance/:iid right rail
// (docs/foresight.md). Shows the crowd's lean (committed tokens per
// faction), the caller's own predictions, and the commit form.
//
// Reads GET /instances/:iid/foresight, commits via POST. Polls slowly —
// the totals are ambience, not gameplay state. The parent gates
// rendering on the `foresight` beta flag; the server enforces it too.
const POLL_INTERVAL_MS = 30 * 1000;

export default {
  name: 'foresight-panel',
  props: {
    iid: {
      type: [String, Number],
      required: true,
    },
    factions: {
      type: Array,
      required: true,
    },
    // The caller's faction id when they're registered in this match
    // (rule 5: players only back their own faction). Null = spectator.
    registeredFactionId: {
      type: Number,
      default: null,
    },
  },
  data() {
    return {
      totals: [],
      mine: [],
      open: false,
      selectedFaction: null,
      tokens: null,
      waiting: false,
      polling: null,
    };
  },
  computed: {
    account() { return this.$store.state.portal.account; },
    balance() { return this.account.foresight_tokens || 0; },
    totalTokens() {
      return this.totals.reduce((sum, t) => sum + t.tokens, 0);
    },
    activeMine() {
      return this.mine.filter((p) => p.status === 'active');
    },
    // Rule 6: all of an account's predictions in a match target one
    // faction — once one is active, further commits are locked to it.
    lockedFactionId() {
      if (this.registeredFactionId) return this.registeredFactionId;
      if (this.activeMine.length > 0) return this.activeMine[0].faction_id;
      return null;
    },
    selectableFactions() {
      if (this.lockedFactionId === null) return this.factions;
      return this.factions.filter((f) => f.id === this.lockedFactionId);
    },
    canCommit() {
      return !this.waiting
        && this.selectedFaction !== null
        && Number.isInteger(this.tokens)
        && this.tokens > 0;
    },
  },
  methods: {
    getTheme(ref) {
      const faction = this.$store.state.portal.data.faction.find((f) => f.key === ref);
      return faction ? `theme-${faction.theme}` : '';
    },
    factionTokens(factionId) {
      const entry = this.totals.find((t) => t.faction_id === factionId);
      return entry ? entry.tokens : 0;
    },
    leanPercent(factionId) {
      if (this.totalTokens === 0) return 0;
      return Math.round((this.factionTokens(factionId) / this.totalTokens) * 100);
    },
    async fetchSummary() {
      try {
        const { data } = await this.$axios.get(`/instances/${this.iid}/foresight`);
        this.totals = data.totals || [];
        this.mine = data.mine || [];
        this.open = data.open === true;

        if (this.selectedFaction === null) {
          this.selectedFaction = this.lockedFactionId
            || (this.factions.length > 0 ? this.factions[0].id : null);
        }
      } catch (err) {
        // Silent failure — the panel degrades to its empty state. A 403
        // means the beta flag is off server-side; the parent shouldn't
        // have rendered us, so just stay empty.
        this.totals = [];
        this.mine = [];
        this.open = false;
      }
    },
    async commit() {
      if (!this.canCommit) return;
      this.waiting = true;

      try {
        const { data } = await this.$axios.post(`/instances/${this.iid}/foresight`, {
          faction_id: this.selectedFaction,
          tokens: this.tokens,
        });

        this.$store.commit('portal/updateAccountForesight', {
          tokens: data.tokens,
          points: data.points,
        });
        this.tokens = null;
        this.$toasted.success(this.$t('page.instance.foresight.committed'));
        await this.fetchSummary();
      } catch (err) {
        this.$toastError(err.response && err.response.data.message);
      }

      this.waiting = false;
    },
  },
  mounted() {
    this.fetchSummary();
    this.polling = setInterval(() => this.fetchSummary(), POLL_INTERVAL_MS);
  },
  beforeDestroy() {
    if (this.polling) clearInterval(this.polling);
  },
};
</script>

<style lang="scss" scoped>
@import '@/styles/shared/variables.scss';

.foresight-faction {
  margin-top: 0.6em;
}

.foresight-faction-label {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.95em;

  .icon {
    width: 16px;
    height: 16px;
    flex: 0 0 auto;
  }

  .name {
    flex: 1 1 auto;
  }

  .tokens {
    flex: 0 0 auto;
    opacity: 0.7;
    font-size: 0.9em;
  }
}

.gauge-container {
  margin-top: 0.25em;
  height: 6px;
  background: rgba(255, 255, 255, 0.08);

  .gauge-content {
    height: 100%;
    transition: width 0.4s ease;
  }
}

// Faction theme tint for icon + gauge fill, same trick as the
// registration capacity gauges (styles/portal/panel/instance.scss).
@each $class, $color in $themes-list {
  .theme-#{$class} {
    color: $color;

    &.gauge-content {
      background: $color;
    }
  }
}

.foresight-empty {
  margin-top: 0.75em;
  opacity: 0.6;
  font-style: italic;
}

.foresight-mine {
  margin-top: 1em;

  h3 {
    font-size: 0.95em;
    text-transform: uppercase;
    opacity: 0.8;
  }

  ul {
    list-style: none;
    margin: 0.25em 0 0;
    padding: 0;
  }

  li {
    display: flex;
    justify-content: space-between;
    gap: 0.75em;
    padding: 0.3em 0;
    font-size: 0.95em;
    border-top: 1px solid rgba(255, 255, 255, 0.08);

    &:first-child {
      border-top: none;
    }
  }

  .status {
    white-space: nowrap;
    opacity: 0.7;

    &.is-correct {
      color: $primary;
      opacity: 1;
    }
  }
}

.foresight-form {
  margin-top: 1em;

  .hint {
    font-size: 0.9em;
    opacity: 0.7;
  }

  select {
    width: 100%;
  }
}
</style>
