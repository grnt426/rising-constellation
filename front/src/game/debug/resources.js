// Where each file the page loaded came from — browser cache, a revalidated
// cache entry (304), or the network — read from the browser's own
// Resource Timing entries, so it costs no requests of its own.
//
// Stale caches show up here: a bundle or map file served from cache after
// a deploy, or the page itself (the HTML that names the bundles) coming
// from cache.
//
// Pure (no store, no Vue, no DOM), so it runs under plain node:
//   node --test front/src/game/debug/__tests__/debug.test.mjs

/**
 * 'cache' | 'revalidated' | 'network' | 'unknown' for one
 * PerformanceResourceTiming / PerformanceNavigationTiming entry.
 */
export function classifyResource(e) {
  if (!e) return 'unknown';
  // Chromium 109+ says so outright
  if (e.deliveryType === 'cache') return 'cache';
  const transfer = e.transferSize;
  const body = e.encodedBodySize || e.decodedBodySize || 0;
  if (typeof transfer !== 'number') return 'unknown';
  if (transfer === 0) return body > 0 ? 'cache' : 'unknown';
  // A 304 carries headers only: less on the wire than the body it reused.
  if (body > 0 && transfer < body) return 'revalidated';
  return 'network';
}

function groupOf(path, type) {
  if (/\.(js|css)$/.test(path) || type === 'script' || type === 'link' || type === 'css') return 'bundles';
  if (path.includes('/map/')) return 'map';
  if (path.includes('/fonts/') || /\.(woff2?|ttf|otf)$/.test(path)) return 'fonts';
  if (/\.(mp3|ogg|webm|wav)$/.test(path)) return 'sound';
  if (/\.(png|jpe?g|webp|avif|svg|gif)$/.test(path)) return 'images';
  return 'other';
}

const kb = (bytes) => (typeof bytes === 'number' ? Math.round((bytes / 1024) * 10) / 10 : undefined);

/**
 * Same-origin static files (API calls and the socket excluded — the HTTP
 * section has those), grouped, with counts by delivery.
 */
export function summarizeResources(entries, origin, limit = 150) {
  const files = (entries || [])
    .filter((e) => typeof e.name === 'string' && e.name.startsWith(origin))
    .map((e) => {
      const url = e.name.slice(origin.length);
      const path = url.split('?')[0];
      return { e, url, path };
    })
    .filter(({ path }) => !path.startsWith('/api/') && !path.startsWith('/socket'))
    .map(({ e, url, path }) => ({
      path: url.length > 200 ? `${url.slice(0, 200)}…` : url,
      group: groupOf(path, e.initiatorType),
      type: e.initiatorType,
      via: classifyResource(e),
      transferKB: kb(e.transferSize),
      bodyKB: kb(e.decodedBodySize),
      ms: Math.round(e.duration),
      protocol: e.nextHopProtocol || undefined,
      status: e.responseStatus || undefined,
    }));

  const counts = {};
  files.forEach((f) => {
    const g = counts[f.group] || (counts[f.group] = {
      cache: 0, revalidated: 0, network: 0, unknown: 0,
    });
    g[f.via] += 1;
  });

  return {
    counts,
    downloadedKB: kb(files.reduce((acc, f) => acc + ((f.transferKB || 0) * 1024), 0)),
    files: files.slice(0, limit),
    truncated: files.length > limit ? files.length - limit : undefined,
  };
}

/** The hashed app bundle a page's HTML points at (`app.149c63af.js`), or null. */
export function appBundleOf(html) {
  const m = /src=["']?[^"'\s>]*\/(app\.[0-9a-f]{6,}\.js)/.exec(html || '');
  return m ? m[1] : null;
}
