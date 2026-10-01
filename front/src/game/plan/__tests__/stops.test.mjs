// Plan (stops) model — plain node, no webpack:
//   node --test front/src/game/plan/__tests__/stops.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  groupStops, editablePlan, buildTail, removeStop, removeAction, removeStopsFrom, removeActionsFrom, moveStop,
  editPayload, summarize, PlanError,
} from '../stops.js';

// Galaxy used throughout (O is where the agent starts):
//
//   O — A — B — C — D
//        \       /
//         E — — '        (A–E–C: a way around B, shorter than A–B–C —
//                         only taken once B is no longer a stop)
//
// With `lineOnly`, E doesn't exist: B is the only way from A to C.
function router(lineOnly = false) {
  const edges = [['O', 'A', 1], ['A', 'B', 1], ['B', 'C', 1], ['C', 'D', 1]];
  if (!lineOnly) edges.push(['A', 'E', 0.8], ['E', 'C', 0.8]);
  const adj = new Map();
  edges.forEach(([a, b, w]) => {
    if (!adj.has(a)) adj.set(a, []);
    if (!adj.has(b)) adj.set(b, []);
    adj.get(a).push([b, w]);
    adj.get(b).push([a, w]);
  });
  // Dijkstra
  return (from, to) => {
    const dist = new Map([[from, 0]]);
    const prev = new Map();
    const todo = new Set([from]);
    while (todo.size) {
      const cur = [...todo].reduce((x, y) => (dist.get(x) <= dist.get(y) ? x : y));
      todo.delete(cur);
      if (cur === to) break;
      (adj.get(cur) || []).forEach(([nb, w]) => {
        const d = dist.get(cur) + w;
        if (!dist.has(nb) || d < dist.get(nb)) { dist.set(nb, d); prev.set(nb, cur); todo.add(nb); }
      });
    }
    if (!dist.has(to)) return null;
    const path = [to];
    while (path[0] !== from) path.unshift(prev.get(path[0]));
    return path;
  };
}

let uid = 100;
const jump = (source, target, stop = false) => ({
  type: 'jump', uid: uid++, data: { source, target, ...(stop ? { stop: true } : {}) },
});
const act = (type, target) => ({ type, uid: uid++, data: { target } });

// The example from the request: Move A, Move B, Move C, Bombard C, Pillage C, Move D
function example() {
  return [
    jump('O', 'A', true),
    jump('A', 'B', true),
    jump('B', 'C', true),
    act('raid', 'C'),
    act('loot', 'C'),
    jump('C', 'D', true),
  ];
}

const targets = (stops) => stops.map((s) => s.target);
const route = (tail) => tail.filter((a) => a.type === 'jump').map((a) => `${a.data.source}>${a.data.target}`);
const describeTail = (tail) => tail.filter((a) => a.type === 'jump').map((a) => `${a.data.source}>${a.data.target}${a.data.stop ? '*' : ''}`);

test('grouping: every marked leg is a stop; actions attach to their stop', () => {
  const stops = groupStops(example(), 'O');
  assert.deepEqual(targets(stops), ['A', 'B', 'C', 'D']);
  assert.deepEqual(stops[2].actions.map((a) => a.type), ['raid', 'loot']);
  assert.deepEqual(stops.map((s) => s.via), [[], [], [], []]);
});

test('grouping: a far-click order (only its destination marked) is one stop "via" the route', () => {
  const queue = [jump('O', 'A'), jump('A', 'B'), jump('B', 'C', true), act('raid', 'C'), jump('C', 'D', true)];
  const stops = groupStops(queue, 'O');
  assert.deepEqual(targets(stops), ['C', 'D']);
  assert.deepEqual(stops[0].via, ['A', 'B']);
  assert.deepEqual(stops[0].actions.map((a) => a.type), ['raid']);
});

test('grouping: unmarked jumps (queued before markers existed) are each their own stop', () => {
  // instance 185, 2026-09-28: 12 single-hop orders restored from a
  // snapshot showed as ONE stop "via 10 systems"
  const hops = ['O', 'A', 'B', 'C', 'D', 'E'];
  const queue = hops.slice(1).map((t, i) => jump(hops[i], t));
  const stops = groupStops(queue, 'O');
  assert.deepEqual(targets(stops), ['A', 'B', 'C', 'D', 'E']);
  assert.ok(stops.every((st) => st.via.length === 0));

  const plan = editablePlan(queue, 'O');
  assert.equal(plan.head.data.target, 'A');
  assert.deepEqual(targets(plan.stops), ['B', 'C', 'D', 'E']);
});

