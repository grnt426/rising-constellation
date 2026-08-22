// Armada helpers. GROUPING is public information: every system
// character summary carries `armada_id`, so all viewers see which
// visible Navarchs stand in formation (2026-08-20 design change). The
// full armada map — {id, name, member_ids} — still rides only the
// OWNER's roster payload (player.characters) and feeds the selection
// panel and the form/join validators. All helpers are null-safe
// against pre-armada payloads.
export default {
  // grouping key from a system character summary (any viewer)
  groupId(character) {
    return character && character.armada_id != null ? character.armada_id : null;
  },
  // full armada map for one of the viewer's OWN characters
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
  groupAdjacent(entries, characterOf = (e) => e.character) {
    const groupPos = new Map();
    const keyed = entries.map((entry, index) => {
      const groupId = this.groupId(characterOf(entry));
      const key = groupId != null ? `a-${groupId}` : `s-${characterOf(entry).id}`;
      if (!groupPos.has(key)) groupPos.set(key, index);
      return { entry, index, key };
    });

    return keyed
      .sort((a, b) => (groupPos.get(a.key) - groupPos.get(b.key)) || (a.index - b.index))
      .map((k) => k.entry);
  },
  // Closed capsule outline along a circular arc: outer arc a0→a1,
  // rounded end cap, inner arc back, rounded end cap. Radii may be
  // asymmetric around the icon circle (thicker toward the inside).
  // Works in any coordinate space — the fan's stretched viewBox turns
  // it into the ring's true ellipse.
  capsulePath(cx, cy, rOuter, rInner, a0deg, a1deg) {
    const rad = (d) => (d * Math.PI) / 180;
    const pt = (r, a) => `${(cx + (r * Math.cos(a))).toFixed(2)} ${(cy + (r * Math.sin(a))).toFixed(2)}`;
    const a0 = rad(a0deg);
    const a1 = rad(a1deg);
    const cap = ((rOuter - rInner) / 2).toFixed(2);
    const large = a1deg - a0deg > 180 ? 1 : 0;

    return [
      `M ${pt(rOuter, a0)}`,
      `A ${rOuter.toFixed(2)} ${rOuter.toFixed(2)} 0 ${large} 1 ${pt(rOuter, a1)}`,
      `A ${cap} ${cap} 0 0 1 ${pt(rInner, a1)}`,
      `A ${rInner.toFixed(2)} ${rInner.toFixed(2)} 0 ${large} 0 ${pt(rInner, a0)}`,
      `A ${cap} ${cap} 0 0 1 ${pt(rOuter, a0)}`,
      'Z',
    ].join(' ');
  },
  // Contiguous same-armada runs (2+ members) over an ALREADY-adjacent
  // entry list; `skip` drops entries (e.g. a relocated besieger) and
  // breaks any run they sat in. Yields {groupId, indexes}.
  bands(entries, characterOf = (e) => e.character, skip = () => false) {
    const bands = [];
    let current = null;

    entries.forEach((entry, index) => {
      const character = characterOf(entry);
      const groupId = skip(entry) ? null : this.groupId(character);

      if (groupId != null && current && current.groupId === groupId) {
        current.indexes.push(index);
      } else {
        if (current && current.indexes.length >= 2) bands.push(current);
        current = groupId != null ? { groupId, indexes: [index] } : null;
      }
    });

    if (current && current.indexes.length >= 2) bands.push(current);
    return bands;
  },
};
