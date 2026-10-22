// The Scenario Workshop edits Edict's canonical tree (lib/edict/ast.ex)
// directly: the node graph is a drawing of this tree, and every gesture on
// the graph is one of the edits below. The server owns parsing, printing and
// checking; this module only reshapes trees, so it never needs to know the
// language's text form.
//
// Edits are pure: each takes a program and returns a new one (the old one is
// kept for undo). Programs are small, so a deep copy per edit is cheap.

let counter = 0;

export function newId() {
  counter += 1;
  return `c${Date.now().toString(36).slice(-5)}${counter.toString(36)}`;
}

export function clone(tree) {
  return JSON.parse(JSON.stringify(tree));
}

// Child fields per kind, mirroring Edict.AST's table:
// expr (one), opt (one or null), exprs (list), block (statements),
// optblock (statements or null), named (name: value list),
// entries (record entries), parts (template parts).
export const FIELDS = {
  setup: { body: 'block' },
  score: { expr: 'expr' },
  tiebreak: { expr: 'expr' },
  var: { expr: 'expr' },
  fn: { body: 'block' },
  on: { body: 'block' },
  every: {
    interval: 'expr', from: 'opt', until: 'opt', body: 'block',
  },
  at: { time: 'expr', body: 'block' },
  when: { cond: 'expr', body: 'block' },
  draft: { body: 'block' },
  note: {},
  let: { expr: 'expr' },
  assign: { target: 'expr', expr: 'expr' },
  if: { cond: 'expr', then: 'block', else: 'optblock' },
  for: { iter: 'expr', body: 'block' },
  while: { cond: 'expr', body: 'block' },
  return: { expr: 'opt' },
  break: {},
  continue: {},
  expr: { expr: 'expr' },
  num: {},
  str: {},
  tmpl: { parts: 'parts' },
  bool: {},
  nil_lit: {},
  hole: {},
  ident: {},
  field: { obj: 'expr' },
  index: { obj: 'expr', index: 'expr' },
  call: { fn: 'expr', args: 'exprs', named: 'named' },
  bin: { l: 'expr', r: 'expr' },
  un: { e: 'expr' },
  list: { items: 'exprs' },
  map: { entries: 'entries' },
  lambda: { body: 'expr' },
  cond: { cond: 'expr', then: 'expr', else: 'expr' },
};

const DECLS = ['setup', 'score', 'tiebreak', 'var', 'fn', 'on', 'every', 'at', 'when', 'draft'];
const STMTS = ['let', 'assign', 'if', 'for', 'while', 'return', 'break', 'continue', 'expr', 'note'];
export const LITERALS = ['num', 'str', 'bool', 'nil_lit', 'hole'];

export const isDecl = (n) => n && DECLS.includes(n.k);
export const isStmt = (n) => n && STMTS.includes(n.k);
export const isExpr = (n) => n && !DECLS.includes(n.k) && !STMTS.includes(n.k);
export const isLiteral = (n) => n && LITERALS.includes(n.k);

// --- reading -----------------------------------------------------------------

// Every child of a node with the slot it sits in: { node, slot } where a slot
// is { pid, field, index } (index null for single fields).
export function childSlots(node) {
  const out = [];
  const fields = FIELDS[node.k] || {};

  Object.keys(fields).forEach((field) => {
    const type = fields[field];
    const value = node[field];
    if (value === null || value === undefined) return;

    if (type === 'expr' || type === 'opt') {
      out.push({ node: value, slot: { pid: node.id, field, index: null } });
    } else if (type === 'exprs' || type === 'block' || type === 'optblock') {
      value.forEach((child, index) => out.push({ node: child, slot: { pid: node.id, field, index } }));
    } else if (type === 'named') {
      value.forEach((n, index) => out.push({ node: n.expr, slot: { pid: node.id, field, index, sub: 'expr' } }));
    } else if (type === 'entries') {
      value.forEach((e, index) => out.push({ node: e.value, slot: { pid: node.id, field, index, sub: 'value' } }));
    } else if (type === 'parts') {
      value.forEach((p, index) => {
        if (p && typeof p === 'object') out.push({ node: p, slot: { pid: node.id, field, index } });
      });
    }
  });

  return out;
}

