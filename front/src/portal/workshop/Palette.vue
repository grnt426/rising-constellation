<template>
  <div class="wk-palette">
    <input
      ref="search"
      v-model="query"
      type="search"
      class="wk-palette-search"
      :placeholder="$t('page.scenario_workshop.palette_search')"
      :aria-label="$t('page.scenario_workshop.palette_search')"
      @keydown.enter="addFirst">
    <div
      v-for="group in groups"
      :key="group.key"
      class="wk-palette-group">
      <button
        type="button"
        class="wk-palette-head"
        :aria-expanded="String(isOpen(group.key))"
        @click="toggle(group.key)">
        <span>{{ group.label }}</span>
        <span class="wk-palette-count">{{ group.items.length }}</span>
      </button>
      <div
        v-if="isOpen(group.key)"
        class="wk-palette-items">
        <button
          v-for="item in group.items"
          :key="`${item.type}-${item.key}`"
          type="button"
          class="wk-palette-item"
          :class="`tone-${item.tone}`"
          draggable="true"
          :title="clickAdds ? item.doc : $t('page.scenario_workshop.palette_add_hint')"
          @dragstart="dragStart($event, item)"
          @click="clickAdds ? $emit('add', item) : $emit('inspect', item)"
          @dblclick="clickAdds || $emit('add', item)"
          @keydown.enter.prevent="$emit('add', item)">
          <span class="wk-palette-label">{{ item.label }}</span>
          <span
            v-if="item.hint"
            class="wk-palette-hint">{{ item.hint }}</span>
        </button>
      </div>
    </div>
    <p
      v-if="!groups.length"
      class="wk-palette-empty">{{ $t('page.scenario_workshop.palette_none') }}</p>
  </div>
</template>

<script>
// Every world path a script can read, flattened from the catalog's schema
// (lists stop the walk: their items are reached with for, map, filter …).
function worldPaths(world, docs) {
  const out = [];
  const walk = (type, path) => {
    if (type && typeof type === 'object' && type.record) {
      Object.keys(type.record).sort().forEach((k) => walk(type.record[k], path ? `${path}.${k}` : k));
    } else {
      out.push({ path, type, doc: docs[path] || '' });
    }
  };
  Object.keys(world).sort().forEach((root) => walk(world[root], root));
  return out;
}

export { worldPaths };

const OPS = [
  { key: '+', doc: 'Add two numbers (or join texts).' },
  { key: '-', doc: 'Subtract.' },
  { key: '*', doc: 'Multiply.' },
  { key: '/', doc: 'Divide.' },
  { key: '==', doc: 'True when both sides are equal.' },
  { key: '!=', doc: 'True when the sides differ.' },
  { key: '<', doc: 'True when the left side is smaller.' },
  { key: '<=', doc: 'True when the left side is smaller or equal.' },
  { key: '>', doc: 'True when the left side is larger.' },
  { key: '>=', doc: 'True when the left side is larger or equal.' },
  { key: 'and', doc: 'True when both sides are true.' },
  { key: 'or', doc: 'True when either side is true.' },
  { key: 'not', doc: 'Turns true into false and false into true.' },
  { key: 'in', doc: 'True when the left value is in the list (or text, or record) on the right.' },
];

