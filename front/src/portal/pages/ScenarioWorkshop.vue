<template>
  <default-layout>
    <div
      class="scenario-workshop"
      :class="[`view-${view}`, { 'is-dropping': dropping }]"
      @keydown="onKeys"
      @dragover.prevent="onDragOver"
      @dragleave="onDragLeave"
      @drop.prevent="onDrop">
      <div
        v-if="!catalog || !program"
        class="wk-loading">{{ loadError || $t('page.scenario_workshop.loading') }}</div>

      <template v-else>
        <aside
          class="wk-left"
          data-tour="palette">
          <h2 class="wk-side-title">{{ $t('page.scenario_workshop.palette_title') }}</h2>
          <v-scrollbar class="wk-left-scroll">
            <palette
              ref="palette"
              :catalog="catalog"
              :user-fns="userFns"
              :library="library"
              @add="addItem($event)"
              @inspect="openDoc(paletteDocKey($event))" />
          </v-scrollbar>
        </aside>

        <section class="wk-main">
          <div class="wk-toolbar">
            <h1 class="wk-scenario-name">{{ scenarioName }}</h1>
            <label class="wk-new">
              <span class="sr-only">{{ $t('page.scenario_workshop.new') }}</span>
              <select
                :value="''"
                @change="loadExample($event.target.value); $event.target.value = ''">
                <option value="">{{ $t('page.scenario_workshop.new') }}…</option>
                <option value="__blank">{{ $t('page.scenario_workshop.blank') }}</option>
                <option value="__race">{{ $t('page.scenario_workshop.template_race') }}</option>
                <option value="__match">{{ $t('page.scenario_workshop.template_match') }}</option>
              </select>
            </label>
            <label class="wk-examples">
              <span class="sr-only">{{ $t('page.scenario_workshop.examples') }}</span>
              <select
                :value="''"
                @change="loadExample($event.target.value); $event.target.value = ''">
                <option value="">{{ $t('page.scenario_workshop.examples') }}…</option>
                <optgroup
                  v-for="group in exampleGroups"
                  :key="group.key"
                  :label="group.label">
                  <option
                    v-for="ex in group.items"
                    :key="ex.key"
                    :value="ex.key">{{ ex.title }}</option>
                </optgroup>
              </select>
            </label>
            <div
              class="wk-views"
              role="tablist"
              data-tour="views">
              <button
                v-for="v in ['nodes', 'split', 'code']"
                :key="v"
                type="button"
                role="tab"
                :aria-selected="String(view === v)"
                :class="{ 'is-active': view === v }"
                @click="setView(v)">{{ $t(`page.scenario_workshop.view_${v}`) }}</button>
            </div>
            <div class="wk-tools">
              <button
                type="button"
                class="wk-file"
                aria-haspopup="menu"
                @click="openFileMenu">{{ $t('page.scenario_workshop.file') }} ▾</button>
              <span
                v-if="link"
                class="wk-link"
                :title="$t('page.scenario_workshop.link_hint', { name: link.name })">
                <span class="wk-link-name">{{ link.name }}</span>
                <button
                  v-if="linkDirty"
                  type="button"
                  class="wk-link-save"
                  :disabled="link.writing"
                  @click="saveToLink">{{ $t('page.scenario_workshop.link_save') }}</button>
                <span
                  v-else
                  class="wk-link-state">{{ $t('page.scenario_workshop.link_synced') }}</span>
              </span>
              <button
                type="button"
                :disabled="!history.length"
                :title="$t('page.scenario_workshop.undo')"
                @click="undo">↶</button>
              <button
                type="button"
                :disabled="!future.length"
                :title="$t('page.scenario_workshop.redo')"
                @click="redo">↷</button>
              <button
                type="button"
                @click="startTour">{{ $t('page.scenario_workshop.tour_start') }}</button>
              <button
                type="button"
                class="wk-playtest"
                data-tour="playtest"
                :disabled="playtesting"
                :title="$t('page.scenario_workshop.playtest_hint')"
                @click="playtest">{{ playtesting ? $t('page.scenario_workshop.playtest_starting') : $t('page.scenario_workshop.playtest') }}</button>
            </div>
          </div>

          <div
            v-if="syntaxError"
            class="wk-banner">{{ $t('page.scenario_workshop.syntax_banner', { line: syntaxError.at ? syntaxError.at[0] : '?', message: syntaxError.message }) }}</div>

          <div class="wk-stage">
            <graph-canvas
              v-if="view !== 'code'"
              ref="canvas"
              class="wk-graph"
              data-tour="canvas"
              :graph="graph"
              :selection="selection"
              :problems="problemsByNode"
              @select="select"
              @moved="moved"
              @wire="onWire"
              @wire-dropped="onWireDropped"
              @detach="onDetach"
              @literal="onLiteral"
              @field="onField"
              @code="onCode"
              @note="onNote"
              @add-row="onAddRow"
              @remove-row="onRemoveRow"
              @expand="expandCode"
              @sizes="onSizes"
              @delete="deleteSelection"
              @context="openContext"
              @quick-add="openQuickAdd"
              @drop-item="onDropItem"
              @fix="applyFix"
              @delete-node="deleteNode"
              @focus-doc="showDocFor($event.id)"
              @hover-doc="onNodeHover"
              @hover-end="onNodeHoverEnd" />
            <code-editor
              v-if="view !== 'nodes'"
              ref="code"
              class="wk-text"
              data-tour="code"
              :value="source"
              :diagnostics="diagnostics"
              :active-line="activeLine"
              :actions="catalog.actions.map((a) => a.name)"
              :assist="assist"
              :settings="editorSettings"
              @doc="onCodeDoc"
              @input="onSourceInput"
              @caret="onCaret"
              @line="onCaret" />
          </div>

          <div
            v-if="hoverDoc"
            class="wk-hover-card"
            :style="{ left: `${hoverDoc.x}px`, top: `${hoverDoc.y}px` }">
            <doc-card
              :doc="hoverDoc.doc"
              :docs="allDocs"
              compact />
          </div>

          <div
            v-if="menu"
            class="wk-menu"
            :style="{ left: `${menu.x}px`, top: `${menu.y}px` }"
            role="menu"
            @mouseleave="menu = null">
            <button
              v-for="item in menu.items"
              :key="item.key"
              type="button"
              role="menuitem"
              :disabled="item.disabled"
              @click="item.run(); menu = null">{{ item.label }}</button>
          </div>

          <div
            v-if="quickAdd"
            ref="quickBox"
            class="wk-quick"
            :style="{ left: `${quickAdd.client.x}px`, top: `${quickAdd.client.y}px` }">
            <div class="wk-quick-head">
              <span>{{ $t('page.scenario_workshop.quick_add') }}</span>
              <button
                type="button"
                class="wk-quick-close"
                :title="$t('page.scenario_workshop.close')"
                :aria-label="$t('page.scenario_workshop.close')"
                @click="closeQuickAdd">×</button>
            </div>
            <palette
              ref="quick"
              :catalog="catalog"
              :user-fns="userFns"
              :library="library"
              click-adds
              @add="addItem($event, quickAdd.at, quickAdd.connect); closeQuickAdd()" />
          </div>
        </section>

        <aside class="wk-right">
          <div
            class="wk-tabs"
            role="tablist">
            <button
              v-for="t in ['simulate', 'problems', 'help', 'scripts']"
              :key="t"
              type="button"
              role="tab"
              :aria-selected="String(tab === t)"
              :class="{ 'is-active': tab === t }"
              @click="tab = t">
              {{ $t(`page.scenario_workshop.tab_${t}`) }}
              <span
                v-if="t === 'problems' && errorCount"
                class="wk-badge">{{ errorCount }}</span>
              <span
                v-else-if="t === 'problems' && warningCount"
                class="wk-badge is-muted">{{ warningCount }}</span>
            </button>
          </div>
          <v-scrollbar class="wk-right-scroll">
            <sim-panel
              v-if="tab === 'simulate'"
              :report="sim.report"
              :failure="sim.failure"
              :running="sim.running"
              :stale="simStale"
              :race="isRace"
              :has-finish="hasFinish"
              :pace="sim.pace"
              :auto="sim.auto"
              :pretend="sim.pretend"
              :pretend-default="pretendDefault"
              :paths="worldPaths"
              :catalog="catalog"
              @run="simulate"
              @pace="sim.pace = $event; simulate()"
              @auto="sim.auto = $event"
              @pretend="setPretend"
              @select-node="focusNode" />

            <div
              v-else-if="tab === 'problems'"
              class="wk-problems">
              <p
                v-if="!diagnostics.length"
                class="wk-muted">{{ $t('page.scenario_workshop.no_problems') }}</p>
              <div
                v-for="(d, i) in diagnostics"
                :key="`d${i}`"
                class="wk-problem-item">
                <button
                  type="button"
                  class="wk-problem-row"
                  :class="`is-${d.severity}`"
                  @click="focusDiag(d)">
                  <span
                    v-if="d.at"
                    class="wk-time">{{ d.at[0] }}:{{ d.at[1] }}</span>
                  {{ d.message }}
                </button>
                <button
                  v-if="d.fix"
                  type="button"
                  class="wk-mini wk-fix"
                  @click="applyFix(d.fix)">{{ $t('page.scenario_workshop.fix', { value: d.fix.value }) }}</button>
              </div>
            </div>

            <account-scripts
              v-else-if="tab === 'scripts'"
              ref="accountScripts"
              :current="account"
              :dirty="accountDirty"
              :saving="accountSaving"
              @save="saveToAccount"
              @open="openAccountScript"
              @publish="publishAccount(true)"
              @unpublish="publishAccount(false)"
              @deleted="onAccountDeleted" />

            <div
              v-else
              class="wk-help">
              <doc-card
                v-if="helpDoc"
                :doc="helpDoc"
                :docs="allDocs"
                @open="openDoc" />
              <p
                v-else
                class="wk-muted wk-doc-empty">{{ $t('page.scenario_workshop.doc_empty') }}</p>

              <details
                class="wk-help-section"
                :open="helpOpen.how"
                @toggle="onHelpToggle('how', $event)">
                <summary>{{ $t('page.scenario_workshop.help_title') }}</summary>
                <p>{{ $t('page.scenario_workshop.help_intro') }}</p>
                <ul class="wk-help-list">
                  <li>{{ $t('page.scenario_workshop.help_wires') }}</li>
                  <li>{{ $t('page.scenario_workshop.help_values') }}</li>
                  <li>{{ $t('page.scenario_workshop.help_code') }}</li>
                  <li>{{ $t('page.scenario_workshop.help_group') }}</li>
                  <li>{{ $t('page.scenario_workshop.help_keys') }}</li>
                </ul>
              </details>

              <details
                ref="editorsHelp"
                class="wk-help-section"
                :open="helpOpen.editors"
                @toggle="onHelpToggle('editors', $event)">
                <summary>{{ $t('page.scenario_workshop.editors_title') }}</summary>
                <p>{{ $t('page.scenario_workshop.editors_intro') }}</p>
                <div class="wk-editor-kits">
                  <button
                    v-for="k in editorKits"
                    :key="k.kind"
                    type="button"
                    class="wk-mini"
                    :disabled="downloading === k.kind"
                    @click="downloadKit(k)">{{ $t(`page.scenario_workshop.editors_${k.kind}`) }}</button>
                </div>
                <p class="wk-muted">{{ $t(canLink ? 'page.scenario_workshop.editors_link' : 'page.scenario_workshop.editors_open') }}</p>
              </details>

              <details
                ref="programmersHelp"
                class="wk-help-section wk-programmers"
                :open="helpOpen.programmers"
                @toggle="onHelpToggle('programmers', $event)">
                <summary>{{ $t('page.scenario_workshop.programmers_title') }}</summary>
                <p>{{ $t('page.scenario_workshop.programmers_intro') }}</p>
                <table class="wk-like">
                  <tr
                    v-for="row in LANGUAGE_LIKE"
                    :key="row.lang">
                    <th>{{ row.lang }}</th>
                    <td>
                      <code
                        v-for="(c, i) in row.code"
                        :key="i">{{ c }}</code>
                    </td>
                  </tr>
                </table>
                <p>{{ $t('page.scenario_workshop.programmers_differs') }}</p>
                <ul class="wk-help-list">
                  <!-- `backticks` in the copy show as code; all of it plain text -->
                  <li
                    v-for="key in PROGRAMMER_NOTES"
                    :key="key">
                    <template v-for="(part, i) in ticks($t(`page.scenario_workshop.programmers_${key}`))">
                      <code
                        v-if="i % 2"
                        :key="i">{{ part }}</code>
                      <template v-else>{{ part }}</template>
                    </template>
                  </li>
                </ul>
              </details>

              <h3 class="wk-ref-title">{{ $t('page.scenario_workshop.reference_title') }}</h3>
              <p class="wk-muted">{{ $t('page.scenario_workshop.reference_hint') }}</p>
              <details
                v-for="group in reference"
                :key="group.label"
                class="wk-ref">
                <summary>{{ $t(`page.scenario_workshop.${group.label}`) }} ({{ group.items.length }})</summary>
                <ul class="wk-ref-list">
                  <li
                    v-for="item in group.items"
                    :key="item.key">
                    <button
                      type="button"
                      class="wk-ref-item"
                      :class="{ 'is-active': docPin === item.key }"
                      @click="openDoc(item.key)">
                      <span class="wk-ref-name">{{ item.title }}</span>
                      <span class="wk-ref-summary">{{ item.summary }}</span>
                    </button>
                  </li>
                </ul>
              </details>
            </div>
          </v-scrollbar>
        </aside>

        <input
          ref="openInput"
          type="file"
          accept=".edict,.txt,text/plain"
          class="sr-only"
          tabindex="-1"
          @change="onPickedFile($event, 'open')">
        <input
          ref="fnsInput"
          type="file"
          accept=".edict,.txt,text/plain"
          class="sr-only"
          tabindex="-1"
          @change="onPickedFile($event, 'functions')">
        <div
          v-if="dropping"
          class="wk-drop">{{ $t('page.scenario_workshop.drop_here') }}</div>

        <datalist id="wk-world-paths">
          <option
            v-for="p in worldPaths"
            :key="p"
            :value="p" />
        </datalist>

        <workshop-tour
          v-if="tour.active"
          :steps="tourSteps"
          :index="tour.index"
          @next="tourNext"
          @close="tourClose" />
      </template>
    </div>
  </default-layout>