// An index over a program: nodes by id, the slot each sits in, its decl.
export function indexProgram(program) {
  const byId = {};
  const slotOf = {};
  const declOf = {};
  const root = { k: 'program', id: '$root' };
  byId.$root = program;

  program.decls.forEach((decl, i) => {
    slotOf[decl.id] = { pid: '$root', field: 'decls', index: i };
    const visit = (node) => {
      byId[node.id] = node;
      declOf[node.id] = decl.id;
      childSlots(node).forEach(({ node: child, slot }) => {
        slotOf[child.id] = slot;
        visit(child);
      });
    };
    visit(decl);
  });

  return {
    byId, slotOf, declOf, root,
  };
}

export function getSlot(index, slot) {
  const parent = index.byId[slot.pid];
  const value = parent[slot.field];
  if (slot.index === null || slot.index === undefined) return value;
  if (slot.sub) return value[slot.index][slot.sub];
  return value[slot.index];
}

function setSlot(index, slot, node) {
  const parent = index.byId[slot.pid];
  if (slot.index === null || slot.index === undefined) {
    parent[slot.field] = node;
  } else if (slot.sub) {
    parent[slot.field][slot.index][slot.sub] = node;
  } else {
    parent[slot.field][slot.index] = node;
  }
}

// Every id in a subtree.
export function subtreeIds(node, acc = new Set()) {
  if (!node || typeof node !== 'object') return acc;
  if (node.id) acc.add(node.id);
  childSlots(node).forEach(({ node: child }) => subtreeIds(child, acc));
  return acc;
}

// A field chain rooted at a name (player.income.credit), as its path text,
// or null.
export function pathText(node) {
  if (node.k === 'ident') return node.name;
  if (node.k === 'field') {
    const inner = pathText(node.obj);
    return inner ? `${inner}.${node.name}` : null;
  }
  return null;
}

// --- building ------------------------------------------------------------------

export const mk = {
  num: (v, unit = null) => ({
    k: 'num', id: newId(), v, unit,
  }),
  str: (v) => ({ k: 'str', id: newId(), v }),
  bool: (v) => ({ k: 'bool', id: newId(), v }),
  nil: () => ({ k: 'nil_lit', id: newId() }),
  hole: () => ({ k: 'hole', id: newId() }),
  ident: (name) => ({ k: 'ident', id: newId(), name }),
  path(text) {
    const [root, ...fields] = text.split('.');
    return fields.reduce((obj, name) => ({
      k: 'field', id: newId(), obj, name,
    }), mk.ident(root));
  },
  call: (name, args = [], named = []) => ({
    k: 'call', id: newId(), fn: mk.ident(name), args, named,
  }),
  bin: (op, l = mk.hole(), r = mk.hole()) => ({
    k: 'bin', id: newId(), op, l, r,
  }),
  un: (op, e = mk.hole()) => ({
    k: 'un', id: newId(), op, e,
  }),
  cond: () => ({
    k: 'cond', id: newId(), cond: mk.hole(), then: mk.hole(), else: mk.hole(),
  }),
  list: () => ({ k: 'list', id: newId(), items: [] }),
  map: () => ({ k: 'map', id: newId(), entries: [] }),
  stmt: (expr) => ({ k: 'expr', id: newId(), expr }),
};

