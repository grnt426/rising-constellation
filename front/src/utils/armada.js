// Armada helpers (owner-only data). The armada map — {id, name,
// member_ids} — travels ONLY on the player roster payload
// (player.characters); system/faction payloads never carry it, so the
// system view derives armada visuals by looking its own agents up in
// the roster. All helpers are null-safe against pre-armada snapshots
// and foreign characters.
export default {
  // armada map for a character id, from the player roster; null when
  // the character is not the viewer's or not in an armada
  ofCharacter(playerCharacters, characterId) {
    const own = (playerCharacters || []).find((c) => c.id === characterId);
    return (own && own.armada) ? own.armada : null;
  },
  size(armada) {
    return armada && Array.isArray(armada.member_ids) ? armada.member_ids.length : 0;
  },
  // "busy" mirrors the server's lead rule: pending orders or any
  // status beyond sitting in a system (docking is in-system activity)
  isBusy(rosterCharacter) {
    if (!rosterCharacter) return true;
    if (!['idle', 'docking'].includes(rosterCharacter.action_status)) return true;
    return !!(rosterCharacter.actions
      && rosterCharacter.actions.queue
      && rosterCharacter.actions.queue.length > 0);
  },
  // Stable adjacency sort: members of the same armada become adjacent
  // at the position of the group's first occurrence; everyone else
  // keeps their relative order.
  groupAdjacent(entries, playerCharacters, characterOf = (e) => e.character) {
    const groupPos = new Map();
    const keyed = entries.map((entry, index) => {
      const armada = this.ofCharacter(playerCharacters, characterOf(entry).id);
      const key = armada ? `a-${armada.id}` : `s-${characterOf(entry).id}`;
      if (!groupPos.has(key)) groupPos.set(key, index);
      return { entry, index, key };
    });

    return keyed
      .sort((a, b) => (groupPos.get(a.key) - groupPos.get(b.key)) || (a.index - b.index))
      .map((k) => k.entry);
  },
};
