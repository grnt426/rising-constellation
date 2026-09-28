<template>
  <!-- Desktop view of an agent's orders as STOPS (see game/plan/stops.js):
       one row per system the player chose, with the actions to perform
       there; the jumps in between are shown as "via", not as orders.
       Stops can be removed, reordered by dragging, and single actions
       cancelled — the rest of the plan is re-routed. Hovering a row
       pulses its destination on the map. Phones keep ActionQueue. -->
  <div
    class="selection-actions agent-plan"
    :class="{ 'is-pending': pending }">
    <div class="header">
      {{ $t('galaxy.selection.view.actions') }}
      <span
        v-if="canEdit && plan.stops.length > 1"
        class="agent-plan-hint">
        {{ $t('galaxy.selection.plan.drag_hint') }}
      </span>
    </div>

    <span
      v-if="character.on_sold"
      class="action-toast">
      {{ $t('galaxy.selection.view.on_sold') }}
    </span>
    <span
      v-else-if="character.on_strike"
      class="action-toast">
      {{ $t('galaxy.selection.view.on_strike') }}
    </span>

    <template v-else>
      <div
        v-if="!plan.head"
        class="agent-plan-empty">
        {{ $t('galaxy.selection.plan.empty') }}
      </div>

      <v-scrollbar
        v-else
        class="agent-plan-rows"
        :settings="scrollbarSettings">
        <!-- the running action: never edited -->
        <div
          class="agent-plan-row is-head"
          data-plan-row="head"
          :data-system-id="headTarget"
          @mouseenter="pulse(headTarget)"
          @mouseleave="unpulse">
          <span class="agent-plan-icon">
            <circle-progress-value
              v-if="plan.head.remaining_time !== 'unknown_yet'"
              :current="plan.head.total_time - liveRemaining(plan.head)"
              :total="plan.head.total_time"
              :increase="1"
              :size="20"
              :width="3"
              :theme="theme" />
            <svgicon :name="`action/${plan.head.type}`" />
          </span>
          <span class="agent-plan-name">{{ systemName(headTarget) }}</span>
          <span class="agent-plan-via">{{ $t('galaxy.selection.plan.current') }}</span>
          <!-- "stop here": drop every order after the running one -->
          <svgicon
            v-if="canEdit && rows.length"
            name="close"
            class="agent-plan-remove agent-plan-stop-here"
            v-tooltip="$t('galaxy.selection.plan.stop_here', { system: systemName(headTarget) })"
            @mouseenter.native="doomedKey = '*'"
            @mouseleave.native="doomedKey = null"
            @click.native.stop="stopHere" />
        </div>

        <div
          v-for="(row, i) in rows"
          :key="row.stop.key"
          class="agent-plan-row"
          :class="{
            'is-doomed': doomedKey === row.stop.key || doomedKey === '*',
            'is-dragged': dragKey === row.stop.key,
            'drop-before': dropIndex === i && row.movable,
            'drop-after': dropIndex === i + 1 && i === rows.length - 1,
            'is-movable': canEdit && row.movable,
          }"
          :data-plan-row="row.movable ? 'stop' : 'head-stop'"
          :data-stop-key="row.stop.key"
          :data-system-id="row.stop.target"
          :draggable="canEdit && row.movable"
          @dragstart="onDragStart($event, row)"
          @dragenter="onDragOver($event, i)"
          @dragover="onDragOver($event, i)"
          @drop="onDrop"
          @dragend="onDragEnd"
          @mouseenter="pulse(row.stop.target)"
          @mouseleave="unpulse">
          <span class="agent-plan-number">{{ i + 1 }}</span>
          <span class="agent-plan-name">{{ systemName(row.stop.target) }}</span>
          <span
            v-if="row.stop.via.length"
            class="agent-plan-via"
            v-tooltip="viaNames(row.stop.via)">
            {{ $tc('galaxy.selection.plan.via', row.stop.via.length, { n: row.stop.via.length }) }}
          </span>
          <span
            v-if="row.stop.gateway"
            class="agent-plan-via">
            {{ $t('galaxy.selection.plan.gateway') }}
          </span>
          <span class="agent-plan-actions">
            <span
              v-for="action in row.stop.actions"
              :key="action.uid || action.index"
              class="agent-plan-action"
              :data-action-type="action.type"
              v-tooltip="actionLabel(action.type)">
              <svgicon :name="`action/${action.type}`" />
              <svgicon
                v-if="canEdit && action.uid != null"
                name="close"
                class="agent-plan-cancel-action"
                @click.native.stop="cancelAction(row.stop, action)" />
            </span>
          </span>
          <svgicon
            v-if="canEdit"
            name="close"
            class="agent-plan-remove"
            v-tooltip="$t('galaxy.selection.plan.remove_stop')"
            @mouseenter.native="doomedKey = row.stop.key"
            @mouseleave.native="doomedKey = null"
            @click.native.stop="removeStop(row.stop)" />
        </div>
      </v-scrollbar>
    </template>
  </div>
