<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.empire.cheats_title') }}
      </h1>

      <!-- give resources -->
      <section class="cheat-section">
        <h2 class="cheat-subtitle">{{ $t('panel.empire.cheats_give_title') }}</h2>
        <div class="cheat-row">
          <select v-model="give.target" class="cheat-select">
            <option value="all">{{ $t('panel.empire.cheats_all_players') }}</option>
            <option
              v-for="p in players"
              :key="`give-${p.id}`"
              :value="p.id">
              {{ p.name }}
            </option>
          </select>
          <select v-model="give.resource" class="cheat-select">
            <option value="credit">{{ $t('panel.empire.cheats_resource_credit') }}</option>
            <option value="technology">{{ $t('panel.empire.cheats_resource_technology') }}</option>
            <option value="ideology">{{ $t('panel.empire.cheats_resource_ideology') }}</option>
          </select>
          <input
            v-model.number="give.amount"
            type="number"
            min="1"
            class="cheat-input"
            :placeholder="$t('panel.empire.cheats_amount')" />
          <button
            class="cheat-button"
            :disabled="!giveValid || busy"
            @click="giveResources">
            {{ $t('panel.empire.cheats_give_button') }}
          </button>
        </div>
      </section>

      <!-- settle system -->
      <section class="cheat-section">
        <h2 class="cheat-subtitle">{{ $t('panel.empire.cheats_settle_title') }}</h2>
        <div class="cheat-row">
          <select v-model="settle.target" class="cheat-select">
            <option
              v-for="p in players"
              :key="`settle-${p.id}`"
              :value="p.id">
              {{ p.name }}
            </option>
          </select>
          <div class="cheat-autocomplete">
            <input
              v-model="settle.query"
              type="text"
              class="cheat-input is-wide"
              autocomplete="off"
              spellcheck="false"
              :placeholder="$t('panel.empire.cheats_system_placeholder')"
              @input="settle.system = null" />
            <div
              v-if="systemSuggestions.length && !settle.system"
              class="cheat-suggestions">
              <div
                v-for="s in systemSuggestions"
                :key="s.id"
                class="cheat-suggestion"
                @click="pickSystem(s)">
                <span>{{ s.name }}</span>
                <span class="cheat-suggestion-meta">
                  {{ Math.round(s.position.x) }}, {{ Math.round(s.position.y) }}
                </span>
              </div>
            </div>
          </div>
          <button
            class="cheat-button"
            :disabled="!settleValid || busy"
            @click="settleSystem">
            {{ $t('panel.empire.cheats_settle_button') }}
          </button>
        </div>
      </section>

      <!-- government / elections -->
      <section class="cheat-section">
        <h2 class="cheat-subtitle">{{ $t('panel.empire.cheats_gov_title') }}</h2>
        <div class="cheat-row">
          <button
            class="cheat-button"
            :disabled="busy"
            @click="simplePush('skip_election_timer')">
            {{ $t('panel.empire.cheats_skip_founding') }}
          </button>
          <button
            class="cheat-button"
            :disabled="busy"
            @click="simplePush('conclude_elections')">
            {{ $t('panel.empire.cheats_conclude_elections') }}
          </button>
          <button
            class="cheat-button"
            :disabled="busy"
            @click="simplePush('clear_lex_cooldowns')">
            {{ $t('panel.empire.cheats_clear_lex') }}
          </button>
        </div>
      </section>

      <!-- game speed -->
      <section class="cheat-section">
        <h2 class="cheat-subtitle">
          {{ $t('panel.empire.cheats_speed_title') }}
          <span class="cheat-speed-current">
            {{ $t('panel.empire.cheats_speed_current', { speedup: currentSpeedup }) }}
          </span>
        </h2>
        <div class="cheat-row">
          <select v-model.number="speed.multiplier" class="cheat-select">
            <option
              v-for="m in speedMultipliers"
              :key="`speed-${m}`"
              :value="m">
              {{ m }}×
            </option>
          </select>
          <button
            class="cheat-button"
            :disabled="busy || speed.multiplier === currentSpeedup"
            @click="setSpeed">
            {{ $t('panel.empire.cheats_speed_apply') }}
          </button>
        </div>
      </section>
    </v-scrollbar>
  </div>
</template>

<script>
const MAX_SUGGESTIONS = 8;

