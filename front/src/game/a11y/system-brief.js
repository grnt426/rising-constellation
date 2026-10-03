// What the system briefing says (SystemBriefing.vue): the screen-reader
// layer of the system view. Ordered the way a player decides: who is
// here and what the enemy is doing first, then the system's state, then
// construction, then buildings. Everything here only builds text and
// plain models; the component renders and acts.
//
// `vm` is the component (or a test double): $t / $tc / $te, $store, and
// $options.filters.income / integer for numbers shown the way the
// visual view shows them. No `@/` imports, so the logic runs under
// plain node (front/src/game/a11y/__tests__).
import { agentListLabel, agentTypeName } from './describe.js';

export const INHABITED = ['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'];

// Moons and asteroids share the orbital biome: planets are listed first.
const BODY_ORDER = ['habitable_planet', 'sterile_planet', 'moon', 'asteroid'];

function game(vm) { return vm.$store.state.game; }

function fmtIncome(vm, value) {
  const f = vm.$options && vm.$options.filters;
  return f && f.income ? f.income(value, 0) : String(Math.round(value));
}

function fmtInt(vm, value) {
  const f = vm.$options && vm.$options.filters;
  return f && f.integer ? f.integer(value) : String(Math.round(value));
}

function factionName(vm, key) {
  return vm.$te(`data.faction.${key}.name`) ? vm.$t(`data.faction.${key}.name`) : String(key || '');
}

function plain(text) {
  return String(text || '').replace(/<br\s*\/?>/g, '. ').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
}

// ---- who owns it -----------------------------------------------------

// 'own' | 'own_dominion' | 'faction' | 'enemy' | 'autonomous' |
// 'uninhabited' | 'uninhabitable' | 'unknown'
export function relation(system, player) {
  if (!system.contact || system.contact.value === 0) return 'unknown';
  if (system.status === 'uninhabitable') return 'uninhabitable';
  if (system.status === 'uninhabited') return 'uninhabited';
  if (system.status === 'inhabited_neutral') return 'autonomous';
  const owner = system.owner || {};
  if (owner.id === player.id) return system.status === 'inhabited_dominion' ? 'own_dominion' : 'own';
  if (owner.faction && owner.faction === player.faction) return 'faction';
  return 'enemy';
}

export function isOwn(rel) {
  return rel === 'own' || rel === 'own_dominion';
}

export function title(vm, system, rel) {
  const owner = system.owner || {};
  const kind = system.status === 'inhabited_dominion' ? 'dominion' : 'system';
  const params = { name: system.name, owner: owner.name, faction: factionName(vm, owner.faction) };
  switch (rel) {
    case 'own': return vm.$t('a11y.system.title.own', params);
    case 'own_dominion': return vm.$t('a11y.system.title.own_dominion', params);
    case 'faction': return vm.$t(`a11y.system.title.faction_${kind}`, params);
    case 'enemy': return vm.$t(`a11y.system.title.enemy_${kind}`, params);
    default: return vm.$t(`a11y.system.title.${rel}`, params);
  }
}

// ---- agents ----------------------------------------------------------

// Agents present, split the way they matter: yours (you act with them),
// enemies (you act on them), factionmates (context). Each entry keeps
// the system's view of the agent and, for your own, your roster entry
// (status, orders, cover, cooldown are only known for your own).
export function agentGroups(vm, system) {
  const { player } = game(vm);
  const roster = new Map((player.characters || []).map((c) => [c.id, c]));
  const groups = { own: [], enemy: [], faction: [] };

  (system.characters || []).forEach((character) => {
    const owner = character.owner || {};
    if (owner.id === player.id) {
      groups.own.push({ character, roster: roster.get(character.id) || null });
    } else if (owner.faction && owner.faction === player.faction) {
      groups.faction.push({ character, roster: null });
    } else {
      groups.enemy.push({ character, roster: null });
    }
  });

  return groups;
}

