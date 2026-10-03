<template>
  <default-layout>
    <div class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <section class="panel-aside-info">
          <h2>
            {{ $t('page.wave_diagnostics.status') }}
            <span
              v-if="report"
              class="wd-badge"
              :class="report.live ? 'is-ok' : 'is-bad'">
              {{ report.live ? $t('page.wave_diagnostics.live') : $t('page.wave_diagnostics.down') }}
            </span>
          </h2>
          <p v-if="report">
            {{ $t('page.wave_diagnostics.instance_state') }}
            <strong>{{ stateName(report.state) }}</strong>
          </p>
          <p>
            <template v-if="lastUpdated">
              {{ $t('page.wave_diagnostics.last_updated', { time: formatTime(lastUpdated) }) }}
            </template>
            <template v-if="paused">
              <br>{{ $t('page.wave_diagnostics.auto_refresh_paused') }}
            </template>
          </p>
          <div class="wd-controls">
            <button
              class="default-button"
              :class="{ disabled: fetching }"
              :aria-disabled="(fetching) ? 'true' : null"
              @click="load">
              {{ fetching ? '...' : $t('page.wave_diagnostics.refresh') }}
            </button>
            <button
              class="default-button"
              @click="paused = !paused">
              {{ paused ? $t('page.wave_diagnostics.resume') : $t('page.wave_diagnostics.pause') }}
            </button>
          </div>
        </section>

        <section
          v-if="rebellion"
          class="panel-aside-info">
          <h2>{{ rebellion.name || $t('page.wave_diagnostics.rebellion.title') }}</h2>
          <div class="wd-flags">
            <span
              class="wd-badge"
              :class="rebellion.is_active ? 'is-ok' : 'is-bad'">
              {{ rebellion.is_active ? $t('page.wave_diagnostics.rebellion.active') : $t('page.wave_diagnostics.rebellion.inactive') }}
            </span>
            <span
              class="wd-badge"
              :class="rebellion.is_bankrupt ? 'is-bad' : 'is-ok'">
              {{ rebellion.is_bankrupt ? $t('page.wave_diagnostics.rebellion.bankrupt') : $t('page.wave_diagnostics.rebellion.solvent') }}
            </span>
          </div>
          <table class="wd-kv">
            <tr
              v-for="key in rebellionKeys"
              :key="`reb-${key}`">
              <td>{{ $t(`page.wave_diagnostics.rebellion.${key}`) }}</td>
              <td>{{ num(rebellion[key]) }}</td>
            </tr>
            <tr>
              <td>{{ $t('page.wave_diagnostics.rebellion.player_id') }}</td>
              <td>#{{ rebellion.id }}</td>
            </tr>
          </table>
        </section>

        <section
          v-if="sectors"
          class="panel-aside-info">
          <h2>{{ $t('page.wave_diagnostics.sectors.title') }}</h2>
          <table class="wd-kv">
            <tr
              v-for="row in sectorOwners"
              :key="`sector-${row.owner}`">
              <td>{{ row.owner || $t('page.wave_diagnostics.sectors.unowned') }}</td>
              <td>{{ num(row.count) }}</td>
            </tr>
          </table>
        </section>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-full-sized">
        <router-link
          class="close-button"
          :to="`/instance/${iid}`">
          {{ $t('page.wave_diagnostics.back') }}
        </router-link>

        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.wave_diagnostics.title') }}</strong>
            <span class="wd-subtitle">#{{ iid }}</span>
          </h1>
        </div>

        <loading-mask v-if="!report && !error" />

        <v-scrollbar
          v-else
          class="content wd-content">
          <div
            v-if="error"
            class="wd-notice is-alert">
            {{ error }}
            <template v-if="report">
              <br>{{ $t('page.wave_diagnostics.errors.showing_last') }}
            </template>
          </div>

          <template v-if="report">
            <div
              v-if="!report.live"
              class="wd-notice">
              {{ $t('page.wave_diagnostics.not_live') }}
            </div>

            <!-- HEALTH ------------------------------------------------------ -->
            <div class="wd-tiles">
              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.state') }}</div>
                <div
                  class="wd-tile-value"
                  :class="report.state === 'running' ? 'is-ok' : 'is-warn'">
                  {{ stateName(report.state) }}
                </div>
                <div class="wd-tile-sub">
                  {{ clock.running ? $t('page.wave_diagnostics.health.clock_running') : $t('page.wave_diagnostics.health.clock_stopped') }}
                  <template v-if="clock.speed"> · {{ clock.speed }}</template>
                </div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.clock') }}</div>
                <div class="wd-tile-value">{{ num(clock.game_ut, 1) }} ut</div>
                <div class="wd-tile-sub">
                  {{ $t('page.wave_diagnostics.health.warlord_ut', { ut: num(clock.warlord_ut, 1) }) }}
                </div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.lag') }}</div>
                <div
                  class="wd-tile-value"
                  :class="lagClass">
                  {{ num(clock.lag_ut, 1) }} ut
                </div>
                <div class="wd-tile-sub">
                  <template v-if="clock.lag_ut > lagWarnUt">{{ $t('page.wave_diagnostics.health.lag_warning') }}</template>
                  <template v-else>{{ $t('page.wave_diagnostics.health.lag_ok') }}</template>
                </div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.match_day') }}</div>
                <div class="wd-tile-value">{{ warlord ? num(warlord.match_day) : '—' }}</div>
                <div
                  v-if="warlord"
                  class="wd-tile-sub">
                  {{ $t('page.wave_diagnostics.health.next_hire', { time: utHint(warlord.next_hire_in_ut) }) }}
                  <br>{{ $t('page.wave_diagnostics.health.scale_players', { n: num(warlord.scale_players) }) }}
                </div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.pass_cost') }}</div>
                <div class="wd-tile-value">{{ perf ? `${num(perf.avg_us)} µs` : '—' }}</div>
                <div
                  v-if="perf"
                  class="wd-tile-sub">
                  {{ $t('page.wave_diagnostics.health.pass_detail', {
                    last: num(perf.last_us),
                    max: num(perf.max_us),
                    passes: num(perf.passes),
                  }) }}
                  <br>{{ $t('page.wave_diagnostics.health.reductions', {
                    avg: num(perf.avg_reductions),
                    last: num(perf.last_reductions),
                  }) }}
                </div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.holdings') }}</div>
                <div class="wd-tile-value">
                  {{ rebellion ? `${num(rebellion.systems)} / ${num(rebellion.dominions)}` : '—' }}
                </div>
                <div class="wd-tile-sub">{{ $t('page.wave_diagnostics.health.holdings_sub') }}</div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.sectors') }}</div>
                <div class="wd-tile-value">
                  {{ sectors ? `${num(sectors.rebel)} / ${num(sectors.total)}` : '—' }}
                </div>
                <div class="wd-tile-sub">{{ $t('page.wave_diagnostics.health.sectors_sub') }}</div>
              </div>

              <div class="wd-tile">
                <div class="wd-tile-label">{{ $t('page.wave_diagnostics.health.resources') }}</div>
                <div
                  v-if="rebellion"
                  class="wd-tile-value is-small">
                  {{ num(rebellion.credit) }} ¤
                </div>
                <div
                  v-else
                  class="wd-tile-value">—</div>
                <div
                  v-if="rebellion"
                  class="wd-tile-sub">
                  {{ $t('page.wave_diagnostics.health.tech_ideo', {
                    technology: num(rebellion.technology),
                    ideology: num(rebellion.ideology),
                  }) }}
                </div>
              </div>
            </div>

            <!-- ORDERS ------------------------------------------------------ -->
            <h2 class="default-title">{{ $t('page.wave_diagnostics.orders.title') }}</h2>
            <p
              v-if="!orders.length"
              class="wd-empty">
              {{ $t('page.wave_diagnostics.orders.none') }}
            </p>
            <table
              v-else
              class="default-table wd-table">
              <tr class="wd-head">
                <th>{{ $t('page.wave_diagnostics.orders.kind') }}</th>
                <th class="is-num">{{ $t('page.wave_diagnostics.orders.taken') }}</th>
                <th class="is-num">{{ $t('page.wave_diagnostics.orders.refused') }}</th>
                <th class="is-num">{{ $t('page.wave_diagnostics.orders.success') }}</th>
                <th>{{ $t('page.wave_diagnostics.orders.last_refusal') }}</th>
              </tr>
              <template v-for="order in orders">
                <tr
                  :key="`order-${order.kind}`"
                  class="is-clickable"
                  @click="toggle(expandedOrders, order.kind)">
                  <td>
                    <span class="wd-caret">{{ expandedOrders.includes(order.kind) ? '▾' : '▸' }}</span>
                    <code>{{ order.kind }}</code>
                  </td>
                  <td class="is-num">{{ num(order.ok) }}</td>
                  <td class="is-num">{{ num(order.failed) }}</td>
                  <td
                    class="is-num wd-rate"
                    :class="rateClass(order.success_rate)">
                    {{ pct(order.success_rate) }}
                  </td>
                  <td>
                    <template v-if="order.last_reason">
                      <code>{{ order.last_reason }}</code>
                      <em v-if="order.last_failed_ut != null"> @ {{ num(order.last_failed_ut, 1) }} ut</em>
                    </template>
                    <template v-else>—</template>
                  </td>
                </tr>
                <tr
                  v-if="expandedOrders.includes(order.kind)"
                  :key="`order-${order.kind}-detail`"
                  class="wd-detail">
                  <td colspan="5">
                    <div class="wd-detail-line">
                      {{ $t('page.wave_diagnostics.orders.last_ok', { ut: order.last_ok_ut != null ? num(order.last_ok_ut, 1) : '—' }) }}
                      ·
                      {{ $t('page.wave_diagnostics.orders.last_failed', { ut: order.last_failed_ut != null ? num(order.last_failed_ut, 1) : '—' }) }}
                    </div>
                    <p
                      v-if="!(order.reasons || []).length"
                      class="wd-empty">
                      {{ $t('page.wave_diagnostics.orders.no_reasons') }}
                    </p>
                    <table
                      v-else
                      class="wd-kv">
                      <tr
                        v-for="r in order.reasons"
                        :key="`order-${order.kind}-${r.reason}`">
                        <td><code>{{ r.reason }}</code></td>
                        <td>{{ num(r.count) }}</td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </template>
            </table>

            <!-- OUTCOMES ---------------------------------------------------- -->
            <h2 class="default-title">{{ $t('page.wave_diagnostics.outcomes.title') }}</h2>
            <p
              v-if="!outcomes.length"
              class="wd-empty">
              {{ $t('page.wave_diagnostics.outcomes.none') }}
            </p>
            <table
              v-else
              class="default-table wd-table">
              <tr class="wd-head">
                <th>{{ $t('page.wave_diagnostics.outcomes.outcome') }}</th>
                <th class="is-num">{{ $t('page.wave_diagnostics.outcomes.attempted') }}</th>
                <th>{{ $t('page.wave_diagnostics.outcomes.results') }}</th>
              </tr>
              <tr
                v-for="outcome in outcomes"
                :key="`outcome-${outcome.label}`">
                <td>{{ outcome.label }}</td>
                <td class="is-num">{{ outcome.attempted == null ? '—' : num(outcome.attempted) }}</td>
                <td>
                  <span
                    v-for="result in outcome.results"
                    :key="`outcome-${outcome.label}-${result.name}`"
                    class="wd-chip">
                    {{ result.name }} <strong>{{ num(result.count) }}</strong>
                    <template v-if="result.share != null">({{ pct(result.share) }})</template>
                  </span>
                </td>
              </tr>
            </table>

            <!-- AGENTS ------------------------------------------------------ -->
            <div class="wd-section-head">
              <h2 class="default-title">
                {{ $t('page.wave_diagnostics.agents.title') }}
                <span class="wd-subtitle">{{ shownAgents.length }} / {{ agents.length }}</span>
              </h2>
              <label class="wd-toggle">
                <input
                  v-model="longPendingOnly"
                  type="checkbox">
                {{ $t('page.wave_diagnostics.agents.long_pending_only') }}
              </label>
            </div>
            <p class="wd-caption">
              {{ $t('page.wave_diagnostics.agents.caption', { n: num(report.stale_after_passes) }) }}
            </p>
            <p
              v-if="!shownAgents.length"
              class="wd-empty">
              {{ longPendingOnly ? $t('page.wave_diagnostics.agents.none_pending') : $t('page.wave_diagnostics.agents.none') }}
            </p>
            <table
              v-else
              class="default-table wd-table">
              <tr class="wd-head">
                <th>{{ $t('page.wave_diagnostics.agents.role') }}</th>
                <th>{{ $t('page.wave_diagnostics.agents.name') }}</th>
                <th>{{ $t('page.wave_diagnostics.agents.stage') }}</th>
                <th>{{ $t('page.wave_diagnostics.agents.duty') }}</th>
                <th>{{ $t('page.wave_diagnostics.agents.target') }}</th>
                <th class="is-num">{{ $t('page.wave_diagnostics.agents.age') }}</th>
                <th>{{ $t('page.wave_diagnostics.agents.engine') }}</th>
              </tr>
              <tr
                v-for="agent in shownAgents"
                :key="`agent-${agent.role}-${agent.id}`"
                :class="{ 'is-stale': agent.stale, 'is-missing': agent.missing }">
                <td>
                  {{ agent.role }}
                  <span
                    v-if="agent.stale"
                    class="wd-badge is-warn">{{ $t('page.wave_diagnostics.agents.stale') }}</span>
                  <span
                    v-if="agent.missing"
                    class="wd-badge is-bad">{{ $t('page.wave_diagnostics.agents.missing') }}</span>
                </td>
                <td>
                  {{ agent.name || '—' }}
                  <em>#{{ agent.id }}</em>
                </td>
                <td><code v-if="agent.stage">{{ show(agent.stage) }}</code><template v-else>—</template></td>
                <td>
                  {{ dutyLine(agent) }}
                </td>
                <td>
                  <template v-if="agent.target != null">
                    {{ agent.target_name || show(agent.target) }}
                    <em v-if="agent.target_name">#{{ show(agent.target) }}</em>
                  </template>
                  <template v-else>—</template>
                </td>
                <td class="is-num">{{ agent.age_ut == null ? '—' : utHint(agent.age_ut) }}</td>
                <td>
                  <template v-if="agent.engine">
                    <code>{{ show(agent.engine.action_status) }}</code>
                    <em v-if="agent.engine.status"> / {{ show(agent.engine.status) }}</em>
                    <div class="wd-engine-sub">
                      <template v-if="agent.engine.system != null">
                        @ {{ agent.engine.system_name || `#${agent.engine.system}` }} ·
                      </template>
                      {{ $t('page.wave_diagnostics.agents.queued', { n: num(agent.engine.queued_actions || 0) }) }}
                    </div>
                  </template>
                  <template v-else>—</template>
                </td>
              </tr>
            </table>

            <!-- EVENTS ------------------------------------------------------ -->
            <h2 class="default-title">{{ $t('page.wave_diagnostics.events.title') }}</h2>
            <p
              v-if="!events.length"
              class="wd-empty">
              {{ $t('page.wave_diagnostics.events.none') }}
            </p>
            <template v-else>
              <p class="wd-caption">{{ $t('page.wave_diagnostics.events.hint') }}</p>
              <table class="default-table wd-table wd-events">
                <tr class="wd-head">
                  <th>{{ $t('page.wave_diagnostics.events.time') }}</th>
                  <th>{{ $t('page.wave_diagnostics.events.kind') }}</th>
                  <th>{{ $t('page.wave_diagnostics.events.character') }}</th>
                  <th>{{ $t('page.wave_diagnostics.events.system') }}</th>
                  <th>{{ $t('page.wave_diagnostics.events.payload') }}</th>
                </tr>
                <template v-for="event in events">
                  <tr
                    :key="`event-${event.id}`"
                    class="is-clickable"
                    @click="toggle(expandedEvents, event.id)">
                    <td class="wd-nowrap">{{ formatDateTime(event.inserted_at) }}</td>
                    <td><code>{{ event.kind }}</code></td>
                    <td>
                      <template v-if="event.character_id != null">
                        {{ agentNames[event.character_id] || '' }}
                        <em>#{{ event.character_id }}</em>
                      </template>
                      <template v-else>—</template>
                    </td>
                    <td>
                      <template v-if="event.system_id != null">
                        {{ systemNames[event.system_id] || '' }}
                        <em>#{{ event.system_id }}</em>
                      </template>
                      <template v-else>—</template>
                    </td>
                    <td class="wd-payload-preview">{{ preview(event.payload) }}</td>
                  </tr>
                  <tr
                    v-if="expandedEvents.includes(event.id)"
                    :key="`event-${event.id}-detail`"
                    class="wd-detail">
                    <td colspan="5">
                      <pre class="wd-pre">{{ pretty(event.payload) }}</pre>
                    </td>
                  </tr>
                </template>
              </table>
            </template>

            <hr class="margin">
          </template>
        </v-scrollbar>
      </div>

      <v-scrollbar class="panel-aside">
        <template v-if="report">
          <section class="panel-aside-info">
            <h2>{{ $t('page.wave_diagnostics.refusals.title') }}</h2>
            <p
              v-if="!refusals.length"
              class="wd-empty">
              {{ $t('page.wave_diagnostics.refusals.none') }}
            </p>
            <table
              v-else
              class="wd-kv">
              <tr
                v-for="r in refusals"
                :key="`refusal-${r.reason}`">
                <td><code>{{ r.reason }}</code></td>
                <td>{{ num(r.count) }}</td>
              </tr>
            </table>
          </section>

          <section
            v-for="block in kvBlocks"
            :key="`kv-${block.key}`"
            class="panel-aside-info">
            <h2>{{ $t(`page.wave_diagnostics.${block.key}.title`) }}</h2>
            <p
              v-if="!block.rows.length"
              class="wd-empty">
              {{ $t('page.wave_diagnostics.empty') }}
            </p>
            <table
              v-else
              class="wd-kv">
              <tr
                v-for="row in block.rows"
                :key="`kv-${block.key}-${row.key}`">
                <td><code>{{ row.key }}</code></td>
                <td>{{ row.value }}</td>
              </tr>
            </table>
          </section>
        </template>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import LoadingMask from '@/portal/components/LoadingMask.vue';

