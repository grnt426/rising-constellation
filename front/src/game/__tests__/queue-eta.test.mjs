// Construction-queue ETAs of the systems list — plain node, no webpack:
//   node --test front/src/game/__tests__/queue-eta.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { queueStamps, queueEta, compareQueueEta } from '../queue-eta.js';

// Speed factor 18: one unit of game time = 10 s of wall time.
const UNIT = 10000;

// The time payload arrived at wall 1_000_000 reading server clock 500_000.
const running = { is_running: true, now_monotonic: 500000, receivedAt: 1000000 };

// A summary with 6 units left, arrived at wall 1_000_000.
const summary = (extra = {}) => ({
  id: 1, queue: 2, queue_remaining_time: 6, ...queueStamps(running, 1000000), ...extra,
});

test('a fresh summary reads its full remaining time', () => {
  const eta = queueEta(summary(), running, UNIT, 1000000);
  assert.deepEqual(eta, { state: 'running', remainingMs: 6 * UNIT, finishAt: 1000000 + 6 * UNIT });
});

test('it counts down, and the finish time holds still', () => {
  const eta = queueEta(summary(), running, UNIT, 1000000 + 2 * UNIT);
  assert.equal(eta.remainingMs, 4 * UNIT);
  assert.equal(eta.finishAt, 1000000 + 6 * UNIT);
});

test('it stops at zero once the time has run out', () => {
  const eta = queueEta(summary(), running, UNIT, 1000000 + 9 * UNIT);
  assert.equal(eta.remainingMs, 0);
});

test('a pause does not count: the server clock stood still', () => {
  // paused 2 units in, for 30 s, then running again for 1 unit
  const pausedAt = 1000000 + 2 * UNIT;
  const paused = { is_running: false, now_monotonic: 500000 + 2 * UNIT, receivedAt: pausedAt };
  assert.equal(queueEta(summary(), paused, UNIT, pausedAt + 20000).remainingMs, 4 * UNIT);

  const resumedAt = pausedAt + 30000;
  const resumed = { is_running: true, now_monotonic: 500000 + 2 * UNIT, receivedAt: resumedAt };
  const eta = queueEta(summary(), resumed, UNIT, resumedAt + UNIT);
  assert.equal(eta.remainingMs, 3 * UNIT);
  assert.equal(eta.finishAt, resumedAt + 4 * UNIT);
});

test('without a clock reading it falls back to the wall clock', () => {
  const noClock = { is_running: true, now_monotonic: null, receivedAt: 1000000 };
  const stamped = summary(queueStamps(noClock, 1000000));
  assert.equal(stamped.queueClockAt, null);
  assert.equal(queueEta(stamped, noClock, UNIT, 1000000 + 2 * UNIT).remainingMs, 4 * UNIT);
  // paused: no way to tell how long it ran, the value is shown as received
  assert.equal(queueEta(stamped, { ...noClock, is_running: false }, UNIT, 1000000 + 2 * UNIT).remainingMs, 6 * UNIT);
});

test('a summary without stamps is taken as fresh', () => {
  const bare = { id: 1, queue: 1, queue_remaining_time: 6 };
  assert.equal(queueEta(bare, running, UNIT, 1000000 + 2 * UNIT).remainingMs, 6 * UNIT);
});

test('empty and stalled queues have no time', () => {
  assert.deepEqual(queueEta(summary({ queue: 0, queue_remaining_time: 'never' }), running, UNIT), { state: 'empty' });
  assert.deepEqual(queueEta(summary({ queue_remaining_time: 'stalled' }), running, UNIT), { state: 'stalled' });
  // speed not loaded yet
  assert.deepEqual(queueEta(summary(), running, undefined), { state: 'unknown' });
});

test('soonest first, then stalled, then empty', () => {
  const at = (extra) => queueEta(summary(extra), running, UNIT, 1000000);
  const list = [
    { name: 'empty', eta: at({ queue: 0, queue_remaining_time: 'never' }) },
    { name: 'monolith', eta: at({ queue: 1, queue_remaining_time: 900 }) },
    { name: 'stalled', eta: at({ queue_remaining_time: 'stalled' }) },
    { name: 'twenty-buildings', eta: at({ queue: 20, queue_remaining_time: 60 }) },
    { name: 'almost-done', eta: at({ queue: 3, queue_remaining_time: 0.5 }) },
  ];

  const sorted = list.slice().sort((a, b) => compareQueueEta(a.eta, b.eta)).map((e) => e.name);
  assert.deepEqual(sorted, ['almost-done', 'twenty-buildings', 'monolith', 'stalled', 'empty']);
});

test('the order compares what is left now, whatever the age of each summary', () => {
  // 10 units left as of 8 units ago beats 5 units left as of now
  const old = summary({ queue_remaining_time: 10 });
  const now = 1000000 + 8 * UNIT;
  const fresh = summary({ queue_remaining_time: 5, ...queueStamps(running, now) });
  assert.ok(compareQueueEta(queueEta(old, running, UNIT, now), queueEta(fresh, running, UNIT, now)) < 0);
});

test('summaries a network hiccup apart tie', () => {
  const a = queueEta(summary(), running, UNIT, 1000000);
  const b = queueEta(summary(queueStamps(running, 1000120)), running, UNIT, 1000120);
  assert.equal(compareQueueEta(a, { ...b, remainingMs: b.remainingMs + 120 }), 0);
});
