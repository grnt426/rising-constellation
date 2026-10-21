// Draws an Edict tree as a node graph.
//
// The mapping is one-to-one, so the graph and the text are the same program:
//
//   * a declaration (setup, score, var, an event, a fn) is a header node;
//   * a statement is a node in a chain. Exec wires run top to bottom, in the
//     order the text reads; a branch or a loop sends its inner chains off to
//     the right;
//   * an expression is a node whose output feeds an input on the left side
//     of the node that uses it. Plain values (numbers, text, choices) sit in
//     the input itself, field paths such as player.income.credit are one
//     node, and anything shown as code (lambdas, templates, or a node the
//     author switched to code) is an editable line of text in the input.
//
// buildGraph() returns { nodes, wires, frames } with positions: a node's
// saved position if the author moved it, else a spot worked out from its
// parent's, so untouched nodes follow what they belong to.

import {
  childSlots, getSlot, indexProgram, isLiteral, pathText,
} from './ast';

const HEADER = 30;
const ROW = 26;
const GAP_X = 46;
const GAP_Y = 34;
const BRANCH_X = 70;

export const WIDTH = {
  decl: 230, stmt: 210, expr: 170, path: 160, get: 110, op: 112, note: 220,
};

const OPS = {
  '+': 'add', '-': 'subtract', '*': 'multiply', '/': 'divide',
  '==': 'equals', '!=': 'differs', '<': 'less', '<=': 'at most', '>': 'more', '>=': 'at least',
  and: 'and', or: 'or', in: 'in',
};

export const OPERATORS = Object.keys(OPS);

// Above this many parts, an expression starts out as a line of code: a
// long formula drawn as nodes sprawls across the canvas and reads worse
// than the text. "Show as nodes" on it is remembered as the author's choice.
const CODE_THRESHOLD = 12;

function size(node) {
  let n = 1;
  childSlots(node).forEach(({ node: child }) => { n += size(child); });
  return n;
}

// A node shows as code when the author asked for it, when there is no
// sensible drawing of it (a lambda's body uses its own names; a template is
// text), or when it is a long formula the author hasn't asked to see drawn.
function asCode(node, prefs) {
  const choice = prefs.code[node.id];
  if (choice === true) return true;
  if (node.k === 'lambda' || node.k === 'tmpl') return true;
  if (choice === false) return false;
  return size(node) > CODE_THRESHOLD;
}

export function buildGraph(program, ctx) {
  // ctx: { catalog, layout: { pos: {}, code: {} }, sizes: {}, snippets: {} }
  const g = {
    nodes: [], wires: [], frames: [], codeIds: [], byId: {},
  };
  const known = {
    fns: Object.fromEntries(program.decls.filter((d) => d.k === 'fn').map((d) => [d.name, d])),
    actions: Object.fromEntries((ctx.catalog ? ctx.catalog.actions : []).map((a) => [a.name, a])),
    builtins: Object.fromEntries((ctx.catalog ? ctx.catalog.builtins : []).map((b) => [b.name, b])),
    setup: Object.fromEntries((ctx.catalog ? ctx.catalog.setup : []).map((s) => [s.name, s])),
  };
  const B = {
    g, ctx, known, decl: null, frame: null, index: indexProgram(program),
  };

  let y = 40;
  const X = 420;

  program.decls.forEach((decl) => {
    B.decl = decl.id;
    B.frame = decl.k === 'fn' ? decl.id : null;
    const saved = ctx.layout.pos[decl.id];
    const start = { x: X, y };
    let bottom;

    if (decl.k === 'draft') {
      bottom = drawDraft(B, decl, saved || start);
    } else {
      bottom = drawDecl(B, decl, saved || start);
    }

    // a declaration the author moved doesn't push the others down
    if (!saved) y = bottom + 70;
  });

  frames(g, ctx);
  return g;
}

// --- sizes and placement ------------------------------------------------------

