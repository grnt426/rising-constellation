// Assembles the Help → Debug report: a JSON document the player saves and
// sends to the developers.
//
// Sections, in the order a reader triages:
//
//   summary      one screen: errors, desyncs, frame time, freezes, slowdown
//   client       build, version, route
//   session      how long the page / game has been open, visibility history
//   errors       everything the collector caught (collector.js)
//   sync         desync probes: fresh server copies diffed against the store
//   connection   socket + channel health, reconnects, round-trip times
//   network      socket traffic by message kind, recent frames, HTTP calls
//   performance  timed real work: map frames and blocks, message decode and
//                handling, FPS and freezes, long tasks, heap — as comparable
//                baseline figures plus a slowdown vs this tab's own start
//   rendering    galaxy map + WebGL state, fonts, audio
//   game         allowlisted store state: ids, UI state, player, selection
//   system       opt-in: hardware
//   browser      opt-in: browser configuration
//
// The game section is built from an explicit allowlist (never the raw
// store: it holds the session tokens), and the finished report goes
// through sanitize() once more, which redacts secret-named keys and token
// shapes anywhere in it.

import store from '@/store';
import { i18n } from '@/plugins/i18n';
import viewport from '@/utils/viewport';
import { isFeatureOn } from '@/utils/features';
import { serverNow } from '@/game/clock';
import { diagnosticsState } from './collector.js';
import { diffValues } from './diff.js';
import { sanitize } from './sanitize.js';
import { summarize } from './stats.js';
import { slowdown } from './series.js';
import {
  renderInfo, mediaInfo, clientInfo, deviceInfo, browserInfo,
} from './environment.js';

export const REPORT_FORMAT = 'tetrarchy-falls-debug-report';
export const REPORT_VERSION = 1;

const PROBE_TIMEOUT_MS = 10000;
const KNOWN_FEATURES = ['agent_fan_display', 'mobile_ui', 'slim_sync', 'help_manual'];

const iso = (ms) => (typeof ms === 'number' && ms > 0 ? new Date(ms).toISOString() : null);
const round = (n) => (typeof n === 'number' ? Math.round(n * 100) / 100 : n);

// The headline percentiles of a series.js Hist summary.
function pick(s) {
  if (!s || !s.n) return null;
  return {
    n: s.n, p50: s.p50, p95: s.p95, p99: s.p99, max: s.max,
  };
}
const ageMs = (ms) => (typeof ms === 'number' && ms > 0 ? Date.now() - ms : null);

// One failing section must not sink the whole report.
const section = (fn) => {
  try {
    return fn();
  } catch (e) {
    return { sectionError: `${e && e.name}: ${e && e.message}` };
  }
};
const asyncSection = async (fn) => {
  try {
    return await fn();
  } catch (e) {
    return { sectionError: `${e && e.name}: ${e && e.message}` };
  }
};

const count = (v) => {
  if (Array.isArray(v)) return v.length;
  if (v && typeof v === 'object') return Object.keys(v).length;
  return v === undefined || v === null ? 0 : 1;
};

// Shape of a big struct without its contents: key → size.
const outline = (obj) => {
  if (!obj || typeof obj !== 'object') return obj;
  const out = {};
  Object.keys(obj).forEach((k) => {
    const v = obj[k];
    out[k] = v && typeof v === 'object' ? `${Array.isArray(v) ? 'array' : 'object'}(${count(v)})` : v;
  });
  return out;
};

const withoutKeys = (obj, keys) => {
  if (!obj || typeof obj !== 'object') return obj;
  const out = { ...obj };
  keys.forEach((k) => { delete out[k]; });
  return out;
};

// ─── session ────────────────────────────────────────────────────────────

