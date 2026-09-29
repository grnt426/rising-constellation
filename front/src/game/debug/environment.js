// What the report knows about the page, the renderer and — only when the
// player opts in — the device and the browser.
//
// Split by how identifying the data is:
//
//   * renderInfo / audioInfo / clientInfo (always): the game's own
//     rendering state and capabilities — WebGL version, limits, context
//     losses, renderer counters, whether rendering fell back to software
//     (a boolean, not the GPU name), font and audio state, the build.
//   * deviceInfo (opt-in "system information"): CPU cores, memory, screen,
//     the GPU model, network class — the hardware.
//   * browserInfo (opt-in "browser configuration"): user agent, languages,
//     time zone, window size and zoom, media preferences, feature support.

import { Howler } from 'howler';
import config from '@/config';
import { ambiance } from '@/plugins/ambiance';
import { version as clientVersion } from '@/../package.json';

const SOFTWARE_RENDERERS = /swiftshader|llvmpipe|softpipe|microsoft basic render|software/i;

const attempt = (fn, fallback) => {
  try {
    return fn();
  } catch (e) {
    return fallback !== undefined ? fallback : { error: e && e.message };
  }
};

const mediaMatches = (query) => attempt(() => window.matchMedia(query).matches, null);

// The unmasked GPU strings. Identifying, so only deviceInfo exports them;
// renderInfo keeps just the software-rendering verdict derived from them.
function gpuStrings(gl) {
  if (!gl) return {};
  return attempt(() => {
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    return {
      vendor: ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
      renderer: ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
    };
  }, {});
}

// A throwaway context when the map never created one (or lost it): does
// WebGL work here at all, and is it hardware accelerated?
function probeWebgl() {
  const out = {};
  const tryContext = (type, attrs) => attempt(() => {
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext(type, attrs);
    if (!gl) return null;
    const info = { ok: true, software: SOFTWARE_RENDERERS.test(gpuStrings(gl).renderer || '') };
    const lose = gl.getExtension('WEBGL_lose_context');
    if (lose) lose.loseContext();
    return info;
  }, null);
  out.webgl2 = tryContext('webgl2');
  out.webgl1 = tryContext('webgl');
  // Refused when the browser would only give a software/blocklisted GPU.
  out.hardwareAccelerated = !!tryContext('webgl', { failIfMajorPerformanceCaveat: true });
  return out;
}

export function liveGl(render) {
  const renderer = render && render.renderer;
  return renderer ? attempt(() => renderer.getContext(), null) : null;
}

/** Always included: the galaxy map's renderer and WebGL state. */
export function renderInfo(render) {
  const map = render.map;
  const renderer = render.renderer;
  const gl = liveGl(render);

  const out = {
    map: map ? {
      initStage: map.initStage,
      framesRendered: map.frameCount,
      rendering: map.mapUpdate !== false,
      inSystem: !!map.inSystem,
      cameraMoving: !!map.moving,
      blocks: map.blocks ? map.blocks.length : undefined,
      lastPointerType: map.lastPointerType,
      cameraZ: attempt(() => Math.round(map.camera.position.z * 100) / 100, undefined),
    } : null,
    mapsCreatedThisPage: render.mapsCreated,
    contextLostEvents: render.contextLost,
    contextRestoredEvents: render.contextRestored,
    events: render.events.toArray(),
  };

  if (renderer && gl) {
    out.webgl = attempt(() => {
      const caps = renderer.capabilities;
      const canvas = renderer.domElement;
      const attrs = gl.getContextAttributes() || {};
      const gpu = gpuStrings(gl);
      return {
        isWebGL2: caps.isWebGL2,
        contextLost: gl.isContextLost(),
        softwareRendering: SOFTWARE_RENDERERS.test(gpu.renderer || ''),
        precision: caps.precision,
        contextAttributes: {
          antialias: attrs.antialias,
          alpha: attrs.alpha,
          depth: attrs.depth,
          stencil: attrs.stencil,
          powerPreference: attrs.powerPreference,
          desynchronized: attrs.desynchronized,
          preserveDrawingBuffer: attrs.preserveDrawingBuffer,
        },
        limits: {
          maxTextureSize: caps.maxTextureSize,
          maxCubemapSize: caps.maxCubemapSize,
          maxRenderbufferSize: gl.getParameter(gl.MAX_RENDERBUFFER_SIZE),
          maxViewportDims: Array.from(gl.getParameter(gl.MAX_VIEWPORT_DIMS) || []),
          maxTextures: caps.maxTextures,
          maxVertexUniforms: caps.maxVertexUniforms,
          maxSamples: caps.maxSamples,
          maxAnisotropy: attempt(() => caps.getMaxAnisotropy(), undefined),
        },
        pixelRatio: renderer.getPixelRatio(),
        drawingBuffer: [gl.drawingBufferWidth, gl.drawingBufferHeight],
        canvasCss: [canvas.clientWidth, canvas.clientHeight],
        info: {
          memory: { ...renderer.info.memory },
          lastFrame: { ...renderer.info.render },
          programs: renderer.info.programs ? renderer.info.programs.length : undefined,
        },
      };
    });
  } else {
    out.probe = probeWebgl();
  }

  return out;
}

