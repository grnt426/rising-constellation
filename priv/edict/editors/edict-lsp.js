#!/usr/bin/env node
'use strict';

/*
 * The Edict language server: core.js behind the Language Server Protocol,
 * for every editor that speaks it (JetBrains IDEs with the LSP4IJ plugin,
 * Neovim, Sublime Text's LSP package, Zed, Helix, Emacs with eglot).
 *
 *   node edict-lsp.js --stdio
 *
 * It speaks JSON-RPC over stdin/stdout, keeps open documents in memory and
 * nothing else: no files written, no network.
 */

const { createEdict } = require('./core');
const catalog = require('./catalog.json');

const edict = createEdict(catalog);
const docs = new Map();
let snippets = false;
let shuttingDown = false;

const ITEM_KINDS = {
  function: 3, action: 2, keyword: 14, snippet: 15, field: 5, variable: 6, module: 9, property: 10, enum: 20, event: 23, value: 12,
};
const SYMBOL_KINDS = {
  module: 2, namespace: 3, property: 7, function: 12, variable: 13, event: 24,
};

// --- positions (UTF-16, the protocol's default) ---------------------------------

function lineStarts(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i += 1) if (text[i] === '\n') starts.push(i + 1);
  return starts;
}

function offsetAt(text, pos) {
  const starts = lineStarts(text);
  if (pos.line >= starts.length) return text.length;
  const lineEnd = pos.line + 1 < starts.length ? starts[pos.line + 1] - 1 : text.length;
  return Math.min(starts[pos.line] + pos.character, lineEnd);
}

function positionAt(text, offset) {
  const starts = lineStarts(text);
  let lo = 0;
  let hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= offset) lo = mid;
    else hi = mid - 1;
  }
  return { line: lo, character: offset - starts[lo] };
}

const rangeOf = (text, r) => ({ start: positionAt(text, r.start), end: positionAt(text, r.end) });

// A snippet as plain text, for clients that can't take snippets.
function plain(snippet) {
  return snippet
    .replace(/\$\{\d+\|([^,|]*)[^}]*\}/g, '$1')
    .replace(/\$\{\d+:([^}]*)\}/g, '$1')
    .replace(/\$\{\d+\}|\$\d+/g, '');
}

// --- requests ---------------------------------------------------------------------

const handlers = {
  initialize(params) {
    const caps = params && params.capabilities;
    snippets = !!(caps && caps.textDocument && caps.textDocument.completion
      && caps.textDocument.completion.completionItem && caps.textDocument.completion.completionItem.snippetSupport);
    return {
      capabilities: {
        positionEncoding: 'utf-16',
        textDocumentSync: 1,
        completionProvider: { triggerCharacters: ['.', '"'] },
        hoverProvider: true,
        signatureHelpProvider: { triggerCharacters: ['(', ','], retriggerCharacters: [','] },
        documentSymbolProvider: true,
        definitionProvider: true,
      },
      serverInfo: { name: 'edict-lsp', version: catalog.version },
    };
  },

  'textDocument/completion'({ textDocument, position }) {
    const text = docs.get(textDocument.uri);
    if (text === undefined) return null;
    const result = edict.complete(text, offsetAt(text, position));
    const range = rangeOf(text, result.range);
    return {
      isIncomplete: false,
      items: result.items.map((it) => ({
        label: it.label,
        kind: ITEM_KINDS[it.kind] || 1,
        detail: it.detail || undefined,
        documentation: it.doc ? { kind: 'markdown', value: it.doc } : undefined,
        sortText: `${it.sort || '5'}${it.label}`,
        filterText: it.label.replace(/…/g, '').replace(/\s+/g, ' ').trim(),
        insertTextFormat: it.snippet && snippets ? 2 : 1,
        textEdit: { range, newText: it.snippet && !snippets ? plain(it.insert) : it.insert },
      })),
    };
  },

  'textDocument/hover'({ textDocument, position }) {
    const text = docs.get(textDocument.uri);
    if (text === undefined) return null;
    const h = edict.hover(text, offsetAt(text, position));
    return h ? { contents: { kind: 'markdown', value: h.md }, range: rangeOf(text, h.range) } : null;
  },

  'textDocument/signatureHelp'({ textDocument, position }) {
    const text = docs.get(textDocument.uri);
    if (text === undefined) return null;
    const s = edict.signature(text, offsetAt(text, position));
    if (!s) return null;
    return {
      signatures: [{
        label: s.label,
        documentation: s.doc ? { kind: 'markdown', value: s.doc } : undefined,
        parameters: s.params.map((p) => ({ label: [p.start, p.end] })),
      }],
      activeSignature: 0,
      activeParameter: s.active < 0 ? s.params.length : s.active,
    };
  },

  'textDocument/documentSymbol'({ textDocument }) {
    const text = docs.get(textDocument.uri);
    if (text === undefined) return [];
    return edict.symbols(text).map((s) => ({
      name: s.name,
      detail: s.detail || undefined,
      kind: SYMBOL_KINDS[s.kind] || 19,
      range: rangeOf(text, { start: s.start, end: s.end }),
      selectionRange: rangeOf(text, { start: s.selStart, end: s.selEnd }),
    }));
  },

  'textDocument/definition'({ textDocument, position }) {
    const text = docs.get(textDocument.uri);
    if (text === undefined) return null;
    const d = edict.definition(text, offsetAt(text, position));
    return d ? { uri: textDocument.uri, range: rangeOf(text, d) } : null;
  },

  shutdown() {
    shuttingDown = true;
    return null;
  },
};

