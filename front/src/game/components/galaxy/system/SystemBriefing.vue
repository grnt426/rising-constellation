<template>
  <!-- The system view for screen readers and the keyboard. A short lead
       (who owns it, critical alerts, who is here, what needs doing) is
       read when the view opens from the keyboard; everything else sits in
       four sections a player expands on demand: Agents, Overview,
       Construction, Buildings. Visually hidden until keyboard focus
       enters it, then it shows as a panel, so mouse play never sees it.
       Wording: game/a11y/system-brief.js. -->
  <section
    class="system-briefing"
    :class="{ 'is-mobile': isMobileView }"
    :aria-label="$t('a11y.system.region', { name: system.name })">
    <h2 class="sb-title">{{ system.name }}</h2>
    <p
      ref="lead"
      class="sb-lead"
      tabindex="-1">{{ leadText }}</p>

    <template v-if="rel !== 'unknown'">
      <!-- 1. agents -->
      <h3 class="sb-heading">
        <button
          type="button"
          class="bare-button sb-toggle"
          :aria-expanded="String(open.agents)"
          @click="toggle('agents')">
          {{ $t('a11y.system.section.agents', { n: agentCount }) }}
        </button>
      </h3>
      <p class="sb-summary">{{ agentsSummaryText }}</p>
      <div
        v-if="open.agents"
        class="sb-body">
        <template v-if="selectedCharacter && actions.length">
          <h4>{{ $t('a11y.system.orders_for', { agent: selectedName }) }}</h4>
          <ul>
            <li
              v-for="action in actions"
              :key="`order-${action.name}`">
              <button
                type="button"
                class="sb-action"
                :aria-disabled="action.status === 'available' ? null : 'true'"
                @click="action.status === 'available' && giveSystemOrder(action)">
                {{ $t(`galaxy.system.actions.${action.name}`) }}
              </button>
              <span
                v-if="action.status !== 'available'"
                class="sb-reason">{{ plain(action.reasons) }}</span>
            </li>
          </ul>
        </template>
        <p v-else-if="!selectedCharacter && player.characters.length">
          {{ $t('a11y.system.select_hint') }}
        </p>

        <template v-for="group in GROUP_ORDER">
          <h4
            v-if="groups[group].length"
            :key="`h-${group}`">
            {{ $tc(`a11y.system.agents.group_${group}`, groups[group].length, { n: groups[group].length }) }}
          </h4>
          <ul
            v-if="groups[group].length"
            :key="`l-${group}`">
            <li
              v-for="entry in groups[group]"
              :key="entry.character.id">
              {{ agentText(entry) }}
              <button
                type="button"
                class="sb-action"
                @click="openAgent(entry)">
                {{ entry.roster
                  ? $t('a11y.system.agent.select', { name: entry.character.name })
                  : $t('a11y.system.agent.open', { name: entry.character.name }) }}
              </button>
              <button
                v-for="action in ordersOn(entry)"
                :key="`${entry.character.id}-${action.name}`"
                type="button"
                class="sb-action"
                :aria-disabled="action.status === 'available' ? null : 'true'"
                @click="action.status === 'available' && orderOnCharacter(action, entry.character.id)">
                {{ $t('a11y.orders.give', {
                  order: $t(`galaxy.system.actions.${action.name}`),
                  system: entry.character.name,
                }) }}
                <span
                  v-if="action.status !== 'available'"
                  class="sr-only">: {{ plain(action.reasons) }}</span>
              </button>
            </li>
          </ul>
        </template>

        <button
          v-if="isOwnSystem"
          type="button"
          class="sb-action"
          @click="deployAgent">
          {{ $t('a11y.system.deploy_agent') }}
        </button>
      </div>

      <!-- 2. overview -->
      <h3 class="sb-heading">
        <button
          type="button"
          class="bare-button sb-toggle"
          :aria-expanded="String(open.overview)"
          @click="toggle('overview')">
          {{ $t('a11y.system.section.overview') }}
        </button>
      </h3>
      <p class="sb-summary">{{ overviewText }}</p>
      <div
        v-if="open.overview"
        class="sb-body">
        <ul>
          <li
            v-for="stat in statList"
            :key="stat.key">
            {{ stat.label }}: {{ stat.text == null ? $t('a11y.unknown') : stat.text }}
            <button
              v-if="stat.details.length"
              type="button"
              class="sb-action"
              :aria-expanded="String(!!openStats[stat.key])"
              @click="$set(openStats, stat.key, !openStats[stat.key])">
              {{ $t('a11y.system.breakdown', { stat: stat.label }) }}
            </button>
            <ul v-if="openStats[stat.key]">
              <li
                v-for="(line, i) in stat.details"
                :key="i">{{ line.label }}: {{ line.value }}</li>
            </ul>
          </li>
        </ul>

        <button
          v-if="system.governor"
          type="button"
          class="sb-action"
          @click="openGovernor">
          {{ $t('a11y.system.agent.open', { name: system.governor.name }) }}
        </button>
        <button
          v-else-if="isOwnSystem"
          type="button"
          class="sb-action"
          @click="assignGovernor">
          {{ $t('galaxy.system.properties.deploy_governor') }}
        </button>
      </div>

      <!-- 3. construction queue (own systems) -->
      <template v-if="isOwnSystem && system.queue">
        <h3 class="sb-heading">
          <button
            type="button"
            class="bare-button sb-toggle"
            :aria-expanded="String(open.queue)"
            @click="toggle('queue')">
            {{ $t('a11y.system.section.queue', { n: queueItems.length }) }}
          </button>
        </h3>
        <p class="sb-summary">{{ queueSummary }}</p>
        <div
          v-if="open.queue"
          class="sb-body">
          <ol v-if="queueItems.length">
            <li
              v-for="(item, i) in queueItems"
              :key="item.id">
              {{ item.text }}
              <button
                type="button"
                class="sb-action"
                :aria-disabled="i === 0 ? 'true' : null"
                @click="i > 0 && moveQueued(i, -1)">
                {{ $t('a11y.system.construction.up', { name: item.name }) }}{{ i === 1 && headStarted ? ` (${$t('a11y.system.construction.resets', { name: queueItems[0].name })})` : '' }}
              </button>
              <button
                type="button"
                class="sb-action"
                :aria-disabled="i === queueItems.length - 1 ? 'true' : null"
                @click="i < queueItems.length - 1 && moveQueued(i, 1)">
                {{ $t('a11y.system.construction.down', { name: item.name }) }}{{ i === 0 && headStarted ? ` (${$t('a11y.system.construction.resets', { name: item.name })})` : '' }}
              </button>
              <button
                type="button"
                class="sb-action"
                @click="cancelQueued(item)">
                {{ $t('a11y.system.construction.cancel', { name: item.name }) }}
              </button>
            </li>
          </ol>
        </div>
      </template>

      <!-- 4. buildings: planets, then moons and asteroids -->
      <h3 class="sb-heading">
        <button
          type="button"
          class="bare-button sb-toggle"
          :aria-expanded="String(open.buildings)"
          @click="toggle('buildings')">
          {{ $t('a11y.system.section.buildings') }}
        </button>
      </h3>
      <p class="sb-summary">{{ buildingsSummaryText }}</p>
      <ul
        v-if="open.buildings"
        class="sb-body">
        <li
          v-for="body in bodyList"
          :key="body.uid">
          <button
            type="button"
            class="bare-button sb-toggle is-body"
            :aria-expanded="String(!!openBodies[body.uid])"
            @click="$set(openBodies, body.uid, !openBodies[body.uid])">
            {{ bodyText(body) }}
          </button>
          <ul v-if="openBodies[body.uid]">
            <li
              v-for="(tile, i) in body.tiles"
              :key="tile.id">
              {{ tileText(tile, i) }}<template v-if="isOwnSystem && lockReason(body, tile)">. {{ lockReason(body, tile) }}</template>

              <button
                v-if="canInspect(tile)"
                type="button"
                class="sb-action"
                :aria-expanded="String(isOpenTile(body, tile, 'details'))"
                @click="toggleTile(body, tile, 'details')">
                {{ $t('a11y.system.tile.details') }}
              </button>
              <template v-if="isOwnSystem">
                <button
                  v-if="canBuild(body, tile)"
                  type="button"
                  class="sb-action"
                  :aria-expanded="String(isOpenTile(body, tile, 'build'))"
                  @click="toggleTile(body, tile, 'build')">
                  {{ $t('a11y.system.tile.build_here') }}
                </button>
                <button
                  v-if="tileActions(body, tile).includes('upgrade')"
                  type="button"
                  class="sb-action"
                  @click="orderTile(body, tile, 'build')">
                  {{ upgradeLabel(tile) }}
                </button>
                <button
                  v-if="tileActions(body, tile).includes('repair')"
                  type="button"
                  class="sb-action"
                  @click="orderTile(body, tile, 'repair')">
                  {{ $t('card.building.repair') }}
                </button>
                <button
                  v-if="tileActions(body, tile).includes('delete')"
                  type="button"
                  class="sb-action is-danger"
                  @click="destroyTile(body, tile)">
                  {{ armedDelete === tileRef(body, tile)
                    ? $t('a11y.system.tile.confirm_destroy', { name: buildingName(tile.building_key) })
                    : $t('a11y.system.tile.destroy', { name: buildingName(tile.building_key) }) }}
                </button>
              </template>

              <p v-if="isOpenTile(body, tile, 'details')">
                {{ tileDetails(body, tile) }}
              </p>

              <ul v-if="isOpenTile(body, tile, 'build')">
                <li
                  v-for="option in buildOptions(body, tile)"
                  :key="option.data.key">
                  {{ optionText(option, body) }}
                  <button
                    v-if="option.status === 'buildable'"
                    type="button"
                    class="sb-action"
                    @click="build(body, tile, option)">
                    {{ $t('a11y.system.tile.build', { name: buildingName(option.data.key) }) }}
                  </button>
                </li>
              </ul>
            </li>
          </ul>
        </li>
      </ul>
    </template>
  </section>
