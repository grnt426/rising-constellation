// Engine unit tests — plain node, no webpack:
//   node --test front/src/game/calc/__tests__/
// (the nested package.json marks this directory ESM, so .js engine modules
// import cleanly).
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  evaluateLine, evaluateDoc, CalcError, canonicalize, interpret, isKnownWord, COMPLETIONS,
} from '../engine.js';
import { buildEnv } from '../env.js';

// Legacy-speed fixture: 20 ut/hour (1 tick = 180 s). Numbers mirror the
// RC Helper spreadsheet example: ideology 5 000 at 70/tick → 1 400/h.
const NOW = new Date(2026, 6, 23, 12, 10, 0).getTime(); // a Thursday

function makeEnv(overrides = {}) {
  return {
    now: NOW,
    perHour: 20,
    isRunning: true,
    resources: {
      credit: { value: 31293, changePerUt: 526 },
      technology: { value: 7233, changePerUt: 50 },
      ideology: { value: 5000, changePerUt: 70 },
    },
    lexSlotCost: 3600,
    names: new Map(),
    ...overrides,
  };
}

const closeTo = (actual, expected, eps = 0.01) => {
  assert.ok(Math.abs(actual - expected) < eps, `expected ${actual} ≈ ${expected}`);
};

test('plain arithmetic', () => {
  const r = evaluateLine('9800 + 3600', makeEnv());
  assert.equal(r.k, 'scalar');
  assert.equal(r.v, 13400);
  assert.equal(r.res, null);
});

test('amount literals unify resources', () => {
  const r = evaluateLine('9800 ideo + 3600 ideo', makeEnv());
  assert.equal(r.v, 13400);
  assert.equal(r.res, 'ideology');

  const r2 = evaluateLine('9800 ideo + 3600', makeEnv());
  assert.equal(r2.res, 'ideology');
});

test('mixing two resources is an error', () => {
  assert.throws(
    () => evaluateLine('9800 ideo + 100 c', makeEnv()),
    (e) => e instanceof CalcError && e.code === 'MIXED_RESOURCES',
  );
});

test('stock variables and aliases', () => {
  assert.equal(evaluateLine('credits', makeEnv()).v, 31293);
  assert.equal(evaluateLine('c', makeEnv()).v, 31293);
  assert.equal(evaluateLine('tech', makeEnv()).v, 7233);
  assert.equal(evaluateLine('ideology', makeEnv()).v, 5000);
});

test('income variables are per-hour rates', () => {
  const r = evaluateLine('ideo income', makeEnv());
  assert.equal(r.k, 'rate');
  assert.equal(r.vPerHour, 1400);
  assert.equal(r.res, 'ideology');
  assert.equal(evaluateLine('ci', makeEnv()).vPerHour, 10520);
});

test('amount ÷ rate = duration (the spreadsheet workflow)', () => {
  const r = evaluateLine('(9800 + 3600 - 5000) / ideo income', makeEnv());
  assert.equal(r.k, 'dur');
  closeTo(r.s, 6 * 3600);
});

test('rate literals bind tighter than division', () => {
  const r = evaluateLine('8400 / 70/tick', makeEnv());
  assert.equal(r.k, 'dur');
  closeTo(r.s, 6 * 3600);

  const r2 = evaluateLine('70 ideo/tick', makeEnv());
  assert.equal(r2.k, 'rate');
  assert.equal(r2.res, 'ideology');
  closeTo(r2.vPerHour, 1400);
});

test('rate × duration = amount', () => {
  const r = evaluateLine('ideo income * 4h', makeEnv());
  assert.equal(r.k, 'scalar');
  closeTo(r.v, 5600);
  assert.equal(r.res, 'ideology');
});

test('amount ÷ duration = rate', () => {
  const r = evaluateLine('8400 ideo / 6h', makeEnv());
  assert.equal(r.k, 'rate');
  closeTo(r.vPerHour, 1400);
});

