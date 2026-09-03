// Resource-bar copy builders — the C hotkey and the bottombar copy
// buttons share these. Four flavors:
//   - plaintext:   fenced monospace block, padded columns (Discord-safe)
//   - discord:     emoji units, markdown bold (no fence — custom emoji
//                  don't render inside code blocks)
//   - spreadsheet: the historical tab-separated 3×2 grid for Excel
//   - picture:     a square PNG card of the resource bar, written to the
//                  clipboard as an image
//
// Income values follow the player's income display setting: with the
// per-hour toggle on (Legacy), the shared text carries the explicit "/h"
// unit so a pasted figure can't be misread as a tick rate.

import svgicon from 'vue-svgicon';
import format, { incomeFactor } from '@/utils/format';
import { copyToClipboard } from '@/utils/clipboard';

const RESOURCE_KEYS = ['credit', 'technology', 'ideology'];

// Custom Discord emoji for the resource units. The legacy guild's emoji
// ids died with that guild — replace these shortcodes with the community
// guild's full tokens (`<:name:id>`, get one by typing `\:name:` in
// Discord) once the resource emoji live there. Shortcodes still convert
// on send when an emoji with that exact name exists; an entry set to ''
// falls back to the localized resource name.
const RESOURCE_EMOJI = {
  credit: ':credit:',
  technology: ':technology:',
  ideology: ':ideology:',
};

// Mirrors $themes-list in styles/shared/variables.scss (canvas can't
// read SCSS variables).
const THEME_HEX = {
  'dark-blue': '#3f66df',
  red: '#bc2433',
  purple: '#8e60bf',
  green: '#a2cd44',
  yellow: '#c9a115',
};

// One row per resource: localized name, formatted stockpile, formatted
// income carrying its unit ("/h" from the income filter, "/tick"
// otherwise).
function resourceRows(player, t) {
  return RESOURCE_KEYS.map((key) => {
    const resource = player[key] || {};
    const change = resource.change || 0;
    return {
      key,
      name: t(`data.bonus_pipeline_in.player_${key}.name`),
      value: format.integer(resource.value || 0),
      change: incomeFactor() !== 1
        ? format.income(change, 0, true)
        : `${format.integer(change, true)}/tick`,
    };
  });
}

export function plainText(player, t) {
  const rows = resourceRows(player, t);
  const nameWidth = Math.max(...rows.map((r) => r.name.length)) + 2;
  const valueWidth = Math.max(...rows.map((r) => r.value.length));
  const changeWidth = Math.max(...rows.map((r) => r.change.length));

  const lines = rows.map((r) => [
    r.name.padEnd(nameWidth, ' '),
    r.value.padStart(valueWidth, ' '),
    '  ',
    r.change.padStart(changeWidth, ' '),
  ].join(''));

  return `\`\`\`\n${lines.join('\n')}\n\`\`\``;
}

export function discordText(player, t) {
  return resourceRows(player, t)
    .map((r) => `${RESOURCE_EMOJI[r.key] || r.name} **${r.value}** (${r.change})`)
    .join('\n');
}

// The historical format, byte-identical to the old C-key copy: rounded
// raw per-tick values, tab-separated for Excel.
export function spreadsheetText(player) {
  const round = (v) => Math.round(v ?? 0);
  const cells = (field) => RESOURCE_KEYS.map((k) => round(player[k] && player[k][field])).join('\t');
  return `${cells('value')}\n${cells('change')}`;
}

// --- picture copy ---------------------------------------------------------

