// An agent's plan as STOPS.
//
// The server stores a flat queue: single-lane jumps and actions, each
// valid only because of where the entries before it leave the agent. The
// player thinks in stops — "go to C, bombard and pillage it, then go to
// D" — with the jumps in between being route, not orders. This module
// converts one to the other so the plan can be edited stop by stop (and
// re-routed) without the player ever juggling individual jumps.
//
// A stop ends a leg at a system the player chose. New orders mark it with
// `data.stop = true` on the leg's last jump (see map.js
// addCharacterAction); queues without markers (older orders) get a stop
// wherever an action happens and at the very end.
//
// Pure: pathfinding comes in as `route(fromId, toId) -> [id, ...]`
// (from and to included), so this runs under plain node for tests.

export const GATEWAY_TYPES = ['gateway_charge', 'gateway_jump', 'gateway_fatigue'];

const isJump = (entry) => entry.type === 'jump';
const isGateway = (entry) => GATEWAY_TYPES.includes(entry.type);

// Keys the server adds to jump data; never re-sent.
const SERVER_KEYS = ['source_position', 'target_position'];

/**
 * Group a (lock-stripped) queue into stops.
 *
 * `origin`: where the plan starts (the agent's system; for an agent in
 * transit, the first jump's source).
 *
 * Each stop: { key, target, via: [ids], entries, actions, gateway,
 * gatewaySource, implicit }. `entries` are the queue entries (with their
 * queue `index`) the stop is made of: its leg's jumps, then its actions.
 */
export function groupStops(queue, origin) {
  const stops = [];
  let leg = [];
  let pos = origin;
  let open = null; // the last stop, while no jump has left it

  const close = (target, extra = {}) => {
    const stop = {
      key: null,
      target,
      via: leg.filter(isJump).map((e) => e.data.target).filter((id, i, all) => i < all.length - 1 || id !== target),
      entries: leg.slice(),
      actions: [],
      gateway: false,
      gatewaySource: null,
      implicit: false,
      ...extra,
    };
    stops.push(stop);
    leg = [];
    open = stop;
    return stop;
  };

  (queue || []).forEach((raw, index) => {
    const entry = { ...raw, index };

    if (isJump(entry)) {
      leg.push(entry);
      pos = entry.data.target;
      open = null;
      if (entry.data.stop) close(pos);
      return;
    }

    if (isGateway(entry)) {
      // a charge ends its leg on the far side; the transit/fatigue
      // phases the engine injects later belong to the same stop
      if (open && open.gateway && open.target === entry.data.target && leg.length === 0) {
        open.entries.push(entry);
      } else {
        leg.push(entry);
        close(entry.data.target, { gateway: true, gatewaySource: entry.data.source });
      }
      pos = entry.data.target;
      return;
    }

    const target = entry.data && entry.data.target != null ? entry.data.target : pos;
    let stop = open && open.target === target && leg.length === 0 ? open : null;
    if (!stop) stop = close(leg.length ? pos : target, { implicit: leg.length > 0 });
    stop.entries.push(entry);
    stop.actions.push(entry);
  });

  if (leg.length) close(pos, { implicit: true });

  stops.forEach((stop) => { stop.key = keyOf(stop); });
  return stops;
}

// Stable identity for a stop across regroupings: the uid of the entry
// that defines it (its first action, else its leg's last entry).
function keyOf(stop) {
  const defining = stop.actions[0] || stop.entries[stop.entries.length - 1];
  if (defining && defining.uid != null) return `u${defining.uid}`;
  return defining ? `i${defining.index}:${stop.target}` : `t${stop.target}`;
}

/**
 * The part of the plan a player can edit: everything but the running head.
 *
 * Returns { head, headStop, stops } where `headStop` is the head's own
 * stop minus the head (its remaining jumps/actions; null if nothing
 * remains) and `stops` the stops after it. `from` is where the agent will
 * be once the head is done.
 */
export function editablePlan(queue, origin) {
  const all = groupStops(queue, origin);
  if (!all.length) return { head: null, from: origin, headStop: null, stops: [] };

  const head = { ...queue[0], index: 0 };
  const [first, ...rest] = all;
  const remaining = first.entries.filter((e) => e.index !== 0);
  const from = positionAfter(head, origin);

  // What is left of the head's own stop once the head is done: the rest of
  // its leg (routed from where the head lands — a started gateway transit
  // needs no routing) and its other actions.
  const remainingJumps = remaining.filter(isJump).map((e) => e.data.target);
  const headStop = remaining.length
    ? {
      ...first,
      entries: remaining,
      actions: first.actions.filter((e) => e.index !== 0),
      via: remainingJumps.filter((id, i) => i < remainingJumps.length - 1 || id !== first.target),
      gateway: first.gateway && remaining.some((e) => e.type === 'gateway_charge'),
    }
    : null;

  return { head, from, headStop, stops: rest };
}

function positionAfter(entry, origin) {
  if (!entry) return origin;
  if (isJump(entry) || isGateway(entry)) return entry.data.target;
  return entry.data && entry.data.target != null ? entry.data.target : origin;
}

/**
 * The jumps that take the agent from `pos` to `stop`: its existing leg if
 * that still starts at `pos` (an untouched stop keeps its exact route —
 * ties and older hand-picked routes don't shift), else a fresh route.
 * Returns [{ source, target, uid? }].
 */