</template>

<script>
import {
  addPiece, appendItem, clone, connectData, connectExec, deleteNodes, detachChainAt, detachData,
  detachExec, duplicate, groupIntoFunction, indexProgram, isStmt, literalFrom, mk, newId,
  reconcileIds, renameGlobal, replaceNode, setFields, setSlotValue, topNames,
} from '@/portal/workshop/ast';
import DefaultLayout from '@/portal/layouts/Default.vue';
import { markPlaytest } from '@/utils/playtest';
import {
  canLink, fileName, pickLinked, readFile, readLinked, saveBlob, saveText, writeLinked,
} from '@/portal/workshop/files';
import { buildGraph } from '@/portal/workshop/graph';
import GraphCanvas from '@/portal/workshop/GraphCanvas.vue';
import CodeEditor from '@/portal/workshop/CodeEditor.vue';
import DocCard from '@/portal/workshop/DocCard.vue';
import {
  fallbackDocs, nodeDocKey, paletteDocKey, referenceGroups,
} from '@/portal/workshop/docs';
import { createEdict } from 'edict-editors/core';
import Palette, { worldPaths } from '@/portal/workshop/Palette.vue';
import SimPanel from '@/portal/workshop/SimPanel.vue';
import WorkshopTour from '@/portal/workshop/Tour.vue';
import AccountScripts from '@/portal/workshop/AccountScripts.vue';

// For programmers (the Help tab): what Edict borrows from the languages
// they know. Code, so not translated.
const LANGUAGE_LIKE = [
  { lang: 'Python', code: ['# comment', 'and  or  not', 'for x in xs { }', 'len(xs)', 'str(n)', '1_000_000'] },
  { lang: 'JavaScript', code: ['{ … } blocks', 'x => x * 2', '{key: 1}', 'let  var'] },
  { lang: 'Swift, Go', code: ['if x > 1 { }', 'nil', 'notify("Hi", tone: "good")'] },
  { lang: 'Rust', code: ['fn total(a, b) { return a + b }'] },
];
const PROGRAMMER_NOTES = ['lines', 'bools', 'numbers', 'values', 'functions', 'lists', 'events'];

const WORKSPACE_KEY = 'edict.workspace.v1';
const LIBRARY_KEY = 'edict.library.v1';
const TOUR_KEY = 'edict.tour.v1';
const VIEW_KEY = 'edict.view.v1';
const HELP_KEY = 'edict.help.v1';

// editor support, generated by the server from the catalog (Edict.EditorKit)
const EDITOR_KITS = [
  { kind: 'vscode', file: 'edict.vsix' },
  { kind: 'notepadpp', file: 'edict-notepad-plus-plus.zip' },
  { kind: 'kit', file: 'edict-editor-kit.zip' },
];
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

// Starting points that aren't examples: a blank scenario, a blank race (a
// race scores the time left and ends with finish(), see the doc), and rules
// for a match (attached to a Forge scenario, run once per player).
const TEMPLATES = {
  __blank: {
    source: 'setup {\n  name = "My scenario"\n  time_limit = 20m\n}\n\nscore player.credit\n',
  },
  __match: {
    source: `# Rules for a Legacy, Tactic or Flash match. Save it to your scripts, then
# attach it to a Forge scenario: it runs once for every player, as if each
# had their own copy (player is that player, its vars are theirs).
setup {
  name = "My match rules"
  description = "Every 6 hours, the faction in the lead pays a tithe."
  factions = 2
}

# Each player's own score, shown to them in the game.
score player.credit

on start {
  notify("This match runs " + scenario.name + ": " + str(len(factions)) + " factions are in play.")
}

every 6h {
  if find(factions, f => f.name == player.faction).rank == 1 {
    take("credit", player.credit * 5%)
    notify("Your faction leads: 5% of your credit goes to the tithe.", tone: "warning")
  }
}
`,
  },
  __race: {
    source: '# A race: the run ends when the goal is met, and players are ranked by the\n# time they had left (0 if they never got there).\nsetup {\n  name = "My race"\n  time_limit = 20m\n}\n\nscore time.left\n\n# Ties go to the higher number here (change it to what should break ties).\ntiebreak player.credit\n\nwhen player.credit >= 1_000_000 {\n  finish("Goal reached!")\n}\n',
  },
};


// the steps inside a node: an event's whole chain, an if's branches
function countSteps(node) {
  if (!node || typeof node !== 'object') return 0;
  return ['body', 'then', 'else'].reduce((n, f) => n + (Array.isArray(node[f])
    ? node[f].reduce((m, step) => m + (step.k === 'note' ? 0 : 1) + countSteps(step), 0)
    : 0), 0);
}

function storage(key, value) {
  try {
    if (value === undefined) return JSON.parse(localStorage.getItem(key));
    localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    // private windows and blocked storage: the page works without it
  }
  return null;
}