/** Always included: fonts and audio, both frequent silent failures. */
export function mediaInfo() {
  return {
    fonts: attempt(() => ({
      status: document.fonts.status,
      loaded: Array.from(document.fonts).filter((f) => f.status === 'loaded').length,
      failed: Array.from(document.fonts).filter((f) => f.status === 'error').map((f) => `${f.family} ${f.weight}`),
      gameFontReady: document.fonts.check('800 22px Nunito'),
    })),
    audio: attempt(() => ({
      unlocked: ambiance.unlocked,
      waitingForGesture: !!ambiance.unlockHandler,
      context: ambiance.context,
      volumes: { ...ambiance.settings },
      webAudioState: Howler.ctx ? Howler.ctx.state : null,
      usingWebAudio: Howler.usingWebAudio,
      noAudio: Howler.noAudio,
      codecs: { mp3: Howler.codecs('mp3'), ogg: Howler.codecs('ogg'), webm: Howler.codecs('webm') },
      howls: (Howler._howls || []).map((h) => h.state()), // eslint-disable-line no-underscore-dangle
      html5PoolFree: (Howler._html5AudioPool || []).length, // eslint-disable-line no-underscore-dangle
    })),
  };
}

/** Always included: which build is running. */
export function clientInfo() {
  // Own-origin bundles only, by file name.
  const assets = (selector, attr) => attempt(() => Array.from(document.querySelectorAll(selector))
    .map((el) => new URL(el.getAttribute(attr), window.location.href))
    .filter((url) => url.origin === window.location.origin)
    .map((url) => url.pathname.split('/').pop()), []);
  return {
    version: clientVersion,
    mode: config.MODE,
    steam: config.IS_STEAM,
    // Hashed bundle names identify the exact deployed build.
    scripts: assets('script[src]', 'src'),
    styles: assets('link[rel="stylesheet"][href]', 'href'),
    origin: window.location.origin,
  };
}

/** Opt-in "system information": the hardware. */
export async function deviceInfo(render) {
  const nav = navigator;
  const conn = nav.connection || nav.mozConnection || nav.webkitConnection;
  const gl = liveGl(render) || attempt(() => document.createElement('canvas').getContext('webgl'), null);
  const gpu = gpuStrings(gl);

  let platformDetails;
  if (nav.userAgentData && nav.userAgentData.getHighEntropyValues) {
    platformDetails = await nav.userAgentData
      .getHighEntropyValues(['architecture', 'bitness', 'model', 'platformVersion'])
      .then((v) => ({
        architecture: v.architecture, bitness: v.bitness, model: v.model, platformVersion: v.platformVersion,
      }))
      .catch(() => undefined);
  }

  return {
    cpuCores: nav.hardwareConcurrency,
    memoryGB: nav.deviceMemory,
    platform: nav.platform,
    platformDetails,
    maxTouchPoints: nav.maxTouchPoints,
    screen: attempt(() => ({
      width: window.screen.width,
      height: window.screen.height,
      availWidth: window.screen.availWidth,
      availHeight: window.screen.availHeight,
      colorDepth: window.screen.colorDepth,
      orientation: window.screen.orientation ? window.screen.orientation.type : undefined,
    })),
    devicePixelRatio: window.devicePixelRatio,
    gpu: {
      ...gpu,
      extensions: attempt(() => (gl ? gl.getSupportedExtensions() : []), []),
    },
    heapLimitMB: performance.memory ? Math.round(performance.memory.jsHeapSizeLimit / 1048576) : undefined,
    network: conn ? {
      type: conn.type,
      effectiveType: conn.effectiveType,
      rttMs: conn.rtt,
      downlinkMbps: conn.downlink,
      saveData: conn.saveData,
    } : undefined,
  };
}

