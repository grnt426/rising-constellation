// Pure helpers for the in-game help manual (modal + Help drawer). No Vue,
// no store: testable with plain node (see __tests__/render.test.mjs).
//
// The server compiles pages to HTML with two kinds of markers the client
// finishes off:
//   <i class="help-icon" data-icon="group/name" title="Name"></i>
//     → inline <svg> from the vue-svgicon registry (same drawing the rest of
//       the UI uses), so icons follow currentColor and need no sprite fetch.
//   <a href="/help/slug" class="help-ref" data-help="slug">label</a>
//     → left as-is; the surfaces intercept clicks on [data-help] and open
//       the page in place instead of leaving the game.

const ICON_RE = /<i class="help-icon" data-icon="([^"]+)" title="([^"]*)"><\/i>/g;

// vue-svgicon keeps the original colours as `_fill` / `_stroke` so it can
// restore them on demand; browsers ignore those attributes, so dropping
// them just makes the intent explicit: help icons take currentColor.
const ORIGINAL_COLOR_RE = / _(?:fill|stroke)="[^"]*"/g;

export function makeIconLookup(registry) {
  return (name) => (registry && registry[name]) || null;
}

// Help images (screenshots) are root-relative Phoenix static files:
// src="/img/help/...". The SPA can be served from another origin than
// Phoenix (Steam, a bare dev server), so surfaces pass `options.origin`
// and those srcs become absolute. Without an origin they are left alone.
const HELP_IMG_SRC_RE = /src="\/img\/help\//g;

export function renderHelpHtml(html, lookupIcon, options = {}) {
  if (!html) return '';
  let out = html.replace(ICON_RE, (match, name, title) => {
    const icon = lookupIcon(name);
    if (!icon) return `<span class="help-icon help-icon-missing" title="${title}"></span>`;
    const body = String(icon.data).replace(ORIGINAL_COLOR_RE, '');
    return `<svg class="svg-icon help-icon" viewBox="${icon.viewBox}" role="img" aria-label="${title}"><title>${title}</title>${body}</svg>`;
  });
  const origin = options.origin ? String(options.origin).replace(/\/+$/, '') : '';
  if (origin) out = out.replace(HELP_IMG_SRC_RE, `src="${origin}/img/help/`);
  return out;
}

// Title matches first, then term matches, then body text; stable by title.
export function searchPages(pages, query) {
  const q = String(query || '').trim().toLowerCase();
  if (!q) return [];
  const rank = (p) => {
    if (p.title.toLowerCase().includes(q)) return 0;
    if ((p.terms || []).some((t) => t.toLowerCase().includes(q))) return 1;
    if ((p.text || '').toLowerCase().includes(q)) return 2;
    return -1;
  };
  return pages
    .map((p) => ({ p, r: rank(p) }))
    .filter(({ r }) => r >= 0)
    .sort((a, b) => a.r - b.r || a.p.title.localeCompare(b.p.title))
    .map(({ p }) => p);
}

// Public URL of a page, for the "copy link" button. `origin` is the site
// origin (config.BASE_URL in production, window.location.origin in dev).
export function publicHelpUrl(origin, slug, speed) {
  const base = `${origin || ''}/help/${slug}`;
  return speed && speed !== 'slow' ? `${base}?speed=${speed}` : base;
}
