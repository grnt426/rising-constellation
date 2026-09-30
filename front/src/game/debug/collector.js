// Always-on, in-memory diagnostics for the Help → Debug report.
//
// A bug report is only as good as what happened BEFORE the player opened
// the Debug tab, so this installs at app boot (main.js) and keeps small
// rolling windows of:
//
//   * errors — Vue errors, uncaught exceptions, unhandled rejections,
//     failed resource loads, router chunk failures, console.error/warn;
//   * socket traffic — every frame's topic/event/size, push→reply round
//     trips (heartbeats included), open/close/error with close codes;
//   * store mutations (types and payload keys only, never values);
//   * HTTP calls (method, path, status, duration);
//   * performance — timed from work the client does anyway, never from a
//     synthetic benchmark: each galaxy-map frame (per block, and the
//     WebGL submit), the frame-to-frame interval (FPS, freezes, clock
//     jumps), and every socket message's JSON decode, handling and the
//     Vue re-render it triggers; plus long tasks and JS heap size;
//   * page lifecycle — visibility, freeze/resume, online/offline, routes;
//   * the WebGL renderer (context losses) via registerMap().
//
// No timers or loops of its own: everything is recorded from hooks on
// existing work (series.js keeps it O(1) per sample). Nothing here leaves
// the browser on its own — report.js reads it when the player generates a
// report — and everything is capped, so a week-long tab holds the same few
// hundred KB as a fresh one. Every hook is wrapped so a diagnostics bug can
// never break the game.

import { formatArgs, sanitize, scrubString } from './sanitize.js';
import {
  Hist, Series, SeriesMap, Worst,
} from './series.js';

const now = () => Date.now();
const mono = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const round = (n) => Math.round(n * 100) / 100;

class Ring {
  constructor(capacity) {
    this.capacity = capacity;
    this.items = [];
    this.dropped = 0;
  }

  push(item) {
    this.items.push(item);
    if (this.items.length > this.capacity) {
      this.items.shift();
      this.dropped += 1;
    }
  }

  toArray() { return this.items.slice(); }
}

// Same message → one entry with a count, so an error thrown every frame
// (an unawaited block.update() rejecting at 60 Hz) can't flush out
// everything else.
class DedupeLog {
  constructor(capacity) {
    this.capacity = capacity;
    this.entries = new Map();
    this.total = 0;
  }

  add(key, build) {
    this.total += 1;
    const t = now();
    const existing = this.entries.get(key);
    if (existing) {
      existing.count += 1;
      existing.lastAt = t;
      // re-insert: Map order doubles as recency order for eviction
      this.entries.delete(key);
      this.entries.set(key, existing);
      return;
    }
    this.entries.set(key, {
      ...build(), count: 1, firstAt: t, lastAt: t,
    });
    if (this.entries.size > this.capacity) {
      this.entries.delete(this.entries.keys().next().value);
    }
  }

  toArray() {
    return Array.from(this.entries.values()).sort((a, b) => a.firstAt - b.firstAt);
  }
}

// Map frames arrive at ~60 Hz: the baseline is the first minute of frames
// after a 30 s warm-up (shader compiles, first geometry uploads).
const FRAME_SERIES = { warmupMs: 30000, baselineSamples: 3600 };
const BLOCK_SERIES = { ...FRAME_SERIES, keep: 10 };
// Messages arrive a few per second at most.
const MESSAGE_SERIES = { warmupMs: 30000, baselineSamples: 200 };
const WORK_SERIES = { ...MESSAGE_SERIES, keep: 10 };

