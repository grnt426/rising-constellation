<template>
  <div
    ref="canvas"
    class="wk-canvas"
    :class="{ 'is-panning': drag && drag.type === 'pan', 'is-wiring': drag && drag.type === 'wire' }"
    tabindex="0"
    :aria-label="$t('page.scenario_workshop.canvas_label')"
    @mousedown="onDown"
    @wheel.prevent="onWheel"
    @dblclick="onDblClick"
    @contextmenu.prevent="onContext"
    @keydown="onKey"
    @dragover.prevent
    @drop.prevent="onDrop">
    <div
      ref="content"
      class="wk-content"
      :style="{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }">
      <div
        v-for="frame in graph.frames"
        :key="`frame-${frame.id}`"
        class="wk-frame"
        :class="{ 'is-selected': selection.includes(frame.id) }"
        :style="frameStyle(frame)">
        <div
          class="wk-frame-title"
          :data-frame="frame.id">{{ frame.title }}</div>
      </div>

      <svg
        class="wk-wires"
        aria-hidden="true">
        <path
          v-for="w in wirePaths"
          :key="w.id"
          :d="w.d"
          class="wk-wire"
          :class="[`is-${w.type}`, { 'is-hot': w.hot }]" />
        <path
          v-if="ghost"
          :d="ghost"
          class="wk-wire is-ghost" />
      </svg>

      <graph-node
        v-for="node in graph.nodes"
        :key="node.id"
        :ref="`n-${node.id}`"
        :node="node"
        :selected="selection.includes(node.id)"
        :problem="problems[node.id] || null"
        :flash="flashId === node.id"
        :style="dragOffsetStyle(node.id)"
        @literal="$emit('literal', $event)"
        @field="$emit('field', $event)"
        @code="$emit('code', $event)"
        @note="$emit('note', $event)"
        @add-row="$emit('add-row', $event)"
        @remove-row="$emit('remove-row', $event)"
        @expand="$emit('expand', $event)"
        @fix="$emit('fix', $event)"
        @delete-node="$emit('delete-node', $event)"
        @focus-doc="$emit('focus-doc', $event)" />
    </div>

    <div
      v-if="rect"
      class="wk-select-rect"
      :style="rectStyle" />

    <div class="wk-zoom">
      <button
        type="button"
        :aria-label="$t('page.scenario_workshop.zoom_out')"
        @click="zoomBy(1 / 1.2)">−</button>
      <span>{{ Math.round(zoom * 100) }}%</span>
      <button
        type="button"
        :aria-label="$t('page.scenario_workshop.zoom_in')"
        @click="zoomBy(1.2)">+</button>
      <button
        type="button"
        @click="fit">{{ $t('page.scenario_workshop.fit') }}</button>
    </div>
  </div>
</template>

<script>
import GraphNode from './GraphNode.vue';

// Exec wires leave a node's bottom (or right) and enter the next one's top;
// data wires leave a value's right side and enter an input on the left.
function wirePath(a, b, type, side) {
  if (type === 'data') {
    const dx = Math.max(40, Math.abs(b.x - a.x) * 0.5);
    return `M ${a.x} ${a.y} C ${a.x + dx} ${a.y}, ${b.x - dx} ${b.y}, ${b.x} ${b.y}`;
  }
  const dy = Math.max(30, Math.abs(b.y - a.y) * 0.5);
  if (side === 'right') {
    const dx = Math.max(40, Math.abs(b.x - a.x) * 0.5);
    return `M ${a.x} ${a.y} C ${a.x + dx} ${a.y}, ${b.x} ${b.y - dy}, ${b.x} ${b.y}`;
  }
  return `M ${a.x} ${a.y} C ${a.x} ${a.y + dy}, ${b.x} ${b.y - dy}, ${b.x} ${b.y}`;
}