// A Siderian is resting while its cooldown runs.
function isResting(roster) {
  return !!(roster && roster.type === 'speaker' && roster.speaker
    && roster.speaker.cooldown && roster.speaker.cooldown.value > 0);
}

export function agentLine(vm, entry, system) {
  const { character, roster } = entry;
  const owner = character.owner || {};

  if (roster) {
    const parts = [agentListLabel(vm, roster)];
    if (isResting(roster)) parts.push(vm.$t('a11y.system.agent.resting'));
    return parts.join(', ');
  }

  const parts = [vm.$t('a11y.agent.identity', {
    type: agentTypeName(vm, character.type),
    name: character.name,
    level: character.level == null ? vm.$t('a11y.unknown') : character.level,
  })];
  parts.push(owner.faction === game(vm).player.faction
    ? owner.name
    : vm.$t('a11y.system.agent.owner', { owner: owner.name, faction: factionName(vm, owner.faction) }));

  if (system.siege && system.siege.besieger_id === character.id) {
    parts.push(vm.$t(`data.character_action_status.${system.siege.type}.name`));
  }
  // Another faction's Erased is only sent to us once its cover is gone.
  if (character.type === 'spy' && owner.faction !== game(vm).player.faction) {
    parts.push(vm.$t('a11y.agent.exposed'));
  }
  if (character.armada_id != null) parts.push(vm.$t('a11y.system.agent.armada'));
  return parts.join(', ');
}

export function agentsSummary(vm, groups) {
  const parts = [];
  if (groups.enemy.length) parts.push(vm.$tc('a11y.system.agents.enemy', groups.enemy.length, { n: groups.enemy.length }));
  if (groups.own.length) parts.push(vm.$tc('a11y.system.agents.own', groups.own.length, { n: groups.own.length }));
  if (groups.faction.length) parts.push(vm.$tc('a11y.system.agents.faction', groups.faction.length, { n: groups.faction.length }));
  return parts.length ? parts.join(', ') : vm.$t('a11y.system.agents.none');
}

// ---- alerts ----------------------------------------------------------

// Critical states, most urgent first: a siege (conquest, pillage,
// bombardment), a Siderian taking control of your dominion, an exposed
// Erased. `remaining(ticks)` turns the siege's remaining ticks into
// text. Each alert has a stable `key` so the briefing can tell a new
// alert from one it has already announced.
export function criticalAlerts(vm, system, rel, groups, remaining) {
  const alerts = [];
  const { player } = game(vm);

  if (system.siege) {
    const all = [...groups.own, ...groups.enemy, ...groups.faction];
    const besieger = all.find((e) => e.character.id === system.siege.besieger_id);
    const mine = besieger && besieger.character.owner.id === player.id;
    const who = besieger
      ? `${agentTypeName(vm, besieger.character.type)} ${besieger.character.name}`
      : vm.$t('a11y.system.alert.unknown_besieger');
    alerts.push({
      key: `siege-${system.siege.type}-${system.siege.besieger_id}`,
      text: vm.$t(mine ? 'a11y.system.alert.siege_mine' : 'a11y.system.alert.siege', {
        who,
        action: vm.$t(`a11y.system.siege.${system.siege.type}`),
        time: remaining(system.siege.days.value),
      }),
    });
  }

  if (rel === 'own_dominion' && (player.dominions_under_attack || []).includes(system.id)) {
    const siderians = groups.enemy.filter((e) => e.character.type === 'speaker')
      .map((e) => e.character.name);
    alerts.push({
      key: 'takeover',
      text: siderians.length
        ? vm.$t('a11y.system.alert.takeover_by', { names: siderians.join(', ') })
        : vm.$t('a11y.system.alert.takeover'),
    });
  }

  groups.own
    .filter((e) => e.roster && e.roster.type === 'spy' && e.roster.is_discovered)
    .forEach((e) => alerts.push({
      key: `exposed-own-${e.character.id}`,
      text: vm.$t('a11y.system.alert.own_exposed', { name: e.character.name }),
    }));

  groups.enemy
    .filter((e) => e.character.type === 'spy')
    .forEach((e) => alerts.push({
      key: `exposed-enemy-${e.character.id}`,
      text: vm.$t('a11y.system.alert.enemy_exposed', { name: e.character.name }),
    }));

  return alerts;
}