function sessionInfo() {
  const d = diagnosticsState();
  const nav = performance.getEntriesByType ? performance.getEntriesByType('navigation')[0] : null;
  const pageLoadedAt = Math.round(performance.timeOrigin || (Date.now() - performance.now()));
  const gameRoute = d.routes.toArray().filter((r) => r.path === '/game').pop();
  const hiddenNow = d.page.hiddenSince ? Date.now() - d.page.hiddenSince : 0;
  return {
    now: new Date().toISOString(),
    pageLoadedAt: iso(pageLoadedAt),
    pageOpenMs: Math.round(performance.now()),
    navigationType: nav ? nav.type : undefined,
    pageLoad: nav ? {
      domContentLoadedMs: Math.round(nav.domContentLoadedEventEnd),
      loadMs: Math.round(nav.loadEventEnd),
      transferKB: nav.transferSize ? Math.round(nav.transferSize / 1024) : undefined,
    } : undefined,
    enteredGameAt: iso(gameRoute && gameRoute.t),
    inGameMs: gameRoute ? ageMs(gameRoute.t) : null,
    firstConnectedAt: iso(d.connection.firstConnectedAt),
    lastConnectedAt: iso(d.connection.lastConnectedAt),
    lastDisconnectedAt: iso(d.connection.lastDisconnectedAt),
    disconnects: d.connection.disconnects,
    visibility: {
      now: document.visibilityState,
      startedHidden: d.page.startedHidden,
      timesHidden: d.page.hiddenCount,
      hiddenMs: d.page.hiddenMs + hiddenNow,
      freezes: d.page.freezes,
      lifecycle: d.page.lifecycle.toArray(),
    },
    onlineEvents: d.page.online.toArray(),
    routes: d.routes.toArray(),
  };
}

// ─── errors / console ───────────────────────────────────────────────────

function errorsInfo() {
  const d = diagnosticsState();
  return {
    captured: d.errors.toArray(),
    resourceLoads: d.resourceErrors.toArray(),
    console: {
      errors: d.consoleErrors.toArray(),
      warnings: d.consoleWarns.toArray(),
      totals: { errors: d.consoleErrors.total, warnings: d.consoleWarns.total },
    },
    totals: { captured: d.errors.total, resourceLoads: d.resourceErrors.total },
  };
}

// ─── connection / network ───────────────────────────────────────────────

function channelInfo(channel) {
  if (!channel) return null;
  return {
    topic: channel.topic,
    state: channel.state,
    joinedOnce: channel.joinedOnce,
    rejoinTries: channel.rejoinTimer ? channel.rejoinTimer.tries : undefined,
    bufferedPushes: channel.pushBuffer ? channel.pushBuffer.length : undefined,
  };
}

function connectionInfo(socket) {
  const d = diagnosticsState();
  const ws = socket.ws;
  const g = store.state.game;
  return {
    socket: ws ? {
      state: ws.connectionState(),
      reconnectTries: ws.reconnectTimer ? ws.reconnectTimer.tries : undefined,
      heartbeatPending: !!ws.pendingHeartbeatRef,
      heartbeatIntervalMs: ws.heartbeatIntervalMs,
      bufferedSends: ws.sendBuffer ? ws.sendBuffer.length : undefined,
      bufferedBytes: ws.conn ? ws.conn.bufferedAmount : undefined,
      closeWasClean: ws.closeWasClean,
      errorsSinceOpen: d.socket.errorsSinceOpen,
    } : null,
    events: d.socket.events.toArray(),
    storeFlags: { connected: g.connected, activeChannels: { ...g.activeChannels } },
    channelStatusChanges: d.channelStatus.toArray(),
    channels: {
      global: channelInfo(socket.global),
      faction: channelInfo(socket.faction),
      player: channelInfo(socket.player),
      cheat: channelInfo(socket.cheat),
    },
    sync: {
      productionDeltaSeq: socket.productionDeltaSeq,
      selectionReloadPending: !!socket.selectionReloadTimer,
      settleSyncPending: !!socket.settleSyncTimer,
      backgroundSyncRunning: !!socket.backgroundSyncTimer,
      slimSyncCapability: store.state.portal.features.slim_sync === true,
    },
    roundTripMs: Array.from(d.socket.rtt.entries())
      .reduce((acc, [kind, hist]) => ({ ...acc, [kind]: pick(hist.summary()) }), {}),
    unansweredPushes: d.socket.pending.size,
    timedOutPushes: { ...d.socket.timeouts },
  };
}