const state = {
  installed: false,
  installedAt: null,
  errors: new DedupeLog(100),
  consoleErrors: new DedupeLog(80),
  consoleWarns: new DedupeLog(80),
  resourceErrors: new DedupeLog(40),
  routes: new Ring(30),
  mutations: new Ring(150),
  mutationCounts: {},
  channelStatus: new Ring(60),
  connection: {
    firstConnectedAt: null,
    lastConnectedAt: null,
    lastDisconnectedAt: null,
    disconnects: 0,
    connected: false,
  },
  http: new Ring(60),
  httpFailures: 0,
  socket: {
    ws: null,
    events: new Ring(80),
    frames: new Ring(200),
    // inbound, by message kind: { n, bytes, maxBytes, parse, handle, react }
    messages: new Map(),
    // outbound, by "topic-kind event": { n, bytes, maxBytes }
    outbound: {},
    bytesIn: 0,
    bytesOut: 0,
    framesIn: 0,
    framesOut: 0,
    pending: new Map(),
    // push → reply round trip, by "topic-kind event": Hist
    rtt: new Map(),
    timeouts: {},
    // the message that last delivered global_time (see afterInbound)
    timeAnchor: null,
    errorsSinceOpen: 0,
  },
  perf: {
    // CPU time of one rendered map frame (controls, blocks, WebGL submit),
    // split by zoom: the far view draws every system, the near view only
    // what is on screen.
    mapFrame: { near: new Series(FRAME_SERIES), far: new Series(FRAME_SERIES) },
    // the renderer.render() share of it
    mapRender: new Series(FRAME_SERIES),
    // rAF-to-rAF: FPS, and freezes of the whole main thread
    frameInterval: { map: new Series(FRAME_SERIES), systemView: new Series(FRAME_SERIES) },
    blocks: new SeriesMap(BLOCK_SERIES, 24),
    work: new SeriesMap(WORK_SERIES, 16),
    decodeMs: new Series(MESSAGE_SERIES),
    decodeMBps: new Series(MESSAGE_SERIES),
    handleMs: new Series(MESSAGE_SERIES),
    reactMs: new Series(MESSAGE_SERIES),
    worst: new Worst(15),
    frames: {
      rendered: 0, far: 0, systemView: 0, drawCalls: 0, triangles: 0, gaps: 0,
    },
    stalls: new Ring(40),
    stallCounts: {
      over100: 0, over250: 0, over1000: 0, duringLoad: 0,
    },
    longTasks: new Ring(40),
    longTaskCount: 0,
    longTaskTotalMs: 0,
    longTaskSupported: false,
    clockJumps: new Ring(20),
    heap: new Ring(120),
    mapInit: {},
    timerResolutionMs: null,
  },
  page: {
    hiddenCount: 0,
    hiddenMs: 0,
    hiddenSince: null,
    startedHidden: false,
    freezes: 0,
    lifecycle: new Ring(40),
    online: new Ring(20),
  },
  render: {
    map: null,
    renderer: null,
    contextLost: 0,
    contextRestored: 0,
    events: new Ring(20),
    mapsCreated: 0,
  },
  // game/map/asset-loader.js: every map download (sprites, fonts, skydome)
  assets: {
    loads: 0,
    firstTry: 0,
    recovered: 0,
    failed: 0,
    // successful loads, retries included
    loadMs: new Series(WORK_SERIES),
    // every load that needed a retry or never arrived, with each reason
    problems: new Ring(40),
  },
};

let capturing = true;
const withoutCapture = (fn) => {
  const prev = capturing;
  capturing = false;
  try { fn(); } finally { capturing = prev; }
};

const safe = (fn) => (...args) => {
  try {
    return fn(...args);
  } catch (e) {
    return undefined;
  }
};

const shortStack = (stack) => (stack ? scrubString(String(stack)).split('\n').slice(0, 12).join('\n') : undefined);

// Public: record an error from anywhere (components, catch blocks).
export const recordError = safe((source, error, extra = {}) => {
  const message = error && error.message !== undefined ? String(error.message) : formatArgs([error]);
  const name = (error && error.name) || 'Error';
  state.errors.add(`${source}|${name}|${message}`, () => ({
    source,
    name,
    message: scrubString(message).slice(0, 2000),
    stack: shortStack(error && error.stack),
    ...sanitize(extra, { maxDepth: 3, maxString: 500 }),
  }));
});

export const recordResourceError = safe((source, url, extra = {}) => {
  const clean = scrubString(String(url || '')).slice(0, 500);
  state.resourceErrors.add(`${source}|${clean}`, () => ({ source, url: clean, ...extra }));
});

// ─── console ────────────────────────────────────────────────────────────

