<template>
  <!-- An agent's orders as STOPS (see game/plan/stops.js): one row per
       system the player chose, with the actions to perform there; the
       jumps in between are shown as "via", not as orders. Stops can be
       removed and reordered, single actions cancelled — the rest of the
       plan is re-routed — and "clear all" drops every queued order.

       Desktop (the selection panel): a × per stop and per action, drag
       to reorder; with shift held, a × also takes everything after it.
       Hovering a × marks what it would remove; hovering a row pulses its
       destination on the map.

       Phones (`compact`, beside the agent's card): no hover and no drag,
       so a tap selects a stop and the bar under the title moves or
       removes it. What a single tap could destroy by landing a few
       pixels off asks for a second one: an action of the selected stop
       (first tap marks it, second cancels it) and "clear all". -->
  <div
    class="selection-actions agent-plan"
    :class="{ 'is-pending': pending, 'is-compact': compact }">
    <div class="header">
      {{ $t('galaxy.selection.view.actions') }}
      <span
        v-if="!compact && canEdit && plan.stops.length > 1"
        class="agent-plan-hint">
        {{ $t('galaxy.selection.plan.drag_hint') }}
      </span>
      <span class="agent-plan-spacer" />
      <!-- every queued order at once (the running one is never edited) -->
      <span
        v-if="canClear"
        class="agent-plan-clear"
        :class="{ 'is-armed': clearArmed }"
        data-plan-clear
        v-tooltip="compact ? null : $t('galaxy.selection.plan.clear_all_hint', { system: systemName(headTarget) })"
        @mouseenter="!compact && hover({ all: true }, $event)"
        @mouseleave="!compact && unhover()"
        @click="clearAll">
        {{ $t(`galaxy.selection.plan.${clearArmed ? 'clear_all_confirm' : 'clear_all'}`) }}
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

      <template v-else>
        <!-- phones: what a tap on a stop offers. Always there (a hint
             until a stop is selected) so the rows below never jump. -->
        <div
          v-if="compact && canEdit && rows.length"
          class="agent-plan-toolbar"
          data-plan-toolbar>
          <template v-if="selectedRow">
            <span class="agent-plan-toolbar-name">{{ systemName(selectedRow.stop.target) }}</span>
            <span class="agent-plan-spacer" />
            <button
              class="agent-plan-tool"
              data-plan-tool="up"
              :disabled="!canMoveSelected(-1)"
              @click="moveSelected(-1)">
              <svgicon name="caret-up" />
            </button>
            <button
              class="agent-plan-tool"
              data-plan-tool="down"
              :disabled="!canMoveSelected(1)"
              @click="moveSelected(1)">
              <svgicon name="caret-down" />
            </button>
            <button
              class="agent-plan-tool is-remove"
              data-plan-tool="remove"
              @click="removeSelected">
              <svgicon name="close" />
            </button>
          </template>
          <span
            v-else
            class="agent-plan-hint">
            {{ $t('galaxy.selection.plan.tap_hint') }}
          </span>
        </div>

        <!-- phones scroll natively: perfect-scrollbar swallows touch
             drags it cannot use, and would pin the sheet around it -->
        <component
          :is="compact ? 'div' : 'v-scrollbar'"
          class="agent-plan-rows"
          v-bind="compact ? {} : { settings: scrollbarSettings }">
          <!-- the running action: never edited -->
          <div
            class="agent-plan-row is-head"
            data-plan-row="head"
            :data-system-id="headTarget"
            @mouseenter="!compact && pulse(headTarget)"
            @mouseleave="!compact && unpulse()">
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
            <span class="agent-plan-spacer" />
            <span
              class="agent-plan-eta"
              data-plan-eta
              v-tooltip="etas.head.tooltip">
              {{ etas.head.label }}
            </span>
            <!-- "stop here": drop every order after the running one -->
            <svgicon
              v-if="!compact && canEdit && rows.length"
              name="close"
              class="agent-plan-remove agent-plan-stop-here"
              v-tooltip="$t('galaxy.selection.plan.stop_here', { system: systemName(headTarget) })"
              @mouseenter.native="hover({ all: true }, $event)"
              @mouseleave.native="unhover"
              @click.native.stop="stopHere" />
          </div>

          <div
            v-for="(row, i) in rows"
            :key="row.stop.key"
            class="agent-plan-row"
            :class="{
              'is-doomed': doomed.stops.has(row.stop.key),
              'is-dragged': dragKey === row.stop.key,
              'is-selected': selectedKey === row.stop.key,
              'drop-before': dropIndex === i && row.movable,
              'drop-after': dropIndex === i + 1 && i === rows.length - 1,
              'is-movable': !compact && canEdit && row.movable,
            }"
            :data-plan-row="row.movable ? 'stop' : 'head-stop'"
            :data-stop-key="row.stop.key"
            :data-system-id="row.stop.target"
            :draggable="!compact && canEdit && row.movable"
            @dragstart="onDragStart($event, row)"
            @dragenter="onDragOver($event, i)"
            @dragover="onDragOver($event, i)"
            @drop="onDrop"
            @dragend="onDragEnd"
            @mouseenter="!compact && pulse(row.stop.target)"
            @mouseleave="!compact && unpulse()"
            @click="compact && select(row)">
            <span class="agent-plan-number">{{ i + 1 }}</span>
            <span class="agent-plan-name">{{ systemName(row.stop.target) }}</span>
            <!-- how it gets there and what it does there: part of the
                 row on desktop, a second line under the name on phones -->
            <span
              class="agent-plan-detail"
              :class="{ 'is-empty': !row.stop.via.length && !row.stop.gateway && !row.stop.actions.length }">
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
              <span class="agent-plan-spacer" />
              <span class="agent-plan-actions">
                <span
                  v-for="action in row.stop.actions"
                  :key="action.uid || action.index"
                  class="agent-plan-action"
                  :class="{ 'is-doomed': doomed.actions.has(action.uid) }"
                  :data-action-type="action.type"
                  v-tooltip="compact ? null : actionTooltip(action)"
                  @click="compact && tapAction($event, row, action)">
                  <svgicon :name="`action/${action.type}`" />
                  <svgicon
                    v-if="canEdit && action.uid != null"
                    name="close"
                    class="agent-plan-cancel-action"
                    @mouseenter.native="!compact && hover({ stopKey: row.stop.key, uid: action.uid }, $event)"
                    @mouseleave.native="!compact && unhover()"
                    @mousedown.native="keepSelection"
                    @click.native="clickCancel($event, row, action)" />
                </span>
              </span>
            </span>
            <!-- when the agent is done here: arrived, and its actions done -->
            <span
              class="agent-plan-eta"
              data-plan-eta
              v-tooltip="etas[row.stop.key].tooltip">
              {{ etas[row.stop.key].label }}
            </span>
            <svgicon
              v-if="!compact && canEdit"
              name="close"
              class="agent-plan-remove"
              v-tooltip="$t('galaxy.selection.plan.remove_stop')"
              @mouseenter.native="hover({ stopKey: row.stop.key }, $event)"
              @mouseleave.native="unhover"
              @mousedown.native="keepSelection"
              @click.native.stop="removeStop(row.stop, $event)" />
          </div>
        </component>
      </template>
    </template>
  </div>
