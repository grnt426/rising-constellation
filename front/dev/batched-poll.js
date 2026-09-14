/*
 * Adaptive polling for the Docker dev server's file watcher.
 *
 * On Docker Desktop for Windows the repo is bind-mounted over 9p, which never
 * delivers inotify events for edits made on the host, so vue.config.js runs
 * webpack's watcher in polling mode: chokidar calls fs.watchFile once per
 * watched path, and Node stats each one every `poll` ms. Every stat is a 9p
 * round trip costing ~200µs of kernel time, so polling once a second kept an
 * otherwise idle stack at ~18% of a core, forever.
 *
 * install() swaps fs.watchFile/unwatchFile for one poller with the same
 * listener contract. It stats every path each ACTIVE_MS while files are
 * changing, and only every IDLE_MS once nothing has changed for
 * ACTIVE_WINDOW_MS.
 */
const fs = require('fs');
const path = require('path');
const { fileURLToPath } = require('url');

const ACTIVE_MS = 1000;
// Worst-case delay before the first rebuild after a quiet spell.
const IDLE_MS = 10000;
const ACTIVE_WINDOW_MS = 5 * 60 * 1000;
// Stats in flight per pass. One at a time is pathologically slow over 9p
// (~7ms each, vs a ~0.7s pass for 800 paths at 4); past libuv's 4 threads
// they only queue.
const CONCURRENCY = 4;

const EPOCH = new Date(0);
// What fs.watchFile reports for a path that doesn't exist.
const MISSING = Object.freeze({
  dev: 0, mode: 0, nlink: 0, uid: 0, gid: 0, rdev: 0, blksize: 0, ino: 0, size: 0, blocks: 0,
  atimeMs: 0, mtimeMs: 0, ctimeMs: 0, birthtimeMs: 0, atime: EPOCH, mtime: EPOCH, ctime: EPOCH, birthtime: EPOCH,
  isFile: () => false,
  isDirectory: () => false,
  isSymbolicLink: () => false,
  isBlockDevice: () => false,
  isCharacterDevice: () => false,
  isFIFO: () => false,
  isSocket: () => false,
});

// fs.watchFile returns a StatWatcher; chokidar only holds on to it.
const handle = { ref() { return this; }, unref() { return this; } };

// absolute path -> { listeners: Set, stats: last seen (null until first stat), persistent }
const watched = new Map();
let timer = null;
let running = false;
let nextPassAt = 0;
let lastChangeAt = Date.now();
let idle = false;

function toPath(filename) {
  return path.resolve(filename instanceof URL ? fileURLToPath(filename) : String(filename));
}

function changed(a, b) {
  return a.mtimeMs !== b.mtimeMs || a.ctimeMs !== b.ctimeMs || a.size !== b.size || a.ino !== b.ino || a.mode !== b.mode;
}

function interval() {
  const wasIdle = idle;
  idle = Date.now() - lastChangeAt >= ACTIVE_WINDOW_MS;
  if (idle && !wasIdle) {
    console.log(`[batched-poll] no changes for ${ACTIVE_WINDOW_MS / 60000} min: polling ${watched.size} paths every ${IDLE_MS / 1000}s`);
  } else if (!idle && wasIdle) {
    console.log(`[batched-poll] change detected: polling every ${ACTIVE_MS / 1000}s`);
  }
  return idle ? IDLE_MS : ACTIVE_MS;
}

function schedule() {
  if (timer || running || watched.size === 0) return;
  let baselinePending = false;
  let persistent = false;
  watched.forEach((entry) => {
    if (!entry.stats) baselinePending = true;
    if (entry.persistent) persistent = true;
  });
  // Newly watched paths get their baseline stat right away, as with fs.watchFile.
  const delay = baselinePending ? 0 : Math.max(0, nextPassAt - Date.now());
  timer = setTimeout(() => {
    timer = null;
    tick();
  }, delay);
  if (!persistent) timer.unref();
}

async function tick() {
  running = true;
  const full = Date.now() >= nextPassAt;
  const queue = [...watched].filter(([, entry]) => full || !entry.stats);
  const worker = async () => {
    while (queue.length) {
      const [file, entry] = queue.pop();
      // eslint-disable-next-line no-await-in-loop
      const curr = await fs.promises.stat(file).catch(() => MISSING);
      // Unwatched (or re-watched) while the stat was in flight.
      if (watched.get(file) !== entry) continue;
      const prev = entry.stats;
      entry.stats = curr;
      // Like fs.watchFile: a missing path reports once, then only real changes.
      if (prev ? changed(prev, curr) : curr === MISSING) {
        if (prev) lastChangeAt = Date.now();
        [...entry.listeners].forEach((listener) => listener(curr, prev || MISSING));
      }
    }
  };
  const results = await Promise.allSettled(Array.from({ length: CONCURRENCY }, worker));
  running = false;
  if (full) nextPassAt = Date.now() + interval();
  schedule();
  // A throwing listener surfaces as an uncaught error, as it would from fs.watchFile.
  const failed = results.find((result) => result.status === 'rejected');
  if (failed) throw failed.reason;
}

function watchFile(filename, options, listener) {
  if (typeof options === 'function') {
    listener = options;
    options = {};
  }
  if (typeof listener !== 'function') throw new TypeError('fs.watchFile listener must be a function');
  const file = toPath(filename);
  let entry = watched.get(file);
  if (!entry) {
    entry = { listeners: new Set(), stats: null, persistent: false };
    watched.set(file, entry);
  }
  if (!options || options.persistent !== false) entry.persistent = true;
  entry.listeners.add(listener);
  if (timer && !entry.stats) {
    clearTimeout(timer);
    timer = null;
  }
  schedule();
  return handle;
}

function unwatchFile(filename, listener) {
  const file = toPath(filename);
  const entry = watched.get(file);
  if (!entry) return;
  if (typeof listener === 'function') entry.listeners.delete(listener);
  else entry.listeners.clear();
  if (entry.listeners.size === 0) watched.delete(file);
  if (watched.size === 0 && timer) {
    clearTimeout(timer);
    timer = null;
  }
}

function install() {
  fs.watchFile = watchFile;
  fs.unwatchFile = unwatchFile;
}

module.exports = { install };