function allTiles(system) {
  const tiles = [];
  (system.bodies || []).forEach((body) => {
    [body, ...(body.bodies || [])].forEach((b) => (b.tiles || []).forEach((tile) => tiles.push(tile)));
  });
  return tiles;
}

// What needs doing in your own system, after the critical alerts: an
// idle construction queue, damaged buildings, a workforce shortage,
// unrest.
export function attention(vm, system, rel) {
  if (!isOwn(rel)) return [];
  const items = [];

  if (system.queue && system.queue.queue && system.queue.queue.length === 0) {
    items.push({ key: 'queue', text: vm.$t('a11y.system.attention.queue_empty') });
  }

  const damaged = allTiles(system).filter((t) => t.building_status === 'damaged').length;
  if (damaged) items.push({ key: 'damaged', text: vm.$tc('a11y.system.attention.damaged', damaged, { n: damaged }) });

  if (typeof system.workforce === 'number' && system.used_workforce > system.workforce) {
    items.push({
      key: 'workforce',
      text: vm.$t('a11y.system.attention.workforce', {
        need: system.used_workforce,
        have: system.workforce,
        pct: Math.round((1 - (system.workforce / system.used_workforce)) * 100),
      }),
    });
  }

  if (system.population_status && system.population_status !== 'normal') {
    items.push({
      key: 'unrest',
      text: vm.$t('a11y.system.attention.unrest', {
        status: vm.$t(`data.population_status.${system.population_status}.name`),
      }),
    });
  }

  return items;
}

// The one paragraph read when the briefing opens: the system, its alerts,
// who is here, what needs doing. Detail lives in the sections below.
export function lead(vm, { heading, alerts, attentionItems, groups, rel }) {
  const parts = [heading];
  alerts.forEach((a) => parts.push(a.text));
  if (rel !== 'unknown') parts.push(agentsSummary(vm, groups));
  attentionItems.forEach((a) => parts.push(a.text));
  return parts.map((p) => p.replace(/[.\s]+$/, '')).join('. ').concat('.');
}

// ---- stats -----------------------------------------------------------

// A stat breakdown ({ building: [{reason, value}], misc: [...] }) as
// spoken lines, with the same labels as the visual breakdown popover.
export function detailLines(vm, details, income = false) {
  if (!details || Array.isArray(details)) return [];
  const lines = [];
  Object.keys(details).forEach((type) => {
    (details[type] || []).filter((d) => d.value !== 0).forEach((d) => {
      lines.push({
        label: detailReason(vm, type, d.reason),
        value: income ? fmtIncome(vm, d.value) : signed(d.value),
      });
    });
  });
  return lines;
}

function signed(value) {
  const rounded = Math.round(value * 10) / 10;
  return rounded > 0 ? `+${rounded}` : String(rounded);
}

function detailReason(vm, type, reason) {
  const keys = {
    building: `data.building.${reason}.name`,
    misc: `resource-detail.misc.${reason}`,
    happiness_penalties: `resource-detail.happiness_penalties.${reason}`,
    doctrine: `data.doctrine.${reason}.name`,
    tradition: `data.tradition.${reason}.name`,
    ship: `data.ship.${reason}.name`,
    government: `resource-detail.government.${reason}`,
  };
  const key = keys[type];
  const typeLabel = vm.$te(`resource-detail.type.${type}`) ? vm.$t(`resource-detail.type.${type}`) : type;
  if (key && vm.$te(key)) return `${typeLabel}: ${vm.$t(key)}`;
  return `${typeLabel}: ${reason}`;
}

