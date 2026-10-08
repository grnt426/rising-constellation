// Server clock + agent ETAs — plain node, no webpack:
//   node --test front/src/game/__tests__/clock.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  serverNow, liveRemaining, liveElapsed, queueFinishTimes, formatCountdown,
} from '../clock.js';

// Speed factor 18: one unit of game time = 10 s of wall time.
const FACTOR = 18;
const UNIT = 10000;

// The payload arrived at wall 1_000_000 reading server clock 500_000.
const running = { is_running: true, now_monotonic: 500000, receivedAt: 1000000 };

test('serverNow extrapolates from the reading while running', () => {
  assert.equal(serverNow(running, 1000000), 500000);
  assert.equal(serverNow(running, 1003000), 503000);
});

test('serverNow stands still while paused', () => {
  const paused = { ...running, is_running: false };
  assert.equal(serverNow(paused, 1060000), 500000);
});

test('serverNow is null without a reading (the old pause/resume broadcasts)', () => {
  assert.equal(serverNow({ ...running, now_monotonic: null }, 1000000), null);
  assert.equal(serverNow(undefined), null);
});

test('liveRemaining counts down from started_at, not the frozen snapshot', () => {
  // a 6-unit jump started 2 units before the reading; the snapshot still
  // says 6 left (it was taken when the jump started)
  const jump = {
    type: 'jump', total_time: 6, remaining_time: 6, started_at: 500000 - 2 * UNIT,
  };
  assert.equal(liveRemaining(jump, running, FACTOR, 1000000), 4);
  assert.equal(liveRemaining(jump, running, FACTOR, 1000000 + 3 * UNIT), 1);
  assert.equal(liveRemaining(jump, running, FACTOR, 1000000 + 9 * UNIT), 0);
});

test('liveRemaining falls back to remaining_time when it cannot tell', () => {
  const queued = { type: 'jump', total_time: 3, remaining_time: 3, started_at: null };
  assert.equal(liveRemaining(queued, running, FACTOR, 1000000), 3);
  const undecided = {
    type: 'infiltrate', total_time: 'unknown_yet', remaining_time: 'unknown_yet', started_at: 1,
  };
  assert.equal(liveRemaining(undecided, running, FACTOR, 1000000), 'unknown_yet');
});

test('queueFinishTimes chains durations after the live head', () => {
  const queue = [
    { type: 'jump', total_time: 6, remaining_time: 6, started_at: 500000 - 2 * UNIT },
    { type: 'jump', total_time: 3, remaining_time: 3, started_at: null },
    { type: 'bombing', total_time: 1.5, remaining_time: 1.5, started_at: null },
  ];
  assert.deepEqual(queueFinishTimes(queue, running, FACTOR, 1000000), [
    1000000 + 4 * UNIT,
    1000000 + 7 * UNIT,
    1000000 + 8.5 * UNIT,
  ]);
});

test('queueFinishTimes: unknown from the first undecided duration on', () => {
  const queue = [
    { type: 'jump', total_time: 1, remaining_time: 1, started_at: null },
    { type: 'infiltrate', total_time: 'unknown_yet', remaining_time: 'unknown_yet', started_at: null },
    { type: 'jump', total_time: 1, remaining_time: 1, started_at: null },
  ];
  assert.deepEqual(queueFinishTimes(queue, running, FACTOR, 1000000), [1000000 + UNIT, null, null]);
});

test('queueFinishTimes: a locked head takes no time', () => {
  const queue = [
    { type: 'locked', total_time: 100, remaining_time: 100, started_at: null },
    { type: 'jump', total_time: 2, remaining_time: 2, started_at: null },
  ];
  assert.deepEqual(queueFinishTimes(queue, running, FACTOR, 1000000), [1000000, 1000000 + 2 * UNIT]);
});

test('queueFinishTimes: a paused instance pushes every ETA back', () => {
  const paused = { ...running, is_running: false };
  const queue = [{ type: 'jump', total_time: 6, remaining_time: 6, started_at: 500000 - 2 * UNIT }];
  // 4 units left however long the pause lasts
  assert.deepEqual(queueFinishTimes(queue, paused, FACTOR, 1000000 + 60000), [1000000 + 60000 + 4 * UNIT]);
});

test('formatCountdown: "w D x H y M zs", leading zero units left out', () => {
  assert.equal(formatCountdown(0), '0s');
  assert.equal(formatCountdown(42 * 1000), '42s');
  assert.equal(formatCountdown((5 * 60) * 1000), '5 M 0s');
  assert.equal(formatCountdown((2 * 3600 + 7) * 1000), '2 H 0 M 7s');
  assert.equal(formatCountdown((86400 + 3 * 60 + 12) * 1000), '1 D 0 H 3 M 12s');
  assert.equal(formatCountdown((3 * 86400 + 4 * 3600 + 5 * 60 + 6) * 1000), '3 D 4 H 5 M 6s');
  assert.equal(formatCountdown(-5000), '0s');
});

test('liveElapsed carries a count forward from the clock reading it was taken at', () => {
  // 10 units counted when the clock read 470_000; it reads 500_000 now
  assert.equal(liveElapsed(10, 470000, running, FACTOR, 1000000), 13);
  assert.equal(liveElapsed(10, 470000, running, FACTOR, 1000000 + (2 * UNIT)), 15);
});

test('liveElapsed stands still while paused, and never goes back', () => {
  const paused = { ...running, is_running: false };
  assert.equal(liveElapsed(10, 470000, paused, FACTOR, 1060000), 13);
  // a reading from after the clock we hold (a fresher copy than our time)
  assert.equal(liveElapsed(10, 530000, running, FACTOR, 1000000), 10);
});

test('liveElapsed is the count as sent without a reading or a clock', () => {
  assert.equal(liveElapsed(10, null, running, FACTOR, 1000000), 10);
  assert.equal(liveElapsed(10, undefined, running, FACTOR, 1000000), 10);
  assert.equal(liveElapsed(10, 470000, undefined, FACTOR, 1000000), 10);
  assert.equal(liveElapsed(10, 470000, running, undefined, 1000000), 10);
  assert.equal(liveElapsed(undefined, 470000, running, FACTOR, 1000000), 0);
});
