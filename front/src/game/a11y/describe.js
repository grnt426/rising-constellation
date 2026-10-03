// Spoken descriptions of agents for screen readers. Every surface that
// describes an agent (the list cards, the full agent card, the fleet
// section) goes through here, so they agree on wording and on what
// counts as unknown. Each function takes the calling component for
// $t / $tc and the store; wording lives under `a11y.*` in game.json.

// Obfuscated stats arrive as null or 'hidden' (CharacterCard renders
// them as ░░).
function known(value) {
  return value !== null && value !== undefined && value !== 'hidden';
}

// Joins parts into sentences; parts may or may not end in a period
// (reused card strings like card.character.origin already do).
function sentence(parts) {
  return parts
    .filter(Boolean)
    .map((part) => part.replace(/[.\s]+$/, ''))
    .join('. ')
    .concat('.');
}

export function agentTypeName(vm, type, count = 1) {
  return vm.$tc(`data.character.${type}.name`, count);
}

export function actionStatusName(vm, status) {
  const key = `data.character_action_status.${status}.name`;
  return status && vm.$te(key) ? vm.$t(key) : '';
}

// Ships in a Navarch's army: built, under construction, and how worn
// the visible built ships are. null when the army itself isn't visible.
export function fleetStats(vm, character) {
  const tiles = character && character.army && character.army.tiles;
  if (!Array.isArray(tiles)) return null;

  const shipsData = vm.$store.state.game.data.ship || [];
  let ships = 0;
  let planned = 0;
  let hull = 0;
  let maxHull = 0;

  tiles.forEach((tile) => {
    if (tile.ship_status === 'planned') planned += 1;
    if (tile.ship_status !== 'filled') return;
    ships += 1;
    const ship = tile.ship;
    if (!ship || ship === 'hidden' || !Array.isArray(ship.units)) return;
    const data = shipsData.find((s) => s.key === ship.key);
    if (!data) return;
    hull += ship.units.reduce((acc, unit) => acc + unit.hull, 0);
    maxHull += data.unit_hull * data.unit_count;
  });

  return {
    ships,
    planned,
    slots: tiles.length,
    hullPct: maxHull > 0 ? Math.round((hull / maxHull) * 100) : null,
  };
}

export function fleetSentence(vm, stats) {
  if (!stats || (stats.ships === 0 && stats.planned === 0)) return '';
  const parts = [vm.$tc('a11y.fleet.ships', stats.ships, { n: stats.ships, slots: stats.slots })];
  if (stats.planned) parts.push(vm.$tc('a11y.fleet.planned', stats.planned, { n: stats.planned }));
  if (stats.hullPct !== null) parts.push(vm.$t('a11y.fleet.hull', { pct: stats.hullPct }));
  return parts.join(', ');
}

// One line for an agent in a list: who, what they're doing, and the
// few flags the closed card shows as icons.
export function agentListLabel(vm, character, { group = null, armadaSize = 0 } = {}) {
  const parts = [
    vm.$t('a11y.agent.identity', {
      type: agentTypeName(vm, character.type),
      name: character.name,
      level: known(character.level) ? character.level : vm.$t('a11y.unknown'),
    }),
  ];

  const status = actionStatusName(vm, character.action_status);
  if (status) parts.push(status);

  const queue = character.actions && Array.isArray(character.actions.queue)
    ? character.actions.queue.length : 0;
  if (queue) parts.push(vm.$tc('a11y.agent.orders_queued', queue, { n: queue }));

  if (character.type === 'admiral' && character.army_size) {
    const filled = character.army_size.filled || 0;
    if (filled) parts.push(vm.$tc('a11y.fleet.ships_short', filled, { n: filled }));
  }
  if (character.type === 'spy' && character.is_discovered) parts.push(vm.$t('a11y.agent.exposed'));
  if (armadaSize) parts.push(vm.$t('a11y.agent.in_armada', { n: armadaSize }));
  if (group) parts.push(vm.$t('a11y.agent.hotkey_group', { group }));

  return parts.join(', ');
}

