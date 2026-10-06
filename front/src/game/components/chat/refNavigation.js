/**
 * Shared navigation behavior for chat refs.
 *
 * Used both by:
 *   - the ChatRef* components (clicks on rendered chips in chat history)
 *   - ChatComposer.vue        (clicks on chips already inserted in the editor)
 *
 * `vm` is any Vue component instance — we just need $store and $root.
 *
 * Returns true if navigation was attempted, false if the ref couldn't be
 * resolved (unknown kind, malformed id, etc.). Callers don't need to
 * branch on the return value today; it's there for symmetry with future
 * ref kinds that may want to no-op silently.
 */
export function navigateRef(vm, kind, id) {
  switch (kind) {
    case 'sys':
      return navigateToSystem(vm, id);
    case 'spot':
      return navigateToSighting(vm, id);
    case 'at':
      return openMentionedPlayer(vm, id);
    default:
      return false;
  }
}

// If a system view is open, close it first so the galaxy camera
// animation isn't hidden behind the system panel.
function leaveSystemView(vm) {
  if (vm.$store.state.game.selectedSystem) {
    vm.$store.dispatch('game/closeSystem', vm);
  }
}

// A mention leads to the card of the player it names.
function openMentionedPlayer(vm, id) {
  const playerId = parseInt(id, 10);
  if (!Number.isFinite(playerId)) return false;

  vm.$store.dispatch('game/openPlayer', { vm, id: playerId });
  return true;
}

function navigateToSystem(vm, id) {
  const systemId = parseInt(id, 10);
  if (!Number.isFinite(systemId)) return false;

  leaveSystemView(vm);
  vm.$root.$emit('map:centerToSystem', systemId);
  return true;
}

// A sighting leads to where the thing is, or was last seen: an agent to
// its system, a fleet to its point in space — followed while the faction
// still sees it, frozen where it was lost otherwise.
function navigateToSighting(vm, id) {
  const sighting = vm.$store.getters['game/sightingById'](parseInt(id, 10));
  if (!sighting) return false;

  if (sighting.kind === 'agent' && sighting.system_id != null) {
    leaveSystemView(vm);
    vm.$root.$emit('map:centerToSystem', sighting.system_id);
    return true;
  }

  if (sighting.position) {
    leaveSystemView(vm);
    vm.$root.$emit('map:centerToPosition', sighting.position);
    return true;
  }

  return false;
}