test('tick durations resolve via perHour', () => {
  const r = evaluateLine('4 ticks', makeEnv());
  assert.equal(r.k, 'dur');
  closeTo(r.s, 720);
});

test('percent and k suffix', () => {
  closeTo(evaluateLine('13400 * 10%', makeEnv()).v, 1340);
  closeTo(evaluateLine('12.5k', makeEnv()).v, 12500);
});

test('until: ETA to a target stockpile', () => {
  const r = evaluateLine('until 13400 ideo', makeEnv());
  assert.equal(r.k, 'eta');
  closeTo(r.s, 21600);
  assert.equal(r.when, NOW + 21600 * 1000);
  assert.equal(r.need, 8400);
});

test('until with lex slot cost folded in', () => {
  const r = evaluateLine('until 9800 ideo + lex slot', makeEnv());
  assert.equal(r.res, 'ideology');
  closeTo(r.s, 21600);
});

test('until an already-reached target', () => {
  const r = evaluateLine('until 4000 ideo', makeEnv());
  assert.equal(r.reached, true);
});

test('until with zero income never completes', () => {
  const env = makeEnv({
    resources: {
      credit: { value: 31293, changePerUt: 526 },
      technology: { value: 7233, changePerUt: 50 },
      ideology: { value: 5000, changePerUt: 0 },
    },
  });
  const r = evaluateLine('until 13400 ideo', env);
  assert.equal(r.never, true);
  assert.equal(r.need, 8400);
});

test('projection: credits in 8h', () => {
  const r = evaluateLine('credits in 8h', makeEnv());
  assert.equal(r.k, 'projection');
  closeTo(r.v, 115453);
});

test('bare snapshot: in 8h', () => {
  const r = evaluateLine('in 8h', makeEnv());
  assert.equal(r.k, 'snapshot');
  closeTo(r.resources.credit, 115453);
  closeTo(r.resources.technology, 15233);
  closeTo(r.resources.ideology, 16200);
});

test('projection at a time of day', () => {
  const r = evaluateLine('credits at 18:00', makeEnv());
  assert.equal(r.k, 'projection');
  closeTo(r.s, (5 * 60 + 50) * 60);
  closeTo(r.v, 31293 + 10520 * (21000 / 3600));
});

test('at next weekday occurrence', () => {
  // NOW is Thursday 12:10 → Friday 18:00 is 29h50m ahead
  const r = evaluateLine('credits at fri 18:00', makeEnv());
  assert.equal(r.k, 'projection');
  closeTo(r.s, ((24 + 5) * 60 + 50) * 60);
});

test('a past time-of-day rolls to tomorrow', () => {
  const r = evaluateLine('credits at 9:00', makeEnv());
  closeTo(r.s, ((24 - 12) * 60 - 10 + 9 * 60) * 60);
});

test('afford', () => {
  assert.equal(evaluateLine('afford 20000 c', makeEnv()).ok, true);
  const r = evaluateLine('afford 50000 c', makeEnv());
  assert.equal(r.ok, false);
  assert.equal(r.shortfall, 18707);
  closeTo(r.s, (18707 / 10520) * 3600);
});

test('assignment and reference across a doc', () => {
  const env = makeEnv();
  const results = evaluateDoc(['total = 9800 + 3600 ideo', 'until total'], env);
  assert.equal(results[0].ok, true);
  assert.equal(results[1].ok, true);
  closeTo(results[1].value.s, 21600);
});

test('a broken line does not poison the doc', () => {
  const env = makeEnv();
  const results = evaluateDoc(['+++', 'x = 5 + 5', 'x * 2'], env);
  assert.equal(results[0].ok, false);
  assert.equal(results[1].ok, true);
  assert.equal(results[2].value.v, 20);
});

test('error codes', () => {
  const codeOf = (src) => {
    try {
      evaluateLine(src, makeEnv());
      return null;
    } catch (e) { return e.code; }
  };
  assert.equal(codeOf('until 5000'), 'NEED_RESOURCE');
  assert.equal(codeOf('foo + 1'), 'UNKNOWN_NAME');
  assert.equal(codeOf('h = 5'), 'NAME_TAKEN');
  assert.equal(codeOf('1/0'), 'DIV_ZERO');
  assert.equal(codeOf('credits + 4h'), 'BAD_OP');
  assert.equal(codeOf('credits ('), 'PARSE');
});

