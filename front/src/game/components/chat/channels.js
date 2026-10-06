/**
 * Chat channels (the tabs), and what the client derives from the posts
 * the game makes on a player's behalf.
 *
 * Mirrors Instance.Faction.ChatMessage.channels/0 on the server. Order is
 * tab order.
 */
export const CHANNELS = ['general', 'claims', 'spotted', 'aid', 'ask'];
export const DEFAULT_CHANNEL = 'general';

// Glyph that marks a line's channel in the combined "All" view. General
// carries none: it is the unmarked case.
export const CHANNEL_TAGS = {
  claims: '⚑',
  spotted: '◉',
  aid: '⇄',
  ask: '?',
};

// Messages written before channels existed, or filed under one this
// client doesn't know, read as General.
export function channelOf(message) {
  return CHANNELS.includes(message.channel) ? message.channel : DEFAULT_CHANNEL;
}

// The system a claim post is about, or null for any other message.
export function claimOf(message) {
  const meta = message.meta;
  return meta && meta.kind === 'claim' && Number.isFinite(meta.system_id) ? meta.system_id : null;
}

// A line the game posts when government ballots open (`[[vote:id]]`
// chips): how many of them, or 0 for any other message.
export function voteCountOf(message) {
  const meta = message.meta;
  if (!meta || meta.kind !== 'vote') return 0;
  return Array.isArray(meta.ballot_ids) ? Math.max(meta.ballot_ids.length, 1) : 1;
}

// Per claimed system, the id of its most recent claim post: an older
// post about the same system has been superseded whatever the flags say.
export function latestClaimIds(messages) {
  const bySystem = new Map();

  messages.forEach((m) => {
    const systemId = claimOf(m);
    if (systemId !== null && m.id != null) bySystem.set(systemId, m.id);
  });

  return new Set(bySystem.values());
}

// A claim post is backed by the flag it announced: same system, planted
// by the same player, still standing. The client holds every faction
// icon, so nothing has to be asked of the server.
export function isLiveClaim(message, icons) {
  const systemId = claimOf(message);
  if (systemId === null) return false;

  return icons.some((icon) => icon.system_id === systemId
    && icon.kind === 'flag'
    && icon.placer_id === message.from_id);
}