test('grouping: an unmarked run followed by an action: each jump a stop, the action at the last', () => {
  const queue = [jump('O', 'A'), jump('A', 'B'), act('raid', 'B'), act('loot', 'B')];
  const stops = groupStops(queue, 'O');
  assert.deepEqual(targets(stops), ['A', 'B']);
  assert.deepEqual(stops[1].actions.map((a) => a.type), ['raid', 'loot']);
});

test('grouping: older unmarked orders followed by new marked ones', () => {
  const queue = [jump('O', 'A'), jump('A', 'B'), jump('B', 'C'), jump('C', 'D', true)];
  const stops = groupStops(queue, 'O');
  // the marked jump closes the whole run: it cannot be told apart from a
  // far-click order through A, B, C (which is what a new client sends)
  assert.deepEqual(targets(stops), ['D']);
  assert.deepEqual(stops[0].via, ['A', 'B', 'C']);
});

test('grouping: a flee jump added by the server (unmarked) is a stop', () => {
  const stops = groupStops([jump('O', 'A')], 'O');
  assert.deepEqual(targets(stops), ['A']);
});

test('rebuilding an unmarked plan marks its stops (the upgrade happens on the first edit)', () => {
  const hops = ['O', 'A', 'B', 'C', 'D'];
  const queue = hops.slice(1).map((t, i) => jump(hops[i], t));
  const before = editablePlan(queue, 'O');
  const after = removeStop(before, before.stops[1].key); // drop C: B → D
  const tail = buildTail(after.stops, after.from, router(true));
  assert.deepEqual(describeTail(tail), ['A>B*', 'B>C', 'C>D*']);
});

test('grouping: an action where the agent already is makes a stop without jumps', () => {
  const stops = groupStops([act('infiltrate', 'O'), jump('O', 'A', true)], 'O');
  assert.deepEqual(targets(stops), ['O', 'A']);
  assert.equal(stops[0].entries.length, 1);
});

test('grouping: a gateway charge ends its leg on the far side', () => {
  const queue = [jump('O', 'A', true), { type: 'gateway_charge', uid: uid++, data: { source: 'A', target: 'Z' } }, act('raid', 'Z')];
  const stops = groupStops(queue, 'O');
  assert.deepEqual(targets(stops), ['A', 'Z']);
  assert.equal(stops[1].gateway, true);
  assert.equal(stops[1].gatewaySource, 'A');
  assert.deepEqual(stops[1].actions.map((a) => a.type), ['raid']);
});

test('the running head is never part of the edit', () => {
  const plan = editablePlan(example(), 'O');
  assert.equal(plan.head.data.target, 'A');
  assert.equal(plan.from, 'A');
  // the head was stop A's only entry: nothing of it is left to edit
  assert.equal(plan.headStop, null);
  assert.deepEqual(targets(plan.stops), ['B', 'C', 'D']);
});

test('an unchanged plan rebuilds to the same route with the same uids (no re-routing)', () => {
  const queue = example();
  const plan = editablePlan(queue, 'O');
  const tail = buildTail(plan.stops, plan.from, () => assert.fail('an untouched leg must not be re-routed'));
  assert.deepEqual(route(tail), ['A>B', 'B>C', 'C>D']);
  assert.deepEqual(tail.map((a) => a.uid), queue.slice(1).map((a) => a.uid));
  assert.deepEqual(tail.filter((a) => a.data.stop).length, 3);
});

test('removing stop B: the route to C is recalculated (detour available)', () => {
  const r = router();
  const before = editablePlan(example(), 'O');
  const keyB = before.stops[0].key;
  const after = removeStop(before, keyB);
  const tail = buildTail(after.stops, after.from, r);

  assert.deepEqual(route(tail), ['A>E', 'E>C', 'C>D']);
  // raid/loot survive with their uids
  assert.deepEqual(tail.filter((a) => a.type !== 'jump').map((a) => a.type), ['raid', 'loot']);

  const summary = summarize(before, after, r);
  assert.deepEqual(summary.removedStops, [{ target: 'B', actions: [] }]);
  assert.deepEqual(summary.rerouted, [{ target: 'C', via: ['E'], jumps: 2 }]);
  assert.deepEqual(summary.passThrough, []);
});

