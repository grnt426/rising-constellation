/**
 * Shared navigation behavior for chat refs.
 *
 * Used both by:
 *   - ChatRefSystem.vue   (clicks on rendered chips in chat history)
 *   - ChatComposer.vue    (clicks on chips already inserted in the editor)
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
    // Phase 2: 'char', 'coord' added here.
    default:
      return false;
  }
}

function navigateToSystem(vm, id) {
  const systemId = parseInt(id, 10);
  if (!Number.isFinite(systemId)) return false;

  // If a system view is open, close it first so the galaxy camera
  // animation isn't hidden behind the system panel.
  if (vm.$store.state.game.selectedSystem) {
    vm.$store.dispatch('game/closeSystem', vm);
  }
  vm.$root.$emit('map:centerToSystem', systemId);
  return true;
}