// Every stat of the system the player can see, in reading order, each
// with its breakdown. A null `text` is below the system's visibility.
const STATS = [
  { key: 'production', label: 'data.bonus_pipeline_in.sys_production.name', income: true },
  { key: 'technology', label: 'data.bonus_pipeline_in.sys_technology.name', income: true },
  { key: 'ideology', label: 'data.bonus_pipeline_in.sys_ideology.name', income: true },
  { key: 'credit', label: 'data.bonus_pipeline_in.sys_credit.name', income: true },
  { key: 'defense', label: 'data.bonus_pipeline_in.sys_defense.name' },
  { key: 'counter_intelligence', label: 'galaxy.system.details.counterintelligence' },
  { key: 'remove_contact', label: 'galaxy.system.details.fixing', field: 'change' },
  { key: 'happiness', label: 'data.bonus_pipeline_in.sys_happiness.name' },
  { key: 'population_status' },
  { key: 'population' },
  { key: 'habitation', label: 'galaxy.system.population.habitation' },
  { key: 'workforce' },
  { key: 'mobility', label: 'galaxy.system.details.mobility' },
  { key: 'radar', label: 'galaxy.system.details.radar' },
  { key: 'contact', label: 'data.bonus_pipeline_in.sys_visibility.name' },
  { key: 'fighter_lvl', label: 'galaxy.system.details.fighters_init_xp' },
  { key: 'corvette_lvl', label: 'galaxy.system.details.corvettes_init_xp' },
  { key: 'frigate_lvl', label: 'galaxy.system.details.frigates_init_xp' },
  { key: 'capital_lvl', label: 'galaxy.system.details.capital_ships_init_xp' },
];

// Stats that read as sentences rather than a number + breakdown.
function sentenceStat(vm, system, key) {
  if (key === 'workforce') {
    if (typeof system.workforce !== 'number') return null;
    return {
      label: vm.$t('a11y.system.stat.workforce'),
      text: vm.$t('a11y.system.stat.workforce_value', { used: system.used_workforce, total: system.workforce }),
      details: [],
    };
  }
  if (key === 'population_status') {
    if (!system.population_status) return null;
    const ps = (game(vm).data.population_status || []).find((p) => p.key === system.population_status);
    return {
      label: vm.$t('galaxy.system.pop_status.title'),
      text: ps
        ? vm.$t('a11y.system.stat.pop_status_value', {
          status: vm.$t(`data.population_status.${ps.key}.name`),
          pct: Math.round((1 - ps.penalty) * 100),
        })
        : vm.$t(`data.population_status.${system.population_status}.name`),
      details: [],
    };
  }
  // population
  if (!system.population || typeof system.population !== 'object') return null;
  return {
    label: vm.$t('data.bonus_pipeline_in.sys_pop.name'),
    text: String(Math.floor(system.population.value)),
    details: detailLines(vm, system.population.details),
  };
}

export function stats(vm, system) {
  return STATS
    .map(({ key, label, income, field }) => {
      if (!label) {
        const entry = sentenceStat(vm, system, key);
        return entry ? { key, ...entry } : null;
      }
      const stat = system[key];
      let text = null;
      if (stat != null) {
        const raw = field ? stat[field] : (typeof stat === 'object' ? stat.value : stat);
        text = income ? fmtIncome(vm, raw) : fmtInt(vm, raw);
      }
      return {
        key,
        label: vm.$t(label),
        text,
        details: stat && typeof stat === 'object' ? detailLines(vm, stat.details, income) : [],
      };
    })
    .filter(Boolean);
}

