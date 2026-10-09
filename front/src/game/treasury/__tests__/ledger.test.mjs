// Treasury ledger model — plain node, no webpack:
//   node --test front/src/game/treasury/__tests__/ledger.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { ledgerLine, ledgerLines } from '../ledger.js';

function row(type, payload, extra = {}) {
  return {
    id: 1,
    inserted_at: '2026-10-08T10:00:00Z',
    actor_profile_id: 7,
    target_profile_id: null,
    event_type: type,
    payload: JSON.stringify(payload),
    ...extra,
  };
}

test('a donation comes in, in the resources given', () => {
  const line = ledgerLine(row('treasury_donated', { amounts: { credit: 500, technology: 0, ideology: 20 } }));

  assert.equal(line.direction, 'in');
  assert.equal(line.kind, 'donated');
  assert.equal(line.actorId, 7);
  assert.deepEqual(line.amounts, { credit: 500, technology: 0, ideology: 20 });
});

test('a withdrawal shows what left the treasury and keeps what the member got', () => {
  const line = ledgerLine(row('treasury_withdrawn', { amounts: { credit: 100 }, net: { credit: 90 } }));

  assert.equal(line.direction, 'out');
  assert.deepEqual(line.amounts, { credit: 100, technology: 0, ideology: 0 });
  assert.deepEqual(line.params.net, { credit: 90, technology: 0, ideology: 0 });
});

test('a grant names its recipient', () => {
  const line = ledgerLine(row('treasury_granted', { amounts: { technology: 40 } }, { target_profile_id: 9 }));

  assert.equal(line.kind, 'granted');
  assert.equal(line.targetId, 9);
});

test('a distribution totals the shares over the members who got one', () => {
  const line = ledgerLine(row('treasury_distributed', { pct: 25, shares: { credit: 30, ideology: 2 }, members: 4 }));

  assert.equal(line.kind, 'distributed');
  assert.deepEqual(line.amounts, { credit: 120, technology: 0, ideology: 8 });
  assert.deepEqual(line.params, { pct: 25, members: 4 });
});

test('a distribution logged without a member count shows one share', () => {
  const line = ledgerLine(row('treasury_distributed', { pct: 25, shares: { credit: 30 } }));

  assert.equal(line.kind, 'distributed_each');
  assert.equal(line.amounts.credit, 30);
});

test('a patent is paid in technology, a lex in ideology, ARK adds credit', () => {
  const patent = ledgerLine(row('government_purchase', { kind: 'patent_purchased', key: 'gateway_theory', cost: 900 }));
  const lex = ledgerLine(row('government_purchase', {
    kind: 'lex_purchased', key: 'open_borders', cost: 300, credit_cost: 3000,
  }));

  assert.equal(patent.kind, 'patent');
  assert.deepEqual(patent.amounts, { credit: 0, technology: 900, ideology: 0 });
  assert.equal(lex.kind, 'lex');
  assert.deepEqual(lex.amounts, { credit: 3000, technology: 0, ideology: 300 });
  assert.equal(lex.params.key, 'open_borders');
});

test('a station order goes out, its cancellation comes back in', () => {
  const cost = { credit: 4000, technology: 500, ideology: 0 };
  const ordered = ledgerLine(row('station_ordered', {
    key: 'gateway', level: 1, system_id: 12, system_name: 'Alpha', cost,
  }));
  const cancelled = ledgerLine(row('station_cancelled', { key: 'gateway', level: 1, system_id: 12, refund: cost }));

  assert.equal(ordered.direction, 'out');
  assert.deepEqual(ordered.amounts, cost);
  assert.equal(ordered.params.systemName, 'Alpha');
  assert.equal(cancelled.direction, 'in');
  assert.deepEqual(cancelled.amounts, cost);
});

test('only a challenge matched from the treasury is a line', () => {
  assert.equal(ledgerLine(row('challenge_matched', { amount: 500, treasury: false })), null);
  assert.equal(ledgerLine(row('challenge_matched', { amount: 500, treasury: true })).amounts.credit, 500);
});

test('a defended challenge pays its forfeit in', () => {
  const line = ledgerLine(row('challenge_defended', { name: 'Vex', stake: 1000, penalty: 100 }));

  assert.equal(line.direction, 'in');
  assert.equal(line.kind, 'challenge_forfeit');
  assert.equal(line.amounts.credit, 100);
});

test('unknown rows and broken payloads are left out, not thrown on', () => {
  const lines = ledgerLines([
    row('election_closed', {}),
    { ...row('treasury_donated', {}), payload: '{not json' },
    row('treasury_donated', { amounts: { credit: 5 } }),
  ]);

  assert.equal(lines.length, 2);
  assert.deepEqual(lines[0].amounts, { credit: 0, technology: 0, ideology: 0 });
  assert.equal(lines[1].amounts.credit, 5);
});
