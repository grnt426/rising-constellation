// node --test front/src/portal/workshop/__tests__/completion.test.mjs
import test from 'node:test';
import assert from 'node:assert';
import { expandSnippet, filterItems } from '../completion.js';
import { isAcceptKey, normalizeScenarioEditor } from '../editor-settings.js';
import { blocks } from '../md-lite.js';

const items = [
  { label: 'give', sort: '1' },
  { label: 'player', sort: '1' },
  { label: 'log', sort: '1' },
  { label: 'sum', sort: '3' },
  { label: 'unique', sort: '3' },
  { label: 'let', sort: '2' },
];

test('typed text narrows the list: starts-with first, then contains', () => {
  assert.deepStrictEqual(filterItems(items, 'l').map((i) => i.label), ['log', 'let', 'player']);
  assert.deepStrictEqual(filterItems(items, 'u').map((i) => i.label), ['unique', 'sum']);
  assert.deepStrictEqual(filterItems(items, '').map((i) => i.label), ['give', 'log', 'player', 'let', 'sum', 'unique']);
  assert.deepStrictEqual(filterItems(items, 'give'), [], 'a word typed in full needs no list');
});

test('a snippet becomes text, its first placeholder selected', () => {
  assert.deepStrictEqual(expandSnippet('give(${1|"credit","technology"|}, ${2:amount})'), {
    text: 'give("credit", amount)', select: [5, 13],
  });
  const every = expandSnippet('every ${1:15s} as ${2:n} {\n\t$0\n}', '  ');
  assert.strictEqual(every.text, 'every 15s as n {\n    \n  }');
  assert.deepStrictEqual(every.select, [6, 9]);
  assert.deepStrictEqual(expandSnippet('on start {\n\t$0\n}'), { text: 'on start {\n  \n}', select: [13, 13] });
  assert.deepStrictEqual(expandSnippet('fmt_time(${1})'), { text: 'fmt_time()', select: [9, 9] });
  assert.strictEqual(expandSnippet('x = ${1|a\\,b,c|}').text, 'x = a,b');
});

test('the accept key setting', () => {
  const key = (k, shift = false) => ({ key: k, shiftKey: shift });
  assert.ok(isAcceptKey(key('Tab'), 'tab'));
  assert.ok(!isAcceptKey(key('Tab', true), 'tab'));
  assert.ok(isAcceptKey(key('Tab', true), 'shift+tab'));
  assert.ok(isAcceptKey(key('Enter'), 'enter'));
  assert.ok(!isAcceptKey(key('Enter'), 'tab'));
  assert.ok(isAcceptKey(key('Enter', true), 'shift+enter'));
  assert.ok(!isAcceptKey({ key: 'Tab', ctrlKey: true }, 'tab'));
  assert.deepStrictEqual(normalizeScenarioEditor(null), { accept: 'tab', suggest: true });
  assert.deepStrictEqual(normalizeScenarioEditor({ accept: 'f13', suggest: false }), { accept: 'tab', suggest: false });
});

test('docs Markdown becomes text blocks, never HTML', () => {
  const b = blocks('**give** · action\n\nGives `credit`.\n```edict\ngive("credit", 5)\n```\n- `amount`: how much\n<img src=x onerror=alert(1)>');
  assert.deepStrictEqual(b[0].parts, [{ style: 'strong', text: 'give' }, { style: 'text', text: ' · action' }]);
  assert.deepStrictEqual(b[2], { kind: 'code', text: 'give("credit", 5)' });
  assert.strictEqual(b[3].kind, 'li');
  assert.deepStrictEqual(b[4].parts, [{ style: 'text', text: '<img src=x onerror=alert(1)>' }]);
});