test('removing stop B when B is the only way to C: C is kept, B is passed through (not a stop)', () => {
  const r = router(true);
  const before = editablePlan(example(), 'O');
  const after = removeStop(before, before.stops[0].key);
  const tail = buildTail(after.stops, after.from, r);

  assert.deepEqual(route(tail), ['A>B', 'B>C', 'C>D']);
  // B's jump is now route, not a stop
  assert.equal(tail.find((a) => a.data.target === 'B').data.stop, undefined);
  assert.equal(tail.find((a) => a.data.target === 'C').data.stop, true);

  const summary = summarize(before, after, r);
  assert.deepEqual(summary.passThrough, [{ target: 'B', on_way_to: 'C' }]);
  assert.deepEqual(summary.rerouted, [{ target: 'C', via: ['B'], jumps: 2 }]);
});

test('removing stop C removes its bombard and pillage; D is routed from B', () => {
  const r = router(true);
  const before = editablePlan(example(), 'O');
  const keyC = before.stops[1].key;
  const after = removeStop(before, keyC);
  const tail = buildTail(after.stops, after.from, r);

  assert.deepEqual(route(tail), ['A>B', 'B>C', 'C>D']);
  assert.deepEqual(tail.filter((a) => a.type !== 'jump'), []);

  const summary = summarize(before, after, r);
  assert.deepEqual(summary.removedStops, [{ target: 'C', actions: ['raid', 'loot'] }]);
  assert.deepEqual(summary.passThrough, [{ target: 'C', on_way_to: 'D' }]);
});

test('pass-through is about the leg that follows the removed stop, not an earlier one', () => {
  // O → A, then C (through B), then back to B: dropping that last visit
  // of B leaves B on the way to C, as it always was — nothing to explain
  const r = router(true);
  const queue = [jump('O', 'A', true), jump('A', 'B'), jump('B', 'C', true), jump('C', 'B', true)];
  const before = editablePlan(queue, 'O');
  assert.deepEqual(targets(before.stops), ['C', 'B']);
  assert.deepEqual(before.stops[0].via, ['B']);

  const after = removeStop(before, before.stops[1].key);
  const summary = summarize(before, after, r);
  assert.deepEqual(summary.removedStops, [{ target: 'B', actions: [] }]);
  assert.deepEqual(summary.passThrough, []);

  // two stops removed in a row, both still on the way to the next one
  const line = editablePlan(example(), 'O');
  const fromB = { ...line, stops: line.stops.filter((st) => st.target === 'D') };
  assert.deepEqual(summarize(line, fromB, r).passThrough, [
    { target: 'B', on_way_to: 'D' }, { target: 'C', on_way_to: 'D' },
  ]);
});

test('removing one action keeps the stop and the other action', () => {
  const queue = example();
  const before = editablePlan(queue, 'O');
  const stopC = before.stops[1];
  const raid = stopC.actions[0];
  const after = removeAction(before, stopC.key, raid.uid);
  const tail = buildTail(after.stops, after.from, router());

  assert.deepEqual(tail.filter((a) => a.type !== 'jump').map((a) => a.type), ['loot']);
  assert.deepEqual(summarize(before, after, router()).removedActions, [{ type: 'raid', target: 'C' }]);
});

test('removing from stop C on: C, its actions and D go; the untouched leg to B is not re-routed', () => {
  const queue = example();
  const before = editablePlan(queue, 'O');
  const after = removeStopsFrom(before, before.stops[1].key);
  assert.deepEqual(targets(after.stops), ['B']);

  const noRoute = () => assert.fail('nothing left to re-route');
  const tail = buildTail(after.stops, after.from, noRoute);
  assert.deepEqual(describeTail(tail), ['A>B*']);
  assert.deepEqual(tail.map((a) => a.uid), [queue[1].uid]);

  const summary = summarize(before, after, noRoute);
  assert.deepEqual(summary.removedStops, [{ target: 'C', actions: ['raid', 'loot'] }, { target: 'D', actions: [] }]);
  assert.deepEqual(summary.rerouted, []);
  assert.deepEqual(summary.passThrough, []);
});

test('removing from the first stop on empties the plan; from the last, it is a plain removal', () => {
  const before = editablePlan(example(), 'O');
  assert.deepEqual(removeStopsFrom(before, before.stops[0].key).stops, []);
  assert.deepEqual(
    targets(removeStopsFrom(before, before.stops[2].key).stops),
    targets(removeStop(before, before.stops[2].key).stops),
  );
  // an unknown key (the plan moved on) changes nothing
  assert.equal(removeStopsFrom(before, 'nope'), before);
});

