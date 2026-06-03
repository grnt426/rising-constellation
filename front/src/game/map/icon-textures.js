import { CanvasTexture, LinearFilter } from 'three';

// One-time bake of each player-icon kind to a CanvasTexture so the
// Three.js layer can paint markers without parsing SVG every frame.
//
// Source SVG data mirrors what the marker/* and ship/* vue-svgicon
// files register on the DOM side; keeping the paths copy-pasted here
// (rather than reaching into vue-svgicon internals) means the map and
// the radial picker stay in lockstep visually without coupling to
// vue-svgicon's runtime registry shape.
//
// Color: a desaturated white-grey at ~65% opacity. Earlier passes
// shipped at near-white 0.95 which read as "blinding" against the
// dark map; the markers should sit quietly on top of systems, not
// compete with faction colors. The dark drop shadow keeps them
// legible against both deep-space black and bright faction sprites.
//
// `shield` re-uses the ship/hull glyph (4 outward-pointing wedges
// forming a diamond) instead of the literal shield outline — the
// hull shape reads as "defend / hold this line" without the
// medieval-shield connotation that didn't fit the game's aesthetic.
const ICON_PATHS = {
  shield: '<path d="M9.542 10.5H2.015l7.527 7.527zM9.542 9.5V1.973L2.015 9.5zM10.542 9.5h7.442l-7.442-7.443zM10.542 10.5v7.443l7.442-7.443z"/>',
  attack: '<path d="M5 2 L15 2 L10 7 Z"/><path d="M18 5 L18 15 L13 10 Z"/><path d="M5 18 L15 18 L10 13 Z"/><path d="M2 5 L2 15 L7 10 Z"/>',
  flag: '<path d="M5 2 L7 2 L7 18 L5 18 Z"/><path d="M7 4 L16 7 L7 10 Z"/>',
  target: '<circle cx="10" cy="10" r="2"/><path d="M10 15c-2.757 0-5-2.243-5-5s2.243-5 5-5 5 2.243 5 5-2.243 5-5 5zm0-9c-2.206 0-4 1.794-4 4s1.794 4 4 4 4-1.794 4-4-1.794-4-4-4z"/>',
  danger: '<circle cx="10" cy="10" r="3"/><path d="M15 13h-1v1h-1v1h1v1h1v-1h1v-1h-1zM6 13H5v1H4v1h1v1h1v-1h1v-1H6zM5 7h1V6h1V5H6V4H5v1H4v1h1zM15 5V4h-1v1h-1v1h1v1h1V6h1V5z"/>',
  path: '<path d="M4 3 L14 10 L4 17 L7 17 L17 10 L7 3 Z"/>',
  question: '<path d="M6 7 C6 4 8 2 10 2 C12 2 14 4 14 7 C14 9 12.5 10 11.5 11 C11 11.5 11 12 11 13 L9 13 C9 11.5 9.5 10.5 10.5 9.5 C11.5 8.5 12 8 12 7 C12 5.5 11 4 10 4 C9 4 8 5.5 8 7 Z"/><circle cx="10" cy="16" r="1.4"/>',
};

const FILL_COLOR = 'rgba(210, 215, 225, 0.65)';
const SHADOW_COLOR = 'rgba(0, 0, 0, 0.7)';
const CANVAS_SIZE = 96;

// Build a CanvasTexture for one icon kind. The SVG is rasterized via
// an <img> loaded from a data URL — slower than a hand-coded Path2D
// but agnostic to the SVG's primitive mix (circles, paths) so we can
// reuse the exact same shapes as the DOM-side radial picker without
// translating each one.
function bakeOne(kind, paths) {
  return new Promise((resolve, reject) => {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" width="${CANVAS_SIZE}" height="${CANVAS_SIZE}" fill="${FILL_COLOR}">${paths}</svg>`;
    // Inline-encode so we don't need a same-origin URL or a Blob/URL
    // lifetime to worry about. encodeURIComponent handles the # and
    // < that would otherwise break the data URL.
    const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;

    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = CANVAS_SIZE;
      canvas.height = CANVAS_SIZE;
      const ctx = canvas.getContext('2d');
      // Soft dark drop shadow so the marker reads on both dark space
      // and bright faction-colored systems.
      ctx.shadowColor = SHADOW_COLOR;
      ctx.shadowBlur = 4;
      ctx.drawImage(img, 0, 0, CANVAS_SIZE, CANVAS_SIZE);

      const texture = new CanvasTexture(canvas);
      // CanvasTextures default to nearest-neighbor in some setups;
      // linear keeps the marker readable when the camera dollies.
      texture.minFilter = LinearFilter;
      texture.magFilter = LinearFilter;
      texture.needsUpdate = true;
      resolve({ kind, texture });
    };
    img.onerror = (e) => reject(new Error(`Failed to bake icon "${kind}": ${e.message || e}`));
    img.src = url;
  });
}

let cachedPromise = null;

// Lazy-loads + caches: any caller after the first gets the same
// textures back without re-baking.
export function loadIconTextures() {
  if (cachedPromise) return cachedPromise;
  cachedPromise = Promise.all(
    Object.entries(ICON_PATHS).map(([kind, paths]) => bakeOne(kind, paths)),
  ).then((entries) => entries.reduce((acc, { kind, texture }) => {
    acc[kind] = texture;
    return acc;
  }, {}));
  return cachedPromise;
}

export const ICON_KINDS = Object.keys(ICON_PATHS);
