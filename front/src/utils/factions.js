// The five playable factions, in canonical declaration order, with their
// theme colors. Mirrors lib/data/game/content/faction.ex (key + color) —
// display names come from i18n at `data.faction.<key>.name`.
export const FACTIONS = [
  { key: 'tetrarchy', theme: 'dark-blue', color: '#3f66df' },
  { key: 'myrmezir', theme: 'red', color: '#bc2433' },
  { key: 'cardan', theme: 'purple', color: '#8e60bf' },
  { key: 'synelle', theme: 'green', color: '#a2cd44' },
  { key: 'ark', theme: 'yellow', color: '#c9a115' },
];

// Bot-held factions (Wave Defense). Kept out of FACTIONS so pickers that
// iterate the playable roster (favorites, profile stats, the create form)
// never offer them, but still resolvable for colors and themes in game.
export const BOT_FACTIONS = [
  { key: 'rebellion', theme: 'orange', color: '#d2691e' },
];

const ALL_FACTIONS = [...FACTIONS, ...BOT_FACTIONS];

export function factionColor(key) {
  const faction = ALL_FACTIONS.find((f) => f.key === key);
  return faction ? faction.color : '#e6e6e6';
}

export function factionTheme(key) {
  const faction = ALL_FACTIONS.find((f) => f.key === key);
  return faction ? faction.theme : 'none';
}

export default FACTIONS;
