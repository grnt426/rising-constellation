/*
 * Adaptive polling for the Docker dev server's file watcher.
 *
 * On Docker Desktop for Windows the repo is bind-mounted over 9p, which never
 * delivers inotify events for edits made on the host, so vue.config.js runs
 * webpack's watcher in polling mode. webpack 5's watcher (watchpack 2) polls
 * each watched directory on its own timer: a readdir plus an lstat per entry
 * every `poll` ms. Every stat is a 9p round trip costing ~200µs of kernel
 * time, so polling once a second kept an otherwise idle stack at ~18% of a
 * core, forever.
 *
 * install() makes those timers adaptive: every ACTIVE_MS (the configured
 * `poll`) while files are changing, and only every IDLE_MS once nothing has
 * changed for ACTIVE_WINDOW_MS. A change anywhere puts every directory back
 * on the fast interval from its next scan on.
 *
 * (Under webpack 4 this module replaced fs.watchFile, which chokidar called
 * once per path; watchpack 2 no longer goes through fs.watchFile.)
 */
const DirectoryWatcher = require('watchpack/lib/DirectoryWatcher');

// Worst-case delay before the first rebuild after a quiet spell.
const IDLE_MS = 10000;
const ACTIVE_WINDOW_MS = 5 * 60 * 1000;

let lastChangeAt = Date.now();
let idle = false;

function interval(activeMs) {
  const wasIdle = idle;
  idle = Date.now() - lastChangeAt >= ACTIVE_WINDOW_MS;
  if (idle && !wasIdle) {
    console.log(`[batched-poll] no changes for ${ACTIVE_WINDOW_MS / 60000} min: polling every ${IDLE_MS / 1000}s`);
  } else if (!idle && wasIdle) {
    console.log(`[batched-poll] change detected: polling every ${activeMs / 1000}s`);
  }
  return idle ? Math.max(activeMs, IDLE_MS) : activeMs;
}

function install() {
  const proto = DirectoryWatcher.prototype;
  if (proto.batchedPollInstalled) return;
  proto.batchedPollInstalled = true;

  // What counts as a change after the initial scan: a file whose recorded
  // mtime moved, a subdirectory not seen before, an entry that went missing.
  // (Every scan reports every subdirectory again, so a known one is not, and
  // nor is an ignored one such as node_modules, which watchpack never records.)
  const { setFileTime, setDirectory, setMissing } = proto;
  proto.setFileTime = function patchedSetFileTime(target, mtime, initial, ...rest) {
    const before = this.files.get(target);
    setFileTime.call(this, target, mtime, initial, ...rest);
    const after = this.files.get(target);
    if (!initial && after && (!before || before.timestamp !== after.timestamp)) lastChangeAt = Date.now();
  };
  proto.setDirectory = function patchedSetDirectory(directoryPath, birthtime, initial, ...rest) {
    if (!initial && directoryPath !== this.path && !this.ignored(directoryPath) && !this.directories.has(directoryPath)) lastChangeAt = Date.now();
    return setDirectory.call(this, directoryPath, birthtime, initial, ...rest);
  };
  proto.setMissing = function patchedSetMissing(itemPath, initial, ...rest) {
    if (!initial && !this.ignored(itemPath) && (this.files.has(itemPath) || this.directories.has(itemPath))) lastChangeAt = Date.now();
    return setMissing.call(this, itemPath, initial, ...rest);
  };

  // watchpack schedules the next scan here, `polledWatching` ms out.
  proto.onScanFinished = function patchedOnScanFinished() {
    if (!this.polledWatching) return;
    this.timeout = setTimeout(() => {
      if (this.closed) return;
      this.doScan(false);
    }, interval(this.polledWatching));
  };
}

module.exports = { install };
