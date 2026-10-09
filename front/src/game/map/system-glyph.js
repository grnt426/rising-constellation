// The "overview" map mode's glyph: what is drawn around a system dot to
// say who stands there and, for the faction's own systems, how well it
// holds. This file decides WHAT to draw (angles, shares, order); the
// SystemGlyphs block turns it into meshes. Pure, so it runs under plain
// node:
//   node --test front/src/game/map/__tests__/system-glyph.test.mjs
//
// Angles are radians, clockwise from 12 o'clock.

const TAU = Math.PI * 2;
const deg = (d) => (d * Math.PI) / 180;

// A full fleet ring: this much fleet upkeep standing in one system.
export const FLEET_CAP = 8000;
// The smallest arc a fleet gets, so that a scout squadron still shows.
const FLEET_MIN_SWEEP = deg(14);
// A fleet whose army the faction cannot read (contact below 4).
const FLEET_UNKNOWN_SWEEP = deg(26);
const FLEET_GAP = deg(9);

export const MAX_PIPS = 7;
const PIP_STEP = deg(21);

// Own faction's systems: an arc of icons per stat. A large icon is worth
// STAT_LARGE, a small one STAT_SMALL: 257 stability is two large icons, a
// full small one and a small one barely filled. Defense tops out around
// 500 and intelligence around 300 in real games; stability rarely passes
// 200, and is the only one that goes negative.
//
// The three stats share one ring around the system, a third each:
// intelligence top left, stability top right, defense underneath.
export const STAT_LARGE = 100;
export const STAT_SMALL = 50;
export const STAT_CAP = 500;
export const STATS = ['defense', 'stability', 'counter_intelligence'];

// A large icon's width in map units, and a small one's share of it.
const STAT_ICON = 0.28;
const STAT_SMALL_RATIO = 0.68;
// icons sit side by side along the ring, a hair apart
const STAT_SPACING = 1.06;

// Where each stat's third is centred, and the part of it the icons use
// (the rest is the gap to the next third).
const STAT_CENTER = { stability: deg(60), defense: deg(180), counter_intelligence: deg(300) };
const STAT_SPAN = deg(106);

// Mine first, then the rest of my faction, then the others faction by
// faction; within a group the largest first.
function order(agents, ownFaction) {
  const rank = (a) => {
    if (a.mine) return 0;
    return a.faction === ownFaction ? 1 : 2;
  };
  return agents.slice().sort((a, b) => rank(a) - rank(b)
    || String(a.faction).localeCompare(String(b.faction))
    || (b.upkeep || 0) - (a.upkeep || 0)
    || a.id - b.id);
}

// Who stands in a system: the faction's intel on it, with the viewer's
// own agents taken from the live roster instead (the intel is up to a
// minute old, the roster is not).
//
//   intelAgents   agents of the system's intel entry ([] without one)
//   liveAgents    the viewer's agents standing there now
//   playerAgentIds  every agent the viewer owns, wherever it is
export function presence({ intelAgents, liveAgents, playerAgentIds, ownFaction }) {
  const others = (intelAgents || [])
    .filter((agent) => !playerAgentIds.has(agent.id))
    .map((agent) => ({ ...agent, mine: false }));
  const all = order([...others, ...(liveAgents || []).map((agent) => ({ ...agent, mine: true }))], ownFaction);

  return {
    fleets: all.filter((agent) => agent.type === 'admiral'),
    agents: all.filter((agent) => agent.type !== 'admiral'),
  };
}

// The fleet ring: one arc per fleet, as long as its share of FLEET_CAP,
// laid clockwise from the top with a gap after each. Past a full ring
// the arcs shrink together so that all of them still fit.
export function fleetArcs(fleets) {
  if (fleets.length === 0) return [];

  const sweeps = fleets.map((fleet) => (typeof fleet.upkeep === 'number'
    ? Math.max((fleet.upkeep / FLEET_CAP) * TAU, FLEET_MIN_SWEEP)
    : FLEET_UNKNOWN_SWEEP));
  const room = TAU - (fleets.length * FLEET_GAP);
  const wanted = sweeps.reduce((sum, sweep) => sum + sweep, 0);
  const scale = wanted > room ? room / wanted : 1;

  let cursor = 0;
  return fleets.map((fleet, i) => {
    const arc = {
      start: cursor,
      sweep: sweeps[i] * scale,
      faction: fleet.faction,
      mine: !!fleet.mine,
      known: typeof fleet.upkeep === 'number',
    };
    cursor += arc.sweep + FLEET_GAP;
    return arc;
  });
}

// The other agents: one pip each on the outer orbit, fanned around
// 6 o'clock. Beyond MAX_PIPS the rest are not drawn.
export function agentPips(agents) {
  const shown = agents.slice(0, MAX_PIPS);
  return shown.map((agent, i) => ({
    angle: Math.PI + ((i - ((shown.length - 1) / 2)) * PIP_STEP),
    faction: agent.faction,
    mine: !!agent.mine,
    type: agent.type,
  }));
}

