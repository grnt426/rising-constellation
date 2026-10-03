// Characters of other factions present on an owned system/dominion, as
// shown to the owning player. The backend already removes still-undercover
// enemy Erased and nulls the cover field (Instance.Player.StellarSystem
// .visible_characters); the numeric cover check below only still matters
// for player snapshots taken before that filtering shipped, where
// undercover spies (with their cover values) could linger until the next
// system update.
//
// Shared by ClosedSystemCard (dots + tooltip) and SystemsListPanel (the
// "enemy agents detected" filter) so the two can never disagree on what
// counts as a detected foreign agent.
export function foreignAgents(system, player, constants) {
  const characters = Array.isArray(system.characters) ? system.characters : [];
  if (characters.length === 0 || !player || !player.faction_id) return [];

  const coverThreshold = typeof (constants || {}).cover_threshold === 'number'
    ? constants.cover_threshold : 0;

  return characters
    .filter((c) => c && c.owner && c.owner.faction_id !== player.faction_id)
    .filter((c) => !(c.type === 'spy' && typeof c.cover === 'number' && c.cover >= coverThreshold));
}