function boxSize(B, node) {
  const measured = B.ctx.sizes[node.id];
  if (measured) return measured;
  const rows = Math.max(node.inputs.length + (node.fields || []).length, node.execOuts.filter((o) => o.side === 'right').length, 1);
  return { w: WIDTH[node.shape] || 200, h: HEADER + rows * ROW + 8 };
}

function place(B, node, auto) {
  const pos = B.ctx.layout.pos[node.id] || auto;
  node.x = pos.x;
  node.y = pos.y;
  node.moved = !!B.ctx.layout.pos[node.id];
  node.decl = B.decl;
  node.frame = B.frame;
  B.g.nodes.push(node);
  B.g.byId[node.id] = node;
  const s = boxSize(B, node);
  node.w = s.w;
  node.h = s.h;
  return node;
}

function wire(B, type, from, to) {
  B.g.wires.push({
    type, from, to, id: `${from.node}:${from.pin}->${to.node}:${to.pin}`,
  });
}

// --- declarations ----------------------------------------------------------------

const EVENT_TITLES = {
  on: (d) => `on ${d.event}`,
  every: () => 'every',
  at: () => 'at',
  when: () => 'when',
};

function drawDecl(B, decl, at) {
  const node = {
    id: decl.id,
    k: decl.k,
    shape: decl.k === 'note' ? 'note' : 'decl',
    tone: 'event',
    inputs: [],
    fields: [],
    execOuts: [],
    execIn: false,
    output: false,
    note: decl.note,
  };

  switch (decl.k) {
    case 'setup':
      node.title = 'Scenario setup';
      node.tone = 'setup';
      decl.body.forEach((s, i) => {
        if (s.k === 'assign' && s.target.k === 'ident') {
          const spec = B.known.setup[s.target.name];
          node.inputs.push({
            key: `row${i}`,
            label: s.target.name,
            slot: { pid: s.id, field: 'expr', index: null },
            type: spec ? spec.type : 'any',
            removable: s.id,
            doc: spec ? spec.doc : null,
          });
        }
      });
      node.addSetup = true;
      break;
    case 'score':
    case 'tiebreak':
      node.title = decl.k;
      node.tone = 'score';
      node.hint = decl.k === 'score' ? 'higher ranks first' : 'breaks ties: higher ranks first';
      node.inputs.push({
        key: 'expr', label: 'value', slot: { pid: decl.id, field: 'expr', index: null }, type: 'number',
      });
      break;
    case 'var':
      node.title = 'var';
      node.tone = 'data';
      node.fields.push({ key: 'name', value: decl.name, editor: 'name' });
      node.inputs.push({
        key: 'expr', label: 'starts at', slot: { pid: decl.id, field: 'expr', index: null }, type: 'any',
      });
      break;
    case 'fn':
      node.title = 'fn';
      node.tone = 'fn';
      node.fields.push({ key: 'name', value: decl.name, editor: 'name' });
      node.fields.push({ key: 'params', value: decl.params.join(', '), editor: 'params' });
      node.execOuts.push({ key: 'do', label: '', side: 'bottom' });
      break;
    case 'note':
      node.title = 'note';
      node.tone = 'note';
      node.text = decl.text;
      break;
    default:
      node.title = EVENT_TITLES[decl.k](decl);
      node.execOuts.push({ key: 'do', label: '', side: 'bottom' });
      if (decl.k === 'every') {
        node.inputs.push({
          key: 'interval', label: 'interval', slot: { pid: decl.id, field: 'interval', index: null }, type: 'number',
        });
        node.inputs.push({
          key: 'from', label: 'from', slot: { pid: decl.id, field: 'from', index: null }, type: 'number', optional: true,
        });
        node.inputs.push({
          key: 'until', label: 'until', slot: { pid: decl.id, field: 'until', index: null }, type: 'number', optional: true,
        });
        node.fields.push({ key: 'as', value: decl.as || '', editor: 'name', optional: true });
      } else if (decl.k === 'at') {
        node.inputs.push({
          key: 'time', label: 'time', slot: { pid: decl.id, field: 'time', index: null }, type: 'number',
        });
      } else if (decl.k === 'when') {
        node.inputs.push({
          key: 'cond', label: 'condition', slot: { pid: decl.id, field: 'cond', index: null }, type: 'bool',
        });
      }
  }

  place(B, node, at);
  let bottom = node.y + node.h;

  // inputs hang to the left
  bottom = Math.max(bottom, drawInputs(B, node));

  if (decl.k === 'fn' || ['on', 'every', 'at', 'when'].includes(decl.k)) {
    bottom = Math.max(bottom, drawChain(B, decl.body, { node: decl.id, pin: 'do' }, { x: node.x, y: node.y + node.h + GAP_Y }));
  }
  return bottom;
}

