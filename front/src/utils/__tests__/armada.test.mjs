// Armada lead + order routing — plain node, no webpack:
//   node --test front/src/utils/__tests__/armada.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import armadaUtil from '../armada.js';

const armada = (extra = {}) => ({ id: 1, name: 'The Iron Tide', member_ids: [1, 2, 3], lead_id: 1, ...extra });

const navarch = (id, status = 'idle', queue = [], map = armada()) => ({
  id,
  name: `navarch-${id}`,
  action_status: status,
  actions: { queue, virtual_position: 10 },
  armada: map,
});

const resting = (map = armada()) => [navarch(1, 'idle', [], map), navarch(2, 'idle', [], map), navarch(3, 'idle', [], map)];

test('at rest the stored lead leads', () => {
  assert.equal(armadaUtil.leadId(armada({ lead_id: 2 }), resting()), 2);
});

test('a member with orders underway leads, whatever is stored', () => {
  const map = armada({ lead_id: 1 });
  const roster = [navarch(1, 'attached', [], map), navarch(2, 'moving', [{ type: 'jump' }], map), navarch(3, 'attached', [], map)];
  assert.equal(armadaUtil.leadId(map, roster), 2);
});

test('maps without a lead fall back to the forming Navarch, then the lowest id', () => {
  assert.equal(armadaUtil.leadId(armada({ lead_id: undefined }), resting()), 1);
  // the stored lead left, and so did the forming Navarch
  assert.equal(armadaUtil.leadId({ id: 1, member_ids: [3, 2], lead_id: 1 }, []), 2);
  assert.equal(armadaUtil.leadId(null, []), null);
});

test('at rest, an order goes to the Navarch it was given to', () => {
  const roster = resting(armada({ lead_id: 1 }));
  assert.equal(armadaUtil.orderRecipient(roster, 2), null);
  assert.equal(armadaUtil.orderRecipient(roster, 1), null);
});

test('while the lead has orders underway, a member\'s order joins the lead\'s plan', () => {
  const map = armada({ lead_id: 1 });
  const roster = [navarch(1, 'moving', [{ type: 'jump' }], map), navarch(2, 'attached', [], map), navarch(3, 'attached', [], map)];
  assert.equal(armadaUtil.orderRecipient(roster, 3).id, 1);
  // the lead itself takes its own orders
  assert.equal(armadaUtil.orderRecipient(roster, 1), null);
});

test('a lead only queued up (not under way yet) still takes the members\' orders', () => {
  const map = armada({ lead_id: 1 });
  const roster = [navarch(1, 'idle', [{ type: 'jump' }], map), navarch(2, 'idle', [], map), navarch(3, 'idle', [], map)];
  assert.equal(armadaUtil.orderRecipient(roster, 2).id, 1);
});

test('a Navarch outside any armada takes its own orders', () => {
  assert.equal(armadaUtil.orderRecipient([{ id: 9, action_status: 'idle', armada: null }], 9), null);
  assert.equal(armadaUtil.leadOf([{ id: 9, armada: null }], 9), null);
});