// The full card read out when an agent's card opens: identity, stats and
// skills, then one sentence saying a fleet exists. The fleet's ships are
// left to the fleet section, read only when the player moves into it.
export function agentCardSummary(vm, character, { fleet = null, nextXp = null } = {}) {
  const unknown = vm.$t('a11y.unknown');
  const value = (v) => (known(v) ? v : unknown);
  const parts = [];

  const specKey = `data.character.${character.type}.specializations.${character.specialization}`;
  parts.push(vm.$t('a11y.agent.identity_full', {
    type: agentTypeName(vm, character.type),
    name: character.name,
    level: value(character.level),
    specialization: character.specialization && vm.$te(specKey) ? vm.$t(specKey) : unknown,
  }));

  const status = character.status === 'on_board' ? actionStatusName(vm, character.action_status) : '';
  if (status) parts.push(vm.$t('a11y.agent.status', { status }));

  if (character.experience && known(character.experience.value) && nextXp !== null) {
    parts.push(vm.$t('a11y.agent.experience', { xp: Math.floor(character.experience.value), next: nextXp }));
  }

  const constant = (vm.$store.state.game.data.constant || [])[0] || {};
  parts.push(vm.$t('a11y.agent.stats', {
    protection: value(character.protection),
    determination: value(character.determination),
    salary: known(character.level) && constant.character_level_wages
      ? Math.round(character.level * constant.character_level_wages) : unknown,
  }));

  if (Array.isArray(character.skills)) {
    const data = (vm.$store.state.game.data.character || []).find((c) => c.key === character.type);
    const skill = (i) => {
      const name = vm.$t(`data.character.${character.type}.skills[${i}].name`);
      const active = data && data.specializations[i]
        && data.specializations[i].key === character.specialization;
      return vm.$t(active ? 'a11y.agent.skill_active' : 'a11y.agent.skill', { name, value: character.skills[i] });
    };
    parts.push(vm.$t('a11y.agent.skills_agent', { skills: [0, 1, 2].map(skill).join(', ') }));
    parts.push(vm.$t('a11y.agent.skills_governor', { skills: [3, 4, 5].map(skill).join(', ') }));
  }

  if (known(character.gender) && known(character.age)) {
    parts.push(vm.$t('card.character.gender_age', {
      gender: vm.$t(`card.character.gender_${character.gender}`),
      age: character.age,
    }));
  }
  if (character.culture) {
    parts.push(vm.$t('card.character.origin', { culture: vm.$t(`data.culture.${character.culture}.name`) }));
  }

  const fleetText = fleetSentence(vm, fleet);
  if (fleetText) parts.push(vm.$t('a11y.agent.has_fleet', { fleet: fleetText }));

  return sentence(parts);
}

// One ship slot of a fleet, for the fleet section's spoken list.
export function shipSlotLabel(vm, tile, line, slot) {
  const where = vm.$t('a11y.fleet.slot', { line, slot });
  if (tile.ship_status === 'empty') return `${where}: ${vm.$t('a11y.fleet.empty')}`;

  const ship = tile.ship;
  if (!ship || ship === 'hidden') return `${where}: ${vm.$t('a11y.fleet.hidden_ship')}`;

  const name = vm.$te(`data.ship.${ship.key}.name`) ? vm.$t(`data.ship.${ship.key}.name`) : ship.key;
  const level = ship.level !== 'hidden' && ship.level !== undefined ? ship.level + 1 : null;
  const parts = [level !== null ? vm.$t('a11y.fleet.ship_level', { name, level }) : name];

  if (tile.ship_status === 'planned') {
    parts.push(vm.$t('card.ship.under_production'));
  } else if (Array.isArray(ship.units)) {
    const data = (vm.$store.state.game.data.ship || []).find((s) => s.key === ship.key);
    if (data) {
      const hull = ship.units.reduce((acc, unit) => acc + unit.hull, 0);
      parts.push(vm.$t('a11y.fleet.hull', { pct: Math.round((hull / (data.unit_hull * data.unit_count)) * 100) }));
    }
  }

  return `${where}: ${parts.join(', ')}`;
}