function drawDraft(B, draft, at) {
  // a draft holding one plain value floats as that value's node
  const [only] = draft.body;
  if (draft.body.length === 1 && only.k === 'expr' && !isStmtCall(B, only.expr)) {
    const n = drawExpr(B, only.expr, { node: null }, at);
    if (n) {
      n.draft = true;
      return n.bottom;
    }
  }
  return drawChain(B, draft.body, null, at, true);
}

function returnsValue(B, name) {
  const fn = B.known.fns[name];
  if (!fn) return true;
  const walk = (stmts) => stmts.some((st) => (st.k === 'return' && st.expr)
    || ['then', 'else', 'body'].some((f) => Array.isArray(st[f]) && walk(st[f])));
  return walk(fn.body);
}

function isStmtCall(B, e) {
  return e.k === 'call' && e.fn.k === 'ident' && (B.known.actions[e.fn.name] || B.known.fns[e.fn.name]);
}

// --- statements --------------------------------------------------------------------

// Draw a chain of statements going down from `at`; returns its bottom.
function drawChain(B, stmts, from, at, draft = false) {
  let prev = from;
  let cursor = { ...at };
  let bottom = at.y;

  stmts.forEach((stmt) => {
    const node = drawStmt(B, stmt, cursor);
    if (draft) node.draft = true;
    if (prev) wire(B, 'exec', prev, { node: stmt.id, pin: 'in' });
    prev = node.terminal ? null : { node: stmt.id, pin: 'then' };
    bottom = Math.max(bottom, node.bottom);
    cursor = { x: node.x, y: node.bottom + GAP_Y };
  });

  return bottom;
}

