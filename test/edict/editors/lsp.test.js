'use strict';

// The language server (lsp/edict-lsp.js), spoken to over stdio the way an
// editor does.

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { spawn } = require('child_process');

const kit = process.env.EDICT_KIT;

function client({ snippets = true } = {}) {
  const proc = spawn(process.execPath, [path.join(kit, 'lsp/edict-lsp.js'), '--stdio'], { stdio: ['pipe', 'pipe', 'inherit'] });
  let buffer = Buffer.alloc(0);
  let nextId = 1;
  const waiting = new Map();
  const notes = [];
  const noteWaiters = [];

  proc.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const headerEnd = buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      const length = Number(/Content-Length: (\d+)/.exec(buffer.slice(0, headerEnd).toString())[1]);
      if (buffer.length < headerEnd + 4 + length) return;
      const msg = JSON.parse(buffer.slice(headerEnd + 4, headerEnd + 4 + length).toString('utf8'));
      buffer = buffer.slice(headerEnd + 4 + length);
      if (msg.id !== undefined && waiting.has(msg.id)) {
        waiting.get(msg.id)(msg);
        waiting.delete(msg.id);
      } else if (msg.method) {
        notes.push(msg);
        noteWaiters.splice(0).forEach((w) => w());
      }
    }
  });

  const write = (msg) => {
    const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...msg }), 'utf8');
    proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    proc.stdin.write(body);
  };
  const request = (method, params) => new Promise((resolve) => {
    const id = nextId;
    nextId += 1;
    waiting.set(id, resolve);
    write({ id, method, params });
  });
  const notify = (method, params) => write({ method, params });
  const nextNote = (method) => new Promise((resolve) => {
    const check = () => {
      const i = notes.findIndex((n) => n.method === method);
      if (i >= 0) resolve(notes.splice(i, 1)[0]);
      else noteWaiters.push(check);
    };
    check();
  });
  const exited = new Promise((resolve) => proc.on('exit', resolve));
  const init = request('initialize', {
    processId: null,
    rootUri: null,
    capabilities: { textDocument: { completion: { completionItem: { snippetSupport: snippets } } } },
  });
  return {
    request, notify, nextNote, exited, init,
  };
}

const uri = 'file:///scenario.edict';
const text = 'setup {\n  name = "x"\n}\nscore player.income.\nfn level_for(w) {\n  return w\n}\nevery 15s as n {\n  give("credit", level_for(n))\n}\n';

test('a whole session: initialize, open, ask, change, shut down', async () => {
  const c = client();
  const init = await c.init;
  const caps = init.result.capabilities;
  assert.strictEqual(caps.textDocumentSync, 1);
  assert.deepStrictEqual(caps.completionProvider.triggerCharacters, ['.', '"']);
  assert.ok(caps.hoverProvider && caps.documentSymbolProvider && caps.definitionProvider);
  c.notify('initialized', {});

  c.notify('textDocument/didOpen', {
    textDocument: {
      uri, languageId: 'edict', version: 1, text,
    },
  });
  const opened = await c.nextNote('textDocument/publishDiagnostics');
  assert.deepStrictEqual(opened.params.diagnostics, []);

  const completion = await c.request('textDocument/completion', { textDocument: { uri }, position: { line: 3, character: 20 } });
  assert.deepStrictEqual(completion.result.items.map((i) => i.label), ['credit', 'ideology', 'technology']);
  assert.deepStrictEqual(completion.result.items[0].textEdit.range, { start: { line: 3, character: 20 }, end: { line: 3, character: 20 } });

  const steps = await c.request('textDocument/completion', { textDocument: { uri }, position: { line: 8, character: 2 } });
  const give = steps.result.items.find((i) => i.label === 'give');
  assert.strictEqual(give.insertTextFormat, 2);
  assert.match(give.textEdit.newText, /^give\(\$\{1\|/);

  const hover = await c.request('textDocument/hover', { textDocument: { uri }, position: { line: 8, character: 3 } });
  assert.match(hover.result.contents.value, /give\(resource/);
  assert.deepStrictEqual(hover.result.range, { start: { line: 8, character: 2 }, end: { line: 8, character: 6 } });

  const sig = await c.request('textDocument/signatureHelp', { textDocument: { uri }, position: { line: 8, character: 17 } });
  assert.match(sig.result.signatures[0].label, /^give\(/);
  assert.strictEqual(sig.result.activeParameter, 1);

  const symbols = await c.request('textDocument/documentSymbol', { textDocument: { uri } });
  assert.deepStrictEqual(symbols.result.map((s) => s.name), ['setup', 'score', 'level_for', 'every 15s as n']);

  const def = await c.request('textDocument/definition', { textDocument: { uri }, position: { line: 8, character: 20 } });
  assert.deepStrictEqual(def.result, { uri, range: { start: { line: 4, character: 3 }, end: { line: 4, character: 12 } } });

  c.notify('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text: 'score "abc\n' }] });
  const changed = await c.nextNote('textDocument/publishDiagnostics');
  assert.deepStrictEqual(changed.params.diagnostics.map((d) => [d.message, d.severity, d.range.start]), [
    ['this text is missing its closing quote', 1, { line: 0, character: 6 }],
  ]);

  // incremental changes work too, should a client send them
  c.notify('textDocument/didChange', {
    textDocument: { uri, version: 3 },
    contentChanges: [{ range: { start: { line: 0, character: 10 }, end: { line: 0, character: 10 } }, text: '"' }],
  });
  const fixed = await c.nextNote('textDocument/publishDiagnostics');
  assert.deepStrictEqual(fixed.params.diagnostics, []);

  const unknown = await c.request('workspace/symbol', { query: 'x' });
  assert.strictEqual(unknown.error.code, -32601);

  const down = await c.request('shutdown', null);
  assert.strictEqual(down.result, null);
  c.notify('exit', null);
  assert.strictEqual(await c.exited, 0);
});

test('clients without snippet support get plain text', async () => {
  const c = client({ snippets: false });
  await c.init;
  c.notify('textDocument/didOpen', {
    textDocument: {
      uri, languageId: 'edict', version: 1, text: 'on start {\n  \n}\n',
    },
  });
  const r = await c.request('textDocument/completion', { textDocument: { uri }, position: { line: 1, character: 2 } });
  const give = r.result.items.find((i) => i.label === 'give');
  assert.strictEqual(give.insertTextFormat, 1);
  assert.strictEqual(give.textEdit.newText, 'give("credit", amount)');
  r.result.items.forEach((i) => assert.ok(!/\$\{|\$\d/.test(i.textEdit.newText), i.label));
  await c.request('shutdown', null);
  c.notify('exit', null);
  assert.strictEqual(await c.exited, 0);
});

test('a broken message does not take the server down', async () => {
  const c = client();
  await c.init;
  c.notify('textDocument/didChange', { textDocument: { uri: 'file:///never-opened.edict' } });
  const r = await c.request('textDocument/hover', { textDocument: { uri: 'file:///never-opened.edict' }, position: { line: 0, character: 0 } });
  assert.ok(!r.error || r.error.code === -32603);
  const down = await c.request('shutdown', null);
  assert.strictEqual(down.result, null);
  c.notify('exit', null);
  assert.strictEqual(await c.exited, 0);
});