export default {
  name: 'palette',
  props: {
    catalog: { type: Object, required: true },
    userFns: { type: Array, default: () => [] },
    library: { type: Array, default: () => [] },
    // the quick add adds on a click; the side panel shows the docs on a
    // click and adds on a double-click (or Enter, or a drag)
    clickAdds: { type: Boolean, default: false },
  },
  data() {
    return { query: '', open: { events: true, actions: true, world: true, flow: true } };
  },
  computed: {
    all() {
      const c = this.catalog;
      const t = (k) => this.$t(`page.scenario_workshop.palette.${k}`);
      const items = [];
      const push = (group, item) => items.push({ group, ...item });

      push('events', {
        type: 'event', key: 'start', label: 'on start', tone: 'event', doc: t('doc_on_start'),
      });
      push('events', {
        type: 'event', key: 'every', label: 'every …', tone: 'event', doc: t('doc_every'),
      });
      push('events', {
        type: 'event', key: 'at', label: 'at …', tone: 'event', doc: t('doc_at'),
      });
      push('events', {
        type: 'event', key: 'when', label: 'when …', tone: 'event', doc: t('doc_when'),
      });
      push('events', {
        type: 'event', key: 'end', label: 'on end', tone: 'event', doc: t('doc_on_end'),
      });

      push('scenario', {
        type: 'decl', key: 'score', label: 'score', tone: 'score', doc: t('doc_score'),
      });
      push('scenario', {
        type: 'decl', key: 'tiebreak', label: 'tiebreak', tone: 'score', doc: t('doc_tiebreak'),
      });
      push('scenario', {
        type: 'decl', key: 'var', label: 'var', tone: 'data', doc: t('doc_var'),
      });
      push('scenario', {
        type: 'decl', key: 'fn', label: 'fn', tone: 'fn', doc: t('doc_fn'),
      });
      push('scenario', {
        type: 'decl', key: 'setup', label: 'setup', tone: 'setup', doc: t('doc_setup'),
      });

      [['if', 'if'], ['for', 'for each'], ['while', 'while'], ['let', 'let'], ['assign', 'set'],
        ['return', 'return'], ['break', 'break'], ['note', 'note'], ['code', 'code block']].forEach(([key, label]) => {
        push('flow', {
          type: 'stmt', key, label, tone: 'flow', doc: t(`doc_${key}`),
        });
      });

      c.actions.forEach((a) => push('actions', {
        type: 'action', key: a.name, label: a.name, tone: 'action', doc: a.doc,
      }));

      // world values read in plain words first ("Credits held"), with the
      // path a script uses as the hint
      worldPaths(c.world, c.world_docs).forEach((w) => push('world', {
        type: 'world',
        key: w.path,
        label: w.doc ? w.doc.split(':')[0].replace(/\.$/, '') : w.path,
        hint: w.path,
        tone: 'world',
        doc: `${w.path}: ${w.doc}`,
      }));

      OPS.forEach((o) => push('logic', {
        type: 'op', key: o.key, label: o.key, tone: 'logic', doc: o.doc,
      }));
      push('logic', {
        type: 'value', key: 'cond', label: 'if … then … else', tone: 'logic', doc: t('doc_cond'),
      });
      push('logic', {
        type: 'value', key: 'list', label: 'list', tone: 'data', doc: t('doc_list'),
      });
      push('logic', {
        type: 'value', key: 'map', label: 'record', tone: 'data', doc: t('doc_map'),
      });

      c.builtins.forEach((b) => push(`fn_${b.group}`, {
        type: 'builtin', key: b.name, label: b.name, tone: 'value', doc: b.doc, hint: b.params.map((p) => p.name).join(', '),
      }));

      this.userFns.forEach((f) => push('mine', {
        type: 'userfn', key: f.name, label: f.name, tone: 'fn', doc: t('doc_userfn'), hint: f.params.join(', '),
      }));
      this.library.forEach((l) => {
        const params = (l.source.match(/fn\s+\w+\(([^)]*)\)/) || [])[1] || '';
        push('library', {
          type: 'library',
          key: l.name,
          label: `${l.name}(${params})`,
          tone: 'fn',
          doc: l.doc || l.source,
          hint: l.builtin ? t('builtin_lib') : t('saved_lib'),
        });
      });

      return items;
    },
    groups() {
      const q = this.query.trim().toLowerCase();
      const order = ['events', 'actions', 'world', 'flow', 'scenario', 'logic', 'fn_math', 'fn_list', 'fn_text', 'fn_record', 'fn_chance', 'mine', 'library'];
      return order
        .map((key) => ({
          key,
          label: this.$t(`page.scenario_workshop.palette.group_${key}`),
          items: this.all.filter((i) => i.group === key
            && (!q || i.label.toLowerCase().includes(q) || (i.hint || '').toLowerCase().includes(q)
              || (i.doc || '').toLowerCase().includes(q))),
        }))
        .filter((g) => g.items.length);
    },
  },
  methods: {
    isOpen(key) { return this.query.trim() !== '' || !!this.open[key]; },
    toggle(key) { this.$set(this.open, key, !this.open[key]); },
    dragStart(e, item) {
      e.dataTransfer.setData('application/x-edict-item', JSON.stringify(item));
      e.dataTransfer.effectAllowed = 'copy';
    },
    addFirst() {
      const first = this.groups[0] && this.groups[0].items[0];
      if (first) this.$emit('add', first);
    },
    focus() { this.$refs.search.focus(); },
  },
};
</script>
