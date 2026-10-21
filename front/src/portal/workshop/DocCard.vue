<template>
  <article
    class="wk-doc"
    :class="{ 'is-compact': compact, 'is-unknown': unknown }">
    <header class="wk-doc-head">
      <h3 class="wk-doc-title">{{ doc.title }}</h3>
      <span
        v-if="doc.kind"
        class="wk-doc-kind">{{ doc.kind }}</span>
    </header>

    <p
      v-if="unknown"
      class="wk-doc-unknown">{{ $t('page.scenario_workshop.doc_unknown', { name: doc.title }) }}</p>
    <p
      v-if="doc.problem"
      class="wk-problem-row"
      :class="`is-${doc.problem.severity}`">{{ doc.problem.message }}</p>

    <p
      v-if="doc.summary"
      class="wk-doc-summary">{{ doc.summary }}</p>
    <p
      v-if="doc.details && !compact"
      class="wk-doc-details">{{ doc.details }}</p>

    <template v-if="doc.usage">
      <h4>{{ $t('page.scenario_workshop.doc_usage') }}</h4>
      <pre class="wk-doc-code">{{ doc.usage }}</pre>
    </template>

    <template v-if="doc.inputs && doc.inputs.length">
      <h4>{{ $t('page.scenario_workshop.doc_inputs') }}</h4>
      <dl class="wk-doc-inputs">
        <template v-for="input in doc.inputs">
          <dt :key="`n-${input.name}`">{{ input.name }}</dt>
          <dd :key="`d-${input.name}`">{{ input.doc }}</dd>
        </template>
      </dl>
    </template>

    <template v-if="doc.output">
      <h4>{{ $t('page.scenario_workshop.doc_output') }}</h4>
      <p class="wk-doc-output">{{ doc.output }}</p>
    </template>

    <template v-if="examples.length">
      <h4>{{ $t('page.scenario_workshop.doc_examples') }}</h4>
      <div
        v-for="(x, i) in examples"
        :key="`x${i}`"
        class="wk-doc-example">
        <pre class="wk-doc-code">{{ x.code }}</pre>
        <span
          v-if="x.result !== null && x.result !== undefined"
          class="wk-doc-result">{{ $t('page.scenario_workshop.doc_gives', { result: x.result }) }}</span>
        <span
          v-if="x.note"
          class="wk-doc-note">{{ x.note }}</span>
      </div>
    </template>

    <p
      v-if="!compact && seeAlso.length"
      class="wk-doc-see">
      {{ $t('page.scenario_workshop.doc_see_also') }}
      <button
        v-for="item in seeAlso"
        :key="item.key"
        type="button"
        class="wk-doc-link"
        @click="$emit('open', item.key)">{{ item.title }}</button>
    </p>

    <p
      v-if="compact && more"
      class="wk-doc-more">{{ $t('page.scenario_workshop.doc_more') }}</p>
  </article>
</template>

<script>
// One entry of the language's docs (Edict.Docs, served with the catalog):
// what it is, how to write it, what goes in, what comes out along the wire,
// examples. Everything renders as text: an entry can quote a script (a
// function's comment).
export default {
  name: 'doc-card',
  props: {
    // {title, kind, summary, details, usage, inputs, output, examples,
    // see_also, problem, state}
    doc: { type: Object, required: true },
    // every entry, to name the see-also links
    docs: { type: Object, default: () => ({}) },
    // the hover version: shorter, no links
    compact: { type: Boolean, default: false },
  },
  computed: {
    unknown() { return this.doc.state === 'unknown'; },
    examples() {
      const all = this.doc.examples || [];
      return this.compact ? all.slice(0, 1) : all;
    },
    seeAlso() {
      return (this.doc.see_also || [])
        .filter((key) => this.docs[key])
        .map((key) => ({ key, title: this.docs[key].title }));
    },
    // the hover card leaves things out: say where the rest is
    more() {
      return !!(this.doc.details || (this.doc.examples || []).length > 1 || (this.doc.see_also || []).length);
    },
  },
};
</script>