// Errors and warnings only. A wrapped console method makes DevTools show
// the wrapper as every message's source line (collector.js instead of the
// real caller), so the plain log/info stream — the bulk of the console,
// and already covered by the socket and lifecycle records — is left alone.
// For errors and warnings the expandable stack trace still shows the
// caller.
function hookConsole() {
  ['error', 'warn'].forEach((level) => {
    const original = console[level]; // eslint-disable-line no-console
    if (typeof original !== 'function') return;
    const target = level === 'error' ? state.consoleErrors : state.consoleWarns;
    console[level] = function diagnosticsConsole(...args) { // eslint-disable-line no-console
      if (capturing) {
        try {
          capturing = false;
          const line = formatArgs(args);
          target.add(line.slice(0, 300), () => ({ message: line }));
        } catch (e) {
          // never let diagnostics break a console call
        } finally {
          capturing = true;
        }
      }
      return original.apply(this, args);
    };
  });
}

// ─── global error hooks ─────────────────────────────────────────────────

function hookGlobalErrors(Vue, router) {
  window.addEventListener('error', safe((event) => {
    const { target } = event;
    // Capture phase also sees failed <img>/<script>/<link> loads, which
    // never reach window.onerror.
    if (target && target !== window && (target.src || target.href)) {
      recordResourceError(`dom:${(target.tagName || '').toLowerCase()}`, target.src || target.href);
      return;
    }
    const error = event.error || { name: 'Error', message: event.message };
    recordError('window', error, {
      file: event.filename ? scrubString(event.filename) : undefined,
      line: event.lineno,
      col: event.colno,
    });
  }), true);

  window.addEventListener('unhandledrejection', safe((event) => {
    const { reason } = event;
    const error = reason instanceof Error ? reason : { name: 'UnhandledRejection', message: formatArgs([reason]) };
    recordError('promise', error);
  }));

  const previous = Vue.config.errorHandler;
  Vue.config.errorHandler = (err, vm, info) => {
    const component = vm && vm.$options && (vm.$options.name || vm.$options._componentTag);
    recordError('vue', err, { component, hook: info });
    if (previous) {
      previous(err, vm, info);
    } else {
      // Setting a handler silences Vue's own logging; keep it visible
      // without double-counting it as a console error.
      withoutCapture(() => {
        console.error(`[Vue error in ${info}${component ? ` <${component}>` : ''}]`, err); // eslint-disable-line no-console
      });
    }
  };

  if (router) {
    // Every route is a lazy chunk: a stale bundle after a deploy shows up
    // here as a ChunkLoadError, and nowhere else.
    router.onError((err) => recordError('router', err));
    router.afterEach(safe((to, from) => {
      state.routes.push({
        t: now(), name: to.name, path: to.path, from: from && from.path,
      });
    }));
  }
}

// ─── store ──────────────────────────────────────────────────────────────

function hookStore(store) {
  store.subscribe(safe((mutation) => {
    const { type, payload } = mutation;
    state.mutationCounts[type] = (state.mutationCounts[type] || 0) + 1;
    const entry = { t: now(), type };
    // Leaving the game resets the store without per-channel commits; the
    // next game's first join must not read as a disconnect.
    if (type === 'game/clear') state.connection.connected = false;
    if (type === 'game/update' && payload && typeof payload === 'object') {
      entry.keys = Object.keys(payload);
    }
    if (type === 'game/statusChannel' && payload) {
      state.channelStatus.push({ t: now(), channel: payload.channel, status: payload.status });
      const { connected } = store.state.game;
      const c = state.connection;
      if (connected && !c.connected) {
        c.lastConnectedAt = now();
        if (!c.firstConnectedAt) c.firstConnectedAt = c.lastConnectedAt;
      } else if (!connected && c.connected) {
        c.lastDisconnectedAt = now();
        c.disconnects += 1;
      }
      c.connected = connected;
    }
    state.mutations.push(entry);
  }));
}

// ─── HTTP ───────────────────────────────────────────────────────────────

const cleanUrl = (url) => scrubString(String(url || '').split('?')[0]).slice(0, 200);

/**
 * plugins/axios.js createAxiosInstance(): the portal store, i18n and the
 * help manual each build their own instance, so every one is hooked there.
 */
