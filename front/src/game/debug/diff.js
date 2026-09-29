// Structural diff between the client's copy of a server struct and a fresh
// copy fetched at report time — the desync probe's core.
//
// The store only ever holds whole-object replacements of server payloads
// (plus a few client-stamped anchors), so a fresh fetch of the same struct
// should match it field for field, give or take what changed server-side
// since the last broadcast. Every difference is listed with its path and a
// short preview of both sides; the reader decides which ones are drift.
//
// Arrays of records (every element an object carrying a unique `id`, `uid`
// or `key`) are matched by that key, so an insertion reports one missing
// record instead of shifting every index after it; a changed order is
// reported on its own. Other arrays compare index by index.
//
// Pure (no store, no Vue), so it runs under plain node:
//   node --test front/src/game/debug/__tests__/debug.test.mjs

import { preview } from './sanitize.js';

// Client-side anchors the store stamps onto server payloads (see
// game/store.js setPlayer / applyProductionDelta, websockets handleReceive).
export const CLIENT_STAMPED_KEYS = ['receivedAt', 'queueReceivedAt', 'resourcesReceivedAt'];

// Values the server advances every tick without broadcasting, which the
// client extrapolates from its last snapshot instead: a differing number
// there is expected drift, not a desync. Flagged `extrapolated` so the
// reader (and the report summary) can set them aside:
//   * `value` of a Core.DynamicValue ({value, change, details}) — resources,
//     game date;
//   * `value` of a countdown ({value, initial}) — cooldowns;
//   * bare countdown numbers named here.
export const COUNTDOWN_KEYS = ['ut_time_left', 'remaining_time'];

const isRunningValue = (parent) => parent && typeof parent === 'object'
  && typeof parent.value === 'number'
  && (typeof parent.change === 'number' || typeof parent.initial === 'number');

function extrapolated(key, parentA, parentB, a, b) {
  if (typeof a !== 'number' || typeof b !== 'number') return false;
  if (key === 'value') return isRunningValue(parentA) && isRunningValue(parentB);
  return COUNTDOWN_KEYS.includes(key);
}

// A zero contribution in a value's `details` breakdown ({reason, value: 0}).
// Ticks append them without broadcasting (nothing numeric changed), so the
// server's fresh copy often carries parts the client's never saw. Adding or
// dropping one changes no number: flagged `cosmetic`, not a desync.
const isZeroPart = (v) => v && typeof v === 'object' && !Array.isArray(v)
  && v.value === 0 && 'reason' in v;
const zeroParts = (v) => (Array.isArray(v) ? v.length > 0 && v.every(isZeroPart) : isZeroPart(v));

const kindOf = (v) => {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  return typeof v;
};

const RECORD_KEYS = ['id', 'uid', 'key'];

// The key an array's elements can be matched on, or null.
function recordKey(a, b) {
  const all = a.concat(b);
  if (!all.length) return null;
  for (let k = 0; k < RECORD_KEYS.length; k += 1) {
    const key = RECORD_KEYS[k];
    const ok = all.every((el) => el && typeof el === 'object' && !Array.isArray(el)
      && (typeof el[key] === 'string' || typeof el[key] === 'number'));
    if (ok) {
      const unique = (arr) => new Set(arr.map((el) => el[key])).size === arr.length;
      if (unique(a) && unique(b)) return key;
    }
  }
  return null;
}

const segment = (path, key) => (path ? `${path}.${key}` : String(key));

/**
 * @returns {{ equal: boolean, count: number, structural: number, cosmetic: number,
 *             truncated: boolean,
 *             differences: Array<{path: string, kind: string, client?: string,
 *                                 server?: string, extrapolated?: true, cosmetic?: true}> }}
 *
 * kinds: 'changed' (value or type differs), 'missing_on_client' (server has
 * it, the store doesn't), 'extra_on_client' (the store has it, the server
 * doesn't), 'order' (same records, different sequence), 'length'.
 * `structural` counts the differences that are neither `extrapolated`
 * drift nor `cosmetic` zero parts: the desync candidates.
 */
export function diffValues(client, server, options = {}) {
  const ignore = new Set(options.ignoreKeys || CLIENT_STAMPED_KEYS);
  const maxDiffs = options.maxDiffs || 200;
  const maxDepth = options.maxDepth || 24;
  const differences = [];
  let count = 0;
  let structural = 0;
  let cosmetic = 0;

  const add = (entry, isCosmetic) => {
    const e = isCosmetic ? { ...entry, cosmetic: true } : entry;
    count += 1;
    if (e.cosmetic) cosmetic += 1;
    else if (!e.extrapolated) structural += 1;
    if (differences.length < maxDiffs) differences.push(e);
  };
  const missing = (path, b) => add({ path, kind: 'missing_on_client', server: preview(b) }, zeroParts(b));
  const extra = (path, a) => add({ path, kind: 'extra_on_client', client: preview(a) }, zeroParts(a));

  const walk = (a, b, path, depth, key, parentA, parentB) => {
    if (a === b) return;
    if (typeof a === 'number' && typeof b === 'number' && Number.isNaN(a) && Number.isNaN(b)) return;

    const ka = kindOf(a);
    const kb = kindOf(b);
    if (ka === 'undefined' && kb !== 'undefined') {
      missing(path, b);
      return;
    }
    if (kb === 'undefined' && ka !== 'undefined') {
      extra(path, a);
      return;
    }
    if (ka !== kb || (ka !== 'object' && ka !== 'array')) {
      const entry = {
        path, kind: 'changed', client: preview(a), server: preview(b),
      };
      if (extrapolated(key, parentA, parentB, a, b)) entry.extrapolated = true;
      add(entry);
      return;
    }
    if (depth >= maxDepth) return;

    if (ka === 'array') {
      const key = recordKey(a, b);
      if (key) {
        const byKey = (arr) => new Map(arr.map((el) => [el[key], el]));
        const ma = byKey(a);
        const mb = byKey(b);
        const at = (k) => `${path}[${key}=${k}]`;
        a.forEach((el) => {
          if (!mb.has(el[key])) extra(at(el[key]), el);
        });
        b.forEach((el) => {
          if (!ma.has(el[key])) missing(at(el[key]), el);
        });
        const commonA = a.filter((el) => mb.has(el[key])).map((el) => el[key]);
        const commonB = b.filter((el) => ma.has(el[key])).map((el) => el[key]);
        if (commonA.some((k, i) => k !== commonB[i])) {
          add({
            path, kind: 'order', client: preview(commonA), server: preview(commonB),
          });
        }
        commonA.forEach((k) => walk(ma.get(k), mb.get(k), at(k), depth + 1));
        return;
      }

      if (a.length !== b.length) {
        const tail = (a.length > b.length ? a : b).slice(Math.min(a.length, b.length));
        add({
          path: `${path}.length`, kind: 'length', client: String(a.length), server: String(b.length),
        }, zeroParts(tail));
      }
      const n = Math.max(a.length, b.length);
      for (let i = 0; i < n; i += 1) walk(a[i], b[i], `${path}[${i}]`, depth + 1);
      return;
    }

    const keys = new Set(Object.keys(a).concat(Object.keys(b)));
    keys.forEach((k) => {
      if (!ignore.has(k) && k !== '__ob__') walk(a[k], b[k], segment(path, k), depth + 1, k, a, b);
    });
  };

  walk(client, server, options.root || '', 0);

  return {
    equal: count === 0,
    count,
    structural,
    cosmetic,
    truncated: count > differences.length,
    differences,
  };
}
