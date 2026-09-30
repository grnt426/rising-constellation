// Bounded, redacting copies of arbitrary values for the debug report.
//
// Everything the report carries passes through here: store snapshots,
// console arguments, error objects, socket replies. Two jobs:
//
//   * Size: a debug report must stay small enough to paste into Discord,
//     so depth, array length, key count and string length are all capped.
//     Circular references and exotic values (BigInt, DOM nodes, typed
//     arrays, functions) degrade to short markers instead of throwing.
//   * Privacy: credentials must never leave the player's machine, even
//     when some unrelated code logs an axios config or a cookie jar. Keys
//     that name a secret are replaced wholesale; strings are scrubbed for
//     token shapes (JWTs, Phoenix tokens, bearer headers, emails).
//
// Pure (no store, no Vue, no DOM required), so it runs under plain node:
//   node --test front/src/game/debug/__tests__/debug.test.mjs

// Keys whose VALUE is never exported, at any depth. Broad on purpose:
// over-redacting costs a little context, under-redacting leaks a login.
export const SECRET_KEY = /token|password|passwd|secret|authorization|cookie|jwt|api_?key|credential|email|steam_id/i;

const STRING_SCRUBBERS = [
  // JSON Web Tokens (the access/refresh tokens).
  [/eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g, '[redacted:jwt]'],
  // Phoenix.Token (registration tokens): base64 "SFMyNTY" = "HS256".
  [/SFMy[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, '[redacted:token]'],
  [/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [redacted]'],
  // Capability URLs and token query params.
  [/([?&#](?:[a-z_]*token|registration|key|code)=)[^&\s"']+/gi, '$1[redacted]'],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[redacted:email]'],
];

export function scrubString(str) {
  let out = str;
  for (let i = 0; i < STRING_SCRUBBERS.length; i += 1) {
    const [re, replacement] = STRING_SCRUBBERS[i];
    out = out.replace(re, replacement);
  }
  return out;
}

export const DEFAULTS = {
  maxDepth: 12,
  maxArray: 500,
  maxKeys: 1000,
  maxString: 4000,
};

function truncateString(str, max) {
  if (str.length <= max) return str;
  return `${str.slice(0, max)}…[+${str.length - max} chars]`;
}

function describeNode(node) {
  const tag = (node.tagName || node.nodeName || 'node').toLowerCase();
  const id = node.id ? `#${node.id}` : '';
  const cls = typeof node.className === 'string' && node.className
    ? `.${node.className.trim().split(/\s+/).slice(0, 3).join('.')}`
    : '';
  return `<${tag}${id}${cls}>`;
}

const isDomNode = (v) => typeof Node !== 'undefined' && v instanceof Node;

/**
 * A JSON-safe, size-bounded, secret-free copy of `value`.
 *
 * Shared references serialize at each occurrence; only true cycles (a value
 * that contains itself) collapse to "[circular]".
 */
export function sanitize(value, options = {}) {
  const opts = { ...DEFAULTS, ...options };
  const ancestors = [];

  const walk = (v, depth) => {
    if (v === null || v === undefined) return v === null ? null : undefined;

    switch (typeof v) {
      case 'string': return truncateString(scrubString(v), opts.maxString);
      case 'number': return Number.isFinite(v) ? v : String(v);
      case 'boolean': return v;
      case 'bigint': return `${v.toString()}n`;
      case 'function': return `[function ${v.name || 'anonymous'}]`;
      case 'symbol': return v.toString();
      default: break;
    }

    if (v instanceof Error) {
      return {
        name: v.name,
        message: truncateString(scrubString(String(v.message)), opts.maxString),
        stack: v.stack ? truncateString(scrubString(String(v.stack)), opts.maxString) : undefined,
      };
    }
    if (v instanceof Date) return Number.isNaN(v.getTime()) ? 'Invalid Date' : v.toISOString();
    if (v instanceof RegExp) return v.toString();
    if (isDomNode(v)) return describeNode(v);
    if (typeof ArrayBuffer !== 'undefined') {
      if (v instanceof ArrayBuffer) return `[ArrayBuffer ${v.byteLength}B]`;
      if (ArrayBuffer.isView(v)) return `[${v.constructor.name} ${v.length !== undefined ? v.length : v.byteLength}]`;
    }

    if (ancestors.includes(v)) return '[circular]';
    if (depth >= opts.maxDepth) return Array.isArray(v) ? `[array ${v.length}]` : '[object]';

    ancestors.push(v);
    try {
      if (v instanceof Map) {
        return walk(Array.from(v.entries()), depth);
      }
      if (v instanceof Set) {
        return walk(Array.from(v.values()), depth);
      }
      if (Array.isArray(v)) {
        const n = Math.min(v.length, opts.maxArray);
        const out = new Array(n);
        for (let i = 0; i < n; i += 1) {
          const item = walk(v[i], depth + 1);
          out[i] = item === undefined ? null : item;
        }
        if (v.length > n) out.push(`…[+${v.length - n} items]`);
        return out;
      }

      const out = {};
      const keys = Object.keys(v);
      const n = Math.min(keys.length, opts.maxKeys);
      for (let i = 0; i < n; i += 1) {
        const key = keys[i];
        // Vue 2 reactivity bookkeeping, never data.
        if (key !== '__ob__') {
          if (SECRET_KEY.test(key)) {
            out[key] = '[redacted]';
          } else {
            let child;
            try {
              child = v[key];
            } catch (e) {
              child = `[getter threw: ${e && e.message}]`;
            }
            const item = walk(child, depth + 1);
            if (item !== undefined) out[key] = item;
          }
        }
      }
      if (keys.length > n) out['…'] = `+${keys.length - n} keys`;
      return out;
    } finally {
      ancestors.pop();
    }
  };

  return walk(value, 0);
}

// Small limits for things captured continuously (console arguments): the
// capture runs on every console call, so it has to stay cheap.
const ARG_LIMITS = {
  maxDepth: 3, maxArray: 10, maxKeys: 20, maxString: 500,
};

/** One console argument as a short string. */
const isDomEvent = (v) => (typeof Event !== 'undefined' && v instanceof Event)
  || (v && typeof v === 'object' && typeof v.type === 'string' && typeof v.timeStamp === 'number' && 'isTrusted' in v);

/**
 * A DOM event as one line: `CloseEvent close on WebSocket code=1006
 * wasClean=false`. Events carry almost nothing as own properties (just
 * isTrusted), so a generic serializer prints `{"isTrusted":true}`. Never
 * prints a WebSocket's url: it carries the access token.
 */
export function describeEvent(e) {
  const parts = [e.constructor && e.constructor.name !== 'Object' ? e.constructor.name : 'Event', e.type];
  const target = e.target;
  if (target) {
    if (target.tagName) parts.push(`on <${String(target.tagName).toLowerCase()}>`);
    else if (target.constructor && target.constructor.name !== 'Object') parts.push(`on ${target.constructor.name}`);
    if (typeof target.status === 'number' && target.status) parts.push(`status=${target.status}`);
    if (target.tagName && typeof target.src === 'string' && target.src) parts.push(`src=${target.src.split('?')[0]}`);
  }
  if (typeof e.code === 'number') parts.push(`code=${e.code}`);
  if (typeof e.reason === 'string' && e.reason) parts.push(`reason=${e.reason}`);
  if (typeof e.wasClean === 'boolean') parts.push(`wasClean=${e.wasClean}`);
  if (typeof e.message === 'string' && e.message) parts.push(`message=${e.message}`);
  if (typeof e.filename === 'string' && e.filename) parts.push(`at ${e.filename}:${e.lineno || 0}`);
  return truncateString(scrubString(parts.join(' ')), 500);
}

export function formatArg(arg) {
  if (typeof arg === 'string') return truncateString(scrubString(arg), 2000);
  if (isDomEvent(arg)) return describeEvent(arg);
  if (arg instanceof Error) {
    const head = `${arg.name}: ${arg.message}`;
    const stack = arg.stack && arg.stack.includes(arg.message) ? arg.stack : `${head}\n${arg.stack || ''}`;
    return truncateString(scrubString(stack), 2000);
  }
  try {
    const json = JSON.stringify(sanitize(arg, ARG_LIMITS));
    return json === undefined ? String(arg) : truncateString(json, 1000);
  } catch (e) {
    return `[unserializable ${Object.prototype.toString.call(arg)}]`;
  }
}

/** A console call's arguments as one line, capped at `max` chars. */
export function formatArgs(args, max = 4000) {
  return truncateString(Array.from(args).map(formatArg).join(' '), max);
}

/** Short JSON rendering of a value, for diff previews. */
export function preview(value, max = 300) {
  if (value === undefined) return undefined;
  try {
    const json = JSON.stringify(sanitize(value, ARG_LIMITS));
    return truncateString(json === undefined ? String(value) : json, max);
  } catch (e) {
    return '[unserializable]';
  }
}