const REFRESH_MS = 15000;
const LAG_WARN_UT = 5;
const PREVIEW_CHARS = 120;
// Game-time factor per match speed (lib/game/instance/time/time.ex): at
// factor 1 (Legacy) one ut is 180 real seconds.
const SPEED_FACTORS = { slow: 1, medium: 20, fast: 120 };
const SECONDS_PER_UT_AT_FACTOR_1 = 180;
const FATAL_STATUSES = [403, 404, 422];

export default {
  name: 'wave-diagnostics',
  data() {
    return {
      report: null,
      error: null,
      fetching: false,
      paused: false,
      lastUpdated: null,
      timer: null,
      longPendingOnly: false,
      expandedOrders: [],
      expandedEvents: [],
      lagWarnUt: LAG_WARN_UT,
      rebellionKeys: ['credit', 'technology', 'ideology', 'systems', 'dominions', 'agents', 'deck'],
    };
  },
  computed: {
    iid() { return this.$route.params.iid; },
    isAdmin() { return this.$store.state.portal.isAdmin; },
    clock() { return (this.report && this.report.clock) || {}; },
    warlord() { return this.report && this.report.warlord; },
    perf() { return this.warlord && this.warlord.perf; },
    rebellion() { return this.report && this.report.rebellion; },
    sectors() { return this.report && this.report.sectors; },
    orders() { return (this.report && this.report.orders) || []; },
    outcomes() { return (this.report && this.report.outcomes) || []; },
    refusals() { return (this.report && this.report.refusals) || []; },
    agents() { return (this.report && this.report.agents) || []; },
    events() { return (this.report && this.report.events) || []; },
    shownAgents() {
      return this.longPendingOnly
        ? this.agents.filter((a) => a.stale || a.missing)
        : this.agents;
    },
    sectorOwners() {
      return ((this.sectors && this.sectors.by_owner) || [])
        .slice()
        .sort((a, b) => b.count - a.count);
    },
    lagClass() {
      const lag = this.clock.lag_ut;
      if (lag == null) return '';
      return lag > LAG_WARN_UT ? 'is-bad' : 'is-ok';
    },
    secondsPerUt() {
      const factor = SPEED_FACTORS[this.clock.speed] || 1;
      return SECONDS_PER_UT_AT_FACTOR_1 / factor;
    },
    agentNames() {
      const names = {};
      this.agents.forEach((a) => { if (a.name) names[a.id] = a.name; });
      return names;
    },
    // The events carry bare system ids; name the ones the agent table knows.
    systemNames() {
      const names = {};
      this.agents.forEach((a) => {
        if (a.target != null && a.target_name) names[a.target] = a.target_name;
        if (a.engine && a.engine.system != null && a.engine.system_name) {
          names[a.engine.system] = a.engine.system_name;
        }
      });
      return names;
    },
    kvBlocks() {
      const w = this.warlord || {};
      return [
        { key: 'ceilings', rows: this.flatten(w.ceilings) },
        { key: 'gauges', rows: this.flatten(w.gauges) },
        { key: 'telemetry', rows: this.flatten(w.telemetry) },
      ];
    },
  },
  watch: {
    iid() {
      this.report = null;
      this.error = null;
      this.expandedOrders = [];
      this.expandedEvents = [];
      this.load();
    },
  },
  methods: {
    async load() {
      if (this.fetching) return;
      this.fetching = true;
      const { iid } = this;

      try {
        const { data } = await this.$axios.get(`/instances/${iid}/wave/diagnostics`);
        if (iid !== this.iid) return;
        this.report = data;
        this.error = null;
        this.lastUpdated = new Date();
      } catch (err) {
        if (iid !== this.iid) return;
        const status = err.response && err.response.status;
        this.error = this.describeError(err, status);
        // Polling can't fix a wrong game id or a non-wave game.
        if (FATAL_STATUSES.includes(status)) this.paused = true;
      } finally {
        this.fetching = false;
      }
    },
    describeError(err, status) {
      const message = err.response && err.response.data && err.response.data.message;
      if (status === 422 || message === 'not_a_wave_instance') {
        return this.$t('page.wave_diagnostics.errors.not_a_wave');
      }
      if (status === 404) return this.$t('page.wave_diagnostics.errors.not_found');
      if (status === 403 || status === 401) return this.$t('page.wave_diagnostics.errors.forbidden');
      return this.$t('page.wave_diagnostics.errors.generic', {
        message: message || err.message || status || '?',
      });
    },
    toggle(list, key) {
      const i = list.indexOf(key);
      if (i === -1) list.push(key);
      else list.splice(i, 1);
    },
    stateName(state) {
      if (!state) return '—';
      const key = `instance.state.${state}.name`;
      return this.$te(key) ? this.$t(key) : state;
    },
    num(value, digits = 0) {
      if (value == null || value === '') return '—';
      if (typeof value !== 'number') return String(value);
      return value.toLocaleString(undefined, {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
      });
    },
    pct(rate) {
      if (rate == null) return '—';
      return `${(rate * 100).toFixed(rate === 1 || rate === 0 ? 0 : 1)}%`;
    },
    rateClass(rate) {
      if (rate == null) return '';
      if (rate >= 0.9) return 'is-ok';
      if (rate >= 0.5) return 'is-warn';
      return 'is-bad';
    },
    // "126 ut (~6.3 h)" at Legacy speed.
    utHint(ut) {
      if (ut == null) return '—';
      return `${this.num(ut, 1)} ut (~${this.realHint(ut)})`;
    },
    realHint(ut) {
      if (ut == null) return '—';
      const seconds = ut * this.secondsPerUt;
      if (seconds < 3600) {
        return this.$t('page.wave_diagnostics.units.min', { n: this.num(seconds / 60) });
      }
      if (seconds < 48 * 3600) {
        return this.$t('page.wave_diagnostics.units.h', { n: this.num(seconds / 3600, 1) });
      }
      return this.$t('page.wave_diagnostics.units.d', { n: this.num(seconds / 86400, 1) });
    },
    show(value) {
      if (value == null) return '—';
      if (typeof value === 'object') return JSON.stringify(value);
      return String(value);
    },
    dutyLine(agent) {
      const parts = [agent.duty, agent.action, agent.theatre]
        .filter((v) => v != null && v !== '')
        .map((v) => this.show(v));
      return parts.length ? parts.join(' · ') : '—';
    },
    // One level of nesting (e.g. telemetry.siderian_ut.travel) flattened to
    // dotted keys; deeper values render as JSON.
    flatten(obj) {
      if (!obj || typeof obj !== 'object') return [];
      const rows = [];
      Object.keys(obj).sort().forEach((key) => {
        const value = obj[key];
        if (value && typeof value === 'object' && !Array.isArray(value)) {
          const inner = Object.keys(value).sort();
          if (!inner.length) rows.push({ key, value: '—' });
          inner.forEach((k) => rows.push({ key: `${key}.${k}`, value: this.kvValue(value[k]) }));
        } else {
          rows.push({ key, value: this.kvValue(value) });
        }
      });
      return rows;
    },
    kvValue(value) {
      if (typeof value === 'number') {
        return this.num(value, Number.isInteger(value) ? 0 : 1);
      }
      return this.show(value);
    },
    preview(payload) {
      if (payload == null) return '—';
      const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
      return text.length > PREVIEW_CHARS ? `${text.slice(0, PREVIEW_CHARS)}…` : text;
    },
    pretty(payload) {
      if (payload == null) return '—';
      return typeof payload === 'string' ? payload : JSON.stringify(payload, null, 2);
    },
    parseDate(value) {
      if (!value) return null;
      // Naive timestamps are UTC on the server.
      const iso = /[zZ]|[+-]\d\d:?\d\d$/.test(value) ? value : `${value}Z`;
      const date = new Date(iso);
      return Number.isNaN(date.getTime()) ? null : date;
    },
    formatTime(date) {
      return date.toLocaleTimeString();
    },
    formatDateTime(value) {
      const date = this.parseDate(value);
      if (!date) return value || '—';
      return date.toLocaleString(undefined, {
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
      });
    },
  },
  mounted() {
    if (!this.isAdmin) {
      this.$router.replace(`/instance/${this.iid}`);
      return;
    }

    this.load();
    this.timer = setInterval(() => {
      if (!this.paused) this.load();
    }, REFRESH_MS);
  },
  beforeDestroy() {
    clearInterval(this.timer);
  },
  components: {
    LoadingMask,
    DefaultLayout,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

$wd-ok: $theme-green;
$wd-warn: $theme-yellow;
$wd-bad: $color-alert;

.is-ok { color: $wd-ok; }
.is-warn { color: $wd-warn; }
.is-bad { color: $wd-bad; }

.wd-subtitle {
  margin-left: 10px;
  font-size: 1.4rem;
  font-weight: normal;
  opacity: .6;
}

.wd-badge {
  display: inline-block;
  margin-left: 6px;
  padding: 1px 6px 0 6px;
  border-radius: 3px;
  font-size: 1.1rem;
  line-height: 18px;
  font-weight: bold;
  text-transform: uppercase;
  color: $black;
  vertical-align: middle;

  &.is-ok { background: $wd-ok; color: $black; }
  &.is-warn { background: $wd-warn; color: $black; }
  &.is-bad { background: $wd-bad; color: $black; }
}

.wd-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  padding: 0 15px 15px 15px;
}

.wd-flags {
  padding: 10px 15px 0 9px;
}

.wd-kv {
  width: 100%;
  margin: 5px 0 10px 0;
  font-size: 1.3rem;

  td {
    padding: 4px 15px;
    border-bottom: solid 1px rgba(0, 0, 0, .15);
    vertical-align: top;
    word-break: break-word;

    &:last-child {
      text-align: right;
      white-space: nowrap;
      font-variant-numeric: tabular-nums;
    }
  }

  code { font-size: 1.2rem; }
}

.wd-content {
  position: relative;
}

.wd-notice {
  margin-bottom: 14px;
  padding: 8px 12px;
  border-left: solid 3px $grey-dark;
  background: rgba(0, 0, 0, .15);
  color: $white-alt-1;

  &.is-alert {
    border-left-color: $color-alert;
    color: $white;
  }
}

.wd-tiles {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(170px, 1fr));
  gap: 10px;
  margin-bottom: 25px;
}

