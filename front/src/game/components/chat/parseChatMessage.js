/**
 * Chat message token parser.
 *
 * Wire format for refs:
 *   [[sys:123|Sol Prime]]    — system, optional label
 *   [[spot:17]]              — sighting (reported enemy fleet / agent)
 *   [[vote:12|leader]]       — government ballot (label: its seat)
 *   [[at:42|Name]]           — mention of a faction member (see mentions.js)
 *
 * The kind is any lowercase word: a kind this client doesn't know still
 * parses as a ref and renders as an inert "unknown" chip (see
 * ChatMessageBody), so an older client shows a placeholder instead of
 * raw brackets when a newer one links something it can't draw yet.
 *
 * Anything that does not match the ref pattern is preserved verbatim as
 * a text node. This keeps backward compatibility with plain messages
 * and means a malformed token (e.g. `[[sys:]]`) is shown as literal
 * text rather than a broken chip.
 *
 * Output node shapes:
 *   { type: 'text', value: 'hello ' }
 *   { type: 'ref',  kind: 'sys' | 'spot' | …, id: '123', label: 'Sol' | null }
 *
 * `id` is kept as a string. Ref components coerce as needed.
 */

// Max refs per message — soft cap on the client (server enforces the same).
export const MAX_REFS_PER_MESSAGE = 10;

// Matches [[kind:id]] or [[kind:id|label]].
// - kind: a lowercase word
// - id:   anything except `|` and `]`
// - label (optional): anything except `]`
const REF_RE = /\[\[([a-z]{2,12}):([^|\]]+)(?:\|([^\]]+))?\]\]/g;

/**
 * Parse a raw chat message string into an array of AST nodes.
 * Always returns at least an empty array (never null/undefined).
 */
export function parseChatMessage(raw) {
  if (typeof raw !== 'string' || raw.length === 0) {
    return [];
  }

  const nodes = [];
  let cursor = 0;

  // Fresh regex per call so lastIndex is local.
  const re = new RegExp(REF_RE.source, 'g');
  let match = re.exec(raw);

  while (match !== null) {
    const [token, kind, id, label] = match;
    const start = match.index;

    if (start > cursor) {
      nodes.push({ type: 'text', value: raw.slice(cursor, start) });
    }

    nodes.push({
      type: 'ref',
      kind,
      id,
      label: label != null ? label : null,
    });

    cursor = start + token.length;
    match = re.exec(raw);
  }

  if (cursor < raw.length) {
    nodes.push({ type: 'text', value: raw.slice(cursor) });
  }

  return nodes;
}

/**
 * Serialize an array of AST nodes back to a wire-format string.
 * Used by ChatComposer on submit when walking its DOM children.
 */
export function stringifyChatMessage(nodes) {
  if (!Array.isArray(nodes)) return '';
  return nodes
    .map((node) => {
      if (node.type === 'text') return node.value;
      if (node.type === 'ref') {
        return node.label
          ? `[[${node.kind}:${node.id}|${node.label}]]`
          : `[[${node.kind}:${node.id}]]`;
      }
      return '';
    })
    .join('');
}

/**
 * Count ref nodes in a raw message — used for the 10-chip soft cap
 * on insert before sending.
 */
export function countRefs(raw) {
  if (typeof raw !== 'string') return 0;
  const re = new RegExp(REF_RE.source, 'g');
  let count = 0;
  while (re.exec(raw) !== null) count += 1;
  return count;
}