test('removing from an action on: it, the later actions of its stop and every later stop go; the stop stays', () => {
  const queue = example();
  const before = editablePlan(queue, 'O');
  const stopC = before.stops[1];

  // from the pillage: the bombard stays, D goes
  const fromLoot = removeActionsFrom(before, stopC.key, stopC.actions[1].uid);
  assert.deepEqual(targets(fromLoot.stops), ['B', 'C']);
  let tail = buildTail(fromLoot.stops, fromLoot.from, router());
  assert.deepEqual(describeTail(tail), ['A>B*', 'B>C*']);
  assert.deepEqual(tail.filter((a) => a.type !== 'jump').map((a) => a.type), ['raid']);

  // from the bombard: both actions go, the agent still travels to C
  const fromRaid = removeActionsFrom(before, stopC.key, stopC.actions[0].uid);
  tail = buildTail(fromRaid.stops, fromRaid.from, router());
  assert.deepEqual(describeTail(tail), ['A>B*', 'B>C*']);
  assert.deepEqual(tail.filter((a) => a.type !== 'jump'), []);
  assert.equal(fromRaid.stops[1].key, stopC.key);

  const summary = summarize(before, fromRaid, router());
  assert.deepEqual(summary.removedActions, [{ type: 'raid', target: 'C' }, { type: 'loot', target: 'C' }]);
  assert.deepEqual(summary.removedStops, [{ target: 'D', actions: [] }]);
});

test("removing from an action of the head's own stop on leaves only what comes before it", () => {
  // the head is the jump to C; bombard and pillage there, then D
  const queue = [jump('O', 'A'), jump('A', 'B'), jump('B', 'C', true), act('raid', 'C'), act('loot', 'C'), jump('C', 'D', true)];
  const before = editablePlan(queue, 'O');
  const loot = before.headStop.actions[1];
  const after = removeActionsFrom(before, before.headStop.key, loot.uid);

  assert.deepEqual(after.stops, []);
  const payload = editPayload(7, after, router(true));
  assert.deepEqual(describeTail(payload.actions), ['A>B', 'B>C*']);
  assert.deepEqual(payload.actions.filter((a) => a.type !== 'jump').map((a) => a.type), ['raid']);

  // and from the head's stop itself: nothing is left after the head
  const cleared = removeStopsFrom(before, before.headStop.key);
  assert.deepEqual(editPayload(7, cleared, router(true)).actions, []);
});

test('reordering: D before C routes A → … → D → C, actions follow their stop', () => {
  const r = router(true);
  const before = editablePlan(example(), 'O');
  const keyD = before.stops[2].key;
  const after = moveStop(before, keyD, 1); // [B, D, C]
  const tail = buildTail(after.stops, after.from, r);

  assert.deepEqual(route(tail), ['A>B', 'B>C', 'C>D', 'D>C']);
  const last = tail.slice(-2).map((a) => a.type);
  assert.deepEqual(last, ['raid', 'loot']);
  assert.equal(summarize(before, after, r).moved, true);
});

test('a head mid-leg: the rest of its leg is re-routed from where the head lands', () => {
  // O → A → B → C is one order (marked on the last jump); the head is O→A
  const queue = [jump('O', 'A'), jump('A', 'B'), jump('B', 'C', true), act('raid', 'C'), jump('C', 'D', true)];
  const plan = editablePlan(queue, 'O');

  assert.equal(plan.from, 'A');
  assert.equal(plan.headStop.target, 'C');
  assert.deepEqual(plan.headStop.via, ['B']);

  const payload = editPayload(7, plan, router(true));
  assert.equal(payload.keep_uid, queue[0].uid);
  assert.deepEqual(route(payload.actions), ['A>B', 'B>C', 'C>D']);
  // unchanged => no reroute reported
  assert.deepEqual(summarize(plan, plan, router(true)).rerouted, []);
});

test('an unreachable stop is a PlanError, not a broken payload', () => {
  const before = editablePlan(example(), 'O');
  const plan = removeStop(before, before.stops[0].key); // A → C needs a new route
  const noRoute = () => null;
  assert.throws(() => buildTail(plan.stops, plan.from, noRoute), (e) => e instanceof PlanError && e.reason === 'no_route');
});

test('server-added jump data is not re-sent', () => {
  const queue = example();
  queue[1].data.source_position = { x: 1, y: 2 };
  queue[1].data.target_position = { x: 3, y: 4 };
  const plan = editablePlan(queue, 'O');
  const tail = buildTail(plan.stops, plan.from, router());
  assert.deepEqual(Object.keys(tail[0].data).sort(), ['source', 'stop', 'target']);
});
