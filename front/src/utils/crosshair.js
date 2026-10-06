// The crosshair at the center of the galaxy map: its saved settings
// (Account.settings.crosshair, edited on the portal's Settings → Galaxy
// crosshair screen) and the geometry drawn from them. Pure, so the map, the
// settings preview and the tests all work from the same numbers.

// The crosshair as it was before it could be changed: black lines, 80px
// wide and 30px tall, around a clear center.
export const DEFAULT_CROSSHAIR = Object.freeze({
  // Which marks are drawn. Any combination; none of them = no crosshair.
  cross: true,
  circle: false,
  dot: false,
  color: '#000000',
  // Take the color of the faction played in each match instead of `color`.
  match_faction: false,
  // Length in px of each horizontal / vertical line. 0 drops that pair.
  width: 80,
  height: 30,
  // Diameters in px.
  circle_size: 24,
  dot_size: 4,
});

export const MARKS = ['cross', 'circle', 'dot'];

// Sizes stay even so every mark is centered on a whole pixel.
export const SIZE_STEP = 2;
export const SIZE_LIMITS = Object.freeze({
  width: { min: 0, max: 300 },
  height: { min: 0, max: 300 },
  circle_size: { min: 8, max: 300 },
  dot_size: { min: 2, max: 24 },
});

// Every line and the circle's outline are this thick, and the lines start
// this far from the center.
export const THICKNESS = 2;
export const GAP = 20;

const HEX = /^#[0-9a-f]{6}$/;

// '#abc', 'AABBCC' and the like as '#aabbcc', or null when it isn't a color.
export function normalizeHex(value) {
  if (typeof value !== 'string') return null;

  let hex = value.trim().toLowerCase();
  if (hex[0] !== '#') hex = `#${hex}`;
  if (/^#[0-9a-f]{3}$/.test(hex)) {
    hex = `#${hex[1]}${hex[1]}${hex[2]}${hex[2]}${hex[3]}${hex[3]}`;
  }

  return HEX.test(hex) ? hex : null;
}

function size(value, key) {
  const { min, max } = SIZE_LIMITS[key];
  const n = typeof value === 'number' ? value : parseFloat(value);
  if (!Number.isFinite(n)) return DEFAULT_CROSSHAIR[key];

  return Math.min(max, Math.max(min, Math.round(n / SIZE_STEP) * SIZE_STEP));
}

// Whatever is saved (nothing, a partial object, values from an older or
// hand-edited blob) as a complete, in-range crosshair.
export function normalizeCrosshair(raw) {
  const saved = raw && typeof raw === 'object' ? raw : {};
  const flag = (key) => (typeof saved[key] === 'boolean' ? saved[key] : DEFAULT_CROSSHAIR[key]);

  return {
    cross: flag('cross'),
    circle: flag('circle'),
    dot: flag('dot'),
    color: normalizeHex(saved.color) || DEFAULT_CROSSHAIR.color,
    match_faction: flag('match_faction'),
    width: size(saved.width, 'width'),
    height: size(saved.height, 'height'),
    circle_size: size(saved.circle_size, 'circle_size'),
    dot_size: size(saved.dot_size, 'dot_size'),
  };
}

export function isDefaultCrosshair(crosshair) {
  const c = normalizeCrosshair(crosshair);
  return Object.keys(DEFAULT_CROSSHAIR).every((key) => c[key] === DEFAULT_CROSSHAIR[key]);
}

// The color to draw with. `factionHex` is the played faction's color, or
// null outside a match (and for anyone without a faction), where the chosen
// color stands in.
export function crosshairColor(crosshair, factionHex) {
  return (crosshair.match_faction && normalizeHex(factionHex)) || crosshair.color;
}

// The boxes to draw, in px from the center of the map: `line`s are filled,
// the `circle` is an outline, the `dot` a filled disc.
export function crosshairMarks(crosshair) {
  const marks = [];
  const half = THICKNESS / 2;

  if (crosshair.cross && crosshair.width > 0) {
    const line = { type: 'line', top: -half, width: crosshair.width, height: THICKNESS };
    marks.push({ ...line, left: -GAP - crosshair.width }, { ...line, left: GAP });
  }

  if (crosshair.cross && crosshair.height > 0) {
    const line = { type: 'line', left: -half, width: THICKNESS, height: crosshair.height };
    marks.push({ ...line, top: -GAP - crosshair.height }, { ...line, top: GAP });
  }

  [['circle', crosshair.circle_size], ['dot', crosshair.dot_size]].forEach(([type, diameter]) => {
    if (crosshair[type]) {
      marks.push({ type, left: -diameter / 2, top: -diameter / 2, width: diameter, height: diameter });
    }
  });

  return marks;
}

// How far the marks reach from the center, { x, y } in px; zeros when
// nothing is drawn.
export function crosshairExtent(crosshair) {
  return crosshairMarks(crosshair).reduce((extent, mark) => ({
    x: Math.max(extent.x, Math.abs(mark.left), mark.left + mark.width),
    y: Math.max(extent.y, Math.abs(mark.top), mark.top + mark.height),
  }), { x: 0, y: 0 });
}

/* Color wheel math: hue 0-360, saturation and value 0-1. */

export function hsvToHex({ h, s, v }) {
  const hue = (((h % 360) + 360) % 360) / 60;
  const c = v * s;
  const x = c * (1 - Math.abs((hue % 2) - 1));
  const m = v - c;

  const [r, g, b] = [
    [c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x],
  ][Math.floor(hue) % 6];

  return `#${[r, g, b]
    .map((channel) => Math.round((channel + m) * 255).toString(16).padStart(2, '0'))
    .join('')}`;
}

export function hexToHsv(value) {
  const hex = normalizeHex(value) || DEFAULT_CROSSHAIR.color;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);

  const max = Math.max(r, g, b);
  const delta = max - Math.min(r, g, b);

  let h = 0;
  if (delta > 0) {
    if (max === r) h = ((g - b) / delta) % 6;
    else if (max === g) h = (b - r) / delta + 2;
    else h = (r - g) / delta + 4;
  }

  return { h: (h * 60 + 360) % 360, s: max === 0 ? 0 : delta / max, v: max };
}