</template>

<script>
import makeRouter from '@/game/plan/route';
import {
  editablePlan, removeStop, removeAction, moveStop, editPayload, summarize, PlanError,
} from '@/game/plan/stops';
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

export default {
  name: 'agent-plan',
  props: {
    character: { type: Object, required: true },
    theme: { type: String, default: 'none' },
  },
  data() {
    return {
      scrollbarSettings: VERTICAL_SCROLL_SETTINGS,
      doomedKey: null,
      dragKey: null,
      dropIndex: null,
      pending: false,
    };
  },
  computed: {
    speedFactor() { return this.$store.getters['game/effectiveSpeedFactor']; },
    queue() { return (this.character.actions && this.character.actions.queue) || []; },
    origin() {
      const first = this.queue[0];
      if (this.character.system != null) return this.character.system;
      if (first && first.data && first.data.source != null) return first.data.source;
      return this.character.actions.virtual_position;
    },
    plan() { return editablePlan(this.queue, this.origin); },
    // Editing needs the running head's uid (queues restored from before
    // uids existed are shown read-only until their head is done).
    canEdit() { return !!this.plan.head && this.plan.head.uid != null && !this.pending; },
    headTarget() {
      const { head } = this.plan;
      return head && head.data ? head.data.target : null;
    },
    rows() {
      const rows = this.plan.stops.map((stop) => ({ stop, movable: true }));
      return this.plan.headStop ? [{ stop: this.plan.headStop, movable: false }, ...rows] : rows;
    },
    systemsById() {
      return new Map(((this.$store.state.game.galaxy || {}).stellar_systems || []).map((s) => [s.id, s]));
    },
  },
  watch: {
    // any fresh copy of the queue ends a pending edit
    queue() { this.pending = false; },
  },
  methods: {
    systemName(id) {
      const system = this.systemsById.get(id);
      return system ? system.name : '░░░';
    },
    viaNames(ids) { return ids.map((id) => this.systemName(id)).join(' → '); },
    actionLabel(type) { return this.$t(`galaxy.selection.plan.action.${type}`); },
    liveRemaining(action) {
      if (typeof action.remaining_time !== 'number' || typeof action.total_time !== 'number') return action.remaining_time;
      const { time } = this.$store.state.game;
      if (action.started_at == null || time.now_monotonic == null || time.receivedAt == null) return action.remaining_time;
      const serverNow = time.now_monotonic + (Date.now() - time.receivedAt);
      return Math.max(0, action.total_time - ((serverNow - action.started_at) * this.speedFactor) / 180000);
    },
    pulse(systemId) {
      if (systemId != null) this.$root.$emit('map:pulseSystem', systemId);
    },
    unpulse() { this.$root.$emit('map:unpulseSystem'); },

    // ---- edits ----------------------------------------------------------
    // The editable stops are rows minus the head's own stop (pinned first).
    movableOffset() { return this.plan.headStop ? 1 : 0; },
    removeStop(stop) { this.submit(removeStop(this.plan, stop.key)); },
    cancelAction(stop, action) { this.submit(removeAction(this.plan, stop.key, action.uid)); },
    stopHere() {
      this.submit({ ...this.plan, headStop: null, stops: [] }, { stopAt: this.headTarget });
    },
    submit(next, opts = {}) {
      if (!this.canEdit) return;
      const router = makeRouter(this.$store.state.game.galaxy);
      let payload;
      let summary;
      try {
        payload = editPayload(this.character.id, next, router);
        summary = summarize(this.plan, next, router);
      } catch (e) {
        if (e instanceof PlanError) {
          this.$toastError(e.reason);
          return;
        }
        throw e;
      }

      this.pending = true;
      this.doomedKey = null;
      this.$socket.player.push('edit_character_actions', payload)
        .receive('ok', () => this.notify(summary, opts))
        .receive('error', (data) => {
          this.pending = false;
          this.$toastError(data.reason);
        })
        .receive('timeout', () => { this.pending = false; });
    },
    notify(summary, opts = {}) {
      const name = (id) => this.systemName(id);
      if (opts.stopAt != null) {
        this.$store.commit('game/setNotifications', [{
          type: 'box',
          key: 'plan_change',
          system_id: opts.stopAt,
          data: {
            agent: this.character.name,
            character_id: this.character.id,
            lines: [{ key: 'cleared', data: { agent: this.character.name, system: name(opts.stopAt), n: summary.removedStops.length } }],
          },
        }]);
        return;
      }
      const lines = [];
      summary.removedStops.forEach((s) => lines.push(s.actions.length
        ? { key: 'removed_stop_actions', data: { system: name(s.target), actions: s.actions.map((t) => this.actionLabel(t)).join(', ') } }
        : { key: 'removed_stop', data: { system: name(s.target) } }));
      summary.removedActions.forEach((a) => lines.push({
        key: 'removed_action', data: { action: this.actionLabel(a.type), system: name(a.target) },
      }));
      summary.passThrough.forEach((p) => lines.push({
        key: 'pass_through', data: { system: name(p.target), next: name(p.on_way_to), agent: this.character.name },
      }));
      summary.rerouted.forEach((r) => lines.push(r.via.length
        ? { key: 'rerouted', data: { system: name(r.target), n: r.jumps, via: r.via.map(name).join(', ') } }
        : { key: 'rerouted_direct', data: { system: name(r.target) } }));
      if (summary.moved) lines.push({ key: 'moved', data: {} });

      const focus = summary.passThrough[0] || summary.rerouted[0] || summary.removedStops[0];
      this.$store.commit('game/setNotifications', [{
        type: 'box',
        key: 'plan_change',
        system_id: focus ? (focus.on_way_to || focus.target) : null,
        data: { agent: this.character.name, character_id: this.character.id, lines },
      }]);
    },

    // ---- drag to reorder (desktop) --------------------------------------
    onDragStart(event, row) {
      if (!this.canEdit || !row.movable) {
        event.preventDefault();
        return;
      }
      this.dragKey = row.stop.key;
      this.dropIndex = null;
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', row.stop.key);
    },
    onDragOver(event, i) {
      if (this.dragKey === null) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      const rect = event.currentTarget.getBoundingClientRect();
      const after = event.clientY > rect.top + (rect.height / 2);
      // never above the pinned head stop
      this.dropIndex = Math.max(this.movableOffset(), after ? i + 1 : i);
    },
    onDrop(event) {
      if (this.dragKey === null) return;
      event.preventDefault();
      const key = this.dragKey;
      const offset = this.movableOffset();
      const from = this.plan.stops.findIndex((s) => s.key === key);
      let to = this.dropIndex - offset;
      this.onDragEnd();
      if (from === -1 || to == null || Number.isNaN(to)) return;
      if (to > from) to -= 1;
      if (to === from) return;
      this.submit(moveStop(this.plan, key, to));
    },
    onDragEnd() {
      this.dragKey = null;
      this.dropIndex = null;
    },
  },
  beforeDestroy() {
    this.unpulse();
  },
  components: { CircleProgressValue },
};
</script>