// A literal from what was typed into a pin, read with the pin's type: a
// number pin understands 15s, 2m, 25%; an enum pin keeps the choice; text
// stays text.
export function literalFrom(text, type) {
  const raw = String(text).trim();
  if (type === 'bool') return mk.bool(raw === 'true');
  if (type === 'text' || (type && type.enum)) return mk.str(String(text));
  if (raw === '') return mk.hole();
  if (raw === 'true' || raw === 'false') return mk.bool(raw === 'true');
  if (raw === 'nil') return mk.nil();

  const pct = raw.match(/^(-?\d[\d_]*(?:\.\d+)?)%$/);
  if (pct) return mk.num(Number(pct[1].replace(/_/g, '')) / 100, 'percent');

  const dur = raw.match(/^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$/);
  if (dur && (dur[1] || dur[2] || dur[3])) {
    const secs = (Number(dur[1] || 0) * 3600) + (Number(dur[2] || 0) * 60) + Number(dur[3] || 0);
    return mk.num(secs, 'duration');
  }

  const n = Number(raw.replace(/_/g, ''));
  if (raw !== '' && Number.isFinite(n)) return mk.num(n);
  if (type === 'number') return mk.hole();
  return mk.str(String(text));
}

// How a literal reads in a pin.
export function literalText(node) {
  if (!node) return '';
  switch (node.k) {
    case 'num': {
      if (node.unit === 'percent') return `${+(node.v * 100).toFixed(6)}%`;
      if (node.unit === 'duration' && node.v >= 0 && Number.isInteger(node.v)) {
        const h = Math.floor(node.v / 3600);
        const m = Math.floor((node.v % 3600) / 60);
        const s = node.v % 60;
        return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join('') || '0s';
      }
      if (node.unit === 'duration') return `${node.v}s`;
      return String(node.v);
    }
    case 'str': return node.v;
    case 'bool': return node.v ? 'true' : 'false';
    case 'nil_lit': return 'nil';
    default: return '';
  }
}

// --- editing ---------------------------------------------------------------------

function addDraft(program, stmts) {
  const draft = { k: 'draft', id: newId(), body: stmts };
  program.decls.push(draft);
  return draft;
}

// Drop drafts that ran empty.
function prune(program) {
  program.decls = program.decls.filter((d) => d.k !== 'draft' || d.body.length > 0);
  return program;
}

// Wrap an expression as a statement when it lands in a statement list.
function asStmt(node) {
  return isStmt(node) ? node : mk.stmt(node);
}

// Remove a statement (and those after it, with `tail`) from its block.
function cutStatements(program, index, id, tail) {
  const slot = index.slotOf[id];
  const block = index.byId[slot.pid][slot.field];
  return block.splice(slot.index, tail ? block.length - slot.index : 1);
}

// Where an exec pin leads: its block and the position to insert at.
function execTarget(index, ownerId, pin) {
  const owner = index.byId[ownerId];
  if (pin === 'next') {
    const slot = index.slotOf[ownerId];
    return { block: index.byId[slot.pid][slot.field], at: slot.index + 1 };
  }
  const field = { do: 'body', body: 'body', true: 'then', false: 'else' }[pin] || pin;
  if (!owner[field]) owner[field] = [];
  return { block: owner[field], at: 0 };
}

// Connect an exec pin to a statement: the statement and everything after it
// in its chain move to the pin, spliced in before whatever followed the pin.
export function connectExec(program, { node: ownerId, pin }, stmtId) {
  const p = clone(program);
  let index = indexProgram(p);
  const stmt = index.byId[stmtId];
  if (!isStmt(stmt)) return { program, error: 'only a statement can follow an exec pin' };

  const slot = index.slotOf[stmtId];
  const moving = index.byId[slot.pid][slot.field].slice(slot.index);
  const movingIds = new Set();
  moving.forEach((s) => subtreeIds(s, movingIds));
  if (movingIds.has(ownerId)) return { program, error: "a chain can't be connected into itself" };

  const tail = cutStatements(p, index, stmtId, true);
  index = indexProgram(p);
  const { block, at } = execTarget(index, ownerId, pin);
  block.splice(at, 0, ...tail);
  return { program: prune(p) };
}

// Detach everything an exec pin leads to into a draft.
export function detachExec(program, { node: ownerId, pin }) {
  const p = clone(program);
  const index = indexProgram(p);
  const { block, at } = execTarget(index, ownerId, pin);
  const tail = block.splice(at, block.length - at);
  if (tail.length === 0) return { program };
  const draft = addDraft(p, tail);
  return { program: prune(p), draftId: draft.id, firstId: tail[0].id };
}

