// Debug report helpers — plain node, no webpack:
//   node --test front/src/game/debug/__tests__/debug.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  sanitize, scrubString, formatArgs, preview,
} from '../sanitize.js';
import { diffValues } from '../diff.js';
import { recordAssetLoad, diagnosticsState } from '../collector.js';
import { summarize } from '../stats.js';
import {
  BINS, binOf, Hist, Series, SeriesMap, Worst, slowdown,
} from '../series.js';

const JWT = 'eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiIxMjMiLCJ0eXAiOiJhY2Nlc3MifQ.c2lnbmF0dXJlLXNpZ25hdHVyZQ';
const PHX = 'SFMyNTY.g2gDYSpuBgBbX2F0eQFiAAFRgA.dGhpc2lzYXNpZ25hdHVyZXZhbHVl';

test('secret-named keys are redacted at any depth', () => {
  const out = sanitize({
    auth: { instance: 12, registration_token: PHX, user_token: JWT },
    portal: { apiToken: 'abc', account: { id: 3, email: 'a@b.co' } },
    headers: { Authorization: `Bearer ${JWT}` },
  });
  assert.deepEqual(out, {
    auth: { instance: 12, registration_token: '[redacted]', user_token: '[redacted]' },
    portal: { apiToken: '[redacted]', account: { id: 3, email: '[redacted]' } },
    headers: { Authorization: '[redacted]' },
  });
});

test('token shapes are scrubbed out of free text', () => {
  const s = scrubString(`boom ${JWT} and ${PHX} Bearer abc.def mail me@x.org /lobby?share_token=zzz&x=1`);
  assert.ok(!s.includes(JWT));
  assert.ok(!s.includes(PHX));
  assert.ok(!s.includes('me@x.org'));
  assert.ok(!s.includes('zzz'));
  assert.match(s, /\[redacted:jwt\]/);
  assert.match(s, /\[redacted:token\]/);
  assert.match(s, /Bearer \[redacted\]/);
  assert.match(s, /share_token=\[redacted\]&x=1/);
});

test('cycles collapse, shared references do not', () => {
  const shared = { n: 1 };
  const a = { left: shared, right: shared };
  a.self = a;
  const out = sanitize(a);
  assert.deepEqual(out, { left: { n: 1 }, right: { n: 1 }, self: '[circular]' });
});

test('limits cap arrays, keys, strings and depth', () => {
  const out = sanitize({
    arr: [1, 2, 3, 4, 5],
    str: 'x'.repeat(20),
    deep: { a: { b: { c: 1 } } },
  }, { maxArray: 2, maxString: 5, maxDepth: 3 });
  assert.deepEqual(out.arr, [1, 2, '…[+3 items]']);
  assert.equal(out.str, 'xxxxx…[+15 chars]');
  assert.deepEqual(out.deep, { a: { b: '[object]' } });
  assert.deepEqual(sanitize({ k1: 1, k2: 2, k3: 3 }, { maxKeys: 2 }), { k1: 1, k2: 2, '…': '+1 keys' });
});

test('exotic values degrade to markers instead of throwing', () => {
  const out = sanitize({
    big: 10n,
    fn: function named() {},
    nan: NaN,
    inf: Infinity,
    date: new Date(0),
    map: new Map([['a', 1]]),
    set: new Set([2]),
    typed: new Float32Array(3),
    err: new Error('nope'),
    undef: undefined,
    throwing: Object.defineProperty({}, 'x', { enumerable: true, get() { throw new Error('bad'); } }),
  });
  assert.equal(out.big, '10n');
  assert.equal(out.fn, '[function named]');
  assert.equal(out.nan, 'NaN');
  assert.equal(out.inf, 'Infinity');
  assert.equal(out.date, '1970-01-01T00:00:00.000Z');
  assert.deepEqual(out.map, [['a', 1]]);
  assert.deepEqual(out.set, [2]);
  assert.equal(out.typed, '[Float32Array 3]');
  assert.equal(out.err.message, 'nope');
  assert.ok(!('undef' in out));
  assert.equal(out.throwing.x, '[getter threw: bad]');
  assert.doesNotThrow(() => JSON.stringify(out));
});