export function attachAxios(axios) {
  if (!axios || !axios.interceptors) return;
  axios.interceptors.request.use((config) => {
    try { config.diagStartedAt = mono(); } catch (e) { /* frozen config */ }
    return config;
  });
  const record = safe((config, status, failed) => {
    const started = config && config.diagStartedAt;
    state.http.push({
      t: now(),
      method: config && config.method ? config.method.toUpperCase() : undefined,
      url: cleanUrl(config && config.url),
      status,
      ms: started ? Math.round(mono() - started) : undefined,
    });
    if (failed) state.httpFailures += 1;
  });
  axios.interceptors.response.use((response) => {
    record(response.config, response.status, false);
    return response;
  }, (error) => {
    record(error && error.config, error && error.response ? error.response.status : 'network', true);
    return Promise.reject(error);
  });
}

// ─── socket ─────────────────────────────────────────────────────────────

// "instance:player:12:34" → "instance:player" — the per-kind tables stay
// readable; the frame log keeps full topics.
const topicKind = (topic) => String(topic || '').split(':').slice(0, 2).join(':');

const byteLength = (raw) => {
  if (typeof raw === 'string') return raw.length;
  if (raw && typeof raw.byteLength === 'number') return raw.byteLength;
  return 0;
};

const bump = (table, key, bytes) => {
  const entry = table[key] || (table[key] = { n: 0, bytes: 0, maxBytes: 0 });
  entry.n += 1;
  entry.bytes += bytes;
  if (bytes > entry.maxBytes) entry.maxBytes = bytes;
};

const MAX_KINDS = 60;
// Capped Map lookup: past `MAX_KINDS` names, everything pools in "other".
const capped = (map, name, create) => {
  let entry = map.get(name);
  if (!entry) {
    const key = map.size < MAX_KINDS ? name : 'other';
    entry = map.get(key);
    if (!entry) {
      entry = create();
      map.set(key, entry);
    }
  }
  return entry;
};

const newMessageStats = () => ({
  n: 0, bytes: 0, maxBytes: 0, parse: new Hist(), handle: new Hist(), react: new Hist(),
});

// What a message IS, for grouping: the push it answers, or the broadcast's
// payload keys (player_player, global_galaxy_system, …).
function messageKind(topic, event, payload, replyTo) {
  const kind = topicKind(topic);
  if (event === 'phx_reply') return `${kind} reply:${replyTo || '?'}`;
  if (event === 'broadcast' && payload && typeof payload === 'object') {
    const keys = Object.keys(payload).sort().slice(0, 3).join('+');
    return `${kind} ${keys || 'broadcast'}`;
  }
  return `${kind} ${event}`;
}

// JSON.parse throughput is only meaningful where the payload dwarfs the
// timer resolution (0.1 ms in most browsers).
const THROUGHPUT_MIN_BYTES = 16384;
const SLOW_MS = 16;