function networkInfo() {
  const d = diagnosticsState();
  const s = d.socket;
  const http = d.http.toArray();
  return {
    socket: {
      framesIn: s.framesIn,
      framesOut: s.framesOut,
      bytesIn: s.bytesIn,
      bytesOut: s.bytesOut,
      // by message kind, costliest first: JSON parse, handling (channel
      // handlers, store commits, map update), and the Vue re-render after
      inbound: Array.from(s.messages.entries())
        .map(([kind, m]) => ({
          kind,
          n: m.n,
          bytes: m.bytes,
          maxBytes: m.maxBytes,
          totalMs: round(m.parse.sum + m.handle.sum + m.react.sum),
          parseMs: pick(m.parse.summary()),
          handleMs: pick(m.handle.summary()),
          reactMs: pick(m.react.summary()),
        }))
        .sort((a, b) => b.totalMs - a.totalMs),
      outbound: s.outbound,
      recentFrames: s.frames.toArray(),
    },
    http: {
      failures: d.httpFailures,
      durationMs: summarize(http.map((r) => r.ms)),
      recent: http,
    },
    storeMutations: {
      counts: { ...d.mutationCounts },
      recent: d.mutations.toArray(),
    },
    consoleLog: d.consoleLog.toArray(),
  };
}

// ─── performance ────────────────────────────────────────────────────────

// Every figure below is timed from work the client does anyway (see
// collector.js); none comes from a benchmark. Two ways to read them:
//
//   * across players — `baseline` holds the comparable numbers (map frame
//     CPU time, FPS, JSON decode throughput, message handling) next to the
//     context needed to compare like with like (galaxy size, draw calls,
//     zoom mix, pixel count). Decode MB/s is the most content-neutral: the
//     same JSON.parse over the same kind of payload, whatever the game;
//   * within this tab — `slowdown` divides the recent window by the tab's
//     own session baseline, so "it got slow after a few hours" shows as
//     > 1 without knowing the player's hardware.

// A per-name SeriesMap (blocks, other work) as a table, costliest first.
function seriesTable(seriesMap) {
  return seriesMap.entries()
    .map(([name, series]) => {
      const s = series.summary();
      return {
        name,
        totalMs: round(s.lifetime.total || 0),
        lifetime: pick(s.lifetime),
        recent: pick(s.recent),
        slowdown: slowdown(s),
        windows: s.windows,
      };
    })
    .sort((a, b) => b.totalMs - a.totalMs);
}

function performanceInfo(mapData) {
  const d = diagnosticsState();
  const p = d.perf;
  const f = p.frames;
  const near = p.mapFrame.near.summary();
  const far = p.mapFrame.far.summary();
  const interval = p.frameInterval.map.summary();
  const decodeMBps = p.decodeMBps.summary();
  const handle = p.handleMs.summary();
  const react = p.reactMs.summary();
  const renderer = d.render.renderer;
  const heap = p.heap.toArray();
  const mem = performance.memory;
  const perFrame = (total) => (f.rendered ? Math.round(total / f.rendered) : null);

  return {
    method: 'passive: map frames (per block + WebGL submit), frame intervals, and each socket message\'s '
      + 'decode / handling / re-render, timed as they happen; no synthetic benchmark',
    baseline: {
      mapFrameMs: { near: pick(near.lifetime), far: pick(far.lifetime) },
      fps: interval.lifetime.p50 ? round(1000 / interval.lifetime.p50) : null,
      decodeMBps: decodeMBps.lifetime.n ? decodeMBps.lifetime.p50 : null,
      messageHandleMs: pick(handle.lifetime),
      messageReactMs: pick(react.lifetime),
      context: {
        systems: mapData ? mapData.systems.length : undefined,
        sectors: mapData ? mapData.sectors.length : undefined,
        radars: mapData ? mapData.radars.length : undefined,
        detectedObjects: mapData ? mapData.detectedObjects.length : undefined,
        framesRendered: f.rendered,
        farViewShare: f.rendered ? round(f.far / f.rendered) : null,
        drawCallsPerFrame: perFrame(f.drawCalls),
        trianglesPerFrame: perFrame(f.triangles),
        pixelRatio: renderer ? renderer.getPixelRatio() : undefined,
        drawingBuffer: renderer ? [renderer.domElement.width, renderer.domElement.height] : undefined,
        speed: store.state.game.time && store.state.game.time.speed,
        mobileLayout: viewport.isMobile,
        timerResolutionMs: p.timerResolutionMs,
      },
      slowdown: {
        mapFrameNear: slowdown(near),
        mapFrameFar: slowdown(far),
        frameInterval: slowdown(interval),
        decode: slowdown(decodeMBps, true),
        messageHandle: slowdown(handle),
        messageReact: slowdown(react),
      },
    },
    worst: p.worst.toArray(),
    blocks: seriesTable(p.blocks),
    work: seriesTable(p.work),
    series: {
      mapFrameNearMs: near,
      mapFrameFarMs: far,
      mapRenderMs: p.mapRender.summary(),
      frameIntervalMs: interval,
      systemViewFrameIntervalMs: p.frameInterval.systemView.summary(),
      decodeMs: p.decodeMs.summary(),
      decodeMBps,
      handleMs: handle,
      reactMs: react,
    },
    frames: { ...f },
    mapInit: { ...p.mapInit },
    freezes: {
      ...p.stallCounts,
      note: 'frame intervals over 100 ms while the tab was visible; the first 10 s of the map are counted in duringLoad only',
      recent: p.stalls.toArray(),
    },
    longTasks: {
      supported: p.longTaskSupported,
      count: p.longTaskCount,
      totalMs: Math.round(p.longTaskTotalMs),
      worstRecent: p.longTasks.toArray(),
    },
    heap: {
      nowMB: mem ? Math.round(mem.usedJSHeapSize / 1048576) : undefined,
      peakMB: heap.length ? Math.max(...heap.map((h) => h.usedMB)) : undefined,
      samples: heap,
    },
    clockJumps: p.clockJumps.toArray(),
  };
}