export default {
  name: 'scenario-workshop',
  components: {
    AccountScripts, DefaultLayout, GraphCanvas, CodeEditor, DocCard, Palette, SimPanel, WorkshopTour,
  },
  data() {
    return {
      catalog: null,
      examples: [],
      loadError: null,
      program: null,
      layout: { pos: {}, code: {} },
      sizes: {},
      snippets: {},
      positions: {},
      source: '',
      diagnostics: [],
      syntaxError: null,
      view: storage(VIEW_KEY) || 'nodes',
      selection: [],
      inspect: null,
      history: [],
      future: [],
      tab: 'simulate',
      menu: null,
      quickAdd: null,
      quickAddClosedAt: 0,
      // the language engine (completion, docs under the caret): frozen, so
      // Vue leaves its tables alone
      assist: null,
      // docs chosen from the reference or a see-also link; the selected node
      // or the code under the caret otherwise
      docPin: null,
      codeDocKey: null,
      hoverDoc: null,
      hoverTimer: null,
      helpOpen: {
        how: true, editors: false, programmers: false, ...(storage(HELP_KEY) || {}),
      },
      library: [],
      builtinLibrary: [],
      activeLine: null,
      sim: {
        report: null, failure: null, running: false, pace: 'typical', auto: false, pretend: [], ranOn: null,
      },
      tour: { active: false, index: 0, done: {} },
      playtesting: false,
      // a file followed while it's edited elsewhere: {handle, name, text, modified, writing}
      link: null,
      // the script as the account has it: {id, name, mine, published_at,
      // author, source (its text when last saved or opened)}, or null for a
      // script not saved to the account
      account: null,
      accountSaving: false,
      linkTimer: null,
      dropping: false,
      downloading: null,
      editorKits: EDITOR_KITS,
      LANGUAGE_LIKE,
      PROGRAMMER_NOTES,
      canLink: canLink(),
      loading: null,
      syncTimer: null,
      parseTimer: null,
      simTimer: null,
      saveTimer: null,
      syncSeq: 0,
      parseSeq: 0,
    };
  },
  computed: {
    graph() {
      return buildGraph(this.program, {
        catalog: this.catalog, layout: this.layout, sizes: this.sizes, snippets: this.snippets, program: this.program,
      });
    },
    index() { return indexProgram(this.program); },
    userFns() { return this.program.decls.filter((d) => d.k === 'fn'); },
    worldPaths() { return this.catalog ? worldPaths(this.catalog.world, this.catalog.world_docs).map((w) => w.path) : []; },
    scenarioName() {
      const setup = this.program.decls.find((d) => d.k === 'setup');
      const row = setup && setup.body.find((s) => s.k === 'assign' && s.target.name === 'name');
      return row && row.expr.k === 'str' ? row.expr.v : this.$t('page.scenario_workshop.untitled');
    },
    errorCount() { return this.diagnostics.filter((d) => d.severity === 'error').length; },
    accountDirty() { return !!this.account && this.account.source !== this.source; },
    editorSettings() { return this.$store.getters['portal/scenarioEditor']; },
    // the docs: the language's entries over ones made from the catalog
    allDocs() { return this.catalog ? { ...fallbackDocs(this.catalog), ...(this.catalog.docs || {}) } : {}; },
    reference() { return referenceGroups(this.allDocs); },
    // what the Help tab explains: a pinned entry, else the selected node,
    // else (in the code view) the name under the caret
    helpDoc() {
      if (this.docPin) return this.docFor(this.docPin);
      const id = this.inspect || this.selection[0];
      const node = id && this.graph.byId[id];
      if (node) return this.docForNode(node);
      if (this.codeDocKey && this.view !== 'nodes') return this.docFor(this.codeDocKey);
      return null;
    },
    // the workshop holds changes the linked file doesn't have yet
    linkDirty() { return !!this.link && this.source !== this.link.text; },
    warningCount() { return this.diagnostics.filter((d) => d.severity === 'warning').length; },
    // a race scores time.left: its score only means something after finish()
    isRace() {
      const score = this.program.decls.find((d) => d.k === 'score');
      return !!score && JSON.stringify(score.expr).includes('"name":"left"') && JSON.stringify(score.expr).includes('"name":"time"');
    },
    hasFinish() { return JSON.stringify(this.program.decls).includes('"name":"finish"'); },
    exampleGroups() {
      const t = (k) => this.$t(`page.scenario_workshop.${k}`);
      const groups = [
        { key: 'start', label: t('examples_start'), items: this.examples.filter((e) => e.level === 'start here') },
        { key: 'ports', label: t('examples_ports'), items: this.examples.filter((e) => e.port_of) },
        { key: 'original', label: t('examples_original'), items: this.examples.filter((e) => e.level === 'original') },
      ];
      return groups.filter((g) => g.items.length);
    },
    // results describe the program they ran; any edit since makes them stale
    simStale() {
      return !!this.sim.ranOn && this.sim.ranOn !== JSON.stringify(this.program.decls);
    },
    // a what-if worth starting from: the first world value a `when` reads,
    // with the value that makes it true when the condition says so
    pretendDefault() {
      const whenDecl = this.program.decls.find((d) => d.k === 'when');
      if (!whenDecl) return null;
      const c = whenDecl.cond;
      const path = (n) => {
        if (n.k === 'ident') return n.name;
        if (n.k === 'field') {
          const inner = path(n.obj);
          return inner && `${inner}.${n.name}`;
        }
        return null;
      };
      const at = Math.round(((this.sim.report && this.sim.report.result.ended_at) || 1200) / 2);
      if (c.k === 'bin' && c.op === 'in' && c.l.k === 'str' && path(c.r)) return { at, path: path(c.r), value: [c.l.v] };
      if (c.k === 'bin' && ['>=', '>', '=='].includes(c.op) && path(c.l) && c.r.k === 'num') {
        return { at, path: path(c.l), value: c.op === '>' ? c.r.v + 1 : c.r.v };
      }
      return null;
    },
    // a diagnostic lands on the nearest drawn node: itself or an ancestor
    problemsByNode() {
      const out = {};
      this.diagnostics.forEach((d) => {
        let id = d.node_id;
        while (id && !this.graph.byId[id]) {
          const viaExpr = this.graph.nodes.find((n) => n.exprId === id);
          if (viaExpr) { id = viaExpr.id; break; }
          const slot = this.index.slotOf[id];
          id = slot ? slot.pid : null;
          if (id === '$root') id = null;
        }
        if (id && (!out[id] || (out[id].severity === 'warning' && d.severity === 'error'))) out[id] = d;
      });
      return out;
    },
    tourSteps() {
      const d = this.tour.done;
      return [
        { key: 'welcome', target: '[data-tour="canvas"]' },
        { key: 'events', target: '.wk-node.tone-event' },
        {
          key: 'values', target: '.wk-node.shape-op', task: true, done: !!d.literal,
        },
        {
          key: 'add', target: '[data-tour="palette"]', task: true, done: !!d.connected,
        },
        {
          key: 'simulate', target: '[data-tour="simulate"]', task: true, done: !!d.simulated,
        },
        {
          key: 'code', target: '[data-tour="views"]', task: true, done: !!d.code,
        },
        { key: 'done', target: null },
      ];
    },
  },
  watch: {
    view(v) { storage(VIEW_KEY, v); },
  },
  async mounted() {
    try {
      const [catalog, examples] = await Promise.all([
        this.$axios.get('/edict/catalog'),
        this.$axios.get('/edict/examples'),
      ]);
      // the engine gets its own copy: Vue makes the catalog reactive in place
      this.assist = Object.freeze(createEdict(JSON.parse(JSON.stringify(catalog.data))));
      this.catalog = catalog.data;
      this.examples = examples.data.examples;
      // functions every author starts with (priv/edict/library), then theirs
      this.builtinLibrary = (examples.data.library || []).map((l) => ({ ...l, builtin: true }));
      this.library = [...this.builtinLibrary, ...(storage(LIBRARY_KEY) || [])];

      const saved = storage(WORKSPACE_KEY);
      if (saved && saved.program && await this.restore(saved)) {
        // the author's last session
      } else {
        await this.loadExample('first_steps');
      }

      const tour = storage(TOUR_KEY);
      if (!tour || !tour.finished) this.startTour();
    } catch (e) {
      this.loadError = this.$t('page.scenario_workshop.load_failed');
    }
  },
  beforeDestroy() {
    [this.syncTimer, this.parseTimer, this.simTimer, this.saveTimer].forEach(clearTimeout);
    document.removeEventListener('mousedown', this.onOutsideQuickAdd, true);
    clearTimeout(this.hoverTimer);
    this.unlink(true);
  },
  methods: {
    // --- loading -----------------------------------------------------------
    async loadExample(key) {
      if (!key) return;
      const template = TEMPLATES[key];
      const ex = this.examples.find((e) => e.key === key);
      const source = template ? template.source : ex && ex.source;
      if (!source) return;
      const hadWork = this.history.length > 0;
      this.account = null;
      await this.loadSource(source);
      // switching replaces the scenario; undo brings the old one back
      if (hadWork) this.$toasted.show(this.$t('page.scenario_workshop.switched', { name: this.scenarioName }), { duration: 6000 });
    },
    // Loading replaces the whole program after a round trip; an edit made in
    // between would land on the old program and be lost, so edits wait for
    // a load in flight (see addItem).
    loadSource(text) {
      this.loading = this.doLoadSource(text).finally(() => { this.loading = null; });
      return this.loading;
    },
    async doLoadSource(text) {
      const { data } = await this.$axios.post('/edict/analyze', { source: text });
      if (!data.program) {
        this.source = text;
        this.diagnostics = data.diagnostics;
        this.syntaxError = data.diagnostics[0];
        this.setView('code');
        return;
      }
      this.pushHistory();
      this.program = reconcileIds(null, data.program);
      this.layout = { pos: {}, code: {} };
      this.sizes = {};
      this.sim.report = null;
      this.selection = [];
      await this.sync(true);
      this.$nextTick(() => this.$refs.canvas && this.$refs.canvas.fit());
    },
    async restore(saved) {
      try {
        const { data } = await this.$axios.post('/edict/analyze', { program: saved.program });
        this.program = data.program;
        this.layout = saved.layout || { pos: {}, code: {} };
        this.account = saved.account || null;
        this.applySync(data);
        return true;
      } catch (e) {
        return false;
      }
    },

    // --- the server round trip ---------------------------------------------
    // After every graph edit: check the tree, get its canonical text, where
    // each node sits in it, and the text of nodes drawn as code.
    scheduleSync() {
      clearTimeout(this.syncTimer);
      this.syncTimer = setTimeout(() => this.sync(), 200);
    },
    async sync(now = false) {
      if (!now) clearTimeout(this.syncTimer);
      this.syncSeq += 1;
      const seq = this.syncSeq;
      const codeIds = [...new Set([...this.graph.codeIds, ...Object.keys(this.layout.code).filter((k) => this.layout.code[k])])];
      try {
        const { data } = await this.$axios.post('/edict/analyze', { program: this.program, code_ids: codeIds });
        if (seq !== this.syncSeq) return;
        this.applySync(data);
      } catch (e) {
        this.toastError(e.response && e.response.data && e.response.data.message ? e.response.data.message : 'error');
      }
    },
    applySync(data) {
      this.diagnostics = data.diagnostics;
      this.source = data.source;
      this.positions = data.positions || {};
      this.snippets = data.snippets || {};
      this.syntaxError = null;
      this.saveSoon();
      if (this.sim.auto) this.simulateSoon();
    },
    saveSoon() {
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(() => storage(WORKSPACE_KEY, { program: this.program, layout: this.layout, account: this.account }), 600);
    },

    // --- history -----------------------------------------------------------
    pushHistory() {
      if (!this.program) return;
      this.history.push({ program: this.program, layout: clone(this.layout) });
      if (this.history.length > 100) this.history.shift();
      this.future = [];
    },
    undo() {
      const prev = this.history.pop();
      if (!prev) return;
      this.future.push({ program: this.program, layout: clone(this.layout) });
      this.program = prev.program;
      this.layout = prev.layout;
      this.sync();
    },
    redo() {
      const next = this.future.pop();
      if (!next) return;
      this.history.push({ program: this.program, layout: clone(this.layout) });
      this.program = next.program;
      this.layout = next.layout;
      this.sync();
    },

    // Apply an edit result from ast.js.
    apply(result, { place, select } = {}) {
      if (!result || result.error) {
        if (result && result.error) this.$toasted.error(result.error);
        return false;
      }
      if (result.program === this.program) return false;
      this.pushHistory();
      if (place) {
        Object.entries(place).forEach(([id, at]) => {
          if (id && at) this.$set(this.layout.pos, id, { x: Math.round(at.x), y: Math.round(at.y) });
        });
      }
      this.program = result.program;
      if (select) this.selection = select;
      this.scheduleSync();
      return true;
    },

    // --- selection and view --------------------------------------------------
    select(ids) {
      this.selection = ids;
      this.inspect = null;
      this.docPin = null;
      const pos = ids[0] && this.positionOf(ids[0]);
      this.activeLine = pos ? pos[0] : null;
    },
    positionOf(id) {
      if (this.positions[id]) return this.positions[id];
      const node = this.graph.byId[id];
      return node && node.exprId ? this.positions[node.exprId] : null;
    },
    setView(v) {
      if (v !== 'code' && this.syntaxError) {
        this.$toasted.error(this.$t('page.scenario_workshop.fix_syntax_first'));
        return;
      }
      if (v !== 'nodes') this.tourMark('code');
      this.view = v;
      // the canvas changed size: frame the scenario again
      this.$nextTick(() => requestAnimationFrame(() => this.$refs.canvas && this.$refs.canvas.fit()));
    },
    focusNode(id) {
      let target = id;
      while (target && !this.graph.byId[target]) {
        const viaExpr = this.graph.nodes.find((n) => n.exprId === target);
        if (viaExpr) { target = viaExpr.id; break; }
        const slot = this.index.slotOf[target];
        target = slot && slot.pid !== '$root' ? slot.pid : null;
      }
      if (!target) return;
      this.select([target]);
      if (this.view === 'code') this.setView('split');
      this.$nextTick(() => this.$refs.canvas && this.$refs.canvas.centerOn(target));
    },
    focusDiag(d) {
      if (d.node_id) this.focusNode(d.node_id);
      else if (d.at && this.$refs.code) this.$refs.code.focusLine(d.at[0]);
    },
    // A line in the text selects the node that starts on it (the innermost).
    onCaret(line) {
      this.activeLine = line;
      const onLine = Object.entries(this.positions).filter(([, at]) => at[0] === line);
      const drawn = onLine.map(([id]) => this.graph.byId[id] || this.graph.nodes.find((n) => n.exprId === id)).filter(Boolean);
      if (drawn.length) {
        const pick = drawn.find((n) => n.execIn) || drawn[0];
        this.selection = [pick.id];
      }
    },

    // --- text edits --------------------------------------------------------------
    onSourceInput(text) {
      this.source = text;
      clearTimeout(this.parseTimer);
      this.parseTimer = setTimeout(() => this.parseSource(), 350);
    },
    async parseSource() {
      this.parseSeq += 1;
      const seq = this.parseSeq;
      const { data } = await this.$axios.post('/edict/analyze', { source: this.source });
      if (seq !== this.parseSeq) return;
      this.diagnostics = data.diagnostics;
      if (!data.program) {
        [this.syntaxError] = data.diagnostics;
        return;
      }
      this.syntaxError = null;
      this.pushHistory();
      this.program = reconcileIds(this.program, data.program);
      // positions for the side-by-side highlight, without rewriting the text
      // the author is typing
      const keep = this.source;
      const { data: synced } = await this.$axios.post('/edict/analyze', { program: this.program, code_ids: this.graph.codeIds });
      this.diagnostics = synced.diagnostics;
      this.positions = synced.positions || {};
      this.snippets = synced.snippets || {};
      this.source = keep;
      this.saveSoon();
      if (this.sim.auto) this.simulateSoon();
    },

    // --- graph edits ---------------------------------------------------------------
    moved(positions) {
      this.pushHistory();
      Object.entries(positions).forEach(([id, at]) => this.$set(this.layout.pos, id, at));
      this.saveSoon();
    },
    onSizes(sizes) {
      const changed = Object.keys(sizes).some((id) => {
        const a = this.sizes[id];
        const b = sizes[id];
        return !a || Math.abs(a.w - b.w) > 2 || Math.abs(a.h - b.h) > 2;
      });
      if (changed) this.sizes = sizes;
    },
    // Normalize a wire gesture to "output → input" and apply it.
    onWire({ from, to }) {
      let a = from;
      let b = to;
      if (a.kind === 'exec-in' || a.kind === 'data-in') [a, b] = [b, a];
      if (a.kind === 'exec-out' && b.kind === 'exec-in') {
        const pin = a.pin === 'then' ? 'next' : a.pin;
        if (this.apply(connectExec(this.program, { node: a.node, pin }, b.node))) this.tourMark('connected');
      } else if (a.kind === 'data-out' && b.kind === 'data-in') {
        const source = this.graph.byId[a.node];
        const exprId = (source && source.exprId) || a.node;
        const slot = this.slotForPin(b.node, b.pin);
        if (slot) this.apply(connectData(this.program, exprId, slot));
      } else {
        this.$toasted.error(this.$t('page.scenario_workshop.wire_mismatch'));
      }
    },
    // The slot behind an input pin; creates a name: value for a named pin
    // that has none yet.
    slotForPin(nodeId, pinKey) {
      const node = this.graph.byId[nodeId];
      const input = node && node.inputs.find((i) => i.key === pinKey);
      if (!input) return null;
      if (input.slot && !input.missing) return input.slot;
      if (input.named) {
        const call = this.index.byId[input.callId];
        this.apply(appendItem(this.program, input.callId, 'named', { name: input.named, expr: mk.hole() }));
        return {
          pid: input.callId, field: 'named', index: call.named.length, sub: 'expr',
        };
      }
      if (input.missing) {
        const call = this.index.byId[input.slot.pid];
        let p = this.program;
        for (let i = call.args.length; i <= input.slot.index; i += 1) p = appendItem(p, call.id, 'args', mk.hole()).program;
        this.apply({ program: p });
        return input.slot;
      }
      return null;
    },
    onWireDropped({ from, at, client }) {
      if (from.kind === 'data-in') {
        const input = this.graph.byId[from.node].inputs.find((i) => i.key === from.pin);
        if (input && input.editor === 'wired') {
          const r = detachData(this.program, input.slot);
          this.apply(r, { place: { [r.draftId]: at, [r.nodeId]: at } });
          return;
        }
        this.openQuickAdd({ at, client, connect: { kind: 'data', node: from.node, pin: from.pin } });
      } else if (from.kind === 'exec-in') {
        const r = detachChainAt(this.program, from.node);
        this.apply(r, { place: { [r.draftId]: at, [from.node]: at } });
      } else if (from.kind === 'exec-out') {
        const node = this.graph.byId[from.node];
        const connected = this.graph.wires.some((w) => w.from.node === from.node && w.from.pin === from.pin);
        if (connected) {
          const pin = from.pin === 'then' ? 'next' : from.pin;
          const r = detachExec(this.program, { node: node.id, pin });
          this.apply(r, { place: { [r.draftId]: at, [r.firstId]: at } });
        } else {
          this.openQuickAdd({ at, client, connect: { kind: 'exec', node: from.node, pin: from.pin } });
        }
      } else if (from.kind === 'data-out') {
        this.openQuickAdd({ at, client, connect: { kind: 'feed', node: from.node } });
      }
    },
    onDetach({ node, pin, kind }) {
      if (kind === 'data-in') {
        const input = this.graph.byId[node].inputs.find((i) => i.key === pin);
        if (input && input.slot) this.apply(detachData(this.program, input.slot));
      } else if (kind === 'exec-out') {
        this.apply(detachExec(this.program, { node, pin: pin === 'then' ? 'next' : pin }));
      } else if (kind === 'exec-in') {
        this.apply(detachChainAt(this.program, node));
      }
    },
    onLiteral({ node, input, text }) {
      const literal = literalFrom(text, input.type);
      const slot = this.slotForPin(node.id, input.key);
      if (!slot) return;
      if (this.apply(setSlotValue(this.program, slot, literal))) this.tourMark('literal');
    },
    onField({ id, key, value }) {
      const node = this.index.byId[id];
      const v = String(value).trim();
      if (key === 'shared') {
        this.apply(setFields(this.program, id, { shared: value === true }));
        return;
      }
      if (key === 'path') {
        if (!/^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$/.test(v)) {
          this.$toasted.error(this.$t('page.scenario_workshop.bad_path'));
          return;
        }
        const path = mk.path(v);
        path.id = id;
        this.apply(replaceNode(this.program, id, path));
      } else if (key === 'op') {
        this.apply(setFields(this.program, id, { op: v }));
      } else if (key === 'params') {
        const params = v === '' ? [] : v.split(',').map((s) => s.trim());
        if (params.some((p) => !NAME.test(p))) {
          this.$toasted.error(this.$t('page.scenario_workshop.bad_name'));
          return;
        }
        this.apply(setFields(this.program, id, { params }));
      } else if (key === 'as') {
        if (v !== '' && !NAME.test(v)) return;
        this.apply(setFields(this.program, id, { as: v === '' ? null : v }));
      } else if (!NAME.test(v)) {
        this.$toasted.error(this.$t('page.scenario_workshop.bad_name'));
      } else if (key === 'name' && (node.k === 'var' || node.k === 'fn')) {
        this.apply(renameGlobal(this.program, id, v));
      } else if (key === 'name') {
        this.apply(setFields(this.program, id, { name: v }));
      } else if (key === 'var') {
        this.apply(setFields(this.program, id, { var: v }));
      } else if (key === 'target') {
        const target = mk.ident(v);
        target.id = node.target.id;
        this.apply(setFields(this.program, id, { target }));
      }
    },
    async onCode({ id, text, kind }) {
      const { data } = await this.$axios.post('/edict/fragment', { source: text, kind });
      if (data.error) {
        this.$toasted.error(this.$t('page.scenario_workshop.code_error', { line: data.error.line, message: data.error.message }));
        return;
      }
      const fresh = reconcileIds(null, { decls: [{ k: 'draft', id: 'x', body: kind === 'expr' ? [{ k: 'expr', id: 'y', expr: data.node }] : data.node }] });
      const nodes = fresh.decls[0].body;
      if (kind === 'expr') {
        const e = nodes[0].expr;
        e.id = id;
        this.apply(replaceNode(this.program, id, e));
      } else {
        if (nodes.length) nodes[0].id = id;
        this.apply(replaceNode(this.program, id, nodes));
      }
    },
    onNote({ id, text }) {
      this.apply(setFields(this.program, id, { text: text.replace(/[\u0000-\u0008\u000b-\u001f]/g, '') }));
    },
    onAddRow(node) {
      if (node.addArg) this.apply(appendItem(this.program, node.addArg, 'args', mk.hole()));
      else if (node.addItem) this.apply(appendItem(this.program, node.addItem, 'items', mk.hole()));
      else if (node.addEntry) {
        const key = (window.prompt(this.$t('page.scenario_workshop.entry_key')) || '').trim();
        if (key) this.apply(appendItem(this.program, node.addEntry, 'entries', { key, value: mk.hole() }));
      } else if (node.addSetup) {
        this.openSetupMenu(node);
      }
    },
    openSetupMenu(node) {
      const setup = this.index.byId[node.id];
      const present = new Set(setup.body.filter((s) => s.k === 'assign').map((s) => s.target.name));
      const rect = document.querySelector(`[data-node="${node.id}"]`).getBoundingClientRect();
      this.menu = {
        x: rect.right,
        y: rect.bottom - 30,
        items: this.catalog.setup.filter((f) => !present.has(f.name)).map((f) => ({
          key: f.name,
          label: f.name,
          run: () => {
            const value = this.setupDefault(f);
            const row = {
              k: 'assign', id: newId(), target: mk.ident(f.name), expr: value,
            };
            this.apply(appendItem(this.program, node.id, 'body', row));
          },
        })),
      };
    },
    setupDefault(field) {
      if (field.type === 'bool') return mk.bool(false);
      if (field.type === 'text' || (field.type && field.type.enum)) return mk.str(field.type.enum ? field.type.enum[0] : '');
      if (field.name === 'time_limit') return mk.num(1200, 'duration');
      if (field.type === 'number') return mk.num(field.default || 1);
      if (field.type && field.type.list) return mk.list();
      if (field.type === 'record') return mk.map();
      return mk.hole();
    },
    // One-click repair from a diagnostic: set the named field of the node it
    // points at (a misspelled name, a choice outside the list).
    applyFix(fix) {
      if (!fix || !this.index.byId[fix.target]) return;
      if (this.apply(setFields(this.program, fix.target, { [fix.field]: fix.value }))) {
        this.$toasted.success(this.$t('page.scenario_workshop.fixed', { value: fix.value }));
      }
    },
    deleteNode(id) {
      if (this.index.byId[id]) this.removeNodes([id]);
    },
    // a what-if changes the run: re-run it if there are results to update
    setPretend(list) {
      this.sim.pretend = list;
      if (this.sim.report || this.sim.failure) this.simulateSoon();
    },
    expandCode(id) {
      this.pushHistory();
      this.$set(this.layout.code, id, false);
      this.sync();
    },
    onRemoveRow({ input }) {
      if (typeof input.removable === 'string') this.apply(deleteNodes(this.program, [input.removable]));
      else if (input.value) this.apply(deleteNodes(this.program, [input.value.id]));
    },
    deleteSelection() {
      if (!this.selection.length) return;
      this.removeNodes(this.selection.filter((id) => this.index.byId[id]));
    },
    // Deleting an event or a fn takes its steps with it: say what went, and
    // offer Undo right there.
    removeNodes(ids) {
      const steps = ids.reduce((n, id) => n + countSteps(this.index.byId[id]), 0);
      const first = this.graph.byId[ids[0]];
      if (!this.apply(deleteNodes(this.program, ids), { select: [] })) return;
      const what = ids.length === 1 && first ? first.title : this.$t('page.scenario_workshop.deleted_nodes', { count: ids.length });
      const message = steps
        ? this.$tc('page.scenario_workshop.deleted_with_steps', steps, { what, count: steps })
        : this.$t('page.scenario_workshop.deleted', { what });
      this.$toasted.show(message, {
        duration: 8000,
        action: {
          text: this.$t('page.scenario_workshop.undo_action'),
          onClick: (e, toast) => {
            this.undo();
            toast.goAway(0);
          },
        },
      });
    },

    // --- adding --------------------------------------------------------------
    uniqueName(base) {
      const taken = new Set([...topNames(this.program).globals, ...topNames(this.program).fns]);
      Object.values(this.index.byId).forEach((n) => { if (n.k === 'let') taken.add(n.name); });
      if (!taken.has(base)) return base;
      let i = 2;
      while (taken.has(`${base}${i}`)) i += 1;
      return `${base}${i}`;
    },
    // Build the tree for a palette item.
    pieceFor(item) {
      const c = this.catalog;
      switch (item.type) {
        case 'event':
          if (item.key === 'start' || item.key === 'end') {
            return {
              k: 'on', id: newId(), event: item.key, body: [],
            };
          }
          if (item.key === 'every') {
            return {
              k: 'every', id: newId(), interval: mk.num(60, 'duration'), from: null, until: null, as: null, body: [],
            };
          }
          if (item.key === 'at') {
            return {
              k: 'at', id: newId(), time: mk.num(600, 'duration'), body: [],
            };
          }
          return {
            k: 'when', id: newId(), cond: mk.hole(), body: [],
          };
        case 'decl':
          if (item.key === 'var') {
            return {
              k: 'var', id: newId(), name: this.uniqueName('counter'), expr: mk.num(0),
            };
          }
          if (item.key === 'fn') {
            return {
              k: 'fn', id: newId(), name: this.uniqueName('helper'), params: [], body: [],
            };
          }
          if (item.key === 'setup') {
            if (this.program.decls.some((d) => d.k === 'setup')) return null;
            return {
              k: 'setup',
              id: newId(),
              body: [{
                k: 'assign', id: newId(), target: mk.ident('name'), expr: mk.str('My scenario'),
              }],
            };
          }
          return { k: item.key, id: newId(), expr: mk.hole() };
        case 'stmt':
          switch (item.key) {
            case 'if': return {
              k: 'if', id: newId(), cond: mk.hole(), then: [], else: null,
            };
            case 'for': return {
              k: 'for', id: newId(), var: 'item', iter: mk.hole(), body: [],
            };
            case 'while': return {
              k: 'while', id: newId(), cond: mk.hole(), body: [],
            };
            case 'let': return {
              k: 'let', id: newId(), name: this.uniqueName('value'), expr: mk.hole(),
            };
            case 'assign': return {
              k: 'assign', id: newId(), target: mk.ident('counter'), expr: mk.hole(),
            };
            case 'return': return { k: 'return', id: newId(), expr: null };
            case 'break': return { k: 'break', id: newId() };
            case 'note': return { k: 'note', id: newId(), text: this.$t('page.scenario_workshop.new_note') };
            default: {
              const s = mk.stmt(mk.hole());
              this.$set(this.layout.code, s.id, true);
              return s;
            }
          }
        case 'action': {
          const a = c.actions.find((x) => x.name === item.key);
          const args = a.params.filter((p) => !p.optional).map((p) => {
            if (p.type && p.type.enum) return mk.str(p.type.enum[0]);
            if (p.type === 'text') return mk.str('');
            return mk.hole();
          });
          return mk.stmt(mk.call(a.name, args));
        }
        case 'builtin': {
          const b = c.builtins.find((x) => x.name === item.key);
          return mk.call(b.name, b.params.filter((p) => !p.optional).map(() => mk.hole()));
        }
        case 'userfn': {
          const f = this.userFns.find((x) => x.name === item.key);
          return mk.stmt(mk.call(f.name, f.params.map(() => mk.hole())));
        }
        case 'world': return mk.path(item.key);
        case 'op': return item.key === 'not' ? mk.un('not') : mk.bin(item.key);
        case 'value':
          if (item.key === 'cond') return mk.cond();
          if (item.key === 'list') return mk.list();
          return mk.map();
        default: return null;
      }
    },
    async addItem(item, at, connect) {
      if (this.loading) await this.loading;
      if (item.type === 'library') {
        await this.importLibrary(item.key);
        return;
      }
      const piece = this.pieceFor(item);
      if (!piece) return;
      const where = at || (this.$refs.canvas ? this.$refs.canvas.viewCenter() : { x: 400, y: 200 });
      const r = addPiece(this.program, piece);
      if (!this.apply(r, { place: { [r.draftId || r.id]: where }, select: [r.id] })) return;

      if (connect) this.connectNew(r.id, piece, connect);
      if (this.view === 'code') this.$nextTick(() => this.sync());
    },
    // A piece added from a dropped wire connects to where the wire came from.
    connectNew(id, piece, connect) {
      this.$nextTick(() => {
        if (connect.kind === 'exec' && isStmt(piece)) {
          const pin = connect.pin === 'then' ? 'next' : connect.pin;
          if (this.apply(connectExec(this.program, { node: connect.node, pin }, piece.id))) this.tourMark('connected');
        } else if (connect.kind === 'data' && !isStmt(piece)) {
          const slot = this.slotForPin(connect.node, connect.pin);
          if (slot) this.apply(connectData(this.program, piece.id, slot));
        } else if (connect.kind === 'data' && piece.k === 'expr') {
          const slot = this.slotForPin(connect.node, connect.pin);
          if (slot) this.apply(connectData(this.program, piece.expr.id, slot));
        }
      });
    },
    onDropItem({ item, at, pin }) {
      let connect = null;
      if (pin && pin.kind === 'exec-out') connect = { kind: 'exec', node: pin.node, pin: pin.pin };
      if (pin && pin.kind === 'data-in') connect = { kind: 'data', node: pin.node, pin: pin.pin };
      this.addItem(item, at, connect);
    },
    openQuickAdd({ at, client, connect }) {
      // the second click of a double-click that closed it shouldn't reopen it
      if (Date.now() - this.quickAddClosedAt < 600) return;
      this.quickAdd = { at, client, connect: connect || null };
      document.addEventListener('mousedown', this.onOutsideQuickAdd, true);
      this.$nextTick(() => this.$refs.quick && this.$refs.quick.focus());
    },
    closeQuickAdd() {
      document.removeEventListener('mousedown', this.onOutsideQuickAdd, true);
      if (this.quickAdd) this.quickAddClosedAt = Date.now();
      this.quickAdd = null;
    },
    // a click (or double-click) anywhere outside the quick add closes it
    onOutsideQuickAdd(e) {
      if (this.$refs.quickBox && !this.$refs.quickBox.contains(e.target)) this.closeQuickAdd();
    },

    // --- functions and the library -------------------------------------------------
    groupSelection() {
      const name = (window.prompt(this.$t('page.scenario_workshop.group_name'), this.uniqueName('step')) || '').trim();
      if (!name) return;
      if (!NAME.test(name)) {
        this.$toasted.error(this.$t('page.scenario_workshop.bad_name'));
        return;
      }
      const known = {
        ...topNames(this.program),
        library: [...this.catalog.builtins.map((b) => b.name), ...this.catalog.actions.map((a) => a.name)],
      };
      // a step inside a selected if/loop comes along with it: keep only the
      // outermost selected steps
      const chosen = new Set(this.selection);
      const insideChosen = (id) => {
        let slot = this.index.slotOf[id];
        while (slot && slot.pid !== '$root') {
          if (chosen.has(slot.pid)) return true;
          slot = this.index.slotOf[slot.pid];
        }
        return false;
      };
      const ids = this.selection.filter((id) => isStmt(this.index.byId[id]) && !insideChosen(id));
      const r = groupIntoFunction(this.program, ids, name, known);
      if (r.error) {
        this.$toasted.error(r.error);
        return;
      }
      // the grouped nodes leave their spots for the new fn's frame
      ids.forEach((id) => this.$delete(this.layout.pos, id));
      this.apply(r, { select: [r.callId] });
      // stay where the author was working: flash the call that replaced the
      // steps, and say where the fn went
      this.$nextTick(() => this.$nextTick(() => this.$refs.canvas && this.$refs.canvas.flash(r.callId)));
      this.$toasted.show(this.$t('page.scenario_workshop.grouped', { name }), { duration: 6000 });
    },
    async saveToLibrary(fnId) {
      const fn = this.index.byId[fnId];
      const { data } = await this.$axios.post('/edict/analyze', { program: { decls: [fn] }, code_ids: [] });
      this.storeLibrary(fn.name, data.source, fn.note || '');
    },
    storeLibrary(name, source, doc = '') {
      const saved = storage(LIBRARY_KEY) || [];
      const existing = saved.find((l) => l.name === name);
      if (existing && existing.source !== source
        && !window.confirm(this.$t('page.scenario_workshop.library_replace', { name }))) return;
      const mine = saved.filter((l) => l.name !== name);
      mine.push({ name, source, doc });
      storage(LIBRARY_KEY, mine);
      this.library = [...this.builtinLibrary, ...mine];
      this.$toasted.success(this.$t('page.scenario_workshop.saved_to_library', { name }));
    },
    async importLibrary(name) {
      const entry = this.library.find((l) => l.name === name);
      if (!entry) return;
      const { data } = await this.$axios.post('/edict/analyze', { source: entry.source });
      if (!data.program) return;
      const fresh = reconcileIds(null, data.program);
      let p = this.program;
      let lastId = null;
      fresh.decls.filter((d) => d.k === 'fn').forEach((fn) => {
        const copy = { ...fn };
        if (this.userFns.some((f) => f.name === copy.name)) copy.name = this.uniqueName(copy.name);
        const r = addPiece(p, copy);
        p = r.program;
        lastId = r.id;
      });
      this.apply({ program: p }, { select: lastId ? [lastId] : [] });
    },

    // --- context menu ---------------------------------------------------------------
    openContext({ id, client, at }) {
      const t = (k) => this.$t(`page.scenario_workshop.menu_${k}`);
      const items = [];
      const node = id && this.index.byId[id];
      if (node) {
        const graphNode = this.graph.byId[id];
        const codeId = graphNode && graphNode.exprId ? graphNode.exprId : id;
        if (node.k !== 'fn' && node.k !== 'setup' && !['on', 'every', 'at', 'when', 'score', 'tiebreak', 'var', 'draft', 'note'].includes(node.k)) {
          // drawn as code: by choice, or by default for a long formula
          const shownAsCode = this.graph.codeIds.includes(codeId) || this.layout.code[id] === true;
          items.push({
            key: 'code',
            label: shownAsCode ? t('show_nodes') : t('show_code'),
            run: () => {
              this.pushHistory();
              const key = isStmt(node) && !graphNode.exprId ? id : codeId;
              this.$set(this.layout.code, key, !shownAsCode);
              if (key !== id) this.$delete(this.layout.code, id);
              this.sync();
            },
          });
        }
        const stmts = this.selection.filter((s) => isStmt(this.index.byId[s]));
        if (stmts.length) {
          items.push({ key: 'group', label: t('group'), run: () => this.groupSelection() });
        }
        if (node.k === 'fn') items.push({ key: 'library', label: t('save_library'), run: () => this.saveToLibrary(id) });
        items.push({ key: 'dup', label: t('duplicate'), run: () => this.apply(duplicate(this.program, id), { place: {} }) });
        if (isStmt(node)) items.push({ key: 'cut', label: t('detach'), run: () => this.apply(detachChainAt(this.program, id)) });
        items.push({ key: 'delete', label: t('delete'), run: () => this.deleteSelection() });
      } else {
        items.push({ key: 'add', label: t('add_here'), run: () => this.openQuickAdd({ at, client }) });
        items.push({ key: 'fit', label: t('fit'), run: () => this.$refs.canvas.fit() });
      }
      this.menu = { x: client.x, y: client.y, items };
    },

    // --- keys ----------------------------------------------------------------------
    onKeys(e) {
      const mod = e.ctrlKey || e.metaKey;
      if (e.key === 'Escape' && (this.menu || this.quickAdd)) {
        this.menu = null;
        this.closeQuickAdd();
        return;
      }
      if (mod && !e.shiftKey && e.key.toLowerCase() === 's') {
        e.preventDefault();
        if (this.link) this.saveToLink();
        else if (this.account && this.account.mine) this.saveToAccount({ asNew: false });
        else this.saveFile();
        return;
      }
      if (mod && !e.shiftKey && e.key.toLowerCase() === 'o') {
        e.preventDefault();
        this.$refs.openInput.click();
        return;
      }
      if (['INPUT', 'SELECT', 'TEXTAREA'].includes(e.target.tagName)) return;
      if (mod && e.key.toLowerCase() === 'z' && !e.shiftKey) { e.preventDefault(); this.undo(); }
      if (mod && (e.key.toLowerCase() === 'y' || (e.key.toLowerCase() === 'z' && e.shiftKey))) { e.preventDefault(); this.redo(); }
      if (mod && e.key.toLowerCase() === 'g') { e.preventDefault(); this.groupSelection(); }

    },

    // --- simulation ----------------------------------------------------------------
    simulateSoon() {
      clearTimeout(this.simTimer);
      this.simTimer = setTimeout(() => this.simulate(), 1200);
    },
    async simulate() {
      if (this.sim.running) return;
      this.sim.running = true;
      this.tab = 'simulate';
      try {
        const { data } = await this.$axios.post('/edict/simulate', {
          program: this.program, pace: this.sim.pace, pretend: this.sim.pretend,
        });
        this.sim.ranOn = JSON.stringify(this.program.decls);
        if (data.ok) {
          this.sim.report = data.report;
          this.sim.failure = null;
        } else {
          this.sim.report = null;
          this.sim.failure = data.errors;
        }
        this.tourMark('simulated');
      } catch (e) {
        this.toastError(e.response && e.response.status === 429 ? (e.response.data && e.response.data.message) || 'too_many' : 'error');
      } finally {
        this.sim.running = false;
      }
    },

    // Play the scenario in a real game: the server boots a single-player run
    // from the script (POST /api/edict/playtest) and hands back the same
    // join payload as the daily, which enters the game the same way.
    async playtest() {
      const profile = this.$store.state.portal.activeProfile;
      if (!profile) {
        this.$toasted.error(this.$t('page.scenario_workshop.playtest_profile'));
        return;
      }
      if (this.view === 'nodes' || this.syncTimer) await this.sync(true);
      if (this.errorCount || this.syntaxError) {
        this.tab = 'problems';
        this.$toasted.error(this.$t('page.scenario_workshop.playtest_errors'));
        return;
      }

      this.playtesting = true;
      try {
        const { data } = await this.$axios.post('/edict/playtest', { source: this.source, profile_id: profile.id });
        if (!data.ok) {
          this.diagnostics = data.errors.map((e) => ({ severity: 'error', ...e }));
          this.tab = 'problems';
          this.playtesting = false;
          return;
        }
        storage(WORKSPACE_KEY, { program: this.program, layout: this.layout });
        markPlaytest(data.instance);
        this.$ambiance.sound('play');
        this.$store.commit('game/init', data);
        this.$ambiance.changeContext('game');
        this.$router.push('/game');
      } catch (e) {
        this.playtesting = false;
        const message = e.response && e.response.data && e.response.data.message;
        this.toastError(message || this.$t('page.scenario_workshop.playtest_failed'));
      }
    },
    // The workshop's own server answers (busy, rate limited); anything else
    // as $toastError. Toasts show their text as text (see plugins/a11y).
    toastError(reason) {
      if (reason === 'busy') return this.$toasted.error(this.$t('page.scenario_workshop.server_busy'));
      if (reason === 'rate_limited' || reason === 'too_many') {
        return this.$toasted.error(this.$t('page.scenario_workshop.server_too_many'));
      }
      return this.$toastError(reason);
    },

    // --- docs ------------------------------------------------------------------------------
    // A docs entry by key, ready for the card: the language's own, or one
    // made for a function in this script, or "not something scripts can read".
    docFor(key, problem = null) {
      if (!key) return null;
      const entry = this.allDocs[key];
      if (entry) return { ...entry, key, problem };
      if (key.startsWith('fn:')) {
        const fn = this.userFns.find((f) => f.name === key.slice(3));
        if (fn) {
          return {
            key,
            title: `${fn.name}(${fn.params.join(', ')})`,
            kind: this.$t('page.scenario_workshop.doc_kind_fn'),
            summary: fn.note || this.$t('page.scenario_workshop.doc_fn_plain'),
            see_also: ['node:fn'],
            problem,
          };
        }
      }
      if (key.startsWith('lib:')) {
        const entry = this.library.find((l) => l.name === key.slice(4));
        if (entry) {
          return {
            key,
            title: entry.name,
            kind: this.$t(entry.builtin ? 'page.scenario_workshop.palette.builtin_lib' : 'page.scenario_workshop.palette.saved_lib'),
            summary: entry.doc || null,
            details: this.$t('page.scenario_workshop.doc_lib_details'),
            examples: [{ code: entry.source.trim(), result: null, note: null }],
            see_also: ['node:fn'],
          };
        }
      }
      if (key.startsWith('world:')) return { key, title: key.slice(6), state: 'unknown', problem };
      return null;
    },
    docForNode(node) {
      const problem = this.problemsByNode[node.id] || null;
      const key = nodeDocKey(node, this.index.byId[node.id], this.catalog);
      const doc = this.docFor(key, problem);
      if (doc) return doc;
      // a name the game doesn't know: say so, with the problem
      if (problem) return { title: node.title, state: 'unknown', problem };
      if (node.doc) return { title: node.title, summary: node.doc };
      // the palette's one-liner for the kind of node
      const palette = `page.scenario_workshop.palette.doc_${node.k === 'on' ? 'on_start' : node.k}`;
      const text = this.$t(palette);
      return text !== palette ? { title: node.title, summary: text } : null;
    },
    paletteDocKey(item) {
      return paletteDocKey(item);
    },
    // from the reference, the node list or a see-also link: show it at the
    // top of the Help tab
    openDoc(key) {
      if (!key) return;
      this.docPin = key;
      this.tab = 'help';
      this.$nextTick(() => {
        const box = this.$el.querySelector('.wk-right-scroll');
        if (box) box.scrollTop = 0;
      });
    },
    // double-clicking a node opens its docs in the Help tab
    showDocFor(id) {
      this.inspect = id;
      this.docPin = null;
      this.tab = 'help';
      this.onNodeHoverEnd();
      this.$nextTick(() => {
        const box = this.$el.querySelector('.wk-right-scroll');
        if (box) box.scrollTop = 0;
      });
    },
    onCodeDoc(found) {
      this.codeDocKey = found ? found.key : null;
      if (found) this.docPin = null;
    },
    onNodeHover({ id, rect }) {
      clearTimeout(this.hoverTimer);
      this.hoverTimer = setTimeout(() => {
        const node = this.graph.byId[id];
        const doc = node && this.docForNode(node);
        if (!doc) return;
        const x = Math.max(8, Math.min(rect.right + 10, window.innerWidth - 400));
        const y = Math.max(8, Math.min(rect.top, window.innerHeight - 340));
        this.hoverDoc = { doc, x, y };
      }, 550);
    },
    onNodeHoverEnd() {
      clearTimeout(this.hoverTimer);
      this.hoverDoc = null;
    },
    // "a `b` c" -> ["a ", "b", " c"]: the odd parts are code
    ticks(text) {
      return String(text).split('`');
    },
    onHelpToggle(key, e) {
      this.helpOpen = { ...this.helpOpen, [key]: e.target.open };
      storage(HELP_KEY, this.helpOpen);
    },

    // --- files ---------------------------------------------------------------------------
    openFileMenu(e) {
      const r = e.currentTarget.getBoundingClientRect();
      const t = (k, args) => this.$t(`page.scenario_workshop.file_${k}`, args);
      const mine = (storage(LIBRARY_KEY) || []).length;
      const items = [
        { key: 'open', label: t('open'), run: () => this.$refs.openInput.click() },
        { key: 'save', label: t('save'), run: () => this.saveFile() },
        { key: 'copy', label: this.$t('page.scenario_workshop.copy_text'), run: () => this.copySource() },
      ];
      if (this.canLink) {
        items.push(this.link
          ? { key: 'unlink', label: t('unlink', { name: this.link.name }), run: () => this.unlink() }
          : { key: 'link', label: t('link'), run: () => this.linkFile() });
      }
      items.push(
        {
          key: 'export_fns', label: t('export_functions'), disabled: !mine, run: () => this.exportFunctions(),
        },
        { key: 'import_fns', label: t('import_functions'), run: () => this.$refs.fnsInput.click() },
        { key: 'editors', label: t('editors'), run: () => this.showEditors() },
        {
          key: 'account_save',
          label: this.account && this.account.mine ? t('account_save') : t('account_save_new'),
          run: () => this.saveToAccount({ asNew: !(this.account && this.account.mine) }),
        },
        { key: 'account_open', label: t('account_open'), run: () => { this.tab = 'scripts'; } },
      );
      this.menu = { x: r.left, y: r.bottom + 2, items };
    },
    async onPickedFile(e, what) {
      const file = e.target.files && e.target.files[0];
      e.target.value = '';
      if (file) await this.takeFile(file, what);
    },
    onDragOver(e) {
      if (e.dataTransfer && [...e.dataTransfer.types].includes('Files')) this.dropping = true;
    },
    onDragLeave(e) {
      if (!e.relatedTarget || !this.$el.contains(e.relatedTarget)) this.dropping = false;
    },
    async onDrop(e) {
      this.dropping = false;
      const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (file) await this.takeFile(file, 'open');
    },
    async takeFile(file, what) {
      const { text, name, error } = await readFile(file);
      if (error) {
        this.$toasted.error(this.$t(`page.scenario_workshop.${error}`));
        return;
      }
      if (what === 'functions') {
        await this.importFunctions(text, name);
        return;
      }
      if (this.link) this.unlink();
      this.account = null;
      await this.loadSource(text);
      this.$toasted.show(this.$t('page.scenario_workshop.opened', { name }), { duration: 6000 });
    },
    // the text as it reads now: after a graph edit the canonical text is a
    // round trip away
    async currentSource() {
      if (!this.syntaxError && (this.view === 'nodes' || this.syncTimer)) await this.sync(true);
      return this.source;
    },
    async saveFile() {
      saveText(await this.currentSource(), fileName(this.scenarioName));
    },

    // --- a linked file -----------------------------------------------------------------
    // The workshop follows the file: saving it in another editor reloads it
    // here, as if typed into the code view (so the author's own layout and
    // comments stay as written). Changes made here go back to the file on
    // Save (Ctrl+S).
    async linkFile() {
      const handle = await pickLinked();
      if (!handle) return;
      const now = await readLinked(handle);
      if (now.error) {
        this.$toasted.error(this.$t(`page.scenario_workshop.${now.error}`));
        return;
      }
      this.unlink(true);
      this.link = {
        handle, name: now.name, text: now.text, modified: now.modified, writing: false, polling: false,
      };
      await this.takeLinkedText(now.text);
      this.linkTimer = setInterval(() => this.pollLink(), 1000);
      window.addEventListener('focus', this.pollLink);
      this.$toasted.show(this.$t('page.scenario_workshop.linked', { name: now.name }), { duration: 8000 });
    },
    unlink(quiet = false) {
      clearInterval(this.linkTimer);
      this.linkTimer = null;
      window.removeEventListener('focus', this.pollLink);
      if (this.link && quiet !== true) {
        this.$toasted.show(this.$t('page.scenario_workshop.unlinked', { name: this.link.name }), { duration: 4000 });
      }
      this.link = null;
    },
    async pollLink() {
      const { link } = this;
      if (!link || link.polling || link.writing) return;
      link.polling = true;
      try {
        const now = await readLinked(link.handle);
        if (this.link !== link || now.modified === link.modified) return;
        link.modified = now.modified;
        if (now.error || now.text === link.text) return;
        // both sides changed since the last save: the author picks
        if (this.linkDirty && !window.confirm(this.$t('page.scenario_workshop.link_conflict', { name: link.name }))) return;
        link.text = now.text;
        await this.takeLinkedText(now.text);
      } catch (e) {
        // the file was moved or deleted, or its permission withdrawn
        if (this.link === link) {
          this.unlink(true);
          this.$toasted.error(this.$t('page.scenario_workshop.link_lost', { name: link.name }));
        }
      } finally {
        link.polling = false;
      }
    },
    async takeLinkedText(text) {
      clearTimeout(this.parseTimer);
      this.source = text;
      await this.parseSource();
    },
    async saveToLink() {
      const { link } = this;
      if (!link || link.writing) return;
      const text = await this.currentSource();
      link.writing = true;
      try {
        const modified = await writeLinked(link.handle, text);
        if (modified === null) {
          this.$toasted.error(this.$t('page.scenario_workshop.link_denied', { name: link.name }));
          return;
        }
        link.text = text;
        link.modified = modified;
        this.$toasted.success(this.$t('page.scenario_workshop.link_saved', { name: link.name }));
      } catch (e) {
        this.$toasted.error(this.$t('page.scenario_workshop.link_lost', { name: link.name }));
      } finally {
        link.writing = false;
      }
    },

    // --- functions as files -------------------------------------------------------------
    // The library (saved functions) as one .edict file of fn declarations:
    // to move it to another browser, or share it.
    exportFunctions() {
      const mine = storage(LIBRARY_KEY) || [];
      if (!mine.length) return;
      const day = new Date().toISOString().slice(0, 10);
      const header = `# ${this.$t('page.scenario_workshop.export_header', { day })}\n\n`;
      saveText(`${header}${mine.map((l) => l.source.trim()).join('\n\n')}\n`, 'my-functions.edict');
    },
    // Every fn in a file goes into the library; a scenario's other parts
    // are left out.
    async importFunctions(text, name) {
      const { data } = await this.$axios.post('/edict/analyze', { source: text });
      if (!data.program) {
        this.$toasted.error(this.$t('page.scenario_workshop.import_unreadable', { name, message: data.diagnostics[0].message }));
        return;
      }
      const fns = data.program.decls.filter((d) => d.k === 'fn');
      if (!fns.length) {
        this.$toasted.error(this.$t('page.scenario_workshop.import_none', { name }));
        return;
      }
      const printed = await Promise.all(fns.map((fn) => this.$axios
        .post('/edict/analyze', { program: { decls: [fn] }, code_ids: [] })
        .then(({ data: d }) => ({ name: fn.name, source: d.source, doc: fn.note || '' }))));
      const saved = storage(LIBRARY_KEY) || [];
      const replaced = printed.filter((f) => saved.some((l) => l.name === f.name && l.source !== f.source)).map((f) => f.name);
      if (replaced.length && !window.confirm(this.$t('page.scenario_workshop.import_replace', { names: replaced.join(', ') }))) return;
      const names = new Set(printed.map((f) => f.name));
      const mine = [...saved.filter((l) => !names.has(l.name)), ...printed];
      storage(LIBRARY_KEY, mine);
      this.library = [...this.builtinLibrary, ...mine];
      const skipped = data.program.decls.some((d) => d.k !== 'fn' && d.k !== 'note');
      const key = skipped ? 'import_done_partial' : 'import_done';
      this.$toasted.success(this.$t(`page.scenario_workshop.${key}`, { count: printed.length, name }), { duration: 6000 });
    },

    // --- scripts saved to the account -------------------------------------------------
    // The server derives the name, text and checks from the tree; the layout
    // rides along so the graph opens as it was left.
    async saveToAccount({ asNew }) {
      if (this.accountSaving) return;
      if (this.loading) await this.loading;
      await this.currentSource();
      const mine = this.account && this.account.mine && !asNew;
      this.accountSaving = true;
      try {
        const body = { program: this.program, layout: this.layout };
        const { data } = mine
          ? await this.$axios.put(`/edict/scripts/${this.account.id}`, body)
          : await this.$axios.post('/edict/scripts', body);
        this.account = this.accountFrom(data.script);
        this.saveSoon();
        this.$toasted.success(this.$t('page.scenario_workshop.account.saved_toast', { name: data.script.name }));
        if (this.$refs.accountScripts) this.$refs.accountScripts.refresh();
      } catch (e) {
        this.accountRefused(e);
      } finally {
        this.accountSaving = false;
      }
    },
    async openAccountScript(summary) {
      // a load still in flight (New…, an example) would land after this one
      if (this.loading) await this.loading;
      if (this.accountDirty && !window.confirm(this.$t('page.scenario_workshop.account.discard_confirm', { name: this.account.name }))) return;
      try {
        const { data } = await this.$axios.get(`/edict/scripts/${summary.id}`);
        if (this.link) this.unlink();
        this.pushHistory();
        if (await this.restore({ program: data.script.program, layout: data.script.layout })) {
          this.account = this.accountFrom(data.script);
          this.selection = [];
          this.sim.report = null;
          this.saveSoon();
          this.$nextTick(() => this.$refs.canvas && this.$refs.canvas.fit());
          this.$toasted.show(this.$t('page.scenario_workshop.opened', { name: data.script.name }), { duration: 4000 });
        }
      } catch (e) {
        this.$toasted.error(this.$t('page.scenario_workshop.account.failed'));
      }
    },
    async publishAccount(publish) {
      if (!this.account || !this.account.mine || this.accountSaving) return;
      if (publish && !window.confirm(this.$t('page.scenario_workshop.account.publish_confirm', { name: this.account.name }))) return;
      this.accountSaving = true;
      try {
        const url = `/edict/scripts/${this.account.id}/publish`;
        const { data } = publish ? await this.$axios.put(url) : await this.$axios.delete(url);
        this.account = { ...this.accountFrom(data.script), source: this.account.source };
        this.saveSoon();
        const key = publish ? 'published_toast' : 'unpublished_toast';
        this.$toasted.success(this.$t(`page.scenario_workshop.account.${key}`, { name: data.script.name }));
        if (this.$refs.accountScripts) this.$refs.accountScripts.refresh();
      } catch (e) {
        this.accountRefused(e);
      } finally {
        this.accountSaving = false;
      }
    },
    onAccountDeleted(script) {
      if (this.account && this.account.id === script.id) {
        this.account = null;
        this.saveSoon();
      }
    },
    accountFrom(script) {
      return {
        id: script.id,
        name: script.name,
        mine: script.mine,
        published_at: script.published_at,
        author: script.author,
        source: script.source,
      };
    },
    // The server's refusals, in words (names in them are plain text).
    accountRefused(e) {
      const body = (e && e.response && e.response.data) || {};
      const say = (key, args) => this.$toasted.error(this.$t(`page.scenario_workshop.account.${key}`, args), { duration: 9000 });
      switch (body.message) {
        case 'script_limit': return say('refused_limit', { limit: body.limit });
        case 'script_has_errors': return say('refused_errors');
        case 'script_duplicate':
          return say('refused_duplicate', {
            name: body.script && body.script.name,
            author: body.script && body.script.author ? body.script.author.name : '?',
          });
        case 'script_invalid': return say('refused_invalid', { detail: body.detail });
        default: return say('failed');
      }
    },

    // --- editor kits ---------------------------------------------------------------------
    showEditors() {
      this.tab = 'help';
      this.helpOpen = { ...this.helpOpen, editors: true };
      // the panel scrolls itself (v-scrollbar), so move it there directly
      this.$nextTick(() => {
        const target = this.$refs.editorsHelp;
        const box = target && target.closest('.wk-right-scroll');
        if (!box) return;
        box.scrollTop += target.getBoundingClientRect().top - box.getBoundingClientRect().top - 8;
      });
    },
    async downloadKit(kit) {
      this.downloading = kit.kind;
      try {
        const res = await this.$axios.get(`/edict/editors/${kit.kind}`, { responseType: 'blob' });
        const disposition = (res.headers && res.headers['content-disposition']) || '';
        const named = /filename="([^"]+)"/.exec(disposition);
        saveBlob(res.data, named ? named[1] : kit.file);
      } catch (e) {
        this.toastError('error');
      } finally {
        this.downloading = null;
      }
    },

    copySource() {
      const done = () => this.$toasted.success(this.$t('page.scenario_workshop.copied'));
      if (navigator.clipboard) navigator.clipboard.writeText(this.source).then(done, () => {});
    },

    // --- the tour ----------------------------------------------------------------------
    startTour() {
      this.tour = { active: true, index: 0, done: {} };
    },
    tourMark(key) {
      if (this.tour.done[key]) return;
      this.$set(this.tour.done, key, true);
      const step = this.tourSteps[this.tour.index];
      if (this.tour.active && step && step.task && step.done) {
        setTimeout(() => this.tourNext(), 900);
      }
    },
    tourNext() {
      if (this.tour.index >= this.tourSteps.length - 1) {
        this.tourClose();
        return;
      }
      this.tour.index += 1;
    },
    tourClose() {
      this.tour.active = false;
      storage(TOUR_KEY, { finished: true, at: new Date().toISOString(), reached: this.tour.index });
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

$panel: rgba(10, 12, 16, .92);
$line: rgba(255, 255, 255, .12);

.scenario-workshop {
  position: relative;
  display: grid;
  grid-template-columns: 230px minmax(0, 1fr) 330px;
  height: calc(100vh - 70px);
  min-height: 520px;
  color: $white;
  font-size: 1.3rem;
}

.wk-loading {
  grid-column: 1 / -1;
  padding: 60px 20px;
  text-align: center;
  opacity: .7;
}

.wk-left,
.wk-right {
  display: flex;
  flex-direction: column;
  min-height: 0;
  background: $panel;
  border-right: solid 1px $line;
}

.wk-right {
  border-right: none;
  border-left: solid 1px $line;
}

.wk-left-scroll,
.wk-right-scroll {
  position: relative;
  flex: 1 1 auto;
  min-height: 0;
}

.wk-side-title {
  margin: 0;
  padding: 12px 14px 6px;
  font-size: 1.2rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  opacity: .7;
}

.wk-main {
  position: relative;
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
}

// wraps rather than run under the side panel when a linked file's name
// needs the room
.wk-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 12px;
  padding: 8px 12px;
  background: $panel;
  border-bottom: solid 1px $line;
}