// The overview's one line: who governs it, then the numbers that decide
// what to do there. Enemy systems: defenses and intel first; your own:
// income first.
export function overviewSummary(vm, system, rel, statList) {
  const by = new Map(statList.map((s) => [s.key, s]));
  const parts = [];

  if (INHABITED.includes(system.status)) {
    parts.push(system.governor
      ? vm.$t('a11y.system.governor', {
        type: agentTypeName(vm, system.governor.type),
        name: system.governor.name,
        level: system.governor.level,
      })
      : vm.$t('a11y.system.no_governor'));
  }

  const say = (keys) => keys
    .map((k) => by.get(k))
    .filter((s) => s && s.text != null)
    .map((s) => `${s.label} ${s.text}`)
    .join(', ');

  const income = say(['production', 'technology', 'ideology', 'credit']);
  const guard = say(['defense', 'counter_intelligence', 'remove_contact']);
  const people = say(['happiness', 'workforce']);

  const order = isOwn(rel) ? [income, people, guard] : [guard, income, people];
  order.filter(Boolean).forEach((p) => parts.push(p));

  if (!parts.length) parts.push(vm.$t('a11y.system.nothing_known'));
  return parts.join('. ').concat('.');
}

// ---- bodies and tiles ------------------------------------------------

// Every body that has tiles, planets first, then moons and asteroids.
export function bodies(system) {
  const list = [];
  (system.bodies || []).forEach((body) => {
    [body, ...(body.bodies || [])].forEach((b) => {
      if ((b.tiles || []).length > 0) list.push(b);
    });
  });
  const rank = (b) => {
    const i = BODY_ORDER.indexOf(b.type);
    return i === -1 ? BODY_ORDER.length : i;
  };
  return list
    .map((b, i) => ({ b, i }))
    .sort((x, y) => (Math.min(rank(x.b), 2) - Math.min(rank(y.b), 2)) || (x.i - y.i))
    .map(({ b }) => b);
}

export function tileCounts(tiles) {
  const counts = { total: tiles.length, built: 0, empty: 0, damaged: 0, hidden: 0, working: 0 };
  tiles.forEach((t) => {
    if (t.building_status === 'hidden') counts.hidden += 1;
    else if (t.building_status === 'empty') counts.empty += 1;
    else counts.built += 1;
    if (t.building_status === 'damaged') counts.damaged += 1;
    if (['new', 'upgrade', 'repair'].includes(t.construction_status)) counts.working += 1;
  });
  return counts;
}

function factorText(vm, value) {
  return value === 'hidden' || value == null ? vm.$t('a11y.unknown') : value;
}

export function bodySummary(vm, body) {
  const c = tileCounts(body.tiles || []);
  const parts = [
    `${body.name}, ${vm.$t(`data.stellar_body.${body.type}.name`)}`,
    c.hidden === c.total
      ? vm.$tc('a11y.system.body.tiles_unknown', c.total, { n: c.total })
      : vm.$t('a11y.system.body.tiles', { built: c.built, total: c.total, open: c.empty }),
    vm.$t('a11y.system.body.factors', {
      prod: factorText(vm, body.industrial_factor),
      sci: factorText(vm, body.technological_factor),
      appeal: factorText(vm, body.activity_factor),
    }),
  ];
  if (body.population === 'hidden') parts.push(vm.$t('a11y.system.body.population_unknown'));
  else if (body.population > 0) parts.push(vm.$t('a11y.system.body.population', { n: body.population }));
  if (c.damaged) parts.push(vm.$tc('a11y.system.attention.damaged', c.damaged, { n: c.damaged }));
  return parts.join('; ');
}

export function buildingsSummary(vm, system) {
  const c = tileCounts(bodies(system).flatMap((b) => b.tiles));
  if (c.total === 0) return vm.$t('a11y.system.buildings.none');
  if (c.hidden === c.total) return vm.$tc('a11y.system.body.tiles_unknown', c.total, { n: c.total });
  const parts = [vm.$t('a11y.system.body.tiles', { built: c.built, total: c.total, open: c.empty })];
  if (c.damaged) parts.push(vm.$tc('a11y.system.attention.damaged', c.damaged, { n: c.damaged }));
  if (c.working) parts.push(vm.$tc('a11y.system.buildings.working', c.working, { n: c.working }));
  return parts.join(', ');
}