.wd-tile {
  padding: 10px 12px;
  background: rgba(0, 0, 0, .15);
  border: solid 1px rgba(0, 0, 0, .2);
  border-radius: 3px;

  .wd-tile-label {
    font-size: 1.1rem;
    text-transform: uppercase;
    opacity: .6;
  }

  .wd-tile-value {
    margin: 4px 0;
    font-size: 2rem;
    font-weight: bold;
    font-variant-numeric: tabular-nums;

    &.is-small { font-size: 1.6rem; }
  }

  .wd-tile-sub {
    font-size: 1.15rem;
    color: $white-alt-1;
  }
}

.wd-section-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  border-bottom: solid 1px rgba(0, 0, 0, .1);
  margin-bottom: 10px;

  .default-title {
    flex-grow: 1;
    border-bottom: none;
    margin-bottom: 0;
  }
}

.wd-toggle {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 1.2rem;
  text-transform: uppercase;
  white-space: nowrap;
  cursor: pointer;
}

.wd-caption {
  margin: 0 0 10px 0;
  font-size: 1.2rem;
  color: $white-alt-2;
}

.wd-empty {
  margin: 0 0 25px 0;
  color: $white-alt-2;
  font-style: italic;
}

.wd-table {
  margin-bottom: 25px;
  font-size: 1.3rem;

  th {
    padding: 8px 10px;
    text-align: left;
    font-size: 1.1rem;
    font-weight: bold;
    text-transform: uppercase;
    opacity: .7;
    border-bottom: 1px solid rgba(0, 0, 0, .2);
    white-space: nowrap;
  }

  td { padding: 7px 10px; }

  .is-num {
    text-align: right;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  tr.wd-head:hover { background: none; }

  tr.is-clickable { cursor: pointer; }

  tr.is-stale td { background: rgba($wd-warn, .1); }
  tr.is-missing td { background: rgba($wd-bad, .14); }

  tr.wd-detail td {
    background: rgba(0, 0, 0, .15);
  }

  code { font-size: 1.2rem; }
}

.wd-rate { font-weight: bold; }

.wd-caret {
  display: inline-block;
  width: 14px;
  opacity: .6;
}

.wd-detail-line {
  margin-bottom: 6px;
  font-size: 1.2rem;
  color: $white-alt-1;
}

.wd-chip {
  display: inline-block;
  margin: 2px 6px 2px 0;
  padding: 1px 8px;
  border-radius: 3px;
  background: $grey-default;
  white-space: nowrap;
}

.wd-engine-sub {
  font-size: 1.15rem;
  color: $white-alt-2;
}

.wd-nowrap { white-space: nowrap; }

.wd-payload-preview {
  max-width: 420px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-family: monospace;
  font-size: 1.15rem;
  color: $white-alt-1;
}

.wd-pre {
  margin: 0;
  max-height: 360px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  font-size: 1.15rem;
}
</style>
