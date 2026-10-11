// Faction buildings (docs/faction-buildings.md) have no art of their
// own yet: icons and illustrations are thematic stand-ins from the
// existing building and patent sets.
export const FACTION_BUILDING_ICONS = {
  gateway: 'building/hypergate',
  training_center: 'building/military_school_dome',
  cyber_command: 'building/counterintelligence_open',
};

export const FACTION_BUILDING_ILLUSTRATIONS = {
  gateway: 'data/patents/orbital_hypergate.jpg',
  training_center: 'data/buildings/military_school_dome.jpg',
  cyber_command: 'data/buildings/counterintelligence_open.jpg',
};

export const FACTION_BUILDING_DEFAULT_ICON = 'building/frame_orbital';

// The station is a 2×2 grid of build slots.
export const STATION_SLOTS = 4;

export function factionBuildingIcon(key) {
  return FACTION_BUILDING_ICONS[key] || FACTION_BUILDING_DEFAULT_ICON;
}