function afterInbound(msg, bytes, parseMs, handleStart) {
  const handled = mono();
  const handleMs = handled - handleStart;
  const s = state.socket;
  const p = state.perf;
  const {
    topic, event, payload, ref,
  } = msg;
  s.framesIn += 1;
  s.bytesIn += bytes;

  let rttMs;
  let replyTo;
  let queuedMs;
  if (event === 'phx_reply' && ref && s.pending.has(ref)) {
    const sent = s.pending.get(ref);
    s.pending.delete(ref);
    // From the moment it went on the wire: a push made while the socket
    // was down waits in Phoenix's send buffer, and that wait is the
    // connection's delay, not the server's.
    const wentOut = sent.sentAt === undefined ? sent.at : sent.sentAt;
    rttMs = mono() - wentOut;
    if (wentOut - sent.at > 50) queuedMs = wentOut - sent.at;
    replyTo = sent.event;
    capped(s.rtt, `${topicKind(sent.topic)} ${sent.event}`, () => new Hist()).add(rttMs);
  }
  if (replyTo === 'heartbeat') return;

  // The store's clock (game/clock.js serverNow) is anchored on the arrival
  // of the last global_time; how long that message took to come bounds
  // how far behind the anchor can be.
  const body = event === 'phx_reply' && payload ? payload.response : payload;
  if (body && typeof body === 'object' && body.global_time && replyTo !== 'get_sync_state') {
    s.timeAnchor = {
      t: now(), topic, event, replyTo, rttMs: rttMs === undefined ? undefined : round(rttMs), bytes,
    };
  }

  const kind = messageKind(topic, event, payload, replyTo);
  const m = capped(s.messages, kind, newMessageStats);
  m.n += 1;
  m.bytes += bytes;
  if (bytes > m.maxBytes) m.maxBytes = bytes;
  m.parse.add(parseMs);
  m.handle.add(handleMs);
  p.decodeMs.add(parseMs);
  p.handleMs.add(handleMs);
  if (bytes >= THROUGHPUT_MIN_BYTES && parseMs > 0) p.decodeMBps.add(bytes / 1048576 / (parseMs / 1000));
  if (parseMs + handleMs > SLOW_MS) {
    p.worst.add(parseMs + handleMs, () => ({
      what: `message ${kind}`, bytes, parseMs: round(parseMs), handleMs: round(handleMs),
    }));
  }

  // Store commits during handling queue Vue's re-render as a microtask;
  // this one is queued after it, so the gap is what the UI spent reacting
  // to the message.
  Promise.resolve().then(safe(() => {
    const reactMs = mono() - handled;
    m.react.add(reactMs);
    p.reactMs.add(reactMs);
    if (reactMs > SLOW_MS) p.worst.add(reactMs, () => ({ what: `re-render after ${kind}` }));
  }));

  const keys = body && typeof body === 'object' ? Object.keys(body).slice(0, 12) : undefined;
  s.frames.push({
    t: now(),
    dir: 'in',
    topic,
    event,
    ref: ref || undefined,
    status: event === 'phx_reply' && payload ? payload.status : undefined,
    replyTo,
    rttMs: rttMs === undefined ? undefined : round(rttMs),
    queuedMs: queuedMs === undefined ? undefined : Math.round(queuedMs),
    bytes,
    parseMs: round(parseMs),
    handleMs: round(handleMs),
    keys,
  });
}

/**
 * Called by plugins/websockets.js right after the Phoenix Socket is built.
 * Wraps this instance's `decode` — Phoenix calls it for every inbound
 * frame, and it invokes its callback (every channel handler, store commit
 * and map update the frame causes) synchronously — so one wrapper times
 * the JSON parse and the handling separately. Also wraps `push` (outbound
 * refs) and `encode` (when each push really went out, for round trips),
 * and subscribes to the lifecycle callbacks.
 */
export const attachSocket = safe((ws) => {
  if (!ws || ws.diagAttached) return;
  ws.diagAttached = true;
  const s = state.socket;
  s.ws = ws;

  const originalDecode = ws.decode;
  if (typeof originalDecode === 'function') {
    ws.decode = function diagDecode(raw, callback) {
      const bytes = byteLength(raw);
      const t0 = mono();
      return originalDecode.call(this, raw, (msg) => {
        const t1 = mono();
        try {
          callback(msg);
        } finally {
          try { afterInbound(msg, bytes, t1 - t0, t1); } catch (e) { /* diagnostics only */ }
        }
      });
    };
  }

  // Phoenix encodes a message only when it actually goes on the wire —
  // straight away, or when the send buffer flushes on (re)connect — so
  // this marks the real send time for round trips.
  const originalEncode = ws.encode;
  if (typeof originalEncode === 'function') {
    ws.encode = function diagEncode(msg, callback) {
      try {
        const pending = msg && msg.ref ? s.pending.get(msg.ref) : null;
        if (pending && pending.sentAt === undefined) pending.sentAt = mono();
      } catch (e) { /* ignore */ }
      return originalEncode.call(this, msg, callback);
    };
  }

  const originalPush = ws.push;
  ws.push = function diagPush(data) {
    try {
      const bytes = data && data.payload ? JSON.stringify(data.payload).length : 0;
      s.framesOut += 1;
      s.bytesOut += bytes;
      bump(s.outbound, `${topicKind(data.topic)} ${data.event}`, bytes);
      if (data.ref) {
        s.pending.set(data.ref, { at: mono(), topic: data.topic, event: data.event });
        // Replies that never come (timeouts, dropped sockets) must not
        // pile up forever.
        if (s.pending.size > 500) {
          const oldest = s.pending.keys().next().value;
          const stale = s.pending.get(oldest);
          s.pending.delete(oldest);
          const key = `${topicKind(stale.topic)} ${stale.event}`;
          s.timeouts[key] = (s.timeouts[key] || 0) + 1;
        }
      }
      if (data.event !== 'heartbeat') {
        s.frames.push({
          t: now(), dir: 'out', topic: data.topic, event: data.event, ref: data.ref, bytes,
        });
      }
    } catch (e) { /* ignore */ }
    return originalPush.call(this, data);
  };

  ws.onOpen(safe(() => {
    s.errorsSinceOpen = 0;
    s.events.push({ t: now(), type: 'open' });
  }));
  ws.onError(safe(() => {
    s.errorsSinceOpen += 1;
    s.events.push({ t: now(), type: 'error', online: navigator.onLine });
  }));
  ws.onClose(safe((event) => {
    s.events.push({
      t: now(),
      type: 'close',
      code: event && event.code,
      reason: event && event.reason ? scrubString(String(event.reason)).slice(0, 200) : undefined,
      wasClean: event && event.wasClean,
    });
  }));
});

