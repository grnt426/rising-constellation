<template>
  <div
    class="wk-node"
    :class="[`tone-${node.tone}`, `shape-${node.shape}`, {
      'is-selected': selected,
      'has-error': !!problem && problem.severity === 'error',
      'has-warning': !!problem && problem.severity === 'warning',
      'is-draft': node.draft,
      'is-flash': flash,
    }]"
    :style="{ left: `${node.x}px`, top: `${node.y}px`, width: `${node.w}px` }"
    :data-node="node.id"
    role="group"
    :aria-label="ariaLabel">
    <span
      v-if="node.execIn"
      class="wk-pin wk-exec wk-exec-in"
      :data-anchor="`${node.id}|in`"
      :data-pin="'in'"
      data-kind="exec-in"
      :title="$t('page.scenario_workshop.pin_exec_in')" />

    <div
      class="wk-head"
      data-drag="1"
      :title="node.doc || null"
      @dblclick.stop="onHeadDblClick">
      <select
        v-if="node.headField && node.headField.editor === 'op'"
        class="wk-head-edit"
        :value="node.headField.value"
        :aria-label="$t('page.scenario_workshop.operator')"
        @mousedown.stop
        @change="$emit('field', { id: node.id, key: 'op', value: $event.target.value })">
        <option
          v-for="op in operators"
          :key="op"
          :value="op">{{ op }}</option>
      </select>
      <!-- a path reads as a title: a click selects the node (to move or
           delete it), a double-click edits the path -->
      <input
        v-else-if="node.headField && editingHead"
        ref="headInput"
        type="text"
        class="wk-head-edit is-mono"
        spellcheck="false"
        list="wk-world-paths"
        :value="node.headField.value"
        :size="Math.max(4, node.headField.value.length)"
        :aria-label="node.title"
        @mousedown.stop
        @keydown.enter="$event.target.blur()"
        @keydown.esc="editingHead = false"
        @blur="editingHead = false"
        @change="$emit('field', { id: node.id, key: 'path', value: $event.target.value })">
      <span
        v-else-if="node.headField"
        class="wk-title is-mono">{{ node.headField.value }}</span>
      <span
        v-else
        class="wk-title">{{ node.title }}</span>
      <button
        v-if="problem"
        type="button"
        class="wk-problem"
        v-tooltip="{ content: problemTip, html: false }"
        :aria-label="problemTip"
        @mousedown.stop
        @click.stop="problem.fix && $emit('fix', problem.fix)">!</button>
      <button
        v-if="selected"
        type="button"
        class="wk-node-delete"
        :title="$t('page.scenario_workshop.remove_node')"
        :aria-label="$t('page.scenario_workshop.remove_node')"
        @mousedown.stop
        @click.stop="$emit('delete-node', node.id)">×</button>
      <span
        v-if="node.output"
        class="wk-pin wk-data wk-data-out"
        :data-anchor="`${node.id}|out`"
        data-pin="out"
        data-kind="data-out"
        :title="$t('page.scenario_workshop.pin_data_out')" />
    </div>

    <div
      v-if="node.note"
      class="wk-note-line"
      :title="node.note">{{ node.note }}</div>
    <div
      v-else-if="node.hint"
      class="wk-note-line">{{ node.hint }}</div>

    <div
      v-if="node.shape === 'note'"
      class="wk-note-text">
      <textarea
        :value="node.text"
        rows="3"
        :aria-label="$t('page.scenario_workshop.note')"
        @change="$emit('note', { id: node.id, text: $event.target.value })" />
    </div>

    <div
      v-for="field in node.fields"
      :key="`f-${field.key}`"
      class="wk-row wk-field">
      <span class="wk-label">{{ fieldLabel(field) }}</span>
      <select
        v-if="field.editor === 'op'"
        :value="field.value"
        :aria-label="$t('page.scenario_workshop.operator')"
        @change="$emit('field', { id: node.id, key: field.key, value: $event.target.value })">
        <option
          v-for="op in operators"
          :key="op"
          :value="op">{{ op }}</option>
      </select>
      <input
        v-else
        type="text"
        spellcheck="false"
        :class="{ 'is-mono': field.editor === 'path' }"
        :value="field.value"
        :placeholder="field.key === 'as' ? $t('page.scenario_workshop.count_as_placeholder') : (field.optional ? $t('page.scenario_workshop.optional') : '')"
        :list="field.editor === 'path' ? 'wk-world-paths' : null"
        :aria-label="fieldLabel(field)"
        @keydown.enter="$event.target.blur()"
        @keydown.esc="$event.target.blur()"
        @change="$emit('field', { id: node.id, key: field.key, value: $event.target.value })">
    </div>

    <div
      v-for="input in node.inputs"
      :key="`i-${input.key}`"
      class="wk-row"
      :class="{ 'is-missing': input.editor === 'empty' && !input.optional }">
      <span
        class="wk-pin wk-data wk-data-in"
        :class="{ 'is-wired': input.editor === 'wired' }"
        :data-anchor="`${node.id}|${input.key}`"
        :data-pin="input.key"
        data-kind="data-in"
        :title="typeLabel(input.type)" />
      <span
        class="wk-label"
        :title="input.doc || null">{{ input.label }}</span>

      <span
        v-if="input.editor === 'wired'"
        class="wk-wired-hint" />

      <select
        v-else-if="isEnum(input.type) && (input.editor === 'literal' || input.editor === 'empty')"
        :value="input.value && input.value.k === 'str' ? input.value.v : ''"
        :aria-label="input.label"
        @change="literal(input, $event.target.value)">
        <option
          v-if="!input.value || input.value.k !== 'str'"
          value="">{{ input.optional ? $t('page.scenario_workshop.default_choice') : '?' }}</option>
        <!-- a value outside the list stays visible, so the mistake shows -->
        <option
          v-if="input.value && input.value.k === 'str' && !input.type.enum.includes(input.value.v)"
          :value="input.value.v">{{ $t('page.scenario_workshop.invalid_choice', { value: input.value.v }) }}</option>
        <option
          v-for="choice in input.type.enum"
          :key="choice"
          :value="choice">{{ choice }}</option>
      </select>

      <select
        v-else-if="input.type === 'bool' && (input.editor === 'literal' || input.editor === 'empty') && (!input.value || input.value.k === 'bool' || input.value.k === 'hole')"
        :value="input.value && input.value.k === 'bool' ? String(input.value.v) : ''"
        :aria-label="input.label"
        @change="literal(input, $event.target.value)">
        <option value="">?</option>
        <option value="true">true</option>
        <option value="false">false</option>
      </select>

      <input
        v-else-if="input.editor === 'code'"
        type="text"
        class="is-mono is-code"
        spellcheck="false"
        :value="input.code === undefined ? '…' : input.code"
        :aria-label="input.label"
        :title="$t('page.scenario_workshop.code_hint')"
        @keydown.enter="$event.target.blur()"
        @change="$emit('code', { id: input.codeId, text: $event.target.value, kind: 'expr' })">

      <input
        v-else
        type="text"
        spellcheck="false"
        :value="literalText(input.value)"
        :placeholder="input.optional ? '–' : '?'"
        :aria-label="input.label"
        @keydown.enter="$event.target.blur()"
        @keydown.esc="$event.target.blur()"
        @change="literal(input, $event.target.value)">

      <!-- outside the editor chain above: a v-if inside it would pair with
           the v-else -->
      <button
        v-if="input.editor === 'code' && input.expandable"
        type="button"
        class="wk-mini"
        :title="$t('page.scenario_workshop.menu_show_nodes')"
        :aria-label="$t('page.scenario_workshop.menu_show_nodes')"
        @click="$emit('expand', input.codeId)">⤢</button>

      <button
        v-if="input.removable"
        type="button"
        class="wk-mini"
        :aria-label="$t('page.scenario_workshop.remove')"
        @click="$emit('remove-row', { node, input })">×</button>
    </div>

    <div
      v-if="node.addArg || node.addItem || node.addEntry || node.addSetup"
      class="wk-row wk-add">
      <button
        type="button"
        class="wk-mini"
        @click="$emit('add-row', node)">+ {{ addLabel }}</button>
    </div>

    <div
      v-if="node.codeKind === 'block'"
      class="wk-code-block">
      <textarea
        class="is-mono"
        spellcheck="false"
        :rows="Math.max(2, (node.code || '').split('\n').length)"
        :value="node.code === undefined ? '…' : node.code"
        :aria-label="$t('page.scenario_workshop.code_block')"
        @change="$emit('code', { id: node.id, text: $event.target.value, kind: 'block' })" />
    </div>

    <div
      v-for="out in rightOuts"
      :key="`o-${out.key}`"
      class="wk-row wk-out-right">
      <span class="wk-label">{{ out.label }}</span>
      <span
        class="wk-pin wk-exec wk-exec-out-right"
        :data-anchor="`${node.id}|${out.key}`"
        :data-pin="out.key"
        data-kind="exec-out" />
    </div>

    <span
      v-for="out in bottomOuts"
      :key="`b-${out.key}`"
      class="wk-pin wk-exec wk-exec-out"
      :data-anchor="`${node.id}|${out.key}`"
      :data-pin="out.key"
      data-kind="exec-out"
      :title="$t('page.scenario_workshop.pin_exec_out')" />
  </div>