// Cut a statement and everything after it out of its chain, into a draft.
export function detachChainAt(program, stmtId) {
  const p = clone(program);
  const index = indexProgram(p);
  if (!isStmt(index.byId[stmtId])) return { program };
  const tail = cutStatements(p, index, stmtId, true);
  const draft = addDraft(p, tail);
  return { program: prune(p), draftId: draft.id };
}

// A copy of a subtree with fresh ids, as a new draft.
export function duplicate(program, id) {
  const p = clone(program);
  const index = indexProgram(p);
  const copy = clone(index.byId[id]);
  const renumber = (node) => {
    if (!node || typeof node !== 'object') return;
    if (node.id) node.id = newId();
    childSlots(node).forEach(({ node: child }) => renumber(child));
  };
  renumber(copy);
  if (isDecl(copy)) {
    if (copy.name) copy.name = `${copy.name}_copy`;
    p.decls.push(copy);
    return { program: p, id: copy.id };
  }
  const draft = addDraft(p, [asStmt(copy)]);
  return { program: p, id: copy.id, draftId: draft.id };
}

// Rename a var or fn and every use of it, unless a local somewhere uses the
// same name (then only the declaration changes, and the checker points at
// what broke).
export function renameGlobal(program, id, newName) {
  const p = clone(program);
  const index = indexProgram(p);
  const decl = index.byId[id];
  const old = decl.name;
  const locals = new Set();
  Object.values(index.byId).forEach((n) => {
    if (n.k === 'let') locals.add(n.name);
    if (n.k === 'for') locals.add(n.var);
    if (n.k === 'fn' || n.k === 'lambda') (n.params || []).forEach((x) => locals.add(x));
    if (n.k === 'every' && n.as) locals.add(n.as);
  });
  decl.name = newName;
  if (!locals.has(old)) {
    Object.values(index.byId).forEach((n) => {
      if (n.k === 'ident' && n.name === old) n.name = newName;
      if (n.k === 'assign' && n.target.k === 'ident' && n.target.name === old) n.target.name = newName;
    });
  }
  return { program: p };
}

// Move an expression into an input slot. What sat there before goes to a
// draft (unless it was a plain value); the expression's old place becomes a
// hole, or closes up if it was a statement in a chain.
export function connectData(program, exprId, slot) {
  const p = clone(program);
  let index = indexProgram(p);
  const moving = index.byId[exprId];
  if (!moving) return { program, error: 'nothing to connect' };
  if (subtreeIds(moving).has(slot.pid)) return { program, error: "a value can't feed itself" };

  const fromSlot = index.slotOf[exprId];
  const fromParent = index.byId[fromSlot.pid];

  if (fromParent.k === 'expr' && isStmt(fromParent)) {
    // a call standing as a statement: take it out of its chain
    cutStatements(p, index, fromParent.id, false);
  } else {
    setSlot(index, fromSlot, mk.hole());
  }

  index = indexProgram(p);
  const old = getSlot(index, slot);
  // What the new value replaces goes to a draft, so no work is lost, unless
  // it was a plain value or a single path (player.credit): a newcomer
  // replacing the score's input expects the old one gone, not loose.
  if (old && !isLiteral(old) && !pathText(old)) addDraft(p, [asStmt(old)]);
  setSlot(index, slot, moving);
  return { program: prune(p) };
}

// Pull a value out of an input into a draft, leaving the input empty.
export function detachData(program, slot) {
  const p = clone(program);
  const index = indexProgram(p);
  const old = getSlot(index, slot);
  if (!old || isLiteral(old)) return { program };
  setSlot(index, slot, mk.hole());
  const draft = addDraft(p, [asStmt(old)]);
  return { program: prune(p), draftId: draft.id, nodeId: old.id };
}

