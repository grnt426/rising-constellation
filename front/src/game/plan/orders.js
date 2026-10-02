// Which orders an agent can be given toward a system: the coarse,
// client-side availability (agent class + system status) shared by the
// long-press action wheel and the agent orders list. The server remains
// the real validator; a rejected order surfaces as the usual error toast.
//
// `key` is the action type map.js's addCharacterAction queues; `name`
// is its label under galaxy.system.actions.
export const INHABITED = ['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'];

// Every order an agent class can give toward a system, for filters.
export const ORDERS_BY_TYPE = {
  admiral: [
    { key: 'colonization', name: 'colonize' },
    { key: 'conquest', name: 'conquer' },
    { key: 'raid', name: 'raid' },
    { key: 'loot', name: 'loot' },
  ],
  spy: [
    { key: 'infiltrate', name: 'infiltrate' },
  ],
  speaker: [
    { key: 'make_dominion', name: 'make_dominion' },
    { key: 'encourage_hate', name: 'encourage_hate' },
  ],
};

export const MOVE_ORDER = { key: 'jump', name: 'move' };

// `system` is a galaxy-map system (MapData: id, status, faction, owner
// name); `player` the store's player. Systems of the player's own
// faction (their own, a factionmate's, their dominions) take no hostile
// orders.
export function availableOrders(character, system, player) {
  if (!character || !system) return [];

  const list = [];
  const friendly = !!system.faction && !!player && system.faction === player.faction;
  const inhabited = INHABITED.includes(system.status);

  if (character.actions && character.actions.virtual_position !== system.id) {
    list.push(MOVE_ORDER);
  }

  if (friendly) return list;

  const orders = ORDERS_BY_TYPE[character.type] || [];
  orders.forEach((order) => {
    let ok = false;
    switch (order.key) {
      case 'colonization': ok = system.status === 'uninhabited' && !system.owner; break;
      case 'make_dominion': ok = ['inhabited_neutral', 'inhabited_dominion'].includes(system.status); break;
      default: ok = inhabited;
    }
    if (ok) list.push(order);
  });

  return list;
}
