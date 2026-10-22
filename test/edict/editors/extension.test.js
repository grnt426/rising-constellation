'use strict';

// The VS Code extension, unpacked from the .vsix, run against a stand-in
// for the `vscode` module: it must declare the language and grammar, and
// register providers that answer with VS Code's own types.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');
const { execFileSync } = require('child_process');

const kit = process.env.EDICT_KIT;
const vsix = fs.readdirSync(kit).find((f) => f.endsWith('.vsix'));

// --- a minimal vscode -------------------------------------------------------------

const registered = {};
const diagnostics = new Map();
class Range { constructor(start, end) { Object.assign(this, { start, end }); } }
class Thing { constructor(...args) { this.args = args; } }
const vscode = {
  Range,
  CompletionItem: class { constructor(label, kind) { Object.assign(this, { label, kind }); } },
  SnippetString: class { constructor(value) { this.value = value; } },
  MarkdownString: class { constructor(value) { this.value = value; } },
  Hover: class { constructor(contents, range) { Object.assign(this, { contents, range }); } },
  SignatureInformation: class { constructor(label, documentation) { Object.assign(this, { label, documentation }); } },
  ParameterInformation: class { constructor(label) { this.label = label; } },
  SignatureHelp: class {},
  DocumentSymbol: class { constructor(name, detail, kind, range, selectionRange) { Object.assign(this, { name, detail, kind, range, selectionRange }); } },
  Location: class { constructor(uri, range) { Object.assign(this, { uri, range }); } },
  Diagnostic: class { constructor(range, message, severity) { Object.assign(this, { range, message, severity }); } },
  DiagnosticSeverity: { Error: 0, Warning: 1 },
  CompletionItemKind: new Proxy({}, { get: (_, k) => `kind:${String(k)}` }),
  SymbolKind: new Proxy({}, { get: (_, k) => `symbol:${String(k)}` }),
  languages: {
    registerCompletionItemProvider: (sel, p, ...triggers) => { registered.completion = { sel, p, triggers }; return new Thing(); },
    registerHoverProvider: (sel, p) => { registered.hover = p; return new Thing(); },
    registerSignatureHelpProvider: (sel, p, ...triggers) => { registered.signature = { p, triggers }; return new Thing(); },
    registerDocumentSymbolProvider: (sel, p) => { registered.symbols = p; return new Thing(); },
    registerDefinitionProvider: (sel, p) => { registered.definition = p; return new Thing(); },
    createDiagnosticCollection: () => ({
      set: (uri, list) => diagnostics.set(uri, list),
      delete: (uri) => diagnostics.delete(uri),
    }),
  },
  workspace: {
    textDocuments: [],
    onDidOpenTextDocument: (f) => { registered.open = f; return new Thing(); },
    onDidChangeTextDocument: (f) => { registered.change = f; return new Thing(); },
    onDidCloseTextDocument: (f) => { registered.close = f; return new Thing(); },
  },
};

function doc(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i += 1) if (text[i] === '\n') starts.push(i + 1);
  return {
    uri: 'file:///scenario.edict',
    languageId: 'edict',
    getText: () => text,
    offsetAt: (p) => starts[p.line] + p.character,
    positionAt: (o) => {
      let line = 0;
      while (line + 1 < starts.length && starts[line + 1] <= o) line += 1;
      return { line, character: o - starts[line] };
    },
  };
}

function unpack() {
  // the .vsix is a zip: let the platform's tools open it
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'edict-vsix-'));
  const file = path.join(kit, vsix);
  try {
    execFileSync('unzip', ['-q', file, '-d', dir]);
  } catch (e) {
    execFileSync('tar', ['-xf', file, '-C', dir]);
  }
  return path.join(dir, 'extension');
}

test('the package declares the language, grammar and entry point', () => {
  const ext = unpack();
  const pkg = JSON.parse(fs.readFileSync(path.join(ext, 'package.json'), 'utf8'));
  assert.strictEqual(pkg.name, 'edict');
  assert.strictEqual(pkg.publisher, 'tetrarchyfalls');
  assert.match(pkg.version, /^\d+\.\d+\.\d+$/);
  assert.deepStrictEqual(pkg.activationEvents, ['onLanguage:edict']);
  assert.deepStrictEqual(pkg.contributes.languages[0].extensions, ['.edict']);
  ['main', 'contributes.languages.0.configuration', 'contributes.grammars.0.path'].forEach((key) => {
    const rel = key.split('.').reduce((o, k) => o[k], pkg);
    assert.ok(fs.existsSync(path.join(ext, rel)), `${key} -> ${rel}`);
  });
  const grammar = JSON.parse(fs.readFileSync(path.join(ext, pkg.contributes.grammars[0].path), 'utf8'));
  assert.strictEqual(grammar.scopeName, pkg.contributes.grammars[0].scopeName);
});

test('activation registers providers that answer with VS Code types', () => {
  const ext = unpack();
  const original = Module._load;
  Module._load = function load(request, ...rest) {
    return request === 'vscode' ? vscode : original.call(this, request, ...rest);
  };
  try {
    const subscriptions = [];
    require(path.join(ext, 'extension.js')).activate({ subscriptions });
    assert.ok(subscriptions.length >= 6);
  } finally {
    Module._load = original;
  }
  assert.deepStrictEqual(registered.completion.sel, { language: 'edict' });
  assert.deepStrictEqual(registered.completion.triggers, ['.', '"']);
  assert.deepStrictEqual(registered.signature.triggers, ['(', ',']);

  const d = doc('score player.income.\non start {\n  give("credit", 5)\n}\n');
  const items = registered.completion.p.provideCompletionItems(d, { line: 0, character: 20 });
  assert.deepStrictEqual(items.map((i) => i.label), ['credit', 'ideology', 'technology']);
  assert.strictEqual(items[0].kind, 'kind:Field');
  assert.ok(items[0].range instanceof Range);

  const steps = registered.completion.p.provideCompletionItems(d, { line: 2, character: 2 });
  const give = steps.find((i) => i.label === 'give');
  assert.strictEqual(give.kind, 'kind:Method');
  assert.match(give.insertText.value, /^give\(/);

  const h = registered.hover.provideHover(d, { line: 2, character: 3 });
  assert.match(h.contents.value, /give\(resource/);

  const s = registered.signature.p.provideSignatureHelp(d, { line: 2, character: 17 });
  assert.strictEqual(s.activeParameter, 1);
  assert.deepStrictEqual(s.signatures[0].parameters.map((p) => s.signatures[0].label.slice(...p.label)), [
    'resource: "credit" | "technology" | "ideology"', 'amount: number',
  ]);

  const syms = registered.symbols.provideDocumentSymbols(d);
  assert.deepStrictEqual(syms.map((x) => [x.name, x.kind]), [['score', 'symbol:Property'], ['on start', 'symbol:Event']]);

  registered.change({ document: doc('score "abc') });
  const diags = diagnostics.get('file:///scenario.edict');
  assert.deepStrictEqual(diags.map((x) => x.message), ['this text is missing its closing quote']);
});
