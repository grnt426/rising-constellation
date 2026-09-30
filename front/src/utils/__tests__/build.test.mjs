// Client/server build comparison — plain node, no webpack:
//   node --test front/src/utils/__tests__/build.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildStatus, CLIENT_VERSION } from '../build.js';

const T1 = '2026-09-30T10:00:00Z';
const T2 = '2026-09-30T12:00:00Z';
const T3 = '2026-10-02T09:00:00Z';
const live = (version, liveSince, deploying = false) => ({ version, live_since: liveSince, deploying });

test('outside a build the bundle calls itself dev', () => {
  assert.equal(CLIENT_VERSION, 'dev');
});

test('no server build yet is unknown', () => {
  assert.deepEqual(buildStatus('abc123', null, null), { status: 'unknown', restartedSinceLoad: null });
});

test('abc123 -> deploy abc456 -> rollback abc123: the rollback is told apart from the original', () => {
  const atLoad = live('abc123', T1);
  // loaded on abc123
  assert.deepEqual(buildStatus('abc123', atLoad, atLoad), { status: 'current', restartedSinceLoad: false });
  // abc456 went live: this tab's code is not the server's any more
  assert.deepEqual(buildStatus('abc123', atLoad, live('abc456', T2, true)), { status: 'stale', restartedSinceLoad: true });
  // rolled back: the same code again, but a server that came online after this tab loaded
  assert.deepEqual(buildStatus('abc123', atLoad, live('abc123', T3)), { status: 'current', restartedSinceLoad: true });
  // a tab loaded after the rollback sees the same revision with no restart since
  assert.deepEqual(buildStatus('abc123', live('abc123', T3), live('abc123', T3)), { status: 'current', restartedSinceLoad: false });
});

test('a tab loaded mid-deploy (new front end, old server) is ahead, then current', () => {
  const atLoad = live('abc123', T1, true);
  assert.deepEqual(buildStatus('abc456', atLoad, atLoad), { status: 'ahead_of_server', restartedSinceLoad: false });
  assert.deepEqual(buildStatus('abc456', atLoad, live('abc456', T2, true)), { status: 'current', restartedSinceLoad: true });
});

test('a bundle that differs with no deploy under way is stale (e.g. served from an old cache)', () => {
  const atLoad = live('abc456', T2);
  assert.deepEqual(buildStatus('abc123', atLoad, atLoad), { status: 'stale', restartedSinceLoad: false });
});

test('a plain restart on the same revision keeps the tab current but marks the restart', () => {
  assert.deepEqual(buildStatus('abc123', live('abc123', T1), live('abc123', T2)), { status: 'current', restartedSinceLoad: true });
});