// ─── game state ─────────────────────────────────────────────────────────

function gameInfo(mapData) {
  const g = store.state.game;
  const p = store.state.portal;
  const settings = p.settings || {};
  const galaxy = g.galaxy || {};

  return {
    ids: {
      accountId: p.account ? p.account.id : undefined,
      profileId: g.auth.profile,
      instanceId: g.auth.instance,
      factionId: g.auth.faction,
      playerId: g.player ? g.player.id : undefined,
      faction: g.playerFaction,
      isAdmin: p.isAdmin,
    },
    flags: {
      connected: g.connected,
      isDead: g.isDead,
      tutorial: !!galaxy.tutorial_id,
      tutorialStep: g.tutorialStep,
      view: g.view,
      activeOverlay: g.activeOverlay,
      mapOverlay: g.mapOverlay ? { type: g.mapOverlay.type, data: g.mapOverlay.data } : null,
      isMapLocked: g.isMapLocked,
      hasSystemTransition: g.hasSystemTransition,
      productionBoxOpen: !!g.production,
      assignmentBoxOpen: !!g.assignment,
      openedCharacterId: g.openedCharacter ? g.openedCharacter.id : null,
      openedPlayerId: g.openedPlayer ? g.openedPlayer.id : null,
      onlinePlayers: count(g.onlinePlayers),
      unreadMessages: g.unreadMessages,
      textNotifications: g.textNotifications.length,
      boxNotifications: g.boxNotifications.length,
      news: g.news.length,
    },
    ui: {
      locale: i18n.locale,
      mobileLayout: viewport.isMobile,
      mapOptions: { ...g.mapOptions },
      mapPosition: g.mapPosition,
      ruler: { active: g.ruler.active, waypoints: g.ruler.waypoints.length },
      charactersGroup: g.charactersGroup,
    },
    portal: {
      isSignedIn: p.isSignedIn,
      isInMaintenance: p.isInMaintenance,
      deployOngoing: p.deployOngoing,
      hasCorrectVersion: p.hasCorrectVersion,
      requiredVersion: p.requiredVersion,
      hasConnectivity: p.hasConnectivity,
      features: { ...p.features },
      featuresResolved: KNOWN_FEATURES.reduce((acc, k) => ({ ...acc, [k]: isFeatureOn(p.features, k) }), {}),
      settings: {
        ...withoutKeys(settings, ['muted_chat', 'muted_icons']),
        mutedChats: count(settings.muted_chat),
        mutedIcons: count(settings.muted_icons),
      },
    },
    time: {
      ...g.time,
      clientServerNow: serverNow(g.time),
      receivedAgoMs: ageMs(g.time.receivedAt),
      effectiveSpeedFactor: store.getters['game/effectiveSpeedFactor'],
    },
    instanceInfo: { ...g.instanceInfo },
    victory: g.victory,
    dailyResult: g.dailyResult,
    diplomacy: g.diplomacy,
    characterMarket: g.character_market,
    faction: g.faction ? {
      ...withoutKeys(g.faction, ['chat']),
      chat: `array(${count(g.faction.chat)})`,
    } : null,
    player: g.player,
    playerReceivedAgoMs: ageMs(g.player && g.player.receivedAt),
    selectedSystem: g.selectedSystem || null,
    selectedCharacter: g.selectedCharacter || null,
    galaxy: outline(galaxy),
    staticData: outline(g.data),
    mapData: mapData ? {
      systems: mapData.systems.length,
      sectors: mapData.sectors.length,
      radars: mapData.radars.length,
      detectedObjects: mapData.detectedObjects.length,
      blackholes: count(mapData.blackholes),
      pendingRepaints: mapData.systemsToRepaint ? mapData.systemsToRepaint.size : undefined,
      hoveredSystemId: mapData.hoveredSystemId,
    } : null,
    calc: store.state.calc ? outline(store.state.calc) : undefined,
    help: store.state.help ? outline(store.state.help) : undefined,
  };
}