// ─── rendering ──────────────────────────────────────────────────────────

// The System block swaps to its far-view group (every system drawn) from
// this altitude up — blocks/system.js.
const FAR_Z = 200;
const STALL_MS = 100;
const HEAP_EVERY_MS = 30000;

const LOAD_GRACE_MS = 10000;

let lastFrame = null;
let lastVisibilityChangeAt = 0;
let lastHeapAt = 0;
let mapStartedAt = 0;

function sampleHeap(wall) {
  lastHeapAt = wall;
  const mem = performance.memory;
  if (!mem) return;
  state.perf.heap.push({
    t: wall,
    usedMB: Math.round(mem.usedJSHeapSize / 1048576),
    totalMB: Math.round(mem.totalJSHeapSize / 1048576),
  });
}

// One animation frame of the map loop, rendered or not: the interval since
// the previous one, freezes, wall-clock jumps, and a heap reading every
// 30 s — all piggybacked on a loop that runs anyway.
function frameTick(ts, series, view) {
  // map.js calls its loop once directly (no rAF timestamp) to start it
  if (typeof ts !== 'number') return;
  const wall = now();
  const prev = lastFrame;
  lastFrame = { ts, wall };
  if (wall - lastHeapAt >= HEAP_EVERY_MS) sampleHeap(wall);
  if (!prev) return;

  const dt = ts - prev.ts;
  // Date.now moved differently from the monotonic frame clock: the system
  // clock was adjusted (NTP, manual change) or the machine slept.
  // Countdowns anchored on Date.now (game/clock.js serverNow) jump too.
  const wallDelta = wall - prev.wall;
  if (Math.abs(wallDelta - dt) > 2000) {
    state.perf.clockJumps.push({ t: wall, wallDeltaMs: Math.round(wallDelta), monoDeltaMs: Math.round(dt) });
  }
  // Hidden (or frozen) in between: the browser paused rAF, the page was
  // not stuck.
  if (lastVisibilityChangeAt > prev.wall) {
    state.perf.frames.gaps += 1;
    return;
  }
  series.add(dt, wall);
  if (dt > STALL_MS) {
    const c = state.perf.stallCounts;
    // The map's first frames compile shaders and upload geometry: a
    // freeze then is expected, and counted apart so it never reads as a
    // problem on its own.
    const duringLoad = wall - mapStartedAt < LOAD_GRACE_MS;
    if (duringLoad) {
      c.duringLoad += 1;
    } else {
      c.over100 += 1;
      if (dt > 250) c.over250 += 1;
      if (dt > 1000) c.over1000 += 1;
    }
    state.perf.stalls.push({
      t: wall, ms: Math.round(dt), view, duringLoad: duringLoad || undefined,
    });
  }
}

/**
 * Hooks for game/map/map.js, whose animation loop is the heaviest regular
 * work the client does. Each is two performance.now() reads and an O(1)
 * record at the call site.
 */