test('formatArgs joins console arguments and keeps error stacks', () => {
  const line = formatArgs(['failed', new TypeError('x is undefined'), { a: 1, token: JWT }]);
  assert.match(line, /^failed TypeError: x is undefined/);
  assert.match(line, /"token":"\[redacted\]"/);
  assert.ok(!line.includes(JWT));
});

test('preview is short JSON', () => {
  assert.equal(preview({ a: [1, 2] }), '{"a":[1,2]}');
  assert.equal(preview('x'.repeat(400)).length <= 300 + 20, true);
  assert.equal(preview(undefined), undefined);
});

test('identical structs are equal, client stamps ignored', () => {
  const server = { id: 1, credit: { value: 10 }, stellar_systems: [{ id: 5, queue: [] }] };
  const client = {
    id: 1, credit: { value: 10 }, receivedAt: 123, stellar_systems: [{ id: 5, queue: [], queueReceivedAt: 9 }],
  };
  const d = diffValues(client, server);
  assert.equal(d.equal, true);
  assert.equal(d.count, 0);
});

test('changed scalars and type changes are reported with both sides', () => {
  const d = diffValues({ a: 1, b: { c: 'x' }, t: [1] }, { a: 2, b: { c: 'x' }, t: { 0: 1 } });
  assert.deepEqual(d.differences, [
    {
      path: 'a', kind: 'changed', client: '1', server: '2',
    },
    {
      path: 't', kind: 'changed', client: '[1]', server: '{"0":1}',
    },
  ]);
});

test('missing keys are reported from both directions', () => {
  const d = diffValues({ a: 1, gone: true }, { a: 1, fresh: 3 });
  assert.deepEqual(d.differences.map((x) => [x.path, x.kind]), [
    ['gone', 'extra_on_client'],
    ['fresh', 'missing_on_client'],
  ]);
});

test('record arrays match by id: one insertion is one difference', () => {
  const client = [{ id: 1, v: 'a' }, { id: 3, v: 'c' }];
  const server = [{ id: 1, v: 'a' }, { id: 2, v: 'b' }, { id: 3, v: 'c' }];
  const d = diffValues({ list: client }, { list: server });
  assert.deepEqual(d.differences.map((x) => [x.path, x.kind]), [['list[id=2]', 'missing_on_client']]);
});

test('record arrays report reordering and nested changes by id', () => {
  const client = [{ id: 1, v: 'a' }, { id: 2, v: 'b' }];
  const server = [{ id: 2, v: 'B' }, { id: 1, v: 'a' }];
  const d = diffValues({ q: client }, { q: server });
  assert.deepEqual(d.differences.map((x) => [x.path, x.kind]), [
    ['q', 'order'],
    ['q[id=2].v', 'changed'],
  ]);
});

test('plain arrays compare by index and report length', () => {
  const d = diffValues({ xs: [1, 2, 3] }, { xs: [1, 5] });
  assert.deepEqual(d.differences.map((x) => [x.path, x.kind]), [
    ['xs.length', 'length'],
    ['xs[1]', 'changed'],
    ['xs[2]', 'extra_on_client'],
  ]);
});

test('arrays with duplicate ids fall back to index matching', () => {
  const d = diffValues({ xs: [{ id: 1 }, { id: 1 }] }, { xs: [{ id: 1 }, { id: 2 }] });
  assert.deepEqual(d.differences.map((x) => x.path), ['xs[1].id']);
});

test('ticking values are flagged extrapolated and kept out of the structural count', () => {
  const client = {
    credit: { value: 100, change: 2, details: {} },
    cooldown: { value: 200, initial: 200 },
    ut_time_left: 50,
    owner: 'a',
    plain: { value: 1 },
  };
  const server = {
    credit: { value: 130, change: 2, details: {} },
    cooldown: { value: 70, initial: 200 },
    ut_time_left: 49,
    owner: 'b',
    plain: { value: 2 },
  };
  const d = diffValues(client, server);
  assert.deepEqual(d.differences.map((x) => [x.path, !!x.extrapolated]), [
    ['credit.value', true],
    ['cooldown.value', true],
    ['ut_time_left', true],
    ['owner', false],
    ['plain.value', false],
  ]);
  assert.equal(d.count, 5);
  assert.equal(d.structural, 2);
});

test('a changed rate is structural even inside a ticking value', () => {
  const d = diffValues({ credit: { value: 1, change: 2 } }, { credit: { value: 1, change: 3 } });
  assert.equal(d.structural, 1);
  assert.equal(d.differences[0].path, 'credit.change');
});