// --- notifications ------------------------------------------------------------------

function publish(uri) {
  const text = docs.get(uri);
  const diagnostics = text === undefined ? [] : edict.diagnose(text).map((d) => ({
    range: rangeOf(text, d),
    severity: d.severity === 'warning' ? 2 : 1,
    source: 'edict',
    message: d.message,
  }));
  send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: { uri, diagnostics } });
}

const notifications = {
  'textDocument/didOpen'({ textDocument }) {
    docs.set(textDocument.uri, textDocument.text);
    publish(textDocument.uri);
  },
  'textDocument/didChange'({ textDocument, contentChanges }) {
    let text = docs.get(textDocument.uri) || '';
    contentChanges.forEach((change) => {
      if (change.range) {
        text = text.slice(0, offsetAt(text, change.range.start)) + change.text + text.slice(offsetAt(text, change.range.end));
      } else {
        text = change.text;
      }
    });
    docs.set(textDocument.uri, text);
    publish(textDocument.uri);
  },
  'textDocument/didClose'({ textDocument }) {
    docs.delete(textDocument.uri);
    publish(textDocument.uri);
  },
  exit() {
    process.exit(shuttingDown ? 0 : 1);
  },
};

// --- JSON-RPC over stdio ---------------------------------------------------------------

function send(message) {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

function dispatch(message) {
  const { id, method, params } = message;
  if (id !== undefined && method) {
    const handler = handlers[method];
    if (!handler) {
      send({ jsonrpc: '2.0', id, error: { code: -32601, message: `unhandled method ${method}` } });
      return;
    }
    try {
      send({ jsonrpc: '2.0', id, result: handler(params || {}) });
    } catch (e) {
      send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(e && e.message) } });
    }
  } else if (method && notifications[method]) {
    try {
      notifications[method](params || {});
    } catch (e) {
      // a bad notification must not take the server down
    }
  }
}

let buffer = Buffer.alloc(0);
process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = buffer.slice(0, headerEnd).toString('ascii');
    const m = /Content-Length:\s*(\d+)/i.exec(header);
    if (!m) {
      buffer = buffer.slice(headerEnd + 4);
      continue;
    }
    const length = Number(m[1]);
    if (buffer.length < headerEnd + 4 + length) return;
    const body = buffer.slice(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
    buffer = buffer.slice(headerEnd + 4 + length);
    let message;
    try {
      message = JSON.parse(body);
    } catch (e) {
      continue;
    }
    dispatch(message);
  }
});
process.stdin.on('end', () => process.exit(shuttingDown ? 0 : 1));
