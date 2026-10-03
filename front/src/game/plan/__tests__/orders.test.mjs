// Orders availability + single-source routes — plain node, no webpack
// (route.js needs front/node_modules for ngraph, so run it where those
// live, e.g. inside the rc container):
//   node --test front/src/game/plan/__tests__/orders.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { availableOrders } from '../orders.js';
import { routesFrom } from '../route.js';

const player = { faction: 'tetrarchy' };

function agent(type, virtualPosition = 1) {
  return { type, actions: { virtual_position: virtualPosition } };
}

function keys(orders) {
  return orders.map((o) => o.key);
}

test('a Navarch can colonize an empty, ownerless system', () => {
  const system = { id: 2, status: 'uninhabited', faction: null, owner: null };
  assert.deepEqual(keys(availableOrders(agent('admiral'), system, player)), ['jump', 'colonization']);
});

test('a Navarch can attack another faction\'s system', () => {
  const system = { id: 2, status: 'inhabited_player', faction: 'cardan', owner: 'Rival' };
  assert.deepEqual(keys(availableOrders(agent('admiral'), system, player)), ['jump', 'conquest', 'raid', 'loot']);
});

test('own-faction systems only take a move order', () => {
  const system = { id: 2, status: 'inhabited_player', faction: 'tetrarchy', owner: 'Ally' };
  assert.deepEqual(keys(availableOrders(agent('admiral'), system, player)), ['jump']);
  assert.deepEqual(keys(availableOrders(agent('speaker'), system, player)), ['jump']);
});

test('no move order toward the system the plan already ends on', () => {
  const system = { id: 1, status: 'inhabited_neutral', faction: null, owner: null };
  assert.deepEqual(keys(availableOrders(agent('spy', 1), system, player)), ['infiltrate']);
});

test('a Siderian can take neutral systems and destabilize any inhabited one', () => {
  const neutral = { id: 2, status: 'inhabited_neutral', faction: null, owner: null };
  const enemy = { id: 3, status: 'inhabited_player', faction: 'cardan', owner: 'Rival' };
  assert.deepEqual(keys(availableOrders(agent('speaker'), neutral, player)), ['jump', 'make_dominion', 'encourage_hate']);
  assert.deepEqual(keys(availableOrders(agent('speaker'), enemy, player)), ['jump', 'encourage_hate']);
});

test('uninhabitable systems take no hostile order', () => {
  const system = { id: 2, status: 'uninhabitable', faction: null, owner: null };
  assert.deepEqual(keys(availableOrders(agent('admiral'), system, player)), ['jump']);
});

//   1 — 2 — 3 — 4        5 (no lanes)
//    \_______/
//       2.5
function galaxy() {
  const edge = (a, b, weight) => ({ s1: { id: a }, s2: { id: b }, weight });
  return { edges: [edge(1, 2, 1), edge(2, 3, 1), edge(3, 4, 1), edge(1, 3, 2.5)] };
}

test('routesFrom finds the shortest route length and its jump count', () => {
  const routes = routesFrom(galaxy(), 1);
  assert.deepEqual(routes.get(1), { weight: 0, hops: 0 });
  assert.deepEqual(routes.get(3), { weight: 2, hops: 2 }); // 1-2-3 beats the 2.5 shortcut
  assert.deepEqual(routes.get(4), { weight: 3, hops: 3 });
});

test('routesFrom leaves unreachable systems out', () => {
  assert.equal(routesFrom(galaxy(), 1).has(5), false);
});

test('routesFrom works from any source, lanes are two-way', () => {
  const routes = routesFrom(galaxy(), 4);
  assert.deepEqual(routes.get(1), { weight: 3, hops: 3 });
});