/** Opt-in "browser configuration". */
export async function browserInfo() {
  const nav = navigator;
  let brands;
  if (nav.userAgentData) {
    brands = {
      brands: nav.userAgentData.brands,
      mobile: nav.userAgentData.mobile,
      platform: nav.userAgentData.platform,
    };
    if (nav.userAgentData.getHighEntropyValues) {
      brands.fullVersionList = await nav.userAgentData.getHighEntropyValues(['fullVersionList'])
        .then((v) => v.fullVersionList)
        .catch(() => undefined);
    }
  }

  let storage;
  if (nav.storage && nav.storage.estimate) {
    storage = await nav.storage.estimate()
      .then((e) => ({ usageMB: Math.round(e.usage / 1048576), quotaMB: Math.round(e.quota / 1048576) }))
      .catch(() => undefined);
  }

  let clipboardWrite;
  if (nav.permissions && nav.permissions.query) {
    // Firefox throws on this permission name.
    clipboardWrite = await nav.permissions.query({ name: 'clipboard-write' })
      .then((p) => p.state)
      .catch(() => 'unsupported');
  }

  const vv = window.visualViewport;
  return {
    userAgent: nav.userAgent,
    userAgentData: brands,
    languages: nav.languages,
    timeZone: attempt(() => Intl.DateTimeFormat().resolvedOptions().timeZone, undefined),
    intlLocale: attempt(() => Intl.DateTimeFormat().resolvedOptions().locale, undefined),
    doNotTrack: nav.doNotTrack,
    automated: nav.webdriver,
    online: nav.onLine,
    window: {
      inner: [window.innerWidth, window.innerHeight],
      outer: [window.outerWidth, window.outerHeight],
      visualViewport: vv ? { width: Math.round(vv.width), height: Math.round(vv.height), scale: vv.scale } : undefined,
    },
    media: {
      darkScheme: mediaMatches('(prefers-color-scheme: dark)'),
      reducedMotion: mediaMatches('(prefers-reduced-motion: reduce)'),
      forcedColors: mediaMatches('(forced-colors: active)'),
      coarsePointer: mediaMatches('(pointer: coarse)'),
      anyCoarsePointer: mediaMatches('(any-pointer: coarse)'),
      noHover: mediaMatches('(hover: none)'),
    },
    secureContext: window.isSecureContext,
    crossOriginIsolated: window.crossOriginIsolated,
    serviceWorkerControlled: !!(nav.serviceWorker && nav.serviceWorker.controller),
    storage,
    clipboardWrite,
    supports: {
      webgl2: typeof WebGL2RenderingContext !== 'undefined',
      offscreenCanvas: typeof OffscreenCanvas !== 'undefined',
      resizeObserver: typeof ResizeObserver !== 'undefined',
      intersectionObserver: typeof IntersectionObserver !== 'undefined',
      requestIdleCallback: typeof window.requestIdleCallback === 'function',
      structuredClone: typeof window.structuredClone === 'function',
      clipboardApi: !!nav.clipboard,
      clipboardItem: typeof window.ClipboardItem !== 'undefined',
      webAudio: typeof (window.AudioContext || window.webkitAudioContext) !== 'undefined',
      pointerEvents: typeof window.PointerEvent !== 'undefined',
      touchEvents: 'ontouchstart' in window,
      webAssembly: typeof WebAssembly !== 'undefined',
      performanceMemory: !!performance.memory,
      longTaskTiming: attempt(() => (PerformanceObserver.supportedEntryTypes || []).includes('longtask'), false),
    },
  };
}
