// When a system's construction queue will be empty, from the owner's
// summary of it (`player.stellar_systems` / `player.dominions`).
//
// `queue_remaining_time` is the units of game time left on the whole queue
// as of the payload that carried it: the server counts every summary down
// before each reply and broadcast (Instance.Player.StellarSystem
// .advance_queue), so a full player payload is current for all its systems.
// From there the client counts down itself, on the server clock where it
// has a reading (it stands still while the instance is paused), else on the
// wall clock.
//
// Pure (no store, no Vue), so it runs under plain node for tests:
//   node --test front/src/game/__tests__/queue-eta.test.mjs

import { serverNow } from './clock.js';

/**
 * The anchors a summary needs, taken when it arrives: wall time, and the
 * server clock's reading at that instant (null when unknown).
 */
export function queueStamps(time, receivedAt) {
  return { queueReceivedAt: receivedAt, queueClockAt: serverNow(time, receivedAt) };
}

// ms of running game time since the summary arrived
function elapsedMs(system, time, wallNow) {
  const now = serverNow(time, wallNow);
  if (typeof system.queueClockAt === 'number' && now != null) {
    return Math.max(0, now - system.queueClockAt);
  }
  if (typeof system.queueReceivedAt !== 'number' || (time && time.is_running === false)) return 0;
  return Math.max(0, wallNow - system.queueReceivedAt);
}

/**
 * `{ state, remainingMs, finishAt }` for a system summary.
 *
 * states: 'running' (remainingMs of game time left, done at wall-clock
 * `finishAt` if nothing changes), 'stalled' (queued, but no production: a
 * siege), 'unknown' (queued, but the game speed isn't loaded yet), 'empty'.
 *
 * `msPerUnit` is one unit of game time in ms (store: tickToMilisecondFactor).
 */
export function queueEta(system, time, msPerUnit, wallNow = Date.now()) {
  const remaining = system.queue_remaining_time;
  if (!(system.queue > 0)) return { state: 'empty' };
  if (typeof remaining !== 'number') return { state: 'stalled' };
  if (!(msPerUnit > 0)) return { state: 'unknown' };

  const remainingMs = Math.max(0, remaining * msPerUnit - elapsedMs(system, time, wallNow));
  return { state: 'running', remainingMs, finishAt: wallNow + remainingMs };
}

const RANK = { running: 0, unknown: 1, stalled: 1, empty: 2 };

/**
 * Sort order for two `queueEta` results: the queue that empties soonest
 * first, then the ones without a time, then empty ones. 0 on a tie (to the
 * second: anchors of the same instant differ by network jitter).
 */
export function compareQueueEta(a, b) {
  if (RANK[a.state] !== RANK[b.state]) return RANK[a.state] - RANK[b.state];
  if (a.state !== 'running') return 0;
  return Math.round(a.remainingMs / 1000) - Math.round(b.remainingMs / 1000);
}
