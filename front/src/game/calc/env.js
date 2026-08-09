// Builds the calc engine's env from a plain snapshot of game state. Kept
// Vue/Vuex-free (data in, data out) so the engine + env pair stays testable
// under plain node; the component layer is responsible for pulling the
// pieces out of the store (see CalcMixin.js).
//
// snapshot = {
//   now,                    // Date.now()
//   effectiveSpeedFactor,   // store getter (base speed × runtime speedup)
//   isRunning,              // time.is_running
//   receivedAt,             // player.receivedAt — server snapshot arrival
//   player,                 // { credit|technology|ideology: {value, change} }
//   constant,               // data.constant[0] or undefined
//   maxPolicies,            // player.max_policies
// }

const RESOURCES = ['credit', 'technology', 'ideology'];

export function buildEnv(snapshot) {
  const {
    now, effectiveSpeedFactor, isRunning, receivedAt, player, constant, maxPolicies,
  } = snapshot;

  const perHour = 20 * effectiveSpeedFactor;

  // Extrapolate stockpiles from the last server push, exactly like the
  // bottom-bar counters do: elapsed real seconds × ut-per-second × change.
  const utPerSecond = effectiveSpeedFactor / 180;
  const elapsedUt = isRunning && receivedAt
    ? ((now - receivedAt) / 1000) * utPerSecond
    : 0;

  const resources = {};
  RESOURCES.forEach((res) => {
    const dv = player[res] || { value: 0, change: 0 };
    resources[res] = {
      value: dv.value + dv.change * elapsedUt,
      changePerUt: dv.change,
    };
  });

  // Next policy-slot unlock: 2^(slots-1) × initial cost, capped
  // (mirrors Instance.Player.Player.purchase_policy_slot/1).
  let lexSlotCost = null;
  if (constant && typeof maxPolicies === 'number') {
    lexSlotCost = Math.round(2 ** (maxPolicies - 1)) * constant.initial_policy_slot_cost;
    if (lexSlotCost > constant.policy_slot_maximum_cost) lexSlotCost = constant.policy_slot_maximum_cost;
  }

  return {
    now,
    perHour,
    isRunning,
    resources,
    lexSlotCost,
    names: new Map(),
  };
}

export default buildEnv;
