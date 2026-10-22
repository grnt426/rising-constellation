'use strict';

// The editor engine (priv/edict/editors/core.js) against the generated
// catalog. Run by test/edict/editor_kit_test.exs:
//   EDICT_KIT=<kit dir> node --test test/edict/editors/

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const kit = process.env.EDICT_KIT;
const { createEdict } = require(path.join(kit, 'lsp/core.js'));
const catalog = require(path.join(kit, 'lsp/catalog.json'));
const examplesDir = process.env.EDICT_EXAMPLES;

const edict = createEdict(catalog);
// the same engine without the docs entries: the signature-based hovers
const bare = createEdict({ ...catalog, docs: {} });

// `|` marks the cursor
function at(src) {
  const i = src.indexOf('|');
  return [src.slice(0, i) + src.slice(i + 1), i];
}
const complete = (src) => edict.complete(...at(src));
const labels = (src) => complete(src).items.map((i) => i.label);
const hover = (src) => {
  const h = bare.hover(...at(src));
  return h && h.md;
};
const docsHover = (src) => {
  const h = edict.hover(...at(src));
  return h && h.md;
};

test('top level offers the parts of a scenario', () => {
  const l = labels('score 1\n|');
  ['setup', 'score', 'on start', 'every', 'when', 'fn'].forEach((x) => assert.ok(l.includes(x), x));
  assert.ok(!labels('setup {\n}\n|').includes('setup'), 'only one setup');
});

test('setup offers the fields not set yet, as snippets', () => {
  const r = complete('setup {\n  name = "x"\n  |\n  patent_discounts = {armoring: 20%}\n}');
  const l = r.items.map((i) => i.label);
  assert.ok(l.includes('time_limit'));
  assert.ok(!l.includes('name'));
  assert.ok(!l.includes('patent_discounts'));
  const faction = r.items.find((i) => i.label === 'faction');
  assert.ok(faction.snippet && faction.insert.includes('tetrarchy'));
});

test('fields follow the world schema, through loops, lambdas and lets', () => {
  assert.deepStrictEqual(labels('score player.income.|'), ['credit', 'ideology', 'technology']);
  assert.ok(labels('on start {\n  for s in player.systems {\n    notify(s.|)\n  }\n}').includes('population'));
  assert.ok(labels('score sum(filter(player.agents, a => a.level > 1), x => x.|)').includes('fleet'));
  assert.ok(labels('on start {\n  let home = first(player.systems)\n  notify(home.|)\n}').includes('housing'));
  // a keyword in front of the path doesn't confuse it
  assert.ok(labels('score player.inc|').includes('income'));
  const r = complete('score player.inc|');
  assert.deepStrictEqual(r.range, { start: 13, end: 16 });
});

test('text offers the values its place takes', () => {
  assert.deepStrictEqual(labels('on start {\n  give("|")\n}'), catalog.enums.resources);
  assert.deepStrictEqual(labels('on start {\n  notify("hi", tone: "|")\n}'), ['info', 'good', 'warning']);
  assert.deepStrictEqual(labels('setup {\n  faction = "|"\n}'), catalog.enums.factions);
  assert.ok(labels('setup {\n  grant_patents = ["|"]\n}').includes('armoring'));
  assert.ok(labels('setup {\n  mutators = ["|"]\n}').includes(catalog.enums.mutators[0].key));
  assert.ok(labels('when "|" in player.patents {\n}').includes('armoring'));
  assert.deepStrictEqual(labels('score count(player.agents, a => a.type == "|")'), ['navarch', 'siderian', 'erased']);
  assert.ok(labels('setup {\n  patent_discounts = {|}\n}').includes('armoring'));
});

test('a hole in text completes like code, with the names in scope', () => {
  const r = complete('every 15s as wave {\n  notify("Wave {wa|}")\n}');
  assert.ok(r.items.some((i) => i.label === 'wave'));
  assert.ok(!r.items.some((i) => i.kind === 'action'));
  assert.ok(labels('on start {\n  notify("You have {player.|}")\n}').includes('credit'));
});

test('steps offer actions and statements; values do not', () => {
  const steps = labels('every 15s as n {\n  |\n}');
  ['give', 'notify', 'let', 'if', 'for', 'n', 'player', 'round'].forEach((x) => assert.ok(steps.includes(x), x));
  assert.ok(!steps.includes('return'), 'return is for functions');
  assert.ok(labels('fn f(x) {\n  |\n}').includes('return'));
  assert.ok(labels('on start {\n  for s in player.systems {\n    |\n  }\n}').includes('break'));
  const value = labels('score |');
  assert.ok(!value.includes('give'));
  assert.ok(value.includes('max'));
  assert.ok(labels('on start {\n  lev|\n}\nfn level_for(w) {\n  return w\n}').includes('level_for'), 'functions declared later');
});