test('paused flag is carried on results', () => {
  const r = evaluateLine('until 13400 ideo', makeEnv({ isRunning: false }));
  assert.equal(r.paused, true);
});

test('until +N is relative to the line-creation snapshot', () => {
  const env = makeEnv();
  // snapshot taken when ideology was 4000; live value is 5000
  const results = evaluateDoc(
    [{ src: 'until +2000 i', base: { credit: 0, technology: 0, ideology: 4000 }, ts: NOW }],
    env,
  );
  const r = results[0].value;
  assert.equal(r.k, 'eta');
  assert.equal(r.target, 6000); // 4000 + 2000, NOT 5000 + 2000
  closeTo(r.s, ((6000 - 5000) / 1400) * 3600);
});

test('until +N without a snapshot falls back to the live value (preview)', () => {
  const r = evaluateLine('until +2800 i', makeEnv());
  assert.equal(r.target, 7800);
  closeTo(r.s, 2 * 3600);
});

test('note reminders: in <dur> <text>, anchored to line creation', () => {
  const env = makeEnv();
  const past = NOW - 3 * 3600 * 1000;
  const results = evaluateDoc(
    [{ src: 'in 2h colony ship arrives', ts: past }],
    env,
  );
  const r = results[0].value;
  assert.equal(r.k, 'note');
  assert.equal(r.text, 'colony ship arrives');
  assert.equal(r.when, past + 2 * 3600 * 1000);
  assert.equal(r.done, true); // written 3h ago, due after 2h → overdue

  const fresh = evaluateDoc([{ src: 'in 2h colony ship arrives', ts: NOW }], makeEnv())[0].value;
  assert.equal(fresh.done, false);
  closeTo(fresh.s, 2 * 3600);
});

test('note reminders: at +2h <text> and at <time> <text>', () => {
  const rel = evaluateDoc([{ src: 'at +2h colony ship arrives', ts: NOW }], makeEnv())[0].value;
  assert.equal(rel.k, 'note');
  assert.equal(rel.when, NOW + 2 * 3600 * 1000);

  const abs = evaluateDoc([{ src: 'at 22:00 move the navarch', ts: NOW }], makeEnv())[0].value;
  assert.equal(abs.k, 'note');
  assert.equal(abs.text, 'move the navarch');
  closeTo(abs.s, ((22 - 12) * 60 - 10) * 60);
});

test('note labels ride on until and afford results', () => {
  const r = evaluateLine('until 13400 ideo buy the lex', makeEnv());
  assert.equal(r.k, 'eta');
  assert.equal(r.label, 'buy the lex');
  closeTo(r.s, 21600);

  const a = evaluateLine('afford 50000 c buy the battleship', makeEnv());
  assert.equal(a.label, 'buy the battleship');
});

test('note text survives characters the lexer does not know', () => {
  const r = evaluateLine("in 1h don't forget!", makeEnv({ }));
  assert.equal(r.k, 'note');
  assert.equal(r.text, "don't forget!");
});

test('junk characters inside real expressions still fail cleanly', () => {
  assert.throws(
    () => evaluateLine('9800 # 3600', makeEnv()),
    (e) => e instanceof CalcError && e.code === 'PARSE',
  );
});

test('buildEnv extrapolates stockpiles from receivedAt', () => {
  const env = buildEnv({
    now: NOW,
    effectiveSpeedFactor: 1,
    isRunning: true,
    receivedAt: NOW - 60 * 1000,
    player: {
      credit: { value: 31293, change: 526 },
      technology: { value: 7233, change: 50 },
      ideology: { value: 5000, change: 70 },
    },
    constant: { initial_policy_slot_cost: 200, policy_slot_maximum_cost: 100000 },
    maxPolicies: 5,
  });
  assert.equal(env.perHour, 20);
  // 60 s at 1/180 ut/s = 1/3 ut
  closeTo(env.resources.credit.value, 31293 + 526 / 3);
  // 2^(5-1) × 200 = 3200
  assert.equal(env.lexSlotCost, 3200);
});

