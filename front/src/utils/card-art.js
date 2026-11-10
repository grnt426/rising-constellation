// Card illustrations (agents, doctrines, patents, buildings, ships,
// avatars) as WebP sized to the screen — see bin/encode-card-art.py.
//
// Every `<dir>/<name>.jpg` has a 400x200 `<name>.webp` beside it; the ones
// listed in card-art-hd.js also have an 800x400 `<name>@2x.webp` made from
// the original artwork. Cards draw art at 304x152 CSS px (238x119 on
// mobile), so with `w` descriptors the browser takes the 400 file on a
// DPR-1 screen and the 800 file on DPR >= 1.5 (retina, phones). The JPEG
// stays the `<img src>` for browsers without WebP.
//
// No Vue, no store: runs under plain node.

import HD from './card-art-hd.js';

const HD_SETS = Object.fromEntries(Object.entries(HD).map(([dir, names]) => [dir, new Set(names)]));

// `path` is any URL ending in `<dir>/<name>.jpg`: 'data/agents/x.jpg',
// '../portal/data/avatars/x.jpg', '/dist/main/data/ships/x.jpg' (Steam).
const CARD_ART = /(?:^|\/)([a-z]+)\/([^/]+)\.jpg$/;

/**
 * @param {string} path      the JPEG's URL
 * @param {object} [options]
 * @param {boolean} [options.lowData]  never offer the 800px file
 * @returns {string|null}    a `srcset` for a WebP `<source>`, or null when
 *                           `path` is not card art (render the plain <img>)
 */
export function cardArtSrcset(path, { lowData = false } = {}) {
  const match = CARD_ART.exec(path || '');
  if (!match || !HD_SETS[match[1]]) return null;

  const stem = path.slice(0, -'.jpg'.length);
  const candidates = [`${stem}.webp 400w`];
  if (!lowData && HD_SETS[match[1]].has(match[2])) {
    candidates.push(`${stem}@2x.webp 800w`);
  }
  return candidates.join(', ');
}

/**
 * The browser asked for less data: the Save-Data setting, or a 2G-class
 * connection. Chromium-only API; elsewhere this is false.
 */
export function prefersLowData(nav = typeof navigator !== 'undefined' ? navigator : undefined) {
  const connection = nav && nav.connection;
  if (!connection) return false;
  return Boolean(connection.saveData) || /(^|-)2g$/.test(connection.effectiveType || '');
}