test('named arguments, keywords after on and for, nothing in comments', () => {
  assert.ok(labels('on start {\n  notify("hi", |)\n}').includes('tone:'));
  assert.ok(labels('on start {\n  send_agent("erased", |)\n}').includes('level:'));
  assert.deepStrictEqual(labels('on |'), ['start', 'end']);
  assert.deepStrictEqual(labels('on start {\n  for s |\n}'), ['in']);
  assert.deepStrictEqual(labels('# hel|lo'), []);
  assert.deepStrictEqual(labels('on start {\n  let |'), []);
});

test('hover explains builtins, actions, fields, setup, numbers and names', () => {
  assert.match(hover('score ro|und(1)'), /round\(x: number, digits\?: number\) → number/);
  assert.match(hover('on start { gi|ve("credit", 1) }'), /Action: changes the game/);
  assert.match(hover('score player.inc|ome.credit'), /Income per game day/);
  assert.match(hover('on start {\n for s in player.systems {\n  give("credit", s.popu|lation)\n }\n}'), /player\.systems\[\]\.population: number/);
  assert.match(hover('setup {\n  time_li|mit = 20m\n}'), /Left out: 30m/);
  assert.match(hover('every 1m3|0s {}'), /90 seconds/);
  assert.match(hover('ev|ery 15s {}'), /on a schedule/);
  assert.match(hover('every 15s as wa|ve {}'), /wave: number/);
  assert.match(hover('on end {\n  notify("x", to|ne: "good")\n}'), /notify/);
  assert.strictEqual(hover('score 1_0|00'), null);
});

test('a function comment shows as plain text in hovers, never as links, images or HTML', () => {
  const src = '# see ![x](https://evil.example/t.png) [y](command:x) <img src=x onerror=1>\nfn helper(x) {\n  return x\n}\nscore help|er(1)';
  const md = hover(src);
  assert.ok(md.includes('\\!\\[x\\]\\(https://evil\\.example/t\\.png\\)'), md);
  assert.ok(md.includes('\\<img src=x onerror=1\\>'), md);
  const sigDoc = edict.signature(...at('# a [link](https://evil.example)\nfn helper(x) {\n  return x\n}\nscore helper(|')).doc;
  assert.ok(!/\]\(/.test(sigDoc.replace(/\\\]\\\(/g, '')), sigDoc);
});

test('with the docs, hovers show the full entry: how to write it, inputs, what comes out, examples', () => {
  const md = docsHover('on start {\n  gi|ve("credit", 5)\n}');
  assert.match(md, /^\*\*give\*\* · action/);
  assert.match(md, /give\(resource, amount\)/);
  assert.match(md, /- `resource`: /);
  assert.match(md, /Gives: /);
  assert.match(docsHover('ev|ery 15s {}'), /15s/);
  assert.match(docsHover('when "armoring" i|n player.patents {\n}'), /\*\*in\*\*/);
  assert.match(docsHover('score player.pat|ents'), /armoring/);
  // which entry the cursor is on
  const key = (src) => (edict.docKey(...at(src)) || {}).key;
  assert.strictEqual(key('on start {\n  gi|ve("credit", 5)\n}'), 'action:give');
  assert.strictEqual(key('o|n end {}'), 'event:on_end');
  assert.strictEqual(key('score 1 |+ 2'), 'operator:+');
  assert.strictEqual(key('score |-1'), 'operator:negate');
  assert.strictEqual(key('on start {\n  for s i|n player.systems {\n  }\n}'), 'keyword:in');
  assert.strictEqual(key('on start {\n  for s in player.systems {\n    log(s.popu|lation)\n  }\n}'), 'world:player.systems[].population');
  assert.strictEqual(key('setup {\n  time_li|mit = 20m\n}'), 'setup:time_limit');
  assert.strictEqual(key('fn f() {\n  return 1\n}\nscore |f()'), 'fn:f');
  ['builtin:sum', 'action:notify', 'event:every', 'operator:in', 'keyword:let', 'setup:rival', 'world:time.left'].forEach((k) => assert.ok(catalog.docs[k], k));
});