test('buildEnv caps the lex slot cost', () => {
  const env = buildEnv({
    now: NOW,
    effectiveSpeedFactor: 1,
    isRunning: true,
    receivedAt: NOW,
    player: { credit: { value: 0, change: 0 }, technology: { value: 0, change: 0 }, ideology: { value: 0, change: 0 } },
    constant: { initial_policy_slot_cost: 200, policy_slot_maximum_cost: 100000 },
    maxPolicies: 12,
  });
  assert.equal(env.lexSlotCost, 100000);
});

// ---------------------------------------------------------------------------
// Shorthand: millions, aliases, bare amounts, freeform questions
// ---------------------------------------------------------------------------

test('uppercase M is always millions', () => {
  const r = evaluateLine('1.56M', makeEnv());
  assert.equal(r.k, 'scalar');
  closeTo(r.v, 1560000);
  const e = evaluateLine('until 1.56M tech', makeEnv());
  assert.equal(e.k, 'eta');
  closeTo(e.target, 1560000);
  assert.equal(evaluateLine('2M c + 500k c', makeEnv()).v, 2500000);
});

test('lowercase m is millions only before a resource word', () => {
  const e = evaluateLine('until 1.5m tech', makeEnv());
  assert.equal(e.k, 'eta');
  closeTo(e.target, 1500000);
  closeTo(evaluateLine('until 2m i', makeEnv()).target, 2000000);
});

test('lowercase m stays minutes everywhere else', () => {
  const d = evaluateLine('30m', makeEnv());
  assert.equal(d.k, 'dur');
  assert.equal(d.s, 1800);
  assert.equal(evaluateLine('in 30m', makeEnv()).k, 'snapshot');
  closeTo(evaluateLine('in 30m', makeEnv()).s, 1800);
  closeTo(evaluateLine('credits in 90m', makeEnv()).s, 5400);
  closeTo(evaluateLine('ideo income * 30m', makeEnv()).v, 700);
  // a note that happens to start with "i" after a minutes duration
  const note = evaluateDoc([{ src: 'in 30m i check the fleet', ts: NOW }], makeEnv())[0].value;
  assert.equal(note.k, 'note');
  assert.equal(note.text, 'i check the fleet');
  closeTo(note.s, 1800);
});

test('bare amount literal means until', () => {
  const r = evaluateLine('345k tech', makeEnv());
  assert.equal(r.k, 'eta');
  assert.equal(r.res, 'technology');
  assert.equal(r.target, 345000);
  assert.equal(canonicalize('345k tech'), 'until 345k tech');
});

test('arithmetic on amounts stays a plain amount', () => {
  const r = evaluateLine('9800 ideo + 3600', makeEnv());
  assert.equal(r.k, 'scalar');
  assert.equal(r.v, 13400);
  assert.equal(interpret('9800 ideo + 3600').changed, false);
  assert.equal(evaluateLine('credits', makeEnv()).k, 'scalar');
  assert.equal(evaluateLine('x = 30k tech', makeEnv()).k, 'scalar');
});

test('u and when are until aliases', () => {
  const u = evaluateLine('u 15k t', makeEnv());
  assert.equal(u.k, 'eta');
  assert.equal(u.res, 'technology');
  assert.equal(u.target, 15000);
  assert.equal(canonicalize('u 15k t'), 'until 15k t');
  assert.equal(canonicalize('when 13400 ideo'), 'until 13400 ideo');
  closeTo(evaluateLine('when 13400 ideo', makeEnv()).s, 21600);
  assert.equal(canonicalize('u +5000 c'), 'until +5000 c');
});