</template>

<script>
import { literalText } from './ast';
import { OPERATORS } from './graph';

export default {
  name: 'graph-node',
  props: {
    node: { type: Object, required: true },
    selected: { type: Boolean, default: false },
    problem: { type: Object, default: null },
    flash: { type: Boolean, default: false },
  },
  data() {
    return { operators: OPERATORS, editingHead: false };
  },
  computed: {
    rightOuts() { return this.node.execOuts.filter((o) => o.side === 'right'); },
    bottomOuts() { return this.node.execOuts.filter((o) => o.side === 'bottom'); },
    addLabel() {
      if (this.node.addSetup) return this.$t('page.scenario_workshop.add_setup');
      if (this.node.addEntry) return this.$t('page.scenario_workshop.add_entry');
      return this.$t('page.scenario_workshop.add_value');
    },
    // shown with html: false: v-tooltip renders HTML by default, and a
    // problem message can quote the script's own text
    problemTip() {
      if (!this.problem) return '';
      const { fix } = this.problem;
      return fix ? `${this.problem.message} · ${this.$t('page.scenario_workshop.fix', { value: fix.value })}` : this.problem.message;
    },
    ariaLabel() {
      return `${this.node.title}${this.problem ? `: ${this.problem.message}` : ''}`;
    },
  },
  methods: {
    literalText,
    isEnum(type) { return type && typeof type === 'object' && Array.isArray(type.enum); },
    literal(input, text) {
      this.$emit('literal', { node: this.node, input, text });
    },
    fieldLabel(field) {
      return {
        name: 'name', params: 'params', as: this.$t('page.scenario_workshop.count_as'), var: 'item', target: 'variable', path: '', op: '',
      }[field.key] || field.key;
    },
    onHeadDblClick() {
      if (this.node.headField && this.node.headField.editor === 'path') {
        this.editingHead = true;
        this.$nextTick(() => this.$refs.headInput && this.$refs.headInput.select());
      } else {
        this.$emit('focus-doc', this.node);
      }
    },
    typeLabel(type) {
      if (!type) return '';
      if (typeof type === 'string') return type;
      if (type.enum) return type.enum.join(' | ');
      if (type.list) return 'list';
      return 'record';
    },
  },
};
</script>
