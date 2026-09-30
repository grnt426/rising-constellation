// Which code this tab runs, next to which game server it talks to.
//
// Two independent facts (see RC.Build / GET /api/version):
//   * the revision — this bundle's (baked in by build-front.sh from the
//     deploy's git hash) and the live server's;
//   * the server's `live_since` — when it came online. Every server start
//     is a new version of the game for a client (in-memory state resets),
//     even on the same revision: a rollback, a crash, a restart.
//
// The store keeps the server build seen when this tab loaded (the first
// `portal:user:*` join) and the latest one (every rejoin), so a tab can
// tell "loaded before a rollback" from "loaded after it" even when the
// revisions match.
//
// No Vue, no store: runs under plain node.

export const CLIENT_VERSION = (typeof process !== 'undefined' && process.env && process.env.VUE_APP_GIT_SHA) || 'dev';

/**
 * @param {string} client  this bundle's revision
 * @param {object} atLoad  server build `{version, live_since, deploying}` when the tab loaded
 * @param {object} now     server build from the latest (re)join
 * @returns {{status: string, restartedSinceLoad: boolean|null}}
 *
 * status:
 *   'unknown'          no server build yet (not signed in, not connected)
 *   'current'          this bundle is the live server's revision
 *   'ahead_of_server'  a newer bundle than the live server: loaded while a
 *                      deploy had shipped its front end but not yet
 *                      restarted the server
 *   'stale'            the live server runs other code; a reload fixes it
 * restartedSinceLoad: the server came online again after this tab loaded
 * (same or different revision) — its in-memory state is not the one this
 * tab started with.
 */
export function buildStatus(client, atLoad, now) {
  if (!now || !now.version) return { status: 'unknown', restartedSinceLoad: null };
  const restartedSinceLoad = atLoad ? atLoad.live_since !== now.live_since : null;

  if (client === now.version) return { status: 'current', restartedSinceLoad };
  // The server has not flipped since this tab loaded, a deploy is under
  // way, and the bundle differs: the front end went out first.
  if (now.deploying && atLoad && !restartedSinceLoad) return { status: 'ahead_of_server', restartedSinceLoad };
  return { status: 'stale', restartedSinceLoad };
}