test('alias words stay usable as names', () => {
  const results = evaluateDoc(['u = 5', 'u * 2', 'when = 3', 'when + 1'], makeEnv());
  assert.equal(results[1].value.v, 10);
  assert.equal(results[3].value.v, 4);
  assert.equal(canonicalize('u = 5'), 'u = 5');
  assert.equal(canonicalize('u + 5000 c'), 'u + 5000 c');
});

test('freeform questions canonicalize to calculator lines', () => {
  const cases = {
    'when 30k tech?': 'until 30k tech',
    'until 30k tech?': 'until 30k tech',
    '30k tech?': 'until 30k tech',
    'when will I have 30k tech?': 'until 30k tech',
    'When will I have 30k tech': 'until 30k tech',
    'when do I have 1.5M credits?': 'until 1.5M credits',
    'how long until 80k tech?': 'until 80k tech',
    'how long till I have 80k tech?': 'until 80k tech',
    "when I'll have 20k ideo?": 'until 20k ideo',
    'until i have 30k tech': 'until 30k tech',
    'when can I afford 50k c?': 'afford 50k c',
    'can I afford 50k c?': 'afford 50k c',
    'afford 50k c?': 'afford 50k c',
    '1.56M tech': 'until 1.56M tech',
    '1.5m ideo?': 'until 1.5M ideo',
    'u 15k t': 'until 15k t',
  };
  Object.entries(cases).forEach(([src, canonical]) => {
    assert.equal(canonicalize(src), canonical, src);
    assert.equal(interpret(src).changed, true, src);
    assert.equal(canonicalize(canonical), canonical, `idempotent: ${canonical}`);
  });

  const q = evaluateLine('when will I have 13400 ideo?', makeEnv());
  assert.equal(q.k, 'eta');
  assert.equal(q.label, null);
  closeTo(q.s, 21600);

  const a = evaluateLine('when can I afford 50000 c?', makeEnv());
  assert.equal(a.k, 'afford');
  assert.equal(a.shortfall, 18707);
});

test('a standalone i after a number is still ideology', () => {
  assert.equal(canonicalize('30k i?'), 'until 30k i');
  assert.equal(evaluateLine('when will i have 30k i?', makeEnv()).res, 'ideology');
  assert.equal(canonicalize('when will i have 30k i'), 'until 30k i');
});

test('canonical lines already in syntax are left alone', () => {
  [
    'until 13400 ideo',
    'until 13400 ideo buy the lex',
    'credits in 8h',
    'in 2h colony ship arrives',
    '8400 / 70/tick',
    'total = 9800 + 3600 ideo',
  ].forEach((src) => {
    assert.deepEqual(interpret(src), { text: src, changed: false }, src);
  });
  // a question mark that is part of a note label survives
  assert.equal(canonicalize('in 2h did the colony ship land?'), 'in 2h did the colony ship land?');
  assert.equal(evaluateLine('in 2h did it land?', makeEnv()).text, 'did it land?');
});

test('unreadable questions still fail with the usual error codes', () => {
  const codeOf = (src) => {
    try {
      evaluateLine(src, makeEnv());
      return null;
    } catch (e) { return e.code; }
  };
  assert.equal(codeOf('when will I have 30k?'), 'NEED_RESOURCE');
  assert.equal(codeOf('foo bar?'), 'PARSE');
  assert.equal(codeOf('?'), 'PARSE');
  assert.equal(codeOf('when foo?'), 'UNKNOWN_NAME');
  assert.equal(canonicalize('foo bar?'), 'foo bar?');
});

test('completion words and known-word lookup', () => {
  const inserts = COMPLETIONS.map((c) => c.insert.trim());
  ['credit', 'tech', 'ideo', 'until', 'when'].forEach((w) => assert.ok(inserts.includes(w), w));
  ['tech', 'credit', 'until', 'when', 'u', 'in', 'ideo'].forEach((w) => assert.equal(isKnownWord(w), true, w));
  assert.equal(isKnownWord('cred'), false);
  assert.equal(isKnownWord('unt'), false);
});
