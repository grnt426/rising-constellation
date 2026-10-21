// Markdown for translated strings ($tmd, and through it most notifications).
//
// The whole string is HTML-escaped before marked sees it, so no markup gets
// through, but markdown's own links and images do, and interpolated data
// lands here too: player names (RC.DisplayName allows brackets, parentheses
// and colons), system names, and so on. A player named
// `[x](javascript:alert(1))` must not put a live script link in other
// players' feeds, so link and image targets are checked before they are
// written out:
//   * links may go to http(s), mailto, a relative path or an #anchor;
//   * images only load from this site (a relative path): an outside image
//     in a name would be a tracking pixel in everyone's notifications.
// Anything else keeps its text and loses the link or image.
//
// No Vue, no webpack aliases: runs under plain node
// (see __tests__/markdown.test.mjs).
import marked from 'marked';
import { escape } from './escape.js';

const ENTITY_RE = /&(?:#(\d+)|#x([0-9a-f]+)|(amp|lt|gt|quot|apos));/gi;
const NAMED_ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
};
const LINK_SCHEME_RE = /^(?:https?|mailto):/i;

function fromCodePoint(n) {
  return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '�';
}

// marked hands the target over still HTML-escaped (escape() ran on the whole
// string, and marked writes autolinked e-mail addresses as entities).
function decodeEntities(s) {
  return s.replace(ENTITY_RE, (match, dec, hex, name) => {
    if (dec) return fromCodePoint(parseInt(dec, 10));
    if (hex) return fromCodePoint(parseInt(hex, 16));
    return NAMED_ENTITIES[name.toLowerCase()];
  });
}

// The target as the browser's URL parser reads it: tabs and newlines are
// dropped wherever they are, leading controls and spaces are trimmed.
function asParsed(url) {
  // eslint-disable-next-line no-control-regex
  return url.replace(/[\t\n\r]/g, '').replace(/^[\u0000- ]+/, '');
}

/**
 * The attribute value to write for a link (`kind` 'link') or image
 * ('image') target, or null to drop the link or image and keep its text.
 *
 * The value is fully HTML-escaped, so the browser reads back exactly the
 * URL that was checked: an entity left in the output can't decode into a
 * scheme after the fact.
 */
export function safeTarget(href, kind) {
  if (typeof href !== 'string') return null;
  const url = decodeEntities(href);
  const parsed = asParsed(url);
  // A colon before the first `/`, `?` or `#` names a scheme (or is
  // something no legitimate target looks like).
  const head = parsed.split(/[/?#]/, 1)[0];
  if (head.includes(':')) {
    if (kind !== 'link' || !LINK_SCHEME_RE.test(parsed)) return null;
  } else if (kind === 'image' && /^[/\\]{2}/.test(parsed)) {
    // protocol-relative: another site
    return null;
  }
  try {
    // same encoding marked applies to targets
    return escape(encodeURI(url).replace(/%25/g, '%'));
  } catch (e) {
    // a lone surrogate
    return null;
  }
}

const renderer = new marked.Renderer();

// marked has already escaped `title` and the rendered `text`.
renderer.link = (href, title, text) => {
  const target = safeTarget(href, 'link');
  if (target === null) return text;
  return `<a href="${target}"${title ? ` title="${title}"` : ''}>${text}</a>`;
};

renderer.image = (href, title, text) => {
  const target = safeTarget(href, 'image');
  if (target === null) return text;
  return `<img src="${target}" alt="${text}"${title ? ` title="${title}"` : ''}>`;
};

export function renderMd(md) {
  return marked(escape(md), { renderer });
}