test('zero-value breakdown parts are cosmetic, non-zero ones are not', () => {
  const client = {
    technology: { value: 5, change: 1, details: {} },
    credit: { value: 1, change: 1, details: { misc: [{ reason: 'time', value: 1 }] } },
    ideology: { value: 1, change: 1, details: {} },
  };
  const server = {
    technology: { value: 5, change: 1, details: { system: [{ reason: 'Qing', value: 0 }] } },
    credit: { value: 1, change: 1, details: { misc: [{ reason: 'time', value: 1 }, { reason: 'mobility', value: 0 }] } },
    ideology: { value: 1, change: 1, details: { bonus: [{ reason: 'lex', value: 2 }] } },
  };
  const d = diffValues(client, server);
  assert.deepEqual(d.differences.map((x) => [x.path, !!x.cosmetic]), [
    ['technology.details.system', true],
    ['credit.details.misc.length', true],
    ['credit.details.misc[1]', true],
    ['ideology.details.bonus', false],
  ]);
  assert.equal(d.cosmetic, 3);
  assert.equal(d.structural, 1);
});

test('difference list is capped but the count is not', () => {
  const a = {};
  const b = {};
  for (let i = 0; i < 50; i += 1) { a[`k${i}`] = i; b[`k${i}`] = i + 1; }
  const d = diffValues(a, b, { maxDiffs: 10 });
  assert.equal(d.count, 50);
  assert.equal(d.differences.length, 10);
  assert.equal(d.truncated, true);
});

test('summarize computes percentiles', () => {
  const s = summarize([5, 1, 4, 2, 3, NaN, 'x']);
  assert.deepEqual(s, {
    n: 5, min: 1, p50: 3, p90: 5, p99: 5, max: 5, mean: 3,
  });
  assert.deepEqual(summarize([]), { n: 0 });
});

test('histogram bins grow monotonically and clamp at both ends', () => {
  assert.equal(binOf(0), 0);
  assert.equal(binOf(0.01), 0);
  assert.equal(binOf(-3), 0);
  assert.equal(binOf(1e12), BINS - 1);
  let prev = 0;
  for (let v = 0.02; v < 1e5; v *= 1.1) {
    const b = binOf(v);
    assert.ok(b >= prev, `bin of ${v} went down`);
    prev = b;
  }
});

test('histogram percentiles land within one bin of the exact value', () => {
  const h = new Hist();
  // deterministic spread over 0.1 .. 50 ms
  const values = [];
  let x = 7;
  for (let i = 0; i < 5000; i += 1) {
    x = (x * 48271) % 2147483647;
    values.push(0.1 + (x / 2147483647) * 49.9);
  }
  values.forEach((v) => h.add(v));
  const sorted = values.slice().sort((a, b) => a - b);
  [0.5, 0.9, 0.95, 0.99].forEach((p) => {
    const exact = sorted[Math.ceil(p * sorted.length) - 1];
    const approx = h.quantile(p);
    assert.ok(Math.abs(approx - exact) / exact < 0.25, `p${p * 100}: ${approx} vs ${exact}`);
  });
  const s = h.summary();
  assert.equal(s.n, 5000);
  assert.equal(s.max, Math.round(sorted[4999] * 100) / 100);
  assert.equal(new Hist().summary().n, 0);
});

test('series rolls windows, freezes a baseline after warm-up, and reports the slowdown', () => {
  const s = new Series({
    windowMs: 1000, keep: 5, warmupMs: 1000, baselineSamples: 50, minRecent: 5,
  });
  // warm-up second: slow, excluded from the baseline
  for (let i = 0; i < 20; i += 1) s.add(20, i * 50);
  // next two seconds: 1 ms frames — the baseline (50 samples)
  for (let i = 0; i < 40; i += 1) s.add(1, 1000 + i * 50);
  // a while later: 3 ms frames
  for (let i = 0; i < 20; i += 1) s.add(3, 9000 + i * 50);
  const sum = s.summary();
  assert.equal(sum.lifetime.n, 80);
  assert.equal(sum.baseline.n, 40 + 10);
  assert.ok(Math.abs(sum.baseline.p50 - 1) < 0.25);
  assert.ok(Math.abs(sum.recent.p50 - 3) < 0.75);
  assert.ok(sum.trend.p50 > 2.4 && sum.trend.p50 < 3.6, `trend ${sum.trend.p50}`);
  // baseline mean (40×1 + 10×3)/50 = 1.4; recent mean 3
  assert.equal(sum.trend.mean, Math.round((3 / 1.4) * 100) / 100);
  // windows: [start, n, p50, p95, max], oldest first, current last
  assert.deepEqual(sum.windows.map((w) => [w[0], w[1]]), [[0, 20], [1000, 20], [2000, 20], [9000, 20]]);
});