// Client-only cross-checks: the same fact held in two places that should
// agree without asking the server.
function consistencyInfo(mapData) {
  const g = store.state.game;
  const out = {};
  if (!mapData || !g.player) return out;

  const byId = mapData.systemsById || new Map(mapData.systems.map((s) => [s.id, s]));
  const ownFaction = g.player.faction;

  // Every system the player struct says is ours should be ours on the map.
  const check = (list) => {
    const bad = [];
    (list || []).forEach((own) => {
      const onMap = byId.get(own.id);
      if (!onMap) bad.push({ id: own.id, problem: 'not_on_map' });
      else if (onMap.faction !== ownFaction) bad.push({ id: own.id, problem: 'map_faction', map: onMap.faction });
    });
    return { checked: (list || []).length, mismatches: bad.length, samples: bad.slice(0, 20) };
  };
  out.playerSystemsOnMap = check(g.player.stellar_systems);
  out.playerDominionsOnMap = check(g.player.dominions);

  // store.galaxy is only replaced by global_galaxy(_sector/_player); the
  // map also applies per-system global_galaxy_system updates.
  const galaxySystems = (g.galaxy && g.galaxy.stellar_systems) || [];
  const drift = [];
  galaxySystems.forEach((s) => {
    const onMap = byId.get(s.id);
    if (onMap && onMap.faction !== s.faction) drift.push({ id: s.id, store: s.faction, map: onMap.faction });
  });
  out.storeGalaxyVsMap = {
    checked: galaxySystems.length,
    factionMismatches: drift.length,
    samples: drift.slice(0, 20),
    note: 'store.galaxy is not updated by global_galaxy_system broadcasts; the map is',
  };
  return out;
}

// ─── desync probes ──────────────────────────────────────────────────────

function push(channel, event, payload) {
  return new Promise((resolve) => {
    if (!channel) {
      resolve({ status: 'skipped', reason: 'no_channel' });
      return;
    }
    if (channel.state !== 'joined') {
      resolve({ status: 'skipped', reason: `channel_${channel.state}` });
      return;
    }
    const sentAt = Date.now();
    const done = (status) => (response) => resolve({
      status, response, sentAt, receivedAt: Date.now(), rttMs: Date.now() - sentAt,
    });
    channel.push(event, payload, PROBE_TIMEOUT_MS)
      .receive('ok', done('ok'))
      .receive('error', done('error'))
      .receive('timeout', done('timeout'));
  });
}

// Diff a fresh server copy against the store's. `read` returns the store
// value; it is read both when the request leaves and when the reply lands,
// so a broadcast arriving mid-probe is flagged rather than mistaken for
// drift (store roots are replaced, never mutated, so identity tells).
async function probe({
  channel, event, payload, read, pick, ignoreKeys, skip,
}) {
  if (skip) return { status: 'skipped', reason: skip };
  const before = read();
  const result = await push(channel, event, payload);
  const out = { event, status: result.status, rttMs: result.rttMs };
  if (result.status !== 'ok') {
    if (result.reason) out.reason = result.reason;
    if (result.response) out.response = result.response;
    return out;
  }
  const after = read();
  const fresh = pick(result.response);
  out.storeUpdatedDuringProbe = before !== after;
  out.clientCopyAgeMs = after && after.receivedAt ? result.receivedAt - after.receivedAt : undefined;
  Object.assign(out, diffResult(diffValues(after, fresh, ignoreKeys ? { ignoreKeys } : {})));
  out.fresh = fresh;
  return out;
}