// Rasterize one registered svgicon to an Image via a data-URL <svg>.
// Resolves to null when the icon isn't in the registry (the caller draws
// a plain fallback dot instead) — never rejects.
function loadIconImage(name, fill, size) {
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

// Draw the resource bar as a square card. Returns a PNG Blob. Rendered
// at 2× for crisp pasting on hidpi screens; the layout is a fixed
// square so it reads well on both desktop and mobile Discord.
export async function renderPictureBlob(player, t, meta = {}) {
  const scale = 2;
  const side = 360;
  const canvas = document.createElement('canvas');
  canvas.width = side * scale;
  canvas.height = side * scale;
  const ctx = canvas.getContext('2d');
  ctx.scale(scale, scale);

  const accent = THEME_HEX[meta.theme] || '#3f66df';
  const rows = resourceRows(player, t);
  const icons = await Promise.all(rows.map((r) => loadIconImage(`resource/${r.key}`, '#e6e6e6', 40)));

  // card
  ctx.fillStyle = '#101319';
  ctx.fillRect(0, 0, side, side);
  ctx.fillStyle = accent;
  ctx.fillRect(0, 0, side, 5);
  ctx.strokeStyle = 'rgba(255, 255, 255, .12)';
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, side - 1, side - 1);

  // header: player name only — Discord handles often differ from game
  // names, so the in-game name is the useful identity on a shared card.
  ctx.textBaseline = 'alphabetic';
  ctx.fillStyle = '#e6e6e6';
  ctx.font = "800 22px 'Nunito', sans-serif";
  ctx.fillText((meta.playerName || '').toUpperCase(), 24, 52);

  // resource rows — stockpile and income sized close together: both
  // matter to the reader of a shared card.
  rows.forEach((row, i) => {
    const y = 120 + (i * 80);

    if (icons[i]) {
      ctx.drawImage(icons[i], 24, y - 6, 40, 40);
    } else {
      ctx.fillStyle = accent;
      ctx.beginPath();
      ctx.arc(44, y + 14, 16, 0, Math.PI * 2);
      ctx.fill();
    }

    ctx.fillStyle = 'rgba(230, 230, 230, .5)';
    ctx.font = "700 12px 'Nunito', sans-serif";
    ctx.fillText(row.name.toUpperCase(), 84, y);

    ctx.fillStyle = '#e6e6e6';
    ctx.font = "800 26px 'Nunito', sans-serif";
    ctx.fillText(row.value, 84, y + 30);

    ctx.fillStyle = accent;
    ctx.font = "800 21px 'Nunito', sans-serif";
    ctx.textAlign = 'right';
    ctx.fillText(row.change, side - 24, y + 30);
    ctx.textAlign = 'left';

    if (i < rows.length - 1) {
      ctx.strokeStyle = 'rgba(255, 255, 255, .08)';
      ctx.beginPath();
      ctx.moveTo(24, y + 52);
      ctx.lineTo(side - 24, y + 52);
      ctx.stroke();
    }
  });

  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
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

// Shared dispatcher for the hotkey and the bottombar buttons. `mode` is
// one of 'plaintext' | 'discord' | 'spreadsheet' | 'picture'; returns
// { ok, mode } so callers can toast appropriately.
export async function copyResources(mode, { player, t, theme, playerName }) {
  if (mode === 'picture') {
    const blob = await renderPictureBlob(player, t, { theme, playerName });
    return { ok: await copyPngBlob(blob), mode };
  }
  let text;
  if (mode === 'discord') {
    text = discordText(player, t);
  } else if (mode === 'spreadsheet') {
    text = spreadsheetText(player);
  } else {
    text = plainText(player, t);
  }
  return { ok: await copyToClipboard(text), mode };
}

// Full flow for a game component (`vm` needs $store / $t / $toasted):
// resolves the mode (explicit → profile setting → plaintext), copies,
// toasts the outcome. The C hotkey and the bottombar buttons both land
// here so they can never drift apart.
export async function copyResourcesForVm(vm, forcedMode) {
  const player = vm.$store.state.game.player;
  if (!player || !player.credit || !player.technology || !player.ideology) return;

  const mode = forcedMode
    || vm.$store.state.portal.settings.resourceCopyMode
    || 'plaintext';

  const { ok } = await copyResources(mode, {
    player,
    t: (key, params) => vm.$t(key, params),
    theme: vm.$store.getters['game/theme'],
    playerName: player.name || '',
  });

  if (!ok) {
    vm.$toasted.error(vm.$t('clipboard.failed'));
  } else if (mode === 'picture') {
    vm.$toasted.success(vm.$t('clipboard.image_copied'));
  } else if (mode === 'spreadsheet') {
    vm.$toasted.success(vm.$t('clipboard.resources_copied'));
  } else {
    vm.$toasted.success(vm.$t('clipboard.resources_copied_text'));
  }
}
