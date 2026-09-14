// Canvas picture helpers shared by the copy-as-image features (resource
// bar picture card, battle simulator fleet export).

import svgicon from 'vue-svgicon';

// Mirrors $themes-list in styles/shared/variables.scss (canvas can't
// read SCSS variables).
export const THEME_HEX = {
  'dark-blue': '#3f66df',
  red: '#bc2433',
  purple: '#8e60bf',
  green: '#a2cd44',
  yellow: '#c9a115',
};

// Rasterize one registered svgicon to an Image via a data-URL <svg>.
// Resolves to null when the icon isn't in the registry (the caller draws
// a plain fallback instead) — never rejects.
export function loadIconImage(name, fill, size) {
  const registry = (svgicon && svgicon.icons) || {};
  const icon = registry[name];
  if (!icon || !icon.data) return Promise.resolve(null);

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${icon.viewBox}" `
    + `width="${size}" height="${size}"><g fill="${fill}">${icon.data}</g></svg>`;
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  });
}

export async function copyPngBlob(blob) {
  if (!blob || !navigator.clipboard || !window.ClipboardItem || !window.isSecureContext) {
    return false;
  }
  try {
    await navigator.clipboard.write([new window.ClipboardItem({ 'image/png': blob })]);
    return true;
  } catch (e) {
    return false;
  }
}