</template>

<script>
import { DateTime } from 'luxon';

import makeRouter from '@/game/plan/route';
import {
  editablePlan, removeStop, removeAction, removeStopsFrom, removeActionsFrom, moveStop, editPayload, summarize,
  PlanError,
} from '@/game/plan/stops';
import { liveRemaining, queueFinishTimes, formatCountdown } from '@/game/clock';
import { VERTICAL_SCROLL_SETTINGS } from '@/utils/scrollbar';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';

// "Sep 29, 2:32:05 PM" (the year goes without saying)
const ETA_FORMAT = {
  month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', second: '2-digit',
};
// Phones have a third of that width: "2:32 PM" today, "Sep 30, 2:32 PM" after.
const ETA_FORMAT_COMPACT_TODAY = { hour: 'numeric', minute: '2-digit' };
const ETA_FORMAT_COMPACT = { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' };
// How long "clear all" stays armed on a phone before it stands down.
const ARMED_MS = 4000;
// The pass-through toast is a sentence to read, not a "saved" blip.
const PASS_THROUGH_TOAST_MS = 9000;

export default {
  name: 'agent-plan',
  props: {
    character: { type: Object, required: true },
    theme: { type: String, default: 'none' },
    // the touch layout (see the template's header)
    compact: { type: Boolean, default: false },
  },
  data() {
    return {
      scrollbarSettings: VERTICAL_SCROLL_SETTINGS,
      // the × under the pointer: { all } (everything queued), else
      // { stopKey, uid? } (a stop's, or one action's) — and whether shift
      // extends it to everything after
      hovered: null,
      shift: false,
      dragKey: null,
      dropIndex: null,
      pending: false,
      // phones: the stop the toolbar acts on, and what awaits its second
      // tap — { all } ("clear all") or { stopKey, uid } (one action)
      selectedKey: null,
      selectedAt: -1,
      selectedTarget: null,
      armed: null,
      // wall clock, ticking each second for the ETA tooltips' countdown
      now: Date.now(),
      clock: null,
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
    canClear() {
      return this.canEdit && this.rows.length > 0 && !this.character.on_sold && !this.character.on_strike;
    },
    headTarget() {
      const { head } = this.plan;
      return head && head.data ? head.data.target : null;
    },
    rows() {
      const rows = this.plan.stops.map((stop) => ({ stop, movable: true }));
      return this.plan.headStop ? [{ stop: this.plan.headStop, movable: false }, ...rows] : rows;
    },
    selectedRow() {
      return this.rows.find((r) => r.stop.key === this.selectedKey) || null;
    },
    clearArmed() { return !!this.armed && !!this.armed.all; },
    // What the hovered × would remove — with shift held, everything after
    // it as well: the stops (by key) and the single actions (by uid) that go.
    doomed() {
      const stops = new Set();
      const actions = new Set();
      const { hovered } = this;
      if (!hovered) return { stops, actions };

      const at = hovered.all ? -1 : this.rows.findIndex((r) => r.stop.key === hovered.stopKey);
      if (!hovered.all && at === -1) return { stops, actions };

      this.rows.forEach(({ stop }, i) => {
        if (i > at) {
          if (hovered.all || this.shift) stops.add(stop.key);
        } else if (i === at && hovered.uid == null) {
          stops.add(stop.key);
        } else if (i === at) {
          const first = stop.actions.findIndex((a) => a.uid === hovered.uid);
          if (first === -1) return;
          stop.actions.slice(first, this.shift ? undefined : first + 1).forEach((a) => actions.add(a.uid));
        }
      });
      return { stops, actions };
    },
    systemsById() {
      return new Map(((this.$store.state.game.galaxy || {}).stellar_systems || []).map((s) => [s.id, s]));
    },
    // Per row ('head', else the stop's key): when its last entry is done,
    // as { label: the date, tooltip: how long from now }. Unknown once an
    // entry before it (or its own) has no duration yet.
    etas() {
      const at = queueFinishTimes(this.queue, this.$store.state.game.time, this.speedFactor, this.now);
      const describe = (entries) => {
        const done = at[Math.max(...entries.map((e) => e.index))];
        if (done != null) {
          return { label: this.etaLabel(done), tooltip: formatCountdown(done - this.now) };
        }
        const undecided = entries.some((e) => typeof e.remaining_time !== 'number');
        return {
          label: '—',
          tooltip: this.$t(`galaxy.selection.view.${undecided ? 'unknown_action_time' : 'unknown_time'}`),
        };
      };

      const etas = {};
      if (this.plan.head) etas.head = describe([this.plan.head]);
      this.rows.forEach(({ stop }) => { etas[stop.key] = describe(stop.entries); });
      return etas;
    },
  },
  watch: {
    // any fresh copy of the queue ends a pending edit
    queue() {
      this.pending = false;
      if (this.selectedKey === null) return;
      if (this.selectedRow) {
        this.selectedAt = this.rows.indexOf(this.selectedRow);
        return;
      }
      // A stop is keyed by its first action: cancelling that one re-keys
      // the stop. Same place, same system: it is still the selected stop.
      const again = this.rows[this.selectedAt];
      if (again && again.stop.target === this.selectedTarget) {
        this.selectedKey = again.stop.key;
      } else {
        this.deselect();
      }
    },
  },
  methods: {
    systemName(id) {
      const system = this.systemsById.get(id);
      return system ? system.name : '░░░';
    },
    viaNames(ids) { return ids.map((id) => this.systemName(id)).join(' → '); },
    actionLabel(type) { return this.$t(`galaxy.selection.plan.action.${type}`); },
    actionTooltip(action) {
      const label = this.actionLabel(action.type);
      if (!this.canEdit || action.uid == null) return label;
      return `${label}<br>${this.$t('galaxy.selection.plan.cancel_action_hint')}`;
    },
    etaLabel(ms) {
      const date = DateTime.fromMillis(ms);
      if (!this.compact) return date.toLocaleString(ETA_FORMAT);
      const today = date.hasSame(DateTime.fromMillis(this.now), 'day');
      return date.toLocaleString(today ? ETA_FORMAT_COMPACT_TODAY : ETA_FORMAT_COMPACT);
    },
    liveRemaining(action) {
      return liveRemaining(action, this.$store.state.game.time, this.speedFactor);
    },
    pulse(systemId) {
      if (systemId != null) this.$root.$emit('map:pulseSystem', systemId);
    },
    unpulse() { this.$root.$emit('map:unpulseSystem'); },

    // ---- edits ----------------------------------------------------------
    // The editable stops are rows minus the head's own stop (pinned first).
    movableOffset() { return this.plan.headStop ? 1 : 0; },
    // Shift-click: the × takes everything queued after it too.
    removeStop(stop, event) {
      const rest = event && event.shiftKey;
      this.submit(rest ? removeStopsFrom(this.plan, stop.key) : removeStop(this.plan, stop.key));
    },
    cancelAction(stop, action, event) {
      const rest = event && event.shiftKey;
      this.submit(rest
        ? removeActionsFrom(this.plan, stop.key, action.uid)
        : removeAction(this.plan, stop.key, action.uid));
    },
    hover(target, event) {
      this.hovered = target;
      this.shift = event.shiftKey;
    },
    unhover() { this.hovered = null; },
    onShiftKey(event) { this.shift = event.shiftKey; },
    onWindowBlur() { this.shift = false; },
    // a shift-click would also extend a text selection across the panel
    keepSelection(event) {
      if (event.shiftKey) event.preventDefault();
    },
    stopHere() {
      this.submit({ ...this.plan, headStop: null, stops: [] });
    },
    // Phones have no hover to show what "clear all" takes: the first tap
    // marks every stop and asks for a second.
    clearAll() {
      if (!this.compact || this.clearArmed) {
        this.stopHere();
        return;
      }
      this.deselect();
      this.arm({ all: true });
    },
    // Mark what the next tap on the same thing will remove (the marking
    // is the hover preview's), for a few seconds.
    arm(target) {
      this.disarm();
      this.armed = target;
      this.hovered = target;
      this.armedTimer = setTimeout(() => this.disarm(), ARMED_MS);
    },
    disarm() {
      clearTimeout(this.armedTimer);
      if (this.armed) this.hovered = null;
      this.armed = null;
    },
    submit(next) {
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
      this.hovered = null;
      this.disarm();
      this.$socket.player.push('edit_character_actions', payload)
        .receive('ok', () => this.notify(summary))
        .receive('error', (data) => {
          this.pending = false;
          this.$toastError(data.reason);
        })
        .receive('timeout', () => { this.pending = false; });
    },
    // The plan redraws itself, so an edit needs no announcement — except
    // a removed stop that is still on the way to the next one: the agent
    // keeps flying through it, which looks exactly like a removal that
    // failed. That one is said (names escaped: a toast's text is HTML).
    notify(summary) {
      summary.passThrough.forEach((p) => {
        this.$toasted.info(this.$t('galaxy.selection.plan.pass_through', {
          system: this.$escape(this.systemName(p.target)),
          next: this.$escape(this.systemName(p.on_way_to)),
          agent: this.$escape(this.character.name),
        }), { duration: PASS_THROUGH_TOAST_MS, className: 'plan-pass-through-toast' });
      });
    },

    // ---- phones: select a stop, then act from the toolbar ----------------
    select(row) {
      if (!this.canEdit) return;
      if (this.selectedKey === row.stop.key) {
        this.deselect();
        return;
      }
      this.disarm();
      this.selectedKey = row.stop.key;
      this.selectedAt = this.rows.indexOf(row);
      this.selectedTarget = row.stop.target;
      this.pulse(row.stop.target);
    },
    deselect() {
      if (this.selectedKey === null) return;
      this.disarm();
      this.selectedKey = null;
      this.unpulse();
    },
    canMoveSelected(delta) {
      const row = this.selectedRow;
      if (!this.canEdit || !row || !row.movable) return false;
      const to = this.plan.stops.findIndex((s) => s.key === row.stop.key) + delta;
      return to >= 0 && to < this.plan.stops.length;
    },
    // The stop keeps its key through the edit, so it stays selected and
    // can be moved again.
    moveSelected(delta) {
      if (!this.canMoveSelected(delta)) return;
      const { key } = this.selectedRow.stop;
      const from = this.plan.stops.findIndex((s) => s.key === key);
      this.submit(moveStop(this.plan, key, from + delta));
    },
    removeSelected() {
      const row = this.selectedRow;
      if (!row) return;
      this.deselect();
      this.removeStop(row.stop);
    },
    // An action's own × is a hover affordance. On a phone a tap on a stop
    // (even on one of its actions) first selects it; a tap on an action
    // of the selected stop marks it, and a second one cancels it. Never
    // on one tap: browsers snap a touch to the nearest thing that takes
    // taps, so a tap meant for the stop's name can land on an action.
    tapAction(event, row, action) {
      event.stopPropagation();
      if (this.selectedKey !== row.stop.key) {
        this.select(row);
        return;
      }
      if (!this.canEdit || action.uid == null) return;
      if (!this.armed || this.armed.uid !== action.uid) {
        this.arm({ stopKey: row.stop.key, uid: action.uid });
        return;
      }
      this.cancelAction(row.stop, action);
    },
    clickCancel(event, row, action) {
      if (this.compact) return; // the action's own tap handler has it
      event.stopPropagation();
      this.cancelAction(row.stop, action, event);
    },

    // ---- drag to reorder (desktop) --------------------------------------
    onDragStart(event, row) {
      if (this.compact || !this.canEdit || !row.movable) {
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
  mounted() {
    this.clock = setInterval(() => { this.now = Date.now(); }, 1000);
    // shift pressed or released while the pointer rests on a ×
    window.addEventListener('keydown', this.onShiftKey);
    window.addEventListener('keyup', this.onShiftKey);
    window.addEventListener('blur', this.onWindowBlur);
  },
  beforeDestroy() {
    clearInterval(this.clock);
    clearTimeout(this.armedTimer);
    window.removeEventListener('keydown', this.onShiftKey);
    window.removeEventListener('keyup', this.onShiftKey);
    window.removeEventListener('blur', this.onWindowBlur);
    this.unpulse();
  },
  components: { CircleProgressValue },
};
</script>