test('series ignores junk samples and falls back to the previous window when the current is sparse', () => {
  const s = new Series({
    windowMs: 1000, warmupMs: 0, baselineSamples: 10, minRecent: 5,
  });
  [NaN, -1, Infinity, 'x', undefined].forEach((v) => s.add(v, 0));
  assert.equal(s.summary().lifetime.n, 0);
  for (let i = 0; i < 10; i += 1) s.add(2, i * 10);
  s.add(8, 1500); // one sample in a new window: too sparse to be "recent"
  const sum = s.summary();
  assert.ok(Math.abs(sum.recent.p50 - 2) < 0.5);
  assert.equal(sum.recent.n, 10);
});

test('slowdown is > 1 when slower, inverted for throughput, and silent on noise', () => {
  const sum = (bn, bm, rn, rm) => ({ baseline: { n: bn, mean: bm }, recent: { n: rn, mean: rm } });
  assert.equal(slowdown(sum(100, 2, 100, 3)), 1.5);
  assert.equal(slowdown(sum(100, 200, 100, 100), true), 2); // MB/s halved
  assert.equal(slowdown(sum(100, 0.2, 100, 0.3)), null); // sub-0.5 ms: timer noise
  assert.equal(slowdown(sum(5, 2, 100, 3)), null); // thin baseline
  assert.equal(slowdown(sum(100, 2, 5, 3)), null); // thin recent window
  assert.equal(slowdown({ baseline: null, recent: null }), null);
  assert.equal(slowdown(undefined), null);
});

test('map asset loads are counted by outcome, with a readable reason per failed attempt', () => {
  const imageError = { type: 'error', target: { tagName: 'IMG' } };
  const http404 = { type: 'load', target: { status: 404 } };
  recordAssetLoad({
    url: 'map/systems/player.png', ok: true, attempts: 1, ms: 40, errors: [],
  });
  recordAssetLoad({
    url: 'map/systems/inhabited.png', ok: true, attempts: 2, ms: 1100, errors: [imageError],
  });
  recordAssetLoad({
    url: 'fonts/nunito-regular.json',
    ok: false,
    attempts: 4,
    ms: 13200,
    errors: [http404, http404, new SyntaxError('Unexpected token <'), http404],
  });
  const a = diagnosticsState().assets;
  assert.deepEqual([a.loads, a.firstTry, a.recovered, a.failed], [3, 1, 1, 1]);
  assert.equal(a.loadMs.summary().lifetime.n, 2);
  assert.deepEqual(a.problems.toArray().map((p) => [p.url, p.ok, p.attempts, p.errors]), [
    ['map/systems/inhabited.png', true, 2, ['error event on <img>']],
    ['fonts/nunito-regular.json', false, 4, ['HTTP 404', 'HTTP 404', 'SyntaxError: Unexpected token <', 'HTTP 404']],
  ]);
});

test('series map pools names past its capacity into "other"', () => {
  const m = new SeriesMap({}, 2);
  m.get('a').add(1);
  m.get('b').add(1);
  m.get('c').add(1);
  m.get('d').add(1);
  assert.deepEqual(m.entries().map(([k, v]) => [k, v.lifetime.n]), [['a', 1], ['b', 1], ['other', 2]]);
  assert.equal(m.get('a').lifetime.n, 1);
});

test('worst keeps the K largest samples, building details only for those', () => {
  const w = new Worst(3);
  let built = 0;
  [5, 1, 9, 3, 7, 2].forEach((v) => w.add(v, () => { built += 1; return { what: `v${v}` }; }));
  assert.deepEqual(w.toArray().map((e) => [e.ms, e.what]), [[9, 'v9'], [7, 'v7'], [5, 'v5']]);
  assert.ok(built < 6, 'details were built for samples that never ranked');
});