export const mapProbe = {
  /** One block's update() (its synchronous part) this frame. */
  block: safe((name, ms) => {
    state.perf.blocks.get(name).add(ms);
    if (ms > SLOW_MS) state.perf.worst.add(ms, () => ({ what: `map block ${name}` }));
  }),

  /** A rendered frame: total CPU ms, of which renderer.render() ms. */
  frame: safe((ts, totalMs, renderMs, z, info) => {
    const p = state.perf;
    const far = z >= FAR_Z;
    frameTick(ts, p.frameInterval.map, far ? 'far' : 'near');
    p.frames.rendered += 1;
    if (far) p.frames.far += 1;
    if (info) {
      p.frames.drawCalls += info.calls || 0;
      p.frames.triangles += info.triangles || 0;
    }
    (far ? p.mapFrame.far : p.mapFrame.near).add(totalMs);
    p.mapRender.add(renderMs);
    if (totalMs > SLOW_MS) {
      p.worst.add(totalMs, () => ({
        what: 'map frame', view: far ? 'far' : 'near', renderMs: round(renderMs), drawCalls: info && info.calls,
      }));
    }
  }),

  /** A loop tick while a system view covers the map (nothing rendered). */
  idle: safe((ts) => {
    state.perf.frames.systemView += 1;
    frameTick(ts, state.perf.frameInterval.systemView, 'system');
  }),

  /** One-shot init stages: fonts, scene build. */
  stage: safe((stage, ms) => {
    state.perf.mapInit[stage] = round(ms);
  }),
};

/** Other regular work worth a distribution (Game.vue: MapData.update). */
export const recordWork = safe((name, ms) => {
  state.perf.work.get(name).add(ms);
  if (ms > SLOW_MS) state.perf.worst.add(ms, () => ({ what: name }));
});

// three.js loaders reject with whatever their transport gave them: an
// Error (font JSON that didn't parse), a bare DOM `error` Event (an image
// that failed — browsers expose no status), or an XHR event whose target
// carries the HTTP status.
function describeLoadError(error) {
  if (!error) return 'unknown';
  if (error instanceof Error) return `${error.name}: ${scrubString(String(error.message)).slice(0, 200)}`;
  const target = error.target || error.currentTarget;
  const status = target && typeof target.status === 'number' ? target.status : null;
  if (status) return `HTTP ${status}`;
  if (error.type) return `${error.type} event${target && target.tagName ? ` on <${target.tagName.toLowerCase()}>` : ''}`;
  return formatArgs([error], 200);
}

/**
 * game/map/asset-loader.js, once per download when it settles:
 * `{ url, ok, attempts, ms, errors }` (errors: one per failed attempt).
 */
export const recordAssetLoad = safe(({
  url, ok, attempts, ms, errors,
}) => {
  const a = state.assets;
  a.loads += 1;
  if (!ok) a.failed += 1;
  else if (attempts > 1) a.recovered += 1;
  else a.firstTry += 1;
  if (ok) a.loadMs.add(ms);
  if (!ok || attempts > 1) {
    a.problems.push({
      t: now(),
      url: scrubString(String(url)).slice(0, 300),
      ok,
      attempts,
      ms: Math.round(ms),
      errors: (errors || []).map(describeLoadError),
      online: navigator.onLine,
    });
  }
});

/** Map.vue: the live galaxy Map instance (renderer, blocks, init stage). */
export const registerMap = safe((map) => {
  state.render.map = map;
  state.render.renderer = map && map.renderer;
  state.render.mapsCreated += 1;
  lastFrame = null;
  mapStartedAt = now();
  const canvas = map && map.renderer && map.renderer.domElement;
  if (!canvas || canvas.diagAttached) return;
  canvas.diagAttached = true;
  canvas.addEventListener('webglcontextlost', safe(() => {
    // destroy() calls forceContextLoss() itself — not a failure. The
    // event lands a task later, possibly after the next map registered,
    // so the flag lives on the canvas.
    if (canvas.diagRetired) return;
    state.render.contextLost += 1;
    state.render.events.push({ t: now(), type: 'contextlost', hidden: document.hidden });
  }));
  canvas.addEventListener('webglcontextrestored', safe(() => {
    state.render.contextRestored += 1;
    state.render.events.push({ t: now(), type: 'contextrestored' });
  }));
});

export const unregisterMap = safe((map) => {
  const canvas = map && map.renderer && map.renderer.domElement;
  if (canvas) canvas.diagRetired = true;
  lastFrame = null;
  if (state.render.map !== map) return;
  state.render.map = null;
  state.render.renderer = null;
});

