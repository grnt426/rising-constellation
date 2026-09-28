// Categorical colors for NON-faction series (income sources, ship classes,
// agent types). Faction series always use utils/factions.js colors — those
// are game identity. Assigned in fixed order, never cycled; validated as a
// set on the portal's dark panel surface (#31363f) with the dataviz
// validator (adjacent pairs).
export const SERIES_COLORS = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181'];

// Neutral for "the rest" and for lost battles / unused capacity.
export const NEUTRAL = '#6b7280';

// Single accent for one-series magnitude marks (activity map).
export const ACCENT = '#00b89a';

export function seriesColor(index) {
  return index < SERIES_COLORS.length ? SERIES_COLORS[index] : NEUTRAL;
}
