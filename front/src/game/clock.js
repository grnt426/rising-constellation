// The server's action clock, and agent ETAs derived from it.
//
// Every action's `started_at` is a reading of the server's action clock
// (monotonic time minus the instance's cumulated pauses). `store.game.time`
// carries a reading of that clock (`now_monotonic`) and when it arrived
// (`receivedAt`), so the client can tell how far along a running action is
// without the server refreshing `remaining_time` — which it only does when
// an action starts or finishes: a moving agent's snapshot keeps the value it
// had when its jump started for the whole jump.
//
// Pure (no store, no Vue), so it runs under plain node for tests:
//   node --test front/src/game/__tests__/clock.test.mjs

// One unit of game time, in ms, at speed factor 1.
export const UNIT_MS = 180000;

/**
 * The server's action clock right now, or null when unknown.
 *
 * Frozen while the instance is paused (autosaves pause it for a few seconds
 * every ~15 minutes): the engine does not simulate then, and on resume the
 * clock picks up where it stopped.
 */
export function serverNow(time, wallNow = Date.now()) {
  if (!time || time.now_monotonic == null || time.receivedAt == null) return null;
  if (time.is_running === false) return time.now_monotonic;
  return time.now_monotonic + (wallNow - time.receivedAt);
}

/**
 * Units of game time left on `action` right now: derived from `started_at`
 * for a running action, else its `remaining_time` as sent (a queued action's
 * whole duration, or 'unknown_yet' while that isn't decided).
 */
export function liveRemaining(action, time, speedFactor, wallNow = Date.now()) {
  const { remaining_time: remaining, total_time: total, started_at: startedAt } = action;
  if (typeof remaining !== 'number' || typeof total !== 'number') return remaining;
  const now = serverNow(time, wallNow);
  if (startedAt == null || now == null || !speedFactor) return remaining;
  return Math.max(0, total - ((now - startedAt) * speedFactor) / UNIT_MS);
}

/**
 * A count of game time that only the server advances, as it stands right
 * now: `value` units were counted when the server's action clock read `at`.
 * Without a reading (`at` null, or no clock yet) it is `value` as sent.
 *
 * A student's `training.elapsed` is such a count: its agent only ticks at
 * its next event, hours apart (Instance.Character.Training).
 */
export function liveElapsed(value, at, time, speedFactor, wallNow = Date.now()) {
  if (typeof value !== 'number') return 0;
  const now = serverNow(time, wallNow);
  if (typeof at !== 'number' || now == null || !speedFactor) return value;
  return value + Math.max(0, ((now - at) * speedFactor) / UNIT_MS);
}

/**
 * When each entry of `queue` will be done, as wall-clock ms — or null once
 * an entry's duration isn't known yet (that entry and every one after it).
 * Entries run back to back, the head first.
 *
 * A `locked` head (the orchestrator running a start/finish hook) takes no
 * time of its own.
 */
export function queueFinishTimes(queue, time, speedFactor, wallNow = Date.now()) {
  const msPerUnit = speedFactor ? UNIT_MS / speedFactor : null;
  let at = wallNow;
  let known = msPerUnit != null;

  return (queue || []).map((action) => {
    if (!known) return null;
    if (action.type === 'locked') return at;
    const remaining = liveRemaining(action, time, speedFactor, wallNow);
    if (typeof remaining !== 'number') {
      known = false;
      return null;
    }
    at += remaining * msPerUnit;
    return at;
  });
}

/**
 * A duration as "w D x H y M zs" (days, hours, minutes, seconds). Leading
 * zero units are left out: "5 M 0s", "1 D 0 H 3 M 12s".
 */
export function formatCountdown(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;

  const parts = [];
  if (days) parts.push(`${days} D`);
  if (days || hours) parts.push(`${hours} H`);
  if (days || hours || minutes) parts.push(`${minutes} M`);
  parts.push(`${seconds}s`);
  return parts.join(' ');
}