// a long name gives way; the controls never move
// a small basis, so the toolbar fits on one line by shortening the name
// before it wraps
.wk-scenario-name {
  flex: 1 1 60px;
  min-width: 60px;
  max-width: 260px;
  margin: 0;
  font-size: 1.6rem;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.wk-new,
.wk-examples,
.wk-views,
.wk-tools {
  flex: 0 0 auto;
}

// the selects show their placeholder; the open list is as wide as it needs
.wk-new select {
  max-width: 110px;
}

.wk-examples select {
  max-width: 180px;
}

.wk-new select,
.wk-examples select,
.wk-tools button,
.wk-views button {
  padding: 5px 9px;
  border: solid 1px $line;
  background: rgba(255, 255, 255, .04);
  color: $white;
  font: inherit;
  cursor: pointer;

  &:disabled {
    opacity: .35;
    cursor: default;
  }
}

.wk-views {
  display: flex;

  button + button {
    border-left: none;
  }

  .is-active {
    background: $primary;
    border-color: $primary;
    color: $black;
  }
}

.wk-tools {
  display: flex;
  gap: 6px;
  margin-left: auto;
}

.wk-tools .wk-playtest {
  border-color: $primary;
  color: $primary;
  font-weight: 700;
}

// the file the workshop follows: its name, and Save when this side is ahead
.wk-link {
  display: flex;
  align-items: center;
  gap: 6px;
  max-width: 200px;
  padding: 0 4px 0 8px;
  border: solid 1px $line;
  color: $white-alt-1;
  font-size: 1.15rem;

  .wk-link-name {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    color: $white;
  }

  .wk-link-state {
    padding-right: 4px;
  }

  .wk-link-save {
    padding: 2px 7px;
    border-color: $primary;
    color: $primary;
  }
}

.scenario-workshop.is-dropping {
  outline: dashed 2px $white-alt-2;
  outline-offset: -6px;
}

.wk-drop {
  position: absolute;
  inset: 0;
  z-index: 60;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(5, 6, 8, .7);
  color: $white;
  font-size: 1.6rem;
  pointer-events: none;
}

.wk-editor-kits {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 6px 0 8px;
}

.wk-banner {
  padding: 6px 12px;
  background: rgba($color-alert, .15);
  border-bottom: solid 1px $color-alert;
  color: lighten($color-alert, 20%);
}

.wk-stage {
  position: relative;
  display: flex;
  flex: 1 1 auto;
  min-height: 0;
}

.wk-graph,
.wk-text {
  flex: 1 1 50%;
  min-width: 0;
}

.view-split .wk-text {
  border-left: solid 1px $line;
}

.wk-tabs {
  display: flex;
  border-bottom: solid 1px $line;

  button {
    flex: 1;
    padding: 9px 4px;
    border: none;
    background: none;
    color: $white;
    font: inherit;
    opacity: .6;
    cursor: pointer;

    &.is-active {
      opacity: 1;
      box-shadow: inset 0 -2px 0 $primary;
    }
  }
}

.wk-badge.is-muted {
  background: $white-alt-2;
}

.wk-badge {
  display: inline-block;
  min-width: 18px;
  margin-left: 4px;
  padding: 0 5px;
  border-radius: 9px;
  background: $color-alert;
  color: $black;
  font-size: 1.1rem;
}

.wk-problems,
.wk-help,
.wk-account {
  padding: 10px 12px;

  p {
    margin: 0 0 10px;
    line-height: 1.45;
  }
}

.wk-problem-item {
  margin-bottom: 5px;

  .wk-problem-row {
    margin-bottom: 0;
  }
}

.wk-fix {
  margin: 3px 0 0 3px;
  border-color: $primary;
  color: $primary;
}

// collapsible parts of the Help tab
.wk-help-section,
.wk-ref {
  margin-bottom: 8px;

  summary {
    padding: 4px 0;
    font-weight: 700;
    cursor: pointer;
  }
}

.wk-help-section {
  padding-bottom: 4px;
  border-bottom: solid 1px $line;
}

.wk-ref-title {
  margin-top: 14px;
}

.wk-ref summary {
  font-weight: 400;
}

// each name on its own line, whole, its description under it
.wk-ref-list {
  margin: 4px 0 0;
  padding: 0;
  list-style: none;
}

.wk-ref-item {
  display: block;
  width: 100%;
  padding: 5px 6px;
  border: none;
  background: none;
  color: $white;
  font: inherit;
  text-align: left;
  cursor: pointer;

  &:hover,
  &.is-active {
    background: rgba(255, 255, 255, .07);
  }

  .wk-ref-name {
    display: block;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 1.15rem;
    overflow-wrap: anywhere;
  }

  .wk-ref-summary {
    display: block;
    margin-top: 1px;
    color: $white-alt-1;
    font-size: 1.15rem;
    line-height: 1.35;
  }
}

.wk-doc-empty {
  font-style: italic;
}

.wk-hover-card {
  position: fixed;
  z-index: 60;
  width: 380px;
  max-height: 330px;
  padding: 9px 12px;
  overflow: hidden;
  background: #1b1e24;
  border: solid 1px rgba(255, 255, 255, .18);
  box-shadow: 0 6px 20px rgba(0, 0, 0, .55);
  pointer-events: none;
}

.wk-help-list {
  padding-left: 18px;

  li {
    margin-bottom: 8px;
  }
}

// For programmers: code in the copy, and what Edict borrows from where
.wk-programmers code {
  padding: 0 3px;
  background: rgba(255, 255, 255, .08);
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 1.1rem;
  white-space: nowrap;
}

.wk-like {
  width: 100%;
  margin: 0 0 10px;
  border-collapse: collapse;

  th {
    padding: 4px 8px 4px 0;
    color: $white-alt-1;
    font-weight: normal;
    text-align: left;
    vertical-align: top;
    white-space: nowrap;
  }

  td {
    padding: 3px 0;
  }

  code {
    display: inline-block;
    margin: 0 4px 4px 0;
  }
}

.wk-menu {
  position: fixed;
  z-index: 50;
  display: flex;
  flex-direction: column;
  min-width: 180px;
  background: $grey-darker;
  border: solid 1px $line;
  box-shadow: 0 6px 24px rgba(0, 0, 0, .6);

  button {
    padding: 7px 12px;
    border: none;
    background: none;
    color: $white;
    font: inherit;
    text-align: left;
    cursor: pointer;

    &:hover {
      background: rgba(255, 255, 255, .08);
    }
  }
}

.wk-quick-head {
  position: sticky;
  top: 0;
  z-index: 1;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 4px 4px 4px 10px;
  background: $grey-darker;
  border-bottom: solid 1px $line;
  color: $white-alt-1;
  font-size: 1.15rem;
}

.wk-quick-close {
  padding: 0 7px;
  border: none;
  background: none;
  color: $white;
  font: inherit;
  font-size: 1.6rem;
  line-height: 1;
  cursor: pointer;

  &:hover {
    background: rgba(255, 255, 255, .1);
  }
}

.wk-quick {
  position: fixed;
  z-index: 50;
  width: 260px;
  max-height: 380px;
  overflow: auto;
  background: $grey-darker;
  border: solid 1px $line;
  box-shadow: 0 6px 24px rgba(0, 0, 0, .6);
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
}

@media (max-width: $mobile-breakpoint) {
  .scenario-workshop {
    grid-template-columns: 1fr;
    grid-template-rows: auto 1fr auto;
    height: auto;
  }

  .wk-main {
    min-height: 70vh;
  }
}
</style>

<style lang="scss">
@import '~@/styles/shared/variables';
@import '~@/portal/workshop/workshop';
</style>