function drawStmt(B, stmt, at) {
  const node = {
    id: stmt.id,
    k: stmt.k,
    shape: 'stmt',
    tone: 'flow',
    inputs: [],
    fields: [],
    execIn: true,
    execOuts: [{ key: 'then', label: '', side: 'bottom' }],
    output: false,
    note: stmt.note,
  };
  const nested = [];

  if (B.ctx.layout.code[stmt.id] === true) {
    node.title = 'code';
    node.tone = 'code';
    node.code = B.ctx.snippets[stmt.id];
    node.codeKind = 'block';
    B.g.codeIds.push(stmt.id);
    place(B, node, at);
    node.bottom = node.y + node.h;
    return node;
  }

  switch (stmt.k) {
    case 'let':
      node.title = 'let';
      node.tone = 'data';
      node.fields.push({ key: 'name', value: stmt.name, editor: 'name' });
      node.inputs.push({
        key: 'expr', label: 'be', slot: { pid: stmt.id, field: 'expr', index: null }, type: 'any',
      });
      break;
    case 'assign': {
      node.title = 'set';
      node.tone = 'data';
      const target = pathText(stmt.target);
      if (stmt.target.k === 'ident') {
        node.fields.push({ key: 'target', value: stmt.target.name, editor: 'name' });
      } else {
        node.inputs.push({
          key: 'target', label: 'target', slot: { pid: stmt.id, field: 'target', index: null }, type: 'any', forceCode: true,
        });
        node.targetText = target;
      }
      node.inputs.push({
        key: 'expr', label: 'to', slot: { pid: stmt.id, field: 'expr', index: null }, type: 'any',
      });
      break;
    }
    case 'if':
      node.title = 'if';
      node.inputs.push({
        key: 'cond', label: 'condition', slot: { pid: stmt.id, field: 'cond', index: null }, type: 'bool',
      });
      node.execOuts = [
        { key: 'true', label: 'true', side: 'right' },
        { key: 'false', label: 'false', side: 'right' },
        { key: 'then', label: 'after', side: 'bottom' },
      ];
      nested.push(['true', stmt.then], ['false', stmt.else || []]);
      break;
    case 'for':
      node.title = 'for each';
      node.fields.push({ key: 'var', value: stmt.var, editor: 'name' });
      node.inputs.push({
        key: 'iter', label: 'in', slot: { pid: stmt.id, field: 'iter', index: null }, type: 'list',
      });
      node.execOuts = [
        { key: 'body', label: 'each', side: 'right' },
        { key: 'then', label: 'after', side: 'bottom' },
      ];
      nested.push(['body', stmt.body]);
      break;
    case 'while':
      node.title = 'while';
      node.inputs.push({
        key: 'cond', label: 'condition', slot: { pid: stmt.id, field: 'cond', index: null }, type: 'bool',
      });
      node.execOuts = [
        { key: 'body', label: 'repeat', side: 'right' },
        { key: 'then', label: 'after', side: 'bottom' },
      ];
      nested.push(['body', stmt.body]);
      break;
    case 'return':
      node.title = 'return';
      node.execOuts = [];
      node.terminal = true;
      node.inputs.push({
        key: 'expr', label: 'value', slot: { pid: stmt.id, field: 'expr', index: null }, type: 'any', optional: true,
      });
      break;
    case 'break':
    case 'continue':
      node.title = stmt.k;
      node.execOuts = [];
      node.terminal = true;
      break;
    case 'note':
      node.title = 'note';
      node.tone = 'note';
      node.shape = 'note';
      node.text = stmt.text;
      break;
    case 'expr': {
      const e = stmt.expr;
      if (e.k === 'call' && e.fn.k === 'ident' && !asCode(e, B.ctx.layout)) {
        // a call standing as a statement is drawn as the call itself; its
        // node id stays the statement's so exec wires find it
        callPins(B, node, e);
        node.exprId = e.id;
        // a step offers its result only if there is one: a builtin, or a fn
        // that returns a value
        node.output = !B.known.actions[e.fn.name] && returnsValue(B, e.fn.name);
      } else {
        node.title = 'evaluate';
        node.inputs.push({
          key: 'expr', label: 'value', slot: { pid: stmt.id, field: 'expr', index: null }, type: 'any',
        });
      }
      break;
    }
    default:
      node.title = stmt.k;
  }

  place(B, node, at);
  let bottom = Math.max(node.y + node.h, drawInputs(B, node));

  // inner chains go off to the right, one under the other
  let ny = node.y;
  nested.forEach(([pin, body]) => {
    const start = { x: node.x + node.w + BRANCH_X, y: ny };
    const end = body.length ? drawChain(B, body, { node: stmt.id, pin }, start) : start.y + 30;
    ny = end + GAP_Y;
    bottom = Math.max(bottom, end);
  });

  node.bottom = bottom;
  return node;
}