// Put a literal (or a rebuilt subtree) into a slot.
export function setSlotValue(program, slot, node) {
  const p = clone(program);
  const index = indexProgram(p);
  setSlot(index, slot, node);
  return { program: p };
}

// Change a node's own fields (a name, an operator, an `as`).
export function setFields(program, id, fields) {
  const p = clone(program);
  const index = indexProgram(p);
  Object.assign(index.byId[id], fields);
  return { program: p };
}

// Replace a node by another tree (a code node's re-parsed text). A statement
// may become several.
export function replaceNode(program, id, replacement) {
  const p = clone(program);
  const index = indexProgram(p);
  const slot = index.slotOf[id];
  if (Array.isArray(replacement)) {
    const block = index.byId[slot.pid][slot.field];
    block.splice(slot.index, 1, ...replacement.map(asStmt));
  } else {
    setSlot(index, slot, replacement);
  }
  return { program: prune(p) };
}

export function deleteNodes(program, ids) {
  const p = clone(program);
  ids.forEach((id) => {
    const index = indexProgram(p);
    const node = index.byId[id];
    if (!node || id === '$root') return;
    const slot = index.slotOf[id];
    const parent = index.byId[slot.pid];

    if (isDecl(node) || (node.k === 'note' && slot.pid === '$root')) {
      p.decls.splice(slot.index, 1);
    } else if (isStmt(node)) {
      parent[slot.field].splice(slot.index, 1);
    } else if (parent.k === 'expr' && isStmt(parent)) {
      // an expression standing alone as a statement goes with it
      const s = index.slotOf[parent.id];
      index.byId[s.pid][s.field].splice(s.index, 1);
    } else if (slot.field === 'items' || slot.field === 'args') {
      parent[slot.field].splice(slot.index, 1);
    } else if (slot.field === 'named' || slot.field === 'entries') {
      parent[slot.field].splice(slot.index, 1);
    } else {
      setSlot(index, slot, mk.hole());
    }
  });
  return { program: prune(p) };
}

// A new, unconnected piece: statements and expressions start in a draft;
// declarations go before the drafts.
export function addPiece(program, piece) {
  const p = clone(program);
  if (isDecl(piece) && piece.k !== 'draft') {
    const firstDraft = p.decls.findIndex((d) => d.k === 'draft');
    p.decls.splice(firstDraft === -1 ? p.decls.length : firstDraft, 0, piece);
    return { program: p, id: piece.id };
  }
  const draft = addDraft(p, [asStmt(piece)]);
  return { program: p, id: piece.id, draftId: draft.id };
}

// Add a value to a list, a record or a call's rest values.
export function appendItem(program, id, field, item) {
  const p = clone(program);
  const index = indexProgram(p);
  index.byId[id][field].push(item);
  return { program: p };
}

// --- group into a function ------------------------------------------------------------

const RESERVED = ['player', 'time', 'rival', 'scenario'];

// The names an expression or statement reads without defining them.
function freeNames(node, bound, out) {
  if (!node || typeof node !== 'object') return out;
  if (node.k === 'ident' && !bound.has(node.name)) out.push(node.name);
  if (node.k === 'lambda') {
    const inner = new Set([...bound, ...node.params]);
    freeNames(node.body, inner, out);
    return out;
  }
  if (node.k === 'call' && node.fn.k === 'ident') {
    // the callee's own name isn't a value read
    node.args.forEach((a) => freeNames(a, bound, out));
    node.named.forEach((n) => freeNames(n.expr, bound, out));
    return out;
  }
  childSlots(node).forEach(({ node: child }) => freeNames(child, bound, out));
  return out;
}

