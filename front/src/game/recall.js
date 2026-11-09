// Whether an agent out on the map can be recalled to the deck right
// now: at rest on one of the player's systems or dominions (anywhere,
// with the "recall from anywhere" cheat), an Erased still under cover,
// a Siderian off cooldown. The server checks it again; this only
// decides whether the button is live. Shared by the desktop selection
// panel and the phone agent cards.
export default function isIdleAndAtHome(game, character) {
  const constant = game.data.constant[0];

  if (character.type === 'spy' && character.spy.cover.value <= constant.cover_threshold) {
    return false;
  }

  if (character.type === 'speaker' && character.speaker && character.speaker.cooldown.value > 0) {
    return false;
  }

  const atHome = !!game.player.stellar_systems.find((s) => s.id === character.system)
    || !!game.player.dominions.find((d) => d.id === character.system);
  const anywhere = !!game.instanceInfo.recall_anywhere;

  return ['idle', 'docking'].includes(character.action_status) && (atHome || anywhere);
}
