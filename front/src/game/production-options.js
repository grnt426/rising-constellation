// What can be built on a given tile, and why not.
//
// Extracted from Production.vue so the phone construction dock offers
// exactly the same set with the same lock reasons — two copies of the
// patent/limitation rules would drift the moment one of them changed.
//
// Returns [{ data, status, message }] where status is
// 'buildable' | 'locked' (missing patent / prerequisite building) |
// 'disabled' (a limitation already satisfied elsewhere).
import { i18n } from '@/plugins/i18n';

function buildingExist(bodies, buildingKey) {
  return bodies.reduce((acc, body) => {
    const hasTiles = body.tiles.some((t) => t.building_key === buildingKey);
    return acc || hasTiles || buildingExist(body.bodies, buildingKey);
  }, false);
}

function buildingBuilt(bodies, buildingKey) {
  return bodies.reduce((acc, body) => {
    const hasTiles = body.tiles
      .some((t) => t.building_key === buildingKey && t.building_status === 'built');
    return acc || hasTiles || buildingBuilt(body.bodies, buildingKey);
  }, false);
}

export function buildingOptions(gameState, system, body, tile) {
  if (!body || !tile) return [];

  const patents = gameState.player.patents;
  const { biome } = gameState.data.stellar_body.find((s) => s.key === body.type);

  return gameState.data.building
    .filter((b) => b.biome === biome && b.type === tile.type)
    .map((b) => {
      const { patent } = b.levels[0];

      let status = 'buildable';
      let message = '';

      if (patent !== null && !patents.some((p) => p === patent)) {
        status = 'locked';
        message = i18n.t('production.patent_needed', { patentName: i18n.t(`data.patent.${patent}.name`) });
      }

      if (b.limitation === 'unique_body' && body.tiles.find((t) => t.building_key === b.key)) {
        status = 'disabled';
        message = i18n.t('production.unique_building');
      }

      if (b.limitation === 'unique_system' && buildingExist(system.bodies, b.key)) {
        status = 'disabled';
        message = i18n.t('production.unique_system');
      }

      return { data: b, status, message };
    });
}

// Ships orderable for a fleet sitting in `system`. `collapse` keeps one
// entry per hull model (the largest unlocked squadron), which is the
// default the build menu opens on.
export function shipOptions(gameState, system, collapse = true) {
  const patents = gameState.player.patents;

  let ships = gameState.data.ship.map((s) => {
    const { shipyard, patent } = s;

    let status = 'buildable';
    let message = '';

    if (shipyard && !buildingBuilt(system.bodies, shipyard)) {
      status = 'locked';
      message = i18n.t('production.building_needed', {
        buildingName: i18n.t(`data.building.${shipyard}.name`),
      });
    }

    const hasAncestorPatents = gameState.data.ship
      .filter((s2) => s2.model === s.model && s2.unit_count < s.unit_count)
      .every((s2) => patents.some((p) => p === s2.patent));

    if (patent !== null && !(hasAncestorPatents && patents.some((p) => p === patent))) {
      status = 'locked';
      message = i18n.t('production.patent_needed', { patentName: i18n.t(`data.patent.${patent}.name`) });
    }

    return { data: s, status, message };
  });

  if (collapse) {
    const models = ships.reduce((acc, ship) => {
      if (!acc[ship.data.model]) acc[ship.data.model] = [];
      acc[ship.data.model].push(ship);
      return acc;
    }, {});

    ships = Object.keys(models).map((key) => {
      const sorted = models[key].sort((a, b) => b.data.unit_count - a.data.unit_count);
      return sorted.find((s) => s.status !== 'locked') || sorted[sorted.length - 1];
    });
  }

  return ships;
}

export default { buildingOptions, shipOptions };