// ─── browser performance observers ──────────────────────────────────────

function observeLongTasks() {
  if (typeof PerformanceObserver === 'undefined') return;
  const types = PerformanceObserver.supportedEntryTypes || [];
  if (!types.includes('longtask')) return;
  state.perf.longTaskSupported = true;
  const observer = new PerformanceObserver(safe((list) => {
    list.getEntries().forEach((entry) => {
      state.perf.longTaskCount += 1;
      state.perf.longTaskTotalMs += entry.duration;
      if (entry.duration >= 100) {
        state.perf.longTasks.push({
          t: Math.round(performance.timeOrigin + entry.startTime),
          ms: Math.round(entry.duration),
          name: entry.name,
        });
      }
    });
  }));
  observer.observe({ type: 'longtask', buffered: true });
}

// Sub-millisecond timings only mean something above the clock's
// granularity (coarsened to 0.1 ms or more in some browsers).
/**
 * The clock's granularity in ms, found by watching it tick a few times
 * (bounded at `budgetMs` of spinning; run once, at boot): a fixed number
 * of reads never sees a 1 ms clock (Firefox) move.
 */
export function timerResolution(clock = mono, budgetMs = 20) {
  let smallest = Infinity;
  let ticks = 0;
  let prev = clock();
  // the budget runs on the wall clock: the one under test may not move
  const deadline = Date.now() + budgetMs;
  while (ticks < 5 && Date.now() < deadline) {
    const t = clock();
    if (t > prev) {
      smallest = Math.min(smallest, t - prev);
      ticks += 1;
    }
    prev = t;
  }
  return Number.isFinite(smallest) ? Math.round(smallest * 10000) / 10000 : null;
}

function measureTimerResolution() {
  state.perf.timerResolutionMs = timerResolution();
}

// ─── page lifecycle ─────────────────────────────────────────────────────

function hookPage() {
  const p = state.page;
  p.startedHidden = document.hidden;
  if (document.hidden) p.hiddenSince = now();
  document.addEventListener('visibilitychange', safe(() => {
    lastVisibilityChangeAt = now();
    if (document.hidden) {
      p.hiddenCount += 1;
      p.hiddenSince = now();
    } else if (p.hiddenSince) {
      p.hiddenMs += now() - p.hiddenSince;
      p.hiddenSince = null;
    }
    p.lifecycle.push({ t: now(), type: document.hidden ? 'hidden' : 'visible' });
  }));
  // Chrome freezes/discards background tabs; timers stop and the socket
  // can drop while frozen.
  document.addEventListener('freeze', safe(() => {
    lastVisibilityChangeAt = now();
    p.freezes += 1;
    p.lifecycle.push({ t: now(), type: 'freeze' });
  }));
  document.addEventListener('resume', safe(() => {
    lastVisibilityChangeAt = now();
    p.lifecycle.push({ t: now(), type: 'resume' });
  }));
  window.addEventListener('pageshow', safe((e) => {
    if (e.persisted) p.lifecycle.push({ t: now(), type: 'bfcache-restore' });
  }));
  window.addEventListener('online', safe(() => p.online.push({ t: now(), online: true })));
  window.addEventListener('offline', safe(() => p.online.push({ t: now(), online: false })));
}

// ─── install ────────────────────────────────────────────────────────────

/**
 * main.js, before the root Vue instance mounts, so boot errors are caught.
 * Idempotent.
 */
export function installDiagnostics({ Vue, store, router }) {
  if (state.installed || typeof window === 'undefined') return;
  state.installed = true;
  state.installedAt = now();
  [
    () => hookConsole(),
    () => hookGlobalErrors(Vue, router),
    () => hookStore(store),
    () => hookPage(),
    () => observeLongTasks(),
    () => measureTimerResolution(),
    // The report's cache section reads the browser's resource timing
    // (bundles, map files); its default 250-entry buffer can fill up
    // before the game even starts, and then drops later entries.
    () => performance.setResourceTimingBufferSize(1000),
  ].forEach((hook) => {
    try { hook(); } catch (e) { /* a missing API must not block the rest */ }
  });
}

/** Read-only view for report.js. */
export function diagnosticsState() {
  return state;
}

export { Ring, DedupeLog };
