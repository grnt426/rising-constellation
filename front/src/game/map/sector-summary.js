// What the far-zoom sector card shows, worked out from what the client
// already holds: the sector's division (who has how many systems), the
// map's systems, the faction's map intel and its government. Pure, so it
// runs under plain node:
//   node --test front/src/game/map/__tests__/sector-summary.test.mjs

// The tug of war for a sector.
//
// The server's rule (Instance.Galaxy.Sector.update_owner/2): a sector goes
// to the faction with the most inhabited systems in it, but only once that
// faction has MORE of them than the current holder. A tie keeps the holder.
// In a faction's start sector that never changed hands (`starter?`), the
// neutral systems cannot take it back.
//
// So the contest is between the holder and its strongest rival, and the
// bar puts those two side by side from the left: the boundary between them
// is the rope's marker, the middle of their combined span is the line. The
// holder keeps the sector while the marker is on the line or past it.
//
//   segments   holder first, then the rival, then everyone else
//   line       where the line sits, as a share of the bar (null: no rival)
//   lead       holder systems minus rival systems (negative: about to flip)
export function controlBar(sector) {
  const holderKey = sector.owner || null;
  const division = (sector.division || [])
    .map((d) => ({ faction: d.faction || null, points: d.points || 0 }))
    .filter((d) => d.points > 0);
  const total = division.reduce((sum, d) => sum + d.points, 0);

  const holder = division.find((d) => d.faction === holderKey) || { faction: holderKey, points: 0 };
  const rivals = division
    .filter((d) => d.faction !== holderKey)
    .sort((a, b) => b.points - a.points);
  const contenders = sector['starter?'] ? rivals.filter((d) => d.faction !== null) : rivals;
  const challenger = contenders[0] || null;
  const others = rivals.filter((d) => d !== challenger);

  const share = (points) => (total > 0 ? points / total : 0);
  const segments = [
    { ...holder, role: 'holder' },
    ...(challenger ? [{ ...challenger, role: 'challenger' }] : []),
    ...others.map((d) => ({ ...d, role: 'other' })),
  ].map((segment) => ({ ...segment, share: share(segment.points) }));

  return {
    total,
    holder: segments[0],
    challenger: challenger ? segments[1] : null,
    segments,
    line: challenger && total > 0 ? share(holder.points + challenger.points) / 2 : null,
    lead: challenger ? holder.points - challenger.points : null,
  };
}

// The factions the sector card pages through: the viewer's own first, then
// every other faction with a system in the sector, the holder ahead of the
// rest and then by number of systems. Neutral systems are nobody's.
export function sectorFactions(sector, ownFaction) {
  const others = (sector.division || [])
    .filter((d) => d.faction && d.faction !== ownFaction && d.points > 0)
    .sort((a, b) => (b.faction === sector.owner) - (a.faction === sector.owner) || b.points - a.points)
    .map((d) => d.faction);

  return [ownFaction, ...others];
}

// What one faction has in a sector, as far as the viewer can tell.
//
//   systems           the map's systems (MapData#systems): faction, class,
//                     owner and the viewer's `visibility` on each
//   faction           whose page this is; ownFaction is the viewer's
//   pointsByClass     population class key -> victory points
//   intel             the viewer's faction map intel (store `mapIntel`)
//
// For the viewer's own faction everything is known. For another one each
// figure only covers what the contact level shows, the same gates as on
// the map: population from contact 3, fleets from 2 and their upkeep from
// 4, income from 4. `population.systems` and `economy.systems` say how many
// of the faction's `systems` a sum covers.
//
// `visibility` is the viewer's own contact, in victory-track points
// (Instance.Galaxy.Agent, :update_contacts: 5 per system another faction
// holds, neutral systems left out): on every other faction's systems for
// the viewer's page, on that faction's systems for another's. Null when
// there is no such system.
export function factionStats({ sectorId, systems, faction, ownFaction, pointsByClass, intel }) {
  const own = faction === ownFaction;
  let held = 0;
  const population = { points: 0, systems: 0 };
  const watched = { points: 0, systems: 0 };

  (systems || []).forEach((system) => {
    if (system.sector_id !== sectorId) return;

    if (system.faction === faction) {
      held += 1;
      if (own || system.visibility > 2) {
        population.systems += 1;
        population.points += pointsByClass[system.class] || 0;
      }
    }

    const counts = own ? (system.owner && system.faction !== ownFaction) : system.faction === faction;
    if (counts) {
      watched.systems += 1;
      watched.points += system.visibility || 0;
    }
  });

  // upkeep sums the fleets that can be read; `unread` counts the others
  const fleets = { count: 0, upkeep: 0, unread: 0 };
  let foreignFleets = 0;
  Object.values((intel && intel.systems) || {}).forEach((system) => {
    if (system.sector_id !== sectorId) return;
    system.agents.forEach((agent) => {
      if (agent.type !== 'admiral') return;
      if (agent.faction === faction) {
        fleets.count += 1;
        if (typeof agent.upkeep === 'number') fleets.upkeep += agent.upkeep;
        else fleets.unread += 1;
      } else if (agent.faction !== ownFaction) {
        foreignFleets += 1;
      }
    });
  });

  const sums = intel && intel.sectors && intel.sectors[sectorId];

  return {
    own,
    systems: held,
    population,
    visibility: watched.systems > 0 ? { points: watched.points, max: watched.systems * 5 } : null,
    fleets,
    // fleets of other factions in sight: the viewer's own page only
    foreignFleets: own ? foreignFleets : null,
    economy: (sums && sums[faction]) || null,
  };
}

// The Cyber Commands the faction has built in a sector: their summed
// estimate of enemy informers, or null when it has none there. Each
// command keeps its own noisy count (docs/faction-buildings.md).
export function sectorCensus(government, sectorId) {
  const commands = ((government && government.station_buildings) || [])
    .filter((b) => b.key === 'cyber_command' && b.status === 'built' && b.sector_id === sectorId);
  if (commands.length === 0) return null;

  return {
    commands: commands.length,
    count: commands.reduce((sum, b) => sum + (b.census || 0), 0),
    // an unpowered station network stops counting: the figure is stale
    powered: government.station_powered !== false,
  };
}