export default {
  name: 'graph-canvas',
  components: { GraphNode },
  props: {
    graph: { type: Object, required: true },
    selection: { type: Array, default: () => [] },
    problems: { type: Object, default: () => ({}) },
  },
  data() {
    return {
      pan: { x: 40, y: 20 },
      zoom: 0.9,
      anchors: {},
      drag: null,
      ghost: null,
      rect: null,
      flashId: null,
      measureQueued: false,
    };
  },
  computed: {
    wirePaths() {
      const offset = (id) => (this.drag && this.drag.type === 'node' && this.drag.ids.includes(id)
        ? this.drag.delta : { x: 0, y: 0 });
      return this.graph.wires.map((w) => {
        const a = this.anchors[`${w.from.node}|${w.from.pin}`];
        const b = this.anchors[`${w.to.node}|${w.to.pin}`];
        if (!a || !b) return null;
        const oa = offset(w.from.node);
        const ob = offset(w.to.node);
        const pa = { x: a.x + oa.x, y: a.y + oa.y };
        const pb = { x: b.x + ob.x, y: b.y + ob.y };
        return {
          id: w.id,
          type: w.type,
          d: wirePath(pa, pb, w.type, a.side),
          hot: this.selection.includes(w.from.node) || this.selection.includes(w.to.node),
        };
      }).filter(Boolean);
    },
    rectStyle() {
      const r = this.rect;
      return {
        left: `${Math.min(r.x0, r.x1)}px`,
        top: `${Math.min(r.y0, r.y1)}px`,
        width: `${Math.abs(r.x1 - r.x0)}px`,
        height: `${Math.abs(r.y1 - r.y0)}px`,
      };
    },
  },
  watch: {
    graph() { this.queueMeasure(); },
  },
  mounted() {
    this.queueMeasure();
    window.addEventListener('mousemove', this.onMove);
    window.addEventListener('mouseup', this.onUp);
  },
  beforeDestroy() {
    window.removeEventListener('mousemove', this.onMove);
    window.removeEventListener('mouseup', this.onUp);
  },
  updated() { this.queueMeasure(); },
  methods: {
    // --- measuring ---------------------------------------------------------
    queueMeasure() {
      if (this.measureQueued) return;
      this.measureQueued = true;
      this.$nextTick(() => requestAnimationFrame(() => {
        this.measureQueued = false;
        this.measure();
      }));
    },
    measure() {
      const { content } = this.$refs;
      if (!content) return;
      const base = content.getBoundingClientRect();
      const anchors = {};
      content.querySelectorAll('[data-anchor]').forEach((el) => {
        const r = el.getBoundingClientRect();
        const kind = el.getAttribute('data-kind');
        anchors[el.getAttribute('data-anchor')] = {
          x: (r.left + r.width / 2 - base.left) / this.zoom,
          y: (r.top + r.height / 2 - base.top) / this.zoom,
          side: kind === 'exec-out' && el.classList.contains('wk-exec-out-right') ? 'right' : 'bottom',
        };
      });
      this.anchors = anchors;

      // report rendered sizes so the layout can space nodes by them
      const sizes = {};
      content.querySelectorAll('.wk-node').forEach((el) => {
        sizes[el.getAttribute('data-node')] = { w: el.offsetWidth, h: el.offsetHeight };
      });
      this.$emit('sizes', sizes);
    },

    // --- coordinates -------------------------------------------------------
    toCanvas(clientX, clientY) {
      const r = this.$refs.canvas.getBoundingClientRect();
      return { x: (clientX - r.left - this.pan.x) / this.zoom, y: (clientY - r.top - this.pan.y) / this.zoom };
    },
    frameStyle(f) {
      return {
        left: `${f.x}px`, top: `${f.y}px`, width: `${f.w}px`, height: `${f.h}px`,
      };
    },
    dragOffsetStyle(id) {
      if (this.drag && this.drag.type === 'node' && this.drag.ids.includes(id)) {
        return { transform: `translate(${this.drag.delta.x}px, ${this.drag.delta.y}px)` };
      }
      return null;
    },

    // --- pointer -----------------------------------------------------------
    onDown(e) {
      if (e.button !== 0 && e.button !== 1) return;
      const target = e.target;
      if (['INPUT', 'SELECT', 'TEXTAREA', 'BUTTON', 'OPTION'].includes(target.tagName)) return;
      this.$refs.canvas.focus({ preventScroll: true });

      const pinEl = target.closest('[data-pin]');
      const nodeEl = target.closest('[data-node]');
      const frameEl = target.closest('[data-frame]');

      if (pinEl && nodeEl && e.button === 0) {
        e.preventDefault();
        const node = nodeEl.getAttribute('data-node');
        const pin = pinEl.getAttribute('data-pin');
        const kind = pinEl.getAttribute('data-kind');
        if (e.altKey) {
          this.$emit('detach', { node, pin, kind });
          return;
        }
        this.drag = {
          type: 'wire', node, pin, kind, start: this.anchors[`${node}|${pin}`],
        };
        return;
      }

      if (frameEl && e.button === 0) {
        e.preventDefault();
        const fnId = frameEl.getAttribute('data-frame');
        const ids = this.graph.nodes.filter((n) => n.frame === fnId).map((n) => n.id);
        this.$emit('select', [fnId, ...ids]);
        this.drag = {
          type: 'node', ids, origin: { x: e.clientX, y: e.clientY }, delta: { x: 0, y: 0 },
        };
        return;
      }

      if (nodeEl && target.closest('[data-drag]') && e.button === 0) {
        e.preventDefault();
        const id = nodeEl.getAttribute('data-node');
        let ids = this.selection;
        if (e.shiftKey) {
          ids = ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id];
          this.$emit('select', ids);
          return;
        }
        if (!ids.includes(id)) {
          ids = [id];
          this.$emit('select', ids);
        }
        this.drag = {
          type: 'node', ids, origin: { x: e.clientX, y: e.clientY }, delta: { x: 0, y: 0 },
        };
        return;
      }

      if (nodeEl) {
        const id = nodeEl.getAttribute('data-node');
        if (!this.selection.includes(id)) this.$emit('select', [id]);
        return;
      }

      // background: pan, or with shift a selection rectangle
      e.preventDefault();
      if (e.shiftKey) {
        const r = this.$refs.canvas.getBoundingClientRect();
        const x = e.clientX - r.left;
        const y = e.clientY - r.top;
        this.rect = {
          x0: x, y0: y, x1: x, y1: y,
        };
        this.drag = { type: 'rect' };
      } else {
        this.$emit('select', []);
        this.drag = {
          type: 'pan', origin: { x: e.clientX, y: e.clientY }, pan0: { ...this.pan },
        };
      }
    },
    onMove(e) {
      if (!this.drag) return;
      const d = this.drag;
      if (d.type === 'pan') {
        this.pan = { x: d.pan0.x + e.clientX - d.origin.x, y: d.pan0.y + e.clientY - d.origin.y };
      } else if (d.type === 'node') {
        d.delta = { x: (e.clientX - d.origin.x) / this.zoom, y: (e.clientY - d.origin.y) / this.zoom };
        this.drag = { ...d };
      } else if (d.type === 'wire' && d.start) {
        const p = this.toCanvas(e.clientX, e.clientY);
        const outward = d.kind === 'exec-out' || d.kind === 'data-out';
        const [a, b] = outward ? [d.start, p] : [p, d.start];
        this.ghost = wirePath(a, b, d.kind.startsWith('exec') ? 'exec' : 'data', d.start.side);
      } else if (d.type === 'rect') {
        const r = this.$refs.canvas.getBoundingClientRect();
        this.rect = { ...this.rect, x1: e.clientX - r.left, y1: e.clientY - r.top };
      }
    },
    onUp(e) {
      const d = this.drag;
      this.drag = null;
      this.ghost = null;
      if (!d) return;

      if (d.type === 'node' && (Math.abs(d.delta.x) > 1 || Math.abs(d.delta.y) > 1)) {
        const positions = {};
        d.ids.forEach((id) => {
          const n = this.graph.byId[id];
          if (n) positions[id] = { x: Math.round(n.x + d.delta.x), y: Math.round(n.y + d.delta.y) };
        });
        this.$emit('moved', positions);
      } else if (d.type === 'wire') {
        this.finishWire(d, e);
      } else if (d.type === 'rect') {
        this.finishRect();
      }
    },
    finishWire(d, e) {
      const el = document.elementFromPoint(e.clientX, e.clientY);
      const pinEl = el && el.closest('[data-pin]');
      const nodeEl = el && el.closest('[data-node]');
      const at = this.toCanvas(e.clientX, e.clientY);

      if (pinEl && nodeEl) {
        const to = { node: nodeEl.getAttribute('data-node'), pin: pinEl.getAttribute('data-pin'), kind: pinEl.getAttribute('data-kind') };
        this.$emit('wire', { from: { node: d.node, pin: d.pin, kind: d.kind }, to });
      } else if (nodeEl && (d.kind === 'exec-out')) {
        // dropping an exec wire anywhere on a statement connects to it
        this.$emit('wire', { from: { node: d.node, pin: d.pin, kind: d.kind }, to: { node: nodeEl.getAttribute('data-node'), pin: 'in', kind: 'exec-in' } });
      } else {
        this.$emit('wire-dropped', { from: { node: d.node, pin: d.pin, kind: d.kind }, at, client: { x: e.clientX, y: e.clientY } });
      }
    },
    finishRect() {
      const r = this.rect;
      this.rect = null;
      const a = this.toCanvas(Math.min(r.x0, r.x1) + this.$refs.canvas.getBoundingClientRect().left, Math.min(r.y0, r.y1) + this.$refs.canvas.getBoundingClientRect().top);
      const b = { x: a.x + Math.abs(r.x1 - r.x0) / this.zoom, y: a.y + Math.abs(r.y1 - r.y0) / this.zoom };
      const ids = this.graph.nodes
        .filter((n) => n.x >= a.x && n.y >= a.y && n.x + n.w <= b.x && n.y + n.h <= b.y)
        .map((n) => n.id);
      this.$emit('select', ids);
    },
    onWheel(e) {
      const factor = e.deltaY < 0 ? 1.1 : 1 / 1.1;
      this.zoomBy(factor, e.clientX, e.clientY);
    },
    zoomBy(factor, clientX, clientY) {
      const r = this.$refs.canvas.getBoundingClientRect();
      const cx = clientX === undefined ? r.width / 2 : clientX - r.left;
      const cy = clientY === undefined ? r.height / 2 : clientY - r.top;
      const zoom = Math.min(2, Math.max(0.25, this.zoom * factor));
      const k = zoom / this.zoom;
      this.pan = { x: cx - (cx - this.pan.x) * k, y: cy - (cy - this.pan.y) * k };
      this.zoom = zoom;
      this.queueMeasure();
    },
    onDblClick(e) {
      if (e.target.closest('[data-node]')) return;
      const at = this.toCanvas(e.clientX, e.clientY);
      this.$emit('quick-add', { at, client: { x: e.clientX, y: e.clientY } });
    },
    onContext(e) {
      const nodeEl = e.target.closest('[data-node]');
      const frameEl = e.target.closest('[data-frame]');
      const id = nodeEl ? nodeEl.getAttribute('data-node') : (frameEl && frameEl.getAttribute('data-frame'));
      if (id && !this.selection.includes(id)) this.$emit('select', [id]);
      this.$emit('context', {
        id, client: { x: e.clientX, y: e.clientY }, at: this.toCanvas(e.clientX, e.clientY),
      });
    },
    onKey(e) {
      if (['INPUT', 'SELECT', 'TEXTAREA'].includes(e.target.tagName)) return;
      if (e.key === 'Delete' || e.key === 'Backspace') {
        e.preventDefault();
        this.$emit('delete');
      }
    },
    onDrop(e) {
      const raw = e.dataTransfer.getData('application/x-edict-item');
      if (!raw) return;
      const el = document.elementFromPoint(e.clientX, e.clientY);
      const pinEl = el && el.closest('[data-pin]');
      const nodeEl = el && el.closest('[data-node]');
      const pin = pinEl && nodeEl
        ? { node: nodeEl.getAttribute('data-node'), pin: pinEl.getAttribute('data-pin'), kind: pinEl.getAttribute('data-kind') }
        : null;
      this.$emit('drop-item', { item: JSON.parse(raw), at: this.toCanvas(e.clientX, e.clientY), pin });
    },

    // --- view --------------------------------------------------------------
    fit() {
      const nodes = this.graph.nodes;
      if (!nodes.length) return;
      const r = this.$refs.canvas.getBoundingClientRect();
      const x0 = Math.min(...nodes.map((n) => n.x)) - 40;
      const y0 = Math.min(...nodes.map((n) => n.y)) - 40;
      const x1 = Math.max(...nodes.map((n) => n.x + n.w)) + 40;
      const y1 = Math.max(...nodes.map((n) => n.y + n.h)) + 40;
      const whole = Math.min(r.width / (x1 - x0), r.height / (y1 - y0));
      // never fit below a readable size: a big scenario starts at its top,
      // and the rest is a pan away
      const zoom = Math.min(1.1, Math.max(0.6, whole));
      this.zoom = zoom;
      const fits = whole >= 0.6;
      this.pan = {
        x: fits ? (r.width - (x1 - x0) * zoom) / 2 - x0 * zoom : 20 - x0 * zoom + Math.max(0, (r.width - (x1 - x0) * zoom) / 2),
        y: fits ? Math.max(10, (r.height - (y1 - y0) * zoom) / 2) - y0 * zoom : 20 - y0 * zoom,
      };
      this.queueMeasure();
    },
    centerOn(id) {
      const n = this.graph.byId[id];
      if (!n) return;
      const r = this.$refs.canvas.getBoundingClientRect();
      this.pan = { x: r.width / 2 - (n.x + n.w / 2) * this.zoom, y: r.height / 3 - n.y * this.zoom };
      this.flashId = id;
      setTimeout(() => { if (this.flashId === id) this.flashId = null; }, 1200);
      this.queueMeasure();
    },
    flash(id) {
      this.flashId = id;
      setTimeout(() => { if (this.flashId === id) this.flashId = null; }, 1200);
    },
    viewCenter() {
      const r = this.$refs.canvas.getBoundingClientRect();
      return this.toCanvas(r.left + r.width / 2, r.top + r.height / 3);
    },
  },
};
</script>