export default {
  name: 'empire-cheats-panel',
  inject: ['mapData'],
  data() {
    return {
      busy: false,
      give: {
        target: 'all',
        resource: 'credit',
        amount: null,
      },
      settle: {
        target: null,
        query: '',
        system: null,
      },
      speed: {
        multiplier: 1,
      },
      // keep in sync with @allowed_speed_multipliers in cheat_channel.ex
      speedMultipliers: [0.25, 0.5, 1, 2, 5, 10, 20, 50],
    };
  },
  computed: {
    players() {
      const players = this.$store.state.game.galaxy.players || {};
      return Object.values(players).slice(0).sort((a, b) => a.name.localeCompare(b.name));
    },
    currentSpeedup() {
      return this.$store.state.game.instanceInfo.speedup || 1;
    },
    giveValid() {
      return this.give.target !== null
        && Number.isFinite(this.give.amount)
        && this.give.amount > 0;
    },
    settleValid() {
      return this.settle.target !== null && this.settle.system !== null;
    },
    systemSuggestions() {
      const q = this.settle.query.trim().toLowerCase();
      if (!q) return [];

      // same prefix-first matching as the F-hotkey Find System overlay
      const systems = this.mapData.systems || [];
      const starts = [];
      const contains = [];

      systems.forEach((s) => {
        if (!s.name) return;
        const lower = s.name.toLowerCase();
        if (lower.startsWith(q)) {
          starts.push(s);
        } else if (lower.includes(q)) {
          contains.push(s);
        }
      });

      const cmp = (a, b) => a.name.localeCompare(b.name);
      starts.sort(cmp);
      contains.sort(cmp);
      return [...starts, ...contains].slice(0, MAX_SUGGESTIONS);
    },
  },
  methods: {
    channel() {
      return this.$socket.joinCheat();
    },
    push(event, payload) {
      const channel = this.channel();
      if (!channel) {
        this.$toastError(this.$t('panel.empire.cheats_channel_error'));
        return Promise.reject();
      }

      this.busy = true;
      return new Promise((resolve) => {
        channel.push(event, payload)
          .receive('ok', (data) => {
            this.busy = false;
            this.$toasted.success(this.$t('panel.empire.cheats_done'));
            resolve(data);
          })
          .receive('error', (data) => {
            this.busy = false;
            this.$toastError(String((data && data.reason) || 'error'));
          })
          .receive('timeout', () => {
            this.busy = false;
            this.$toastError(this.$t('panel.empire.cheats_channel_error'));
          });
      });
    },
    giveResources() {
      this.push('give_resources', {
        target: this.give.target === 'all' ? 'all' : this.give.target,
        resource: this.give.resource,
        amount: this.give.amount,
      });
    },
    settleSystem() {
      this.push('settle_system', {
        target: this.settle.target,
        system_id: this.settle.system.id,
      }).then(() => {
        this.settle.query = '';
        this.settle.system = null;
      });
    },
    simplePush(event) {
      this.push(event, {});
    },
    setSpeed() {
      this.push('set_speed', { multiplier: this.speed.multiplier });
    },
    pickSystem(system) {
      this.settle.system = system;
      this.settle.query = system.name;
    },
  },
  mounted() {
    // join eagerly so the first click doesn't race the channel join
    this.channel();
    this.speed.multiplier = this.currentSpeedup;

    if (this.players.length && this.settle.target === null) {
      this.settle.target = this.players[0].id;
    }
  },
};
</script>

<style scoped>
.cheat-section {
  margin-bottom: 1.5rem;
}
.cheat-subtitle {
  text-transform: uppercase;
  font-size: 1.2rem;
  opacity: 0.7;
  margin-bottom: 0.75rem;
}
.cheat-row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: flex-start;
}
.cheat-select,
.cheat-input,
.cheat-button {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
  padding: 6px 10px;
  font: inherit;
}
.cheat-select option {
  background: #111;
}
.cheat-input {
  width: 110px;
}
.cheat-input.is-wide {
  width: 200px;
}
.cheat-button {
  cursor: pointer;
}
.cheat-button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.15);
}
.cheat-button:disabled {
  opacity: 0.4;
  cursor: default;
}
.cheat-autocomplete {
  position: relative;
}
.cheat-suggestions {
  position: absolute;
  top: 100%;
  left: 0;
  right: 0;
  z-index: 10;
  background: #10131a;
  border: 1px solid rgba(255, 255, 255, 0.2);
  max-height: 220px;
  overflow-y: auto;
}
.cheat-suggestion {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  padding: 5px 10px;
  cursor: pointer;
}
.cheat-suggestion:hover {
  background: rgba(255, 255, 255, 0.1);
}
.cheat-suggestion-meta {
  opacity: 0.6;
}
.cheat-speed-current {
  text-transform: none;
  opacity: 0.8;
  margin-left: 8px;
}
</style>