// Turn a run of statements in one chain into a fn: the run moves into the
// fn's body, a call takes its place, and the names it reads from around it
// become the fn's parameters. Returns { program, fnId } or { error }.
export function groupIntoFunction(program, ids, name, known) {
  const p = clone(program);
  const index = indexProgram(p);
  const slots = ids.map((id) => ({ id, slot: index.slotOf[id] }));
  if (slots.some(({ id }) => !isStmt(index.byId[id]))) return { error: 'select statements (the nodes in a chain) to group' };

  const { pid, field } = slots[0].slot;
  if (slots.some(({ slot }) => slot.pid !== pid || slot.field !== field)) {
    return { error: 'the selected nodes must be in one chain' };
  }
  const positions = slots.map(({ slot }) => slot.index).sort((a, b) => a - b);
  if (positions[positions.length - 1] - positions[0] !== positions.length - 1) {
    return { error: 'the selected nodes must follow each other in the chain' };
  }

  const block = index.byId[pid][field];
  const run = block.slice(positions[0], positions[0] + positions.length);

  // names defined inside the run (let, for) are its own
  const defined = new Set();
  run.forEach((s) => subtreeIds(s).forEach((id) => {
    const n = index.byId[id];
    if (n && n.k === 'let') defined.add(n.name);
    if (n && n.k === 'for') defined.add(n.var);
  }));

  const globals = new Set([...known.globals, ...known.fns, ...known.library, ...RESERVED]);
  const reads = [];
  run.forEach((s) => freeNames(s, new Set(), reads));
  const params = [...new Set(reads.filter((n) => !defined.has(n) && !globals.has(n)))];

  // a local from outside that the run changes can't come back out
  const assigned = [];
  run.forEach((s) => subtreeIds(s).forEach((id) => {
    const n = index.byId[id];
    if (n && n.k === 'assign') {
      let t = n.target;
      while (t.k !== 'ident') t = t.obj;
      if (!defined.has(t.name) && !known.globals.includes(t.name)) assigned.push(t.name);
    }
  }));
  if (assigned.length) {
    return { error: `can't group: it changes ${[...new Set(assigned)].join(', ')}, which belongs to the code around it` };
  }

  const fn = {
    k: 'fn', id: newId(), name, params, body: run,
  };
  const callStmt = mk.stmt(mk.call(name, params.map((n) => mk.ident(n))));
  block.splice(positions[0], positions.length, callStmt);

  const firstDraft = p.decls.findIndex((d) => d.k === 'draft');
  p.decls.splice(firstDraft === -1 ? p.decls.length : firstDraft, 0, fn);
  return { program: p, fnId: fn.id, callId: callStmt.id };
}

// --- carrying ids across a re-parse -------------------------------------------------

// The server's parser numbers nodes afresh. To keep the graph's layout when
// the text view is edited, match the new tree against the old one by
// position and kind, and give matched nodes their old ids back. Unmatched
// nodes get fresh ids, so no id is ever shared.
export function reconcileIds(oldProgram, newProgram) {
  const p = clone(newProgram);
  const renumber = (node) => {
    if (!node || typeof node !== 'object') return;
    if (node.id) node.id = newId();
    childSlots(node).forEach(({ node: child }) => renumber(child));
  };
  p.decls.forEach(renumber);
  if (!oldProgram) return p;

  const match = (a, b) => {
    if (!a || !b || a.k !== b.k) return;
    b.id = a.id;
    const ac = childSlots(a);
    const bc = childSlots(b);
    bc.forEach(({ node, slot }) => {
      const twin = ac.find(({ slot: s }) => s.field === slot.field && s.index === slot.index);
      if (twin) match(twin.node, node);
    });
  };

  // declarations: by kind and name where they have one, else by order of kind
  const used = new Set();
  p.decls.forEach((decl) => {
    const twin = oldProgram.decls.find((d) => !used.has(d.id) && d.k === decl.k
      && (decl.name === undefined || d.name === decl.name)
      && (decl.event === undefined || d.event === decl.event));
    if (twin) {
      used.add(twin.id);
      match(twin, decl);
    }
  });
  return p;
}

// Names a program defines at the top: vars and fns.
export function topNames(program) {
  return {
    globals: program.decls.filter((d) => d.k === 'var').map((d) => d.name),
    fns: program.decls.filter((d) => d.k === 'fn').map((d) => d.name),
  };
}