export function legFor(stop, pos, route) {
  const dest = stop.gateway ? stop.gatewaySource : stop.target;
  const old = stop.entries.filter(isJump);
  const chained = old.length > 0
    && old[0].data.source === pos
    && old[old.length - 1].data.target === dest
    && old.every((e, i) => i === 0 || old[i - 1].data.target === e.data.source);
  if (chained) return old.map((e) => ({ source: e.data.source, target: e.data.target, uid: e.uid }));
  if (pos === dest) return [];

  const path = route(pos, dest);
  if (!path || path.length === 0) throw new PlanError('no_route', dest);

  const uids = new Map(old.map((e) => [`${e.data.source}>${e.data.target}`, e.uid]));
  const hops = [];
  for (let i = 0; i < path.length - 1; i += 1) {
    hops.push({ source: path[i], target: path[i + 1], uid: uids.get(`${path[i]}>${path[i + 1]}`) });
  }
  return hops;
}

/**
 * Rebuild the queue tail for `stops` (in order), starting at `from`:
 * the leg to each stop, then its actions. Re-sent entries carry their uid
 * (the server keeps it when type/target/source match), so identities —
 * and stop keys — survive the edit.
 */
export function buildTail(stops, from, route) {
  const tail = [];
  let pos = from;

  stops.forEach((stop) => {
    const charge = stop.gateway ? stop.entries.find((e) => e.type === 'gateway_charge') : null;
    if (stop.gateway && !charge) throw new PlanError('gateway_in_transit', stop.target);

    const hops = legFor(stop, pos, route);
    hops.forEach((hop, i) => {
      const data = { source: hop.source, target: hop.target };
      if (!stop.gateway && i === hops.length - 1) data.stop = true;
      tail.push(withUid({ type: 'jump', data }, hop.uid));
    });

    if (charge) tail.push(resend(charge));
    pos = stop.target;

    stop.actions.forEach((action) => tail.push(resend(action, pos)));
  });

  return tail;
}

function resend(entry, target) {
  const data = { ...entry.data };
  SERVER_KEYS.forEach((k) => delete data[k]);
  if (target != null && data.target != null) data.target = target;
  return withUid({ type: entry.type, data }, entry.uid);
}

function withUid(payload, uid) {
  return uid != null ? { ...payload, uid } : payload;
}

export class PlanError extends Error {
  constructor(reason, systemId) {
    super(reason);
    this.reason = reason;
    this.systemId = systemId;
  }
}

// ---- edits --------------------------------------------------------------
// Each returns the new { headStop, stops } (inputs untouched).

export function removeStop(plan, key) {
  if (plan.headStop && plan.headStop.key === key) return { ...plan, headStop: null };
  return { ...plan, stops: plan.stops.filter((s) => s.key !== key) };
}

export function removeAction(plan, stopKey, uid) {
  const strip = (stop) => {
    if (!stop || stop.key !== stopKey) return stop;
    return {
      ...stop,
      actions: stop.actions.filter((a) => a.uid !== uid),
      entries: stop.entries.filter((e) => e.uid !== uid),
    };
  };
  return { ...plan, headStop: strip(plan.headStop), stops: plan.stops.map(strip) };
}

/** Move the stop `key` to position `to` among the editable stops. */
export function moveStop(plan, key, to) {
  const from = plan.stops.findIndex((s) => s.key === key);
  if (from === -1) return plan;
  const stops = plan.stops.slice();
  const [stop] = stops.splice(from, 1);
  stops.splice(Math.max(0, Math.min(to, stops.length)), 0, stop);
  return { ...plan, stops };
}

/** The payload for `edit_character_actions`. */
export function editPayload(characterId, plan, route) {
  const stops = plan.headStop ? [plan.headStop, ...plan.stops] : plan.stops;
  return {
    character_id: characterId,
    keep_uid: plan.head.uid,
    actions: buildTail(stops, plan.from, route),
  };
}

/**
 * What an edit changes, for the player: stops removed, actions removed,
 * legs whose route changed, and removed stops the agent still passes
 * through on the way somewhere else (the "why is B still there?" case).
 */
export function summarize(before, after, route) {
  const list = (plan) => (plan.headStop ? [plan.headStop, ...plan.stops] : plan.stops);
  const oldStops = list(before);
  const newStops = list(after);
  const newKeys = new Set(newStops.map((s) => s.key));

  const removedStops = oldStops.filter((s) => !newKeys.has(s.key));
  const removedActions = [];
  oldStops.forEach((s) => {
    const kept = newStops.find((n) => n.key === s.key);
    if (!kept) return;
    const keptUids = new Set(kept.actions.map((a) => a.uid));
    s.actions.filter((a) => !keptUids.has(a.uid)).forEach((a) => removedActions.push({ type: a.type, target: s.target }));
  });

  // the via each stop will actually have once rebuilt
  const rerouted = [];
  let pos = after.from;
  newStops.forEach((stop) => {
    const hops = legFor(stop, pos, route);
    const via = hops.map((h) => h.target).filter((id, i) => stop.gateway || i < hops.length - 1);
    const old = oldStops.find((s) => s.key === stop.key);
    if (old && !sameList(old.via, via)) rerouted.push({ target: stop.target, via, jumps: hops.length });
    stop.newVia = via;
    pos = stop.target;
  });

  const passThrough = [];
  removedStops.forEach((removed) => {
    const through = newStops.find((s) => (s.newVia || []).includes(removed.target));
    if (through) passThrough.push({ target: removed.target, on_way_to: through.target });
  });

  const moved = !sameList(
    oldStops.filter((s) => newKeys.has(s.key)).map((s) => s.key),
    newStops.map((s) => s.key),
  );

  return {
    removedStops: removedStops.map((s) => ({ target: s.target, actions: s.actions.map((a) => a.type) })),
    removedActions,
    rerouted,
    passThrough,
    moved,
  };
}

function sameList(a, b) {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}