</template>

<script>
import viewport from '@/utils/viewport';
import { formatDuration } from '@/utils/format';
import { lastInputWasKeyboard, lastInputWasShortcut } from '@/plugins/a11y';
import buildingValidation from '@/utils/buildingValidation';
import { buildingOptions } from '@/game/production-options';
import { agentTypeName } from '@/game/a11y/describe';
import * as brief from '@/game/a11y/system-brief';
import SystemOrdersMixin from '@/game/mixins/SystemOrdersMixin';

const GROUP_ORDER = ['enemy', 'own', 'faction'];

// Which sections are expanded, kept while the page lives: a player who
// opens Buildings on one system wants it open on the next.
const remembered = {
  agents: false, overview: false, queue: false, buildings: false,
};

export default {
  name: 'system-briefing',
  mixins: [SystemOrdersMixin],
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
  },
  data() {
    return {
      open: { ...remembered },
      openStats: {},
      openBodies: {},
      // `${bodyUid}:${tileId}:details|build` → true
      openTiles: {},
      armedDelete: null,
      announcedAlerts: [],
      GROUP_ORDER,
    };
  },
  computed: {
    isMobileView() { return viewport.isMobile; },
    rel() { return brief.relation(this.system, this.player); },
    heading() { return brief.title(this, this.system, this.rel); },
    groups() { return brief.agentGroups(this, this.system); },
    agentCount() { return (this.system.characters || []).length; },
    alerts() {
      return brief.criticalAlerts(this, this.system, this.rel, this.groups, (ticks) => this.duration(ticks));
    },
    attentionItems() { return brief.attention(this, this.system, this.rel); },
    leadText() {
      return brief.lead(this, {
        heading: this.heading,
        alerts: this.alerts,
        attentionItems: this.attentionItems,
        groups: this.groups,
        rel: this.rel,
      });
    },
    agentsSummaryText() { return brief.agentsSummary(this, this.groups); },
    statList() { return brief.stats(this, this.system); },
    overviewText() { return brief.overviewSummary(this, this.system, this.rel, this.statList); },
    bodyList() { return brief.bodies(this.system); },
    buildingsSummaryText() { return brief.buildingsSummary(this, this.system); },
    selectedName() {
      return this.selectedCharacter
        ? `${agentTypeName(this, this.selectedCharacter.type)} ${this.selectedCharacter.name}`
        : '';
    },
    ordersByCharacter() {
      return new Map(this.systemCharacters.map((entry) => [entry.character.id, entry.actions]));
    },
    tickToSecond() { return this.$store.getters['game/tickToSecondFactor']; },
    queueItems() {
      const queue = (this.system.queue && this.system.queue.queue) || [];
      const rate = this.system.production && this.system.production.value;
      let ticks = 0;
      return queue.map((item) => {
        ticks += item.remaining_prod;
        const name = this.productionName(item);
        const where = this.productionWhere(item);
        const eta = rate ? this.duration(ticks / rate) : this.$t('a11y.unknown');
        return {
          id: item.id,
          name,
          text: this.$t('a11y.system.construction.item', { name, where, eta }),
        };
      });
    },
    queueSummary() {
      if (!this.queueItems.length) return this.$t('a11y.system.attention.queue_empty');
      return this.$tc('a11y.system.construction.summary', this.queueItems.length, {
        n: this.queueItems.length,
        first: this.queueItems[0].text,
      });
    },
    // The head is always being built while the system produces; moving
    // it loses its progress (same warning as the drag reorder).
    headStarted() {
      const head = this.system.queue && this.system.queue.queue[0];
      return !!head && (head.remaining_prod < head.total_prod
        || (this.system.production && this.system.production.value > 0));
    },
  },
  watch: {
    // A system opened from the keyboard (or a screen reader's activate
    // command) reads its lead; a mouse open leaves focus alone. So does
    // a standard-set hotkey (next system): mouse players use it, so the
    // panel stays shut and the lead is only spoken, unless the player is
    // already in the briefing.
    'system.id': {
      immediate: true,
      handler() {
        this.openTiles = {};
        this.armedDelete = null;
        this.announcedAlerts = this.alerts.map((a) => a.key);
        const inside = !!this.$el && this.$el.contains(document.activeElement);
        if (lastInputWasKeyboard() || inside) {
          this.$nextTick(this.focusLead);
        } else if (lastInputWasShortcut()) {
          this.$announce(this.leadText);
        }
      },
    },
    // A critical alert that appears while the view is open is spoken
    // right away (a siege starting on your system can't wait).
    alerts(list) {
      list.filter((a) => !this.announcedAlerts.includes(a.key))
        .forEach((a) => this.$announce(a.text, { assertive: true }));
      this.announcedAlerts = list.map((a) => a.key);
    },
  },
  methods: {
    plain: brief.plain,
    toggle(section) {
      this.open[section] = !this.open[section];
      remembered[section] = this.open[section];
    },
    duration(ticks) {
      return formatDuration(ticks * this.tickToSecond, (key, params) => this.$t(key, params));
    },
    agentText(entry) {
      const line = brief.agentLine(this, entry, this.system);
      return this.selectedCharacter && this.selectedCharacter.id === entry.character.id
        ? `${line}, ${this.$t('a11y.system.agent.selected')}`
        : line;
    },
    // B (Game.vue): back to the briefing from anywhere while the system
    // is open, e.g. after opening an agent's card from it.
    focusLead() {
      if (this.$refs.lead) this.$refs.lead.focus({ preventScroll: true });
    },
    ordersOn(entry) { return this.ordersByCharacter.get(entry.character.id) || []; },
    bodyText(body) { return brief.bodySummary(this, body); },
    tileText(tile, index) { return brief.tileLine(this, tile, index); },
    buildingName(key) { return this.$t(`data.building.${key}.name`); },
    buildingData(key) { return this.$store.state.game.data.building.find((b) => b.key === key); },

    // ---- agents ----
    giveSystemOrder(action) {
      this.orderOnSystem(action.icon);
      this.$announce(this.$t('a11y.orders.sent', {
        order: this.$t(`galaxy.system.actions.${action.name}`),
        system: this.system.name,
      }));
    },
    openAgent(entry) {
      if (entry.roster) {
        this.$store.dispatch('game/selectCharacter', { vm: this, id: entry.character.id });
      } else {
        this.$store.dispatch('game/openCharacter', { vm: this, id: entry.character.id });
      }
    },
    openGovernor() {
      this.$store.dispatch('game/openCharacter', { vm: this, id: this.system.governor.id });
    },
    deployAgent() {
      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', { systemId: this.system.id, mode: 'on_board' });
    },
    assignGovernor() {
      this.$root.$emit('openBottomMiniPanel', 'character-deck');
      this.$store.commit('game/prepareAssignment', { systemId: this.system.id, mode: 'governor' });
    },

    // ---- construction queue ----
    productionName(item) {
      if (item.type === 'ship') return this.$t(`data.ship.${item.prod_key}.name`);
      const name = this.buildingName(item.prod_key);
      if (item.type === 'building_repairs') return this.$t('a11y.system.construction.repair', { name });
      return this.$t('a11y.system.tile.building_level', { name, level: item.prod_level });
    },
    productionWhere(item) {
      if (item.type === 'ship') {
        // target_id is a string server-side (it is a body uid for buildings)
        const navarch = (this.system.characters || []).find((c) => String(c.id) === String(item.target_id));
        return navarch ? navarch.name : '';
      }
      const body = this.bodyList.find((b) => b.uid === item.target_id);
      return body ? body.name : '';
    },
    moveQueued(index, delta) {
      const ids = this.system.queue.queue.map((item) => item.id);
      const [id] = ids.splice(index, 1);
      ids.splice(index + delta, 0, id);
      this.$socket.player.push('reorder_production', {
        system_id: this.system.id,
        production_ids: ids,
      }).receive('ok', () => {
        this.$announce(this.$t('a11y.system.construction.moved', {
          name: this.queueItems.find((q) => q.id === id).name,
          n: index + delta + 1,
        }));
      }).receive('error', (data) => this.$toastError(data.reason));
    },
    cancelQueued(item) {
      this.$socket.player.push('cancel_production', {
        system_id: this.system.id,
        production_id: item.id,
      }).receive('ok', () => {
        this.$announce(this.$t('a11y.system.construction.cancelled', { name: item.name }));
      }).receive('error', (data) => this.$toastError(data.reason));
    },

    // ---- buildings ----
    tileRef(body, tile) { return `${body.uid}:${tile.id}`; },
    isOpenTile(body, tile, kind) { return !!this.openTiles[`${this.tileRef(body, tile)}:${kind}`]; },
    toggleTile(body, tile, kind) {
      const key = `${this.tileRef(body, tile)}:${kind}`;
      this.$set(this.openTiles, key, !this.openTiles[key]);
    },
    canInspect(tile) {
      return !!tile.building_key && tile.building_key !== 'hidden'
        && ['built', 'damaged'].includes(tile.building_status);
    },
    canBuild(body, tile) {
      if (tile.building_status !== 'empty' || tile.building_key) return false;
      const data = {
        playerPatents: this.player.patents,
        bodiesData: this.$store.state.game.data.stellar_body,
        buildingsData: this.$store.state.game.data.building,
      };
      return buildingValidation.isBuildable(tile, body, data);
    },
    // Why an empty slot of your own can't take a building yet: the same
    // rules as buildingValidation.isBuildable, put into words.
    lockReason(body, tile) {
      if (tile.building_status !== 'empty' || tile.building_key || this.canBuild(body, tile)) return '';
      const { data } = this.$store.state.game;
      const bodyData = data.stellar_body.find((b) => b.key === body.type);
      if (!bodyData) return '';
      if (bodyData.biome === 'orbital') {
        return this.$t('a11y.system.tile.locked_orbital', { class: this.$t('data.patent_class.orbital.name') });
      }
      if (tile.id === 1) {
        const infra = data.building.find((b) => b.biome === bodyData.biome && b.type === 'infrastructure');
        const patent = infra && infra.levels[0].patent;
        return patent
          ? this.$t('a11y.system.tile.locked_patent', { patent: this.$t(`data.patent.${patent}.name`) })
          : '';
      }
      return this.$t('a11y.system.tile.locked_infrastructure');
    },
    // Same rules as the tile grid's corner buttons (BodiesItem).
    tileActions(body, tile) {
      const actions = [];
      if (!this.canInspect(tile)) return actions;
      const data = this.buildingData(tile.building_key);
      if (tile.building_status === 'damaged' && tile.construction_status === 'none') actions.push('repair');
      if (data) {
        if (buildingValidation.upgradeBuildingStatus(tile, body, this.player.patents, data)) actions.push('upgrade');
        if (data.type !== 'infrastructure' && tile.construction_status === 'none') actions.push('delete');
      }
      return actions;
    },
    levelData(key, level) {
      const data = this.buildingData(key);
      return data ? data.levels.find((l) => l.level === level) : null;
    },
    costText(levelData) {
      return this.$t('a11y.system.cost', {
        production: this.$options.filters.integer(levelData.production),
        credit: this.$options.filters.integer(levelData.credit),
      });
    },
    upgradeLabel(tile) {
      const next = this.levelData(tile.building_key, tile.building_level + 1);
      return this.$t('a11y.system.tile.upgrade', {
        name: this.buildingName(tile.building_key),
        level: tile.building_level + 1,
        cost: next ? this.costText(next) : '',
      });
    },
    tileDetails(body, tile) {
      const parts = [];
      const level = tile.building_level === 'hidden' ? null : tile.building_level;
      const current = level ? this.levelData(tile.building_key, level) : null;
      const data = this.buildingData(tile.building_key);
      if (current) {
        parts.push(this.$t('a11y.system.effect.level', {
          level,
          effects: brief.bonusText(this, current.bonus, body, this.system) || this.$t('a11y.system.effect.none'),
        }));
      }
      if (data && data.workforce) parts.push(this.$t('a11y.system.effect.workforce', { n: data.workforce }));
      const adds = this.system.contact.value === 5 ? brief.contribution(this, this.system, tile.building_key) : '';
      if (adds) parts.push(this.$t('a11y.system.effect.contribution', { adds }));
      return parts.map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('. ').concat('.');
    },
    buildOptions(body, tile) {
      return buildingOptions(this.$store.state.game, this.system, body, tile);
    },
    optionText(option, body) {
      const name = this.buildingName(option.data.key);
      if (option.status !== 'buildable') {
        return this.$t('a11y.system.option.unavailable', { name, reason: option.message });
      }
      const first = option.data.levels[0];
      const needs = [this.costText(first)];
      if (option.data.workforce) needs.push(this.$t('a11y.system.effect.workforce', { n: option.data.workforce }));
      const parts = [`${name}: ${needs.join(', ')}`];
      const effects = brief.bonusText(this, first.bonus, body, this.system);
      if (effects) parts.push(this.$t('a11y.system.option.effects', { effects }));
      const credit = this.player.credit && this.player.credit.value;
      if (typeof credit === 'number' && credit < first.credit) parts.push(this.$t('a11y.system.option.short_credit'));
      return parts.join('. ').concat('.');
    },
    build(body, tile, option) {
      this.$ambiance.sound('order-building');
      this.$socket.player.push('order_building', {
        system_id: this.system.id,
        production_data: {
          type: 'build',
          target_id: body.uid,
          tile_id: tile.id,
          prod_key: option.data.key,
          prod_level: 1,
        },
      }).receive('ok', () => {
        this.toggleTile(body, tile, 'build');
        this.$announce(this.$t('a11y.system.queued', {
          name: this.buildingName(option.data.key),
          where: body.name,
        }));
      }).receive('error', (data) => this.$toastError(data.reason));
    },
    orderTile(body, tile, type) {
      const level = type === 'build' ? tile.building_level + 1 : tile.building_level;
      this.$ambiance.sound('order-building');
      this.$socket.player.push('order_building', {
        system_id: this.system.id,
        production_data: {
          type,
          target_id: body.uid,
          tile_id: tile.id,
          prod_key: tile.building_key,
          prod_level: level,
        },
      }).receive('ok', () => {
        this.$announce(this.$t('a11y.system.queued', {
          name: type === 'repair'
            ? this.$t('a11y.system.construction.repair', { name: this.buildingName(tile.building_key) })
            : this.$t('a11y.system.tile.building_level', { name: this.buildingName(tile.building_key), level }),
          where: body.name,
        }));
      }).receive('error', (data) => this.$toastError(data.reason));
    },
    // Destroying is instant and permanent: the first press arms the
    // button (and says so), a second press within five seconds destroys.
    destroyTile(body, tile) {
      const ref = this.tileRef(body, tile);
      if (this.armedDelete !== ref) {
        this.armedDelete = ref;
        clearTimeout(this.armTimer);
        this.armTimer = setTimeout(() => { this.armedDelete = null; }, 5000);
        this.$announce(this.$t('a11y.system.tile.armed', { name: this.buildingName(tile.building_key) }));
        return;
      }
      this.armedDelete = null;
      clearTimeout(this.armTimer);
      this.$socket.player.push('remove_building', {
        system_id: this.system.id,
        production_data: { target_id: body.uid, tile_id: tile.id },
      }).receive('ok', () => {
        this.$announce(this.$t('a11y.system.tile.destroyed', { name: this.buildingName(tile.building_key) }));
      }).receive('error', (data) => this.$toastError(data.reason));
    },
  },
  mounted() {
    this.$root.$on('focusSystemBriefing', this.focusLead);
  },
  beforeDestroy() {
    clearTimeout(this.armTimer);
    this.$root.$off('focusSystemBriefing', this.focusLead);
  },
};
</script>