// A call's pins: positional parameters, then name: values.
function callPins(B, node, call) {
  const name = call.fn.name;
  const action = B.known.actions[name];
  const builtin = B.known.builtins[name];
  const userFn = B.known.fns[name];
  const sig = action || builtin;

  node.title = name;
  node.callName = name;
  node.tone = action ? 'action' : (userFn ? 'fn' : 'value');
  node.doc = sig ? sig.doc : null;

  if (sig) {
    const rest = sig.params.find((p) => p.rest);
    const fixed = sig.params.filter((p) => !p.rest);
    fixed.forEach((p, i) => {
      if (i < call.args.length || !p.optional) {
        node.inputs.push({
          key: `a${i}`,
          label: p.name,
          slot: { pid: call.id, field: 'args', index: i },
          type: p.type,
          missing: i >= call.args.length,
        });
      }
    });
    call.args.slice(fixed.length).forEach((_, j) => {
      const i = fixed.length + j;
      node.inputs.push({
        key: `a${i}`, label: rest ? `${rest.name} ${j + 1}` : `extra ${j + 1}`, slot: { pid: call.id, field: 'args', index: i }, type: rest ? rest.type : 'any',
      });
    });
    if (rest) node.addArg = call.id;

    (sig.named || []).forEach((p) => {
      const at = call.named.findIndex((n) => n.name === p.name);
      node.inputs.push({
        key: `n_${p.name}`,
        label: `${p.name}:`,
        slot: at === -1 ? null : {
          pid: call.id, field: 'named', index: at, sub: 'expr',
        },
        type: p.type,
        named: p.name,
        callId: call.id,
        optional: true,
      });
    });
  } else {
    const params = userFn ? userFn.params : call.args.map((_, i) => `value ${i + 1}`);
    params.forEach((p, i) => {
      node.inputs.push({
        key: `a${i}`, label: p, slot: { pid: call.id, field: 'args', index: i }, type: 'any', missing: i >= call.args.length,
      });
    });
  }
}

// --- expressions -------------------------------------------------------------------

// Draw the inputs of `node` (whose tree node is `owner`): every input holding
// more than a plain value gets a node of its own, placed to the left.
// Returns the bottom of what was drawn.
function drawInputs(B, node) {
  let bottom = node.y + node.h;
  let cursorY = node.y;

  node.inputs.forEach((input, i) => {
    const value = input.slot ? readSlot(B, input.slot) : null;
    input.value = value;

    if (!value) {
      input.editor = 'empty';
      return;
    }
    if (isLiteral(value)) {
      input.editor = 'literal';
      return;
    }
    if (input.forceCode || asCode(value, B.ctx.layout)) {
      input.editor = 'code';
      input.codeId = value.id;
      input.expandable = !input.forceCode && value.k !== 'lambda' && value.k !== 'tmpl';
      input.code = B.ctx.snippets[value.id];
      B.g.codeIds.push(value.id);
      return;
    }

    const pinY = node.y + HEADER + i * ROW;
    const at = { x: node.x - GAP_X - WIDTH.expr, y: Math.max(pinY - 8, cursorY) };
    const child = drawExpr(B, value, { node: node.id, pin: input.key }, at);
    if (child) {
      input.editor = 'wired';
      input.childId = value.id;
      cursorY = child.bottom + 12;
      bottom = Math.max(bottom, child.bottom);
    }
  });

  return bottom;
}

// An input's current value (null when the slot is empty or gone).
function readSlot(B, slot) {
  if (!B.index.byId[slot.pid]) return null;
  try {
    return getSlot(B.index, slot) || null;
  } catch (e) {
    return null;
  }
}