function diffResult(diff) {
  return {
    equal: diff.equal,
    // desync candidates, as opposed to extrapolated values drifting and
    // zero-value breakdown parts (see diff.js)
    structuralDifferences: diff.structural,
    extrapolatedDifferences: diff.count - diff.structural - diff.cosmetic,
    cosmeticDifferences: diff.cosmetic,
    differencesTruncated: diff.truncated,
    differences: diff.differences,
  };
}

const STAMPS = ['receivedAt', 'queueReceivedAt', 'resourcesReceivedAt'];

async function syncInfo(socket) {
  const g = store.state.game;
  if (!g.connected) return { skipped: 'not_connected' };

  const selectedSystem = g.selectedSystem;
  const selectedCharacter = g.selectedCharacter;

  const [player, system, character, global, faction] = await Promise.all([
    probe({
      channel: socket.player,
      event: 'get_player',
      payload: {},
      read: () => store.state.game.player,
      pick: (r) => r.player_player,
    }),
    probe({
      channel: socket.faction,
      event: 'get_system',
      payload: { system_id: selectedSystem && selectedSystem.id },
      read: () => store.state.game.selectedSystem,
      pick: (r) => r.system,
      skip: selectedSystem ? null : 'no_system_open',
    }),
    probe({
      channel: socket.player,
      event: 'get_character',
      payload: { character_id: selectedCharacter && selectedCharacter.id },
      read: () => store.state.game.selectedCharacter,
      pick: (r) => r.character,
      skip: selectedCharacter ? null : 'no_character_selected',
    }),
    push(socket.global, 'get_sync_state', {}),
    probe({
      channel: socket.faction,
      event: 'get_faction',
      payload: {},
      read: () => store.state.game.faction,
      pick: (r) => r.faction_faction,
      // chat is compared by length only (see below): message text stays out
      ignoreKeys: [...STAMPS, 'chat'],
    }),
  ]);

  if (faction.fresh) {
    faction.chatLength = { client: count(g.faction && g.faction.chat), server: count(faction.fresh.chat) };
    faction.fresh = withoutKeys(faction.fresh, ['chat']);
  }
  // The fresh copies are large and mostly identical to game.*; keep them
  // only where something structural differs, so the reader can see the
  // server's side.
  [player, system, character, faction].forEach((p) => {
    if (!p.structuralDifferences) delete p.fresh;
  });

  return {
    player,
    selectedSystem: system,
    selectedCharacter: character,
    faction,
    ...syncStateInfo(global),
  };
}

// get_sync_state: time (clock drift), victory, character market, speed.
function syncStateInfo(result) {
  if (result.status !== 'ok') {
    return { clock: { status: result.status, reason: result.reason, rttMs: result.rttMs } };
  }
  const g = store.state.game;
  const r = result.response;
  const time = r.global_time || {};

  // Server read its clock ~halfway through the round trip.
  const midpoint = result.receivedAt - result.rttMs / 2;
  const estimate = serverNow(g.time, midpoint);
  const clock = {
    status: 'ok',
    rttMs: result.rttMs,
    serverNowMonotonic: time.now_monotonic,
    clientEstimate: estimate,
    // > 0: the client thinks the server clock is further along than it is
    // (agents look further along their jumps, ETAs read short).
    driftMs: estimate !== null && typeof time.now_monotonic === 'number'
      ? Math.round(estimate - time.now_monotonic) : null,
    driftUncertaintyMs: Math.round(result.rttMs / 2),
    isRunning: { client: g.time.is_running, server: time.is_running },
    speed: { client: g.time.speed, server: time.speed },
    gameDate: {
      client: g.time.now ? g.time.now.value : undefined,
      server: time.now ? time.now.value : undefined,
      clientCopyAgeMs: ageMs(g.time.receivedAt),
    },
    speedup: {
      client: g.instanceInfo.speedup,
      server: r.global_speedup ? r.global_speedup.multiplier : undefined,
    },
  };

  const compare = (client, fresh) => {
    const out = {
      ...diffResult(diffValues(client, fresh)),
      clientCopyAgeMs: ageMs(client && client.receivedAt),
    };
    if (out.structuralDifferences) out.fresh = fresh;
    return out;
  };

  return {
    clock,
    victory: compare(g.victory, r.global_victory),
    characterMarket: compare(g.character_market, r.global_character_market),
  };
}

