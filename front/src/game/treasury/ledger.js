// The faction treasury's ledger: turns the audit rows the server keeps
// (`get_treasury_log`, RC.Instances.FactionEventLog) into lines the
// Treasury panel can show. Pure, so it runs under plain node:
//   node --test front/src/game/treasury/__tests__/ledger.test.mjs
//
// A line is { id, at, direction, kind, actorId, targetId, amounts, params }:
//   direction  'in' (into the treasury) or 'out'
//   kind       the wording to use (panel.faction_government.ledger.<kind>)
//   amounts    what moved, { credit, technology, ideology }, always >= 0
//   params     what the wording names besides the actor (see each case)

export const RESOURCES = ['credit', 'technology', 'ideology'];

function amountsOf(map) {
  const source = map || {};
  return RESOURCES.reduce((acc, resource) => {
    const value = Number(source[resource]);
    acc[resource] = Number.isFinite(value) && value > 0 ? value : 0;
    return acc;
  }, {});
}

function scale(amounts, factor) {
  return RESOURCES.reduce((acc, resource) => {
    acc[resource] = amounts[resource] * factor;
    return acc;
  }, {});
}

function payloadOf(entry) {
  if (!entry.payload) return {};
  if (typeof entry.payload !== 'string') return entry.payload;
  try {
    return JSON.parse(entry.payload) || {};
  } catch (err) {
    return {};
  }
}

// One audit row to one ledger line, or null when the row moved nothing
// (a personal challenge match, a type this ledger does not know).
export function ledgerLine(entry) {
  const p = payloadOf(entry);
  const line = {
    id: entry.id,
    at: entry.inserted_at,
    actorId: entry.actor_profile_id || null,
    targetId: entry.target_profile_id || null,
    params: {},
  };

  switch (entry.event_type) {
    case 'treasury_donated':
      return { ...line, direction: 'in', kind: 'donated', amounts: amountsOf(p.amounts) };

    // `amounts` is what left the treasury; the member got `net`, the
    // market tax on the difference is sunk
    case 'treasury_withdrawn':
      return {
        ...line,
        direction: 'out',
        kind: 'withdrawn',
        amounts: amountsOf(p.amounts),
        params: { net: amountsOf(p.net) },
      };

    case 'treasury_granted':
      return { ...line, direction: 'out', kind: 'granted', amounts: amountsOf(p.amounts) };

    // `shares` is one member's share. Rows written before the member
    // count was recorded can only say what each member got.
    case 'treasury_distributed': {
      const shares = amountsOf(p.shares);
      const members = Number(p.members) > 0 ? Number(p.members) : null;
      return {
        ...line,
        direction: 'out',
        kind: members ? 'distributed' : 'distributed_each',
        amounts: members ? scale(shares, members) : shares,
        params: { pct: p.pct, members },
      };
    }

    // patents are paid in technology, lexes in ideology; ARK pays a
    // credit surcharge on top of either
    case 'government_purchase': {
      const lex = p.kind === 'lex_purchased';
      return {
        ...line,
        direction: 'out',
        kind: lex ? 'lex' : 'patent',
        amounts: amountsOf({
          [lex ? 'ideology' : 'technology']: p.cost,
          credit: p.credit_cost,
        }),
        params: { key: p.key },
      };
    }

    case 'station_ordered':
      return {
        ...line,
        direction: 'out',
        kind: 'station_ordered',
        amounts: amountsOf(p.cost),
        params: { key: p.key, level: p.level, systemId: p.system_id, systemName: p.system_name },
      };

    case 'station_cancelled':
      return {
        ...line,
        direction: 'in',
        kind: 'station_cancelled',
        amounts: amountsOf(p.refund),
        params: { key: p.key, level: p.level, systemId: p.system_id, systemName: p.system_name },
      };

    case 'challenge_matched':
      if (!p.treasury) return null;
      return { ...line, direction: 'out', kind: 'challenge_matched', amounts: amountsOf({ credit: p.amount }) };

    // the challenger's forfeit: 10% of the stake goes to the treasury
    case 'challenge_defended':
      if (!(Number(p.penalty) > 0)) return null;
      return {
        ...line,
        direction: 'in',
        kind: 'challenge_forfeit',
        amounts: amountsOf({ credit: p.penalty }),
        params: { name: p.name },
      };

    default:
      return null;
  }
}

export function ledgerLines(entries) {
  return (entries || []).map(ledgerLine).filter((line) => line !== null);
}