function drawExpr(B, e, to, at) {
  const node = {
    id: e.id,
    k: e.k,
    shape: 'expr',
    tone: 'value',
    inputs: [],
    fields: [],
    execIn: false,
    execOuts: [],
    output: true,
  };

  const path = pathText(e);
  if (path && e.k === 'field') {
    node.title = path;
    node.shape = 'path';
    node.tone = path.split('.')[0] in { player: 1, time: 1, rival: 1, scenario: 1 } ? 'world' : 'data';
    node.headField = { key: 'path', value: path, editor: 'path' };
    node.doc = (B.ctx.catalog && B.ctx.catalog.world_docs[path]) || null;
  } else {
    switch (e.k) {
      case 'ident':
        node.title = e.name;
        node.shape = 'get';
        node.tone = ['player', 'time', 'rival', 'scenario'].includes(e.name) ? 'world' : 'data';
        node.headField = { key: 'path', value: e.name, editor: 'path' };
        break;
      case 'call':
        if (e.fn.k === 'ident') {
          callPins(B, node, e);
        } else {
          node.title = 'call';
        }
        break;
      case 'bin':
        node.title = e.op;
        node.shape = 'op';
        node.tone = 'logic';
        node.headField = { key: 'op', value: e.op, editor: 'op' };
        node.inputs.push({
          key: 'l', label: '', slot: { pid: e.id, field: 'l', index: null }, type: 'any',
        });
        node.inputs.push({
          key: 'r', label: '', slot: { pid: e.id, field: 'r', index: null }, type: 'any',
        });
        break;
      case 'un':
        node.title = e.op === 'not' ? 'not' : 'negate';
        node.shape = 'op';
        node.tone = 'logic';
        node.inputs.push({
          key: 'e', label: '', slot: { pid: e.id, field: 'e', index: null }, type: e.op === 'not' ? 'bool' : 'number',
        });
        break;
      case 'cond':
        node.title = 'if … then … else';
        node.tone = 'logic';
        node.inputs.push({
          key: 'cond', label: 'if', slot: { pid: e.id, field: 'cond', index: null }, type: 'bool',
        });
        node.inputs.push({
          key: 'then', label: 'then', slot: { pid: e.id, field: 'then', index: null }, type: 'any',
        });
        node.inputs.push({
          key: 'else', label: 'else', slot: { pid: e.id, field: 'else', index: null }, type: 'any',
        });
        break;
      case 'list':
        node.title = 'list';
        node.tone = 'data';
        e.items.forEach((_, i) => node.inputs.push({
          key: `i${i}`, label: `${i}`, slot: { pid: e.id, field: 'items', index: i }, type: 'any', removable: true,
        }));
        node.addItem = e.id;
        break;
      case 'map':
        node.title = 'record';
        node.tone = 'data';
        e.entries.forEach((entry, i) => node.inputs.push({
          key: `e${i}`,
          label: `${entry.key}:`,
          slot: {
            pid: e.id, field: 'entries', index: i, sub: 'value',
          },
          type: 'any',
        }));
        node.addEntry = e.id;
        break;
      case 'index':
        node.title = 'item at';
        node.tone = 'data';
        node.inputs.push({
          key: 'obj', label: 'of', slot: { pid: e.id, field: 'obj', index: null }, type: 'list',
        });
        node.inputs.push({
          key: 'index', label: 'position', slot: { pid: e.id, field: 'index', index: null }, type: 'number',
        });
        break;
      case 'field':
        node.title = `.${e.name}`;
        node.tone = 'data';
        node.inputs.push({
          key: 'obj', label: 'of', slot: { pid: e.id, field: 'obj', index: null }, type: 'record',
        });
        break;
      default:
        node.title = e.k;
    }
  }

  place(B, node, at);
  if (to && to.node) wire(B, 'data', { node: e.id, pin: 'out' }, to);
  node.bottom = Math.max(node.y + node.h, drawInputs(B, node));
  return node;
}

// --- frames ------------------------------------------------------------------------

// Each fn gets a box around its nodes: the bounding box of everything drawn
// for it, padded, with room for the title.
function frames(g, ctx) {
  const byFrame = {};
  g.nodes.forEach((n) => {
    if (!n.frame) return;
    (byFrame[n.frame] = byFrame[n.frame] || []).push(n);
  });

  Object.keys(byFrame).forEach((fnId) => {
    const nodes = byFrame[fnId];
    const pad = 24;
    const x0 = Math.min(...nodes.map((n) => n.x)) - pad;
    const y0 = Math.min(...nodes.map((n) => n.y)) - pad - 26;
    const x1 = Math.max(...nodes.map((n) => n.x + n.w)) + pad;
    const y1 = Math.max(...nodes.map((n) => n.y + n.h)) + pad;
    const head = nodes.find((n) => n.id === fnId);
    g.frames.push({
      id: fnId,
      x: x0,
      y: y0,
      w: x1 - x0,
      h: y1 - y0,
      title: head ? `fn ${head.fields[0].value}(${head.fields[1].value})` : 'fn',
      collapsed: !!ctx.layout.collapsed && !!ctx.layout.collapsed[fnId],
    });
  });
}

export function nodeKindOf(node) {
  return node.execIn ? 'stmt' : node.k;
}