// One tile, as heard in a body's list.
export function tileLine(vm, tile, index) {
  const slot = vm.$t('a11y.system.tile.slot', { n: index + 1 });
  const infra = tile.type === 'infrastructure' ? `, ${vm.$t('a11y.system.tile.infrastructure')}` : '';

  if (tile.building_status === 'hidden') return `${slot}${infra}: ${vm.$t('a11y.unknown')}`;
  if (tile.building_status === 'empty' && !tile.building_key) return `${slot}${infra}: ${vm.$t('a11y.system.tile.empty')}`;

  const name = tile.building_key && tile.building_key !== 'hidden'
    ? vm.$t(`data.building.${tile.building_key}.name`)
    : vm.$t('a11y.system.tile.unknown_building');
  const parts = [tile.building_level && tile.building_level !== 'hidden'
    ? vm.$t('a11y.system.tile.building_level', { name, level: tile.building_level })
    : name];
  if (tile.building_status === 'damaged') parts.push(vm.$t('a11y.system.tile.damaged'));
  if (['new', 'upgrade', 'repair'].includes(tile.construction_status)) {
    parts.push(vm.$t(`card.building.production.${tile.construction_status}`));
  }
  return `${slot}${infra}: ${parts.join(', ')}`;
}

// ---- building effects ------------------------------------------------

// A building level's bonuses in words: "+6 Housing", "+2 Production per
// Industrial Potential (8 here)". Mirrors CardComplexBonus.
export function bonusText(vm, bonusList, body, system) {
  const { data } = game(vm);
  const pipeIn = data.bonus_pipeline_in || [];
  return (bonusList || []).map((bonus) => {
    const bin = pipeIn.find((b) => b.key === bonus.from) || { from: 'none' };
    const label = vm.$te(`data.bonus_pipeline_out.${bonus.to}.name`)
      ? vm.$t(`data.bonus_pipeline_out.${bonus.to}.name`) : bonus.to;
    const amount = bonus.type === 'mul'
      ? `${bonus.value > 0 ? '+' : ''}${Math.round(bonus.value * 100)}%`
      : signed(bonus.value);

    if (bin.from === 'none') return `${amount} ${label}`;

    const fromLabel = vm.$te(`data.bonus_pipeline_in.${bonus.from}.name`)
      ? vm.$t(`data.bonus_pipeline_in.${bonus.from}.name`) : bonus.from;
    let source = null;
    if (bin.from === 'stellar_body' && body) source = body[bin.from_key];
    else if (system && bin.from_key && system[bin.from_key] != null) {
      const v = system[bin.from_key];
      source = typeof v === 'object' ? v.value : v;
    }
    if (bonus.from === bonus.to) return `${amount} ${label}`;
    const here = source != null && source !== 'hidden'
      ? vm.$t('a11y.system.effect.here', { value: Math.round(source * 10) / 10 })
      : '';
    return vm.$t('a11y.system.effect.per', { amount, label, from: fromLabel, here }).trim();
  }).join(', ');
}

// What a built building currently adds to the system, from the stat
// breakdowns (own systems only: foreign breakdowns are stripped). The
// breakdowns are per building type, so two Mines share one total.
export function contribution(vm, system, buildingKey) {
  const parts = [];
  stats(vm, system).forEach((stat) => {
    const raw = system[stat.key];
    const details = raw && typeof raw === 'object' && raw.details && raw.details.building;
    if (!Array.isArray(details)) return;
    const total = details.filter((d) => d.reason === buildingKey).reduce((acc, d) => acc + d.value, 0);
    if (total !== 0) {
      const income = ['production', 'technology', 'ideology', 'credit'].includes(stat.key);
      parts.push(`${income ? fmtIncome(vm, total) : signed(total)} ${stat.label}`);
    }
  });
  return parts.join(', ');
}

export { plain };
