/**
 * Mentions: `@Name` in a chat message, addressed to a faction member.
 *
 * On the wire a mention is a ref like any other, `[[at:<player id>|Name]]`
 * (see parseChatMessage): the id says who is meant, the label is only
 * what a client that cannot resolve the id falls back to. Nothing of it
 * is server-side: whether a message mentions the reader is read off the
 * message, and what the reader has already seen is the reader's own
 * business (Chat.vue keeps it per browser, like the read marks).
 */

export const MENTION_KIND = 'at';

const MENTION_RE = /\[\[at:(\d+)(?:\|[^\]]*)?\]\]/g;

// Ids of the players a raw message mentions.
export function mentionedIds(raw) {
  if (typeof raw !== 'string' || raw.indexOf('[[at:') === -1) return [];

  const ids = [];
  const re = new RegExp(MENTION_RE.source, 'g');
  let match = re.exec(raw);

  while (match !== null) {
    ids.push(parseInt(match[1], 10));
    match = re.exec(raw);
  }

  return ids;
}

// Whether a message is somebody else calling on this player.
export function mentionsPlayer(message, playerId) {
  return message.from_id !== playerId
    && typeof message.message === 'string'
    && mentionedIds(message.message).includes(playerId);
}

// A label rides inside the token: keep the token's own delimiters out.
export function mentionLabel(name) {
  return String(name || '').replace(/[[\]|]/g, ' ').trim();
}

export function mentionToken(member) {
  const label = mentionLabel(member.name);
  return label ? `[[at:${member.id}|${label}]]` : `[[at:${member.id}]]`;
}

const WORD_CHAR = /[\p{L}\p{N}_]/u;

/**
 * Turns every hand-typed `@Name` that is exactly a member's name into a
 * mention token, so a player who never touched the picker still reaches
 * whoever they meant. Case-insensitive; the longest name wins (names can
 * hold spaces, and one can start with another); `@` must open a word and
 * the name must end one. Anything else stays the text it was.
 */
export function linkMentions(text, members) {
  if (typeof text !== 'string' || text.indexOf('@') === -1 || !Array.isArray(members)) return text;

  const byLength = members
    .filter((m) => m && m.name)
    .map((m) => ({ member: m, lower: String(m.name).toLowerCase() }))
    .sort((a, b) => b.lower.length - a.lower.length);
  if (byLength.length === 0) return text;

  const lower = text.toLowerCase();
  let out = '';
  let i = 0;

  while (i < text.length) {
    const opensWord = text[i] === '@' && (i === 0 || !WORD_CHAR.test(text[i - 1]));
    const hit = opensWord && byLength.find(({ lower: name }) => {
      if (!lower.startsWith(name, i + 1)) return false;
      const after = text[i + 1 + name.length];
      return after === undefined || !WORD_CHAR.test(after);
    });

    if (hit) {
      out += mentionToken(hit.member);
      i += 1 + hit.lower.length;
    } else {
      out += text[i];
      i += 1;
    }
  }

  return out;
}

// Members a picker should offer for what was typed after `@`: those with
// a word starting with it first, then those merely containing it.
export function matchMembers(query, members, limit = 6) {
  const q = String(query || '').toLowerCase();
  const scored = [];

  (members || []).forEach((member) => {
    const name = String(member.name || '').toLowerCase();
    if (!name) return;

    if (q === '' || name.startsWith(q)) scored.push({ member, rank: 0 });
    else if (name.split(/\s+/).some((word) => word.startsWith(q))) scored.push({ member, rank: 1 });
    else if (name.includes(q)) scored.push({ member, rank: 2 });
  });

  return scored
    .sort((a, b) => a.rank - b.rank || a.member.name.localeCompare(b.member.name))
    .slice(0, limit)
    .map((s) => s.member);
}