// ─── summary ────────────────────────────────────────────────────────────

function summaryOf(report) {
  const sync = report.sync || {};
  const probed = ['player', 'selectedSystem', 'selectedCharacter', 'faction', 'victory', 'characterMarket']
    .filter((k) => sync[k] && typeof sync[k].equal === 'boolean');
  const desynced = probed
    .filter((k) => sync[k].structuralDifferences > 0)
    .map((k) => `${k} (${sync[k].structuralDifferences})`);
  const drifting = probed.reduce((acc, k) => acc + sync[k].extrapolatedDifferences, 0);
  const perf = report.performance || {};
  const base = perf.baseline || {};
  const errors = report.errors || {};
  const frames = perf.frames || {};
  // the zoom level most frames were drawn at
  const view = frames.far > (frames.rendered || 0) - frames.far ? 'far' : 'near';
  const frame = base.mapFrameMs && base.mapFrameMs[view];
  const worstSlowdown = Object.entries(base.slowdown || {})
    .filter(([, ratio]) => typeof ratio === 'number')
    .sort((a, b) => b[1] - a[1])[0];
  return {
    errorsCaptured: errors.totals ? errors.totals.captured : undefined,
    consoleErrors: errors.console ? errors.console.totals.errors : undefined,
    failedResourceLoads: errors.totals ? errors.totals.resourceLoads : undefined,
    structsCompared: probed.length,
    desyncedStructs: desynced,
    extrapolatedValuesDrifting: drifting,
    clockDriftMs: sync.clock ? sync.clock.driftMs : undefined,
    disconnects: report.session ? report.session.disconnects : undefined,
    medianFps: base.fps,
    mapFrameMs: frame ? { view, p50: frame.p50, p95: frame.p95 } : undefined,
    decodeMBps: base.decodeMBps,
    slowdown: worstSlowdown ? { metric: worstSlowdown[0], ratio: worstSlowdown[1] } : undefined,
    freezesOver250ms: perf.freezes ? perf.freezes.over250 : undefined,
    heapMB: perf.heap ? perf.heap.nowMB : undefined,
    webglContextLosses: report.rendering ? report.rendering.contextLostEvents : undefined,
  };
}

/**
 * @param {object} opts
 * @param {object} opts.socket      the $socket plugin object
 * @param {object} [opts.mapData]   Game.vue's MapData (inject: ['mapData'])
 * @param {boolean} opts.includeSystem   opt-in hardware section
 * @param {boolean} opts.includeBrowser  opt-in browser section
 * @param {string} [opts.description]    the player's own words
 */
export async function buildReport({
  socket, mapData, includeSystem, includeBrowser, description,
}) {
  const started = performance.now();
  const d = diagnosticsState();

  const report = {
    format: REPORT_FORMAT,
    formatVersion: REPORT_VERSION,
    generatedAt: new Date().toISOString(),
    description: description && description.trim() ? description.trim().slice(0, 4000) : undefined,
    included: { game: true, system: !!includeSystem, browser: !!includeBrowser },
    summary: null,
    client: section(() => ({ ...clientInfo(), route: window.location.pathname })),
    session: section(sessionInfo),
    errors: section(errorsInfo),
    sync: await asyncSection(() => syncInfo(socket)),
    consistency: section(() => consistencyInfo(mapData)),
    connection: section(() => connectionInfo(socket)),
    network: section(networkInfo),
    performance: section(() => performanceInfo(mapData)),
    rendering: section(() => ({ ...renderInfo(d.render), ...mediaInfo() })),
    game: section(() => gameInfo(mapData)),
  };

  if (includeSystem) report.system = await asyncSection(() => deviceInfo(d.render));
  if (includeBrowser) report.browser = await asyncSection(browserInfo);

  report.summary = section(() => summaryOf(report));
  report.buildMs = Math.round(performance.now() - started);

  return sanitize(report, {
    maxDepth: 40, maxArray: 3000, maxKeys: 3000, maxString: 20000,
  });
}

export function reportFilename(report) {
  const ids = (report.game && report.game.ids) || {};
  const stamp = (report.generatedAt || new Date().toISOString()).replace(/[:.]/g, '-').replace('Z', '');
  return `tf-debug-i${ids.instanceId || 'x'}-p${ids.profileId || 'x'}-${stamp}.json`;
}
