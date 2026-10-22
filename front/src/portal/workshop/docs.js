// The workshop's view of the language docs (Edict.Docs, in the catalog as
// `docs`): which entry a node on the canvas is, and the reference list.

// The docs key for a drawn node: `builtin:sum`, `action:give`, `event:every`,
// `operator:in`, `world:player.patents`, `node:for_each`, `fn:<yours>`.
export function nodeDocKey(node, ast, catalog) {
  if (node.docKey) return node.docKey;
  if (!ast) return null;
  if (node.title === 'code') return 'node:code';
  const isBuiltin = (name) => catalog.builtins.some((b) => b.name === name);
  const isAction = (name) => catalog.actions.some((a) => a.name === name);
  const callKey = (call) => {
    const name = call.fn && call.fn.name;
    if (!name) return 'node:call';
    if (isBuiltin(name)) return `builtin:${name}`;
    if (isAction(name)) return `action:${name}`;
    return `fn:${name}`;
  };
  switch (ast.k) {
    case 'expr': return ast.expr && ast.expr.k === 'call' ? callKey(ast.expr) : 'node:unused_value';
    case 'call': return callKey(ast);
    case 'field': {
      const root = String(node.title).split('.')[0];
      return catalog.world[root] ? `world:${node.title}` : 'node:field';
    }
    case 'ident': return catalog.world[ast.name] ? `world:${ast.name}` : null;
    case 'bin': return `operator:${ast.op}`;
    case 'un': return ast.op === 'not' ? 'operator:not' : 'operator:negate';
    case 'on': return `event:on_${ast.event}`;
    case 'every':
    case 'at':
    case 'when': return `event:${ast.k}`;
    case 'assign': return 'node:set';
    case 'for': return 'node:for_each';
    case 'index': return 'node:item_at';
    case 'map': return 'node:record';
    case 'tmpl': return 'node:template';
    case 'cond': return 'node:if_then_else';
    default: return `node:${ast.k}`;
  }
}

// The docs key for an item of the node list (Palette.vue).
const STMT_KEYS = {
  if: 'node:if', for: 'node:for_each', while: 'node:while', let: 'node:let', assign: 'node:set', return: 'node:return', break: 'keyword:break', note: 'node:note', code: 'node:code',
};
const VALUE_KEYS = { cond: 'node:if_then_else', list: 'node:list', map: 'node:record' };

export function paletteDocKey(item) {
  switch (item.type) {
    case 'event': return item.key === 'start' || item.key === 'end' ? `event:on_${item.key}` : `event:${item.key}`;
    case 'decl': return `node:${item.key}`;
    case 'stmt': return STMT_KEYS[item.key] || null;
    case 'action': return `action:${item.key}`;
    case 'builtin': return `builtin:${item.key}`;
    case 'world': return `world:${item.key}`;
    case 'op': return `operator:${item.key}`;
    case 'value': return VALUE_KEYS[item.key] || null;
    case 'userfn': return `fn:${item.key}`;
    case 'library': return `lib:${item.key}`;
    default: return null;
  }
}

const typeName = (t) => {
  if (!t) return 'any';
  if (typeof t === 'string') return t;
  if (t.list) return `list of ${typeName(t.list)}`;
  if (t.record) return 'record';
  if (t.enum) return t.enum.map((v) => JSON.stringify(v)).join(' | ');
  return 'any';
};

// Entries made from the catalog itself, for anything the docs don't cover
// (yet): a signature and its one-line doc.
export function fallbackDocs(catalog) {
  const out = {};
  const signature = (s) => {
    const parts = s.params.map((p) => (p.rest ? `${p.name}…` : p.name)).concat((s.named || []).map((p) => `${p.name}: …`));
    return `${s.name}(${parts.join(', ')})`;
  };
  const inputs = (s) => s.params.concat(s.named || []).map((p) => ({ name: p.name, doc: typeName(p.type) }));
  catalog.builtins.forEach((b) => {
    out[`builtin:${b.name}`] = {
      title: b.name, kind: b.group, summary: b.doc, usage: signature(b), inputs: inputs(b), output: typeName(b.returns),
    };
  });
  catalog.actions.forEach((a) => {
    out[`action:${a.name}`] = {
      title: a.name, kind: 'action', summary: a.doc, usage: signature(a), inputs: inputs(a),
    };
  });
  catalog.setup.forEach((f) => {
    out[`setup:${f.name}`] = {
      title: f.name, kind: 'setup field', summary: f.doc, usage: `${f.name} = …`,
    };
  });
  Object.entries(catalog.world_docs || {}).forEach(([path, doc]) => {
    out[`world:${path}`] = { title: path, kind: 'world value', summary: doc };
  });
  Object.entries(catalog.root_docs || {}).forEach(([root, doc]) => {
    if (!out[`world:${root}`]) out[`world:${root}`] = { title: root, kind: 'world value', summary: doc };
  });
  return out;
}

const GROUPS = [
  ['event:', 'reference_events'],
  ['action:', 'reference_actions'],
  ['builtin:', 'reference_builtins'],
  ['operator:', 'reference_operators'],
  ['setup:', 'reference_setup'],
  ['world:', 'reference_world'],
  ['keyword:', 'reference_keywords'],
  ['node:', 'reference_nodes'],
];

const EVENT_ORDER = ['event:on_start', 'event:every', 'event:at', 'event:when', 'event:on_end'];

// [{key: label key, items: [{key, title, summary}]}], in reading order
export function referenceGroups(docs) {
  const keys = Object.keys(docs);
  return GROUPS.map(([prefix, label]) => {
    let items = keys.filter((k) => k.startsWith(prefix));
    items = prefix === 'event:'
      ? items.sort((a, b) => EVENT_ORDER.indexOf(a) - EVENT_ORDER.indexOf(b))
      : items.sort((a, b) => docs[a].title.localeCompare(docs[b].title));
    return { label, items: items.map((k) => ({ key: k, title: docs[k].title, summary: docs[k].summary })) };
  }).filter((g) => g.items.length);
}