test('signature help tracks the argument being typed', () => {
  const sig = (src) => edict.signature(...at(src));
  assert.strictEqual(sig('score round(1, |)').active, 1);
  assert.strictEqual(sig('score max(1, 2, 3, |)').active, 0, 'a rest parameter stays active');
  const named = sig('on start { notify("x", tone: |) }');
  assert.strictEqual(named.params[named.active].label, 'tone: "info" | "good" | "warning"');
  const user = sig('fn area(h, w) { return h * w }\nscore area(1, |)');
  assert.strictEqual(user.label, 'area(h, w)');
  assert.strictEqual(user.active, 1);
  const s = sig('score round(|');
  s.params.forEach((p) => assert.strictEqual(s.label.slice(p.start, p.end), p.label));
  assert.strictEqual(sig('score 1 + |'), null);
});

test('outline and go to definition', () => {
  const text = 'setup {\n  name = "x"\n}\nscore player.credit\nvar total = 0\nfn level_for(w) {\n  return w\n}\nevery 15s as n {\n  total = total + level_for(n)\n}\n';
  const syms = edict.symbols(text);
  assert.deepStrictEqual(syms.map((s) => [s.kind, s.name]), [
    ['module', 'setup'], ['property', 'score'], ['variable', 'total'], ['function', 'level_for'], ['event', 'every 15s as n'],
  ]);
  const fnSym = syms.find((s) => s.name === 'level_for');
  assert.strictEqual(text.slice(fnSym.start, fnSym.end), 'fn level_for(w) {\n  return w\n}');

  const def = (src) => {
    const [t, o] = at(src);
    const d = edict.definition(t, o);
    return d && t.slice(d.start, d.end) + '@' + d.start;
  };
  assert.strictEqual(def('fn level_for(w) {\n  return w\n}\nscore level_|for(1)'), 'level_for@3');
  assert.strictEqual(def('var total = 0\non start {\n  total = to|tal + 1\n}'), 'total@4');
  assert.strictEqual(def('on start {\n  for s in player.systems {\n    give("credit", s|.population)\n  }\n}'), 's@17');
  assert.strictEqual(def('score player.cre|dit'), null);
});

test('the lexer checks match the game wording', () => {
  const messages = (src) => edict.diagnose(src).map((d) => d.message);
  assert.deepStrictEqual(messages('score "abc'), ['this text is missing its closing quote']);
  assert.deepStrictEqual(messages('score 12abc'), ['a number can only end in s, m, h (a duration) or % (a percentage)']);
  assert.deepStrictEqual(messages(`# ${String.fromCharCode(0x202e)}`), ['the script contains a hidden text-direction character']);
  assert.deepStrictEqual(messages('score "a\\qb"'), ['unknown escape \\q (use \\n, \\t, \\", \\\\, \\{ or \\})']);
  assert.deepStrictEqual(messages('on start {'), ['this { is never closed']);
  assert.deepStrictEqual(messages('score 1)'), ['this ) has no matching (']);
  assert.deepStrictEqual(messages('score 1 @'), ['unexpected character "@"']);
  assert.deepStrictEqual(messages('score 1\r\n# windows\r\n'), [], 'Windows line endings are fine');
});

test('every example: no false alarms, and every request at every offset answers', () => {
  const files = fs.readdirSync(examplesDir).filter((f) => f.endsWith('.edict'));
  assert.ok(files.length >= 10);
  files.forEach((f) => {
    const text = fs.readFileSync(path.join(examplesDir, f), 'utf8');
    assert.deepStrictEqual(edict.diagnose(text), [], f);
    assert.ok(edict.symbols(text).length >= 2, f);
    for (let o = 0; o <= text.length; o += 3) {
      const r = edict.complete(text, o);
      assert.ok(r.range.start <= o && r.range.end === o, `${f}@${o}`);
      edict.hover(text, o);
      edict.signature(text, o);
      edict.definition(text, o);
    }
  });
});

test('every builtin, action and world root can be completed and hovered', () => {
  const steps = labels('on start {\n  |\n}');
  catalog.builtins.forEach((b) => {
    assert.ok(steps.includes(b.name), b.name);
    assert.ok(hover(`score ${b.name.slice(0, 1)}|${b.name.slice(1)}(1)`), b.name);
  });
  catalog.actions.forEach((a) => assert.ok(steps.includes(a.name), a.name));
  Object.keys(catalog.world).forEach((r) => assert.ok(steps.includes(r), r));
  catalog.keywords.forEach((k) => assert.ok(catalog.keyword_docs[k], `doc for ${k}`));
});