<style lang="scss" scoped>
// Out of sight (but read by screen readers) until keyboard focus is
// inside; then a panel over the left of the system view.
.system-briefing:not(:focus-within) {
  position: absolute !important;
  width: 1px !important;
  height: 1px !important;
  padding: 0 !important;
  margin: -1px !important;
  overflow: hidden !important;
  clip: rect(0, 0, 0, 0) !important;
  white-space: nowrap !important;
  border: 0 !important;
}

.system-briefing:focus-within {
  position: fixed;
  top: 54px;
  bottom: 54px;
  left: 0;
  // over the chat (330) and notification center (340), under the
  // mini panels (400) the agent deck opens in
  z-index: 345;
  width: 440px;
  max-width: 100vw;
  padding: 12px 16px;
  overflow-y: auto;
  color: #f1f3f6;
  background: rgba(8, 12, 22, 0.97);
  border-right: 1px solid rgba(255, 255, 255, 0.2);
  box-shadow: 0 0 20px rgba(0, 0, 0, 0.6);

  &.is-mobile {
    width: 100vw;
  }
}

.sb-title {
  margin: 0 0 4px;
  font-size: 1.6em;
  text-transform: uppercase;
}

.sb-lead {
  margin: 0 0 12px;
  line-height: 1.4;
}

.sb-heading {
  margin: 14px 0 2px;
  font-size: 1.2em;
}

.sb-toggle {
  cursor: pointer;
  text-align: left;

  &::before {
    content: '▸ ';
  }

  &[aria-expanded="true"]::before {
    content: '▾ ';
  }

  &.is-body {
    display: block;
    margin: 4px 0;
  }
}

.sb-summary {
  margin: 0;
  opacity: 0.85;
}

.sb-body {
  margin: 6px 0 0;
  padding-left: 18px;

  ul,
  ol {
    padding-left: 18px;
  }

  li {
    margin: 4px 0;
    line-height: 1.4;
  }

  h4 {
    margin: 10px 0 2px;
    font-size: 1em;
    text-transform: uppercase;
    opacity: 0.85;
  }
}

.sb-action {
  margin: 2px 4px 2px 0;
  padding: 2px 8px;
  font: inherit;
  font-size: 0.9em;
  color: inherit;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.3);
  cursor: pointer;

  &[aria-disabled="true"] {
    opacity: 0.55;
    cursor: default;
  }

  &.is-danger {
    border-color: #e85a5a;
  }
}

.sb-reason {
  display: block;
  font-size: 0.85em;
  opacity: 0.8;
}
</style>