// One stat as icons, largest first: a large icon per full STAT_LARGE, then
// what is left over on small ones, the last filled only as far as it goes
// (`fill`, 0..1, left to right). A stat at zero is one empty small icon:
// the system has the stat, and none of it. A negative value (stability)
// reads the same way on its size, with every icon `broken`. Past STAT_CAP
// the icons stop.
export function statIcons(value) {
  if (typeof value !== 'number' || Number.isNaN(value)) return [];

  const broken = value < 0;
  const size = Math.min(Math.abs(value), STAT_CAP);
  const large = Math.floor(size / STAT_LARGE);
  let rest = size - (large * STAT_LARGE);

  const icons = Array.from({ length: large }, () => ({ large: true, fill: 1, broken }));
  if (rest >= STAT_SMALL) {
    icons.push({ large: false, fill: 1, broken });
    rest -= STAT_SMALL;
  }
  // a sliver of an icon is noise next to full ones
  const fill = rest / STAT_SMALL;
  if (icons.length === 0 || fill >= 0.05) icons.push({ large: false, fill, broken });
  return icons;
}

// The stats of a system the faction holds, each as its icons. Nothing for
// any other system, and no entry for a stat the intel does not carry.
export function statRows(intelSystem) {
  if (!intelSystem || !intelSystem.own) return [];

  return STATS
    .map((key) => ({ key, icons: statIcons(intelSystem[key]) }))
    .filter((row) => row.icons.length > 0);
}

// Where the icons of `statRows` go on the stat ring of radius `radius`:
// one entry per icon, { key, x, y, size, fill, broken }, x to the right
// and y up from the system.
//
// The two upper stats start at the top and run down their side (stability
// clockwise, intelligence the other way), so a system with little of
// either keeps its sides clear. Defense is centred under the system and
// reads left to right. In each, the largest icons come first and the
// part-filled one last.
//
// A third has room for about four large icons. A stat that needs more
// (480 is four large and two small) shrinks every icon of the system
// together, so that the sizes still compare across its three stats.
export function statLayout(rows, radius) {
  const width = (icon) => (icon.large ? 1 : STAT_SMALL_RATIO) * STAT_ICON * STAT_SPACING;
  const room = radius * STAT_SPAN;
  const widest = Math.max(0, ...rows.map((row) => row.icons.reduce((sum, icon) => sum + width(icon), 0)));
  const shrink = widest > room ? room / widest : 1;

  return rows.flatMap((row) => {
    const center = STAT_CENTER[row.key];
    const angles = row.icons.map((icon) => (width(icon) * shrink) / radius);
    const total = angles.reduce((sum, a) => sum + a, 0);

    let from;
    let direction;
    if (row.key === 'stability') {
      from = center - (STAT_SPAN / 2);
      direction = 1;
    } else if (row.key === 'counter_intelligence') {
      from = center + (STAT_SPAN / 2);
      direction = -1;
    } else {
      // clockwise runs right to left under the system
      from = center + (total / 2);
      direction = -1;
    }

    let cursor = from;
    return row.icons.map((icon, i) => {
      const angle = cursor + ((direction * angles[i]) / 2);
      cursor += direction * angles[i];
      return {
        key: row.key,
        x: radius * Math.sin(angle),
        y: radius * Math.cos(angle),
        size: (icon.large ? 1 : STAT_SMALL_RATIO) * STAT_ICON * shrink,
        fill: icon.fill,
        broken: icon.broken,
      };
    });
  });
}

// Where the glyph sits around a system dot, in map units. Stars come in
// several sizes (`display_size_factor`, 1 to 2.2 times a 0.4-wide sprite),
// so the ring starts from the star's own edge.
//
// `extent` is how far the glyph reaches: everything else drawn beside a
// system in overview mode (its name, the agents' name tags, the players'
// markers) keeps clear of it. A system of the viewer's faction
// (`withStats`) also carries the stat ring, outside everything else.
export function glyphRadii(sizeFactor = 1, withStats = false) {
  // the star fills about three quarters of its sprite
  const star = 0.2 * sizeFactor * 0.75;
  const fleetInner = star + 0.08;
  const fleetOuter = fleetInner + 0.08;
  const pipRadius = 0.05;
  const pipOrbit = fleetOuter + 0.12;
  // as tight around the pips as a large icon allows
  const statRadius = pipOrbit + pipRadius + (STAT_ICON / 2) + 0.03;

  return {
    fleet: [fleetInner, fleetOuter],
    siege: [fleetOuter + 0.035, fleetOuter + 0.065],
    pipOrbit,
    pipRadius,
    statRadius,
    extent: withStats
      ? statRadius + (STAT_ICON / 2) + 0.03
      : pipOrbit + pipRadius + 0.03,
  };
}

// How much larger than its map size the glyph is drawn at a camera
// altitude. Up close it is drawn to scale; from further up it grows, so
// that it keeps about the same size on screen instead of shrinking into a
// halo (at the default altitude a ring drawn to scale is 20 pixels wide).
// In steps: what is laid out around the glyph (names, markers) only has
// to move when a step is crossed.
export function glyphScale(altitude) {
  const scale = Math.min(Math.max(altitude / 36, 1), 2.75);
  return Math.round(scale * 4) / 4;
}
