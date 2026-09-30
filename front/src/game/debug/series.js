// Distributions of passively timed work, for the Debug report.
//
// Performance figures come from work the client does anyway (map frames,
// block updates, socket message decoding and handling), sampled at up to
// ~60 Hz for a tab that may stay open for days. So recording has to be
// O(1) and memory flat:
//
//   * Hist — a log-binned histogram (bins ~25% wide from 0.01 up): count,
//     sum, min, max, and percentiles to within one bin, in ~1 KB no
//     matter how many samples.
//   * Series — a Hist for the whole session, one for the current window
//     (1 min by default), compact summaries of the last N windows, and a
//     frozen baseline: the first `baselineSamples` recorded after a warm-up
//     (boot is noisy: shader compiles, the join payload, first renders).
//     `trend` = recent ÷ baseline, which says whether this tab got slower
//     than itself — the one comparison that needs no knowledge of the
//     player's hardware.
//   * Worst — the K largest single samples with their context.
//
// Pure (no store, no Vue, no DOM), so it runs under plain node:
//   node --test front/src/game/debug/__tests__/debug.test.mjs

const MIN = 0.01;
const FACTOR = 1.25;
const LOG_FACTOR = Math.log(FACTOR);
export const BINS = 80; // top bin starts at ~3.5e5

const round = (n) => (typeof n === 'number' ? Math.round(n * 100) / 100 : n);

// Bin 0 holds [0, MIN]; bin i holds (MIN·F^(i-1), MIN·F^i].
export function binOf(v) {
  if (!(v > MIN)) return 0;
  const i = Math.ceil(Math.log(v / MIN) / LOG_FACTOR - 1e-9);
  return i >= BINS ? BINS - 1 : i;
}


export class Hist {
  constructor() {
    this.counts = new Uint32Array(BINS);
    // per-bin sum of the samples, so a quantile reads the mean of the
    // samples actually in its bin rather than the bin's midpoint
    this.sums = new Float64Array(BINS);
    this.n = 0;
    this.sum = 0;
    this.min = Infinity;
    this.max = -Infinity;
  }

  add(v) {
    const bin = binOf(v);
    this.counts[bin] += 1;
    this.sums[bin] += v;
    this.n += 1;
    this.sum += v;
    if (v < this.min) this.min = v;
    if (v > this.max) this.max = v;
  }

  /**
   * The p-quantile (0..1), to within one bin: the mean of that bin's
   * samples. Exact when a bin holds a single distinct value, which is the
   * usual case under a coarse clock (Firefox reads whole milliseconds, so
   * every sample is 0, 1, 2… and each lands alone in its bin).
   */
  quantile(p) {
    if (!this.n) return null;
    const target = Math.max(1, Math.ceil(p * this.n));
    let seen = 0;
    for (let i = 0; i < BINS; i += 1) {
      seen += this.counts[i];
      if (seen >= target) return this.sums[i] / this.counts[i];
    }
    return this.max;
  }

  summary() {
    if (!this.n) return { n: 0 };
    return {
      n: this.n,
      mean: round(this.sum / this.n),
      p50: round(this.quantile(0.5)),
      p90: round(this.quantile(0.9)),
      p95: round(this.quantile(0.95)),
      p99: round(this.quantile(0.99)),
      max: round(this.max),
      total: round(this.sum),
    };
  }
}

export const SERIES_DEFAULTS = {
  windowMs: 60000,
  keep: 30,
  warmupMs: 60000,
  baselineSamples: 3600,
  // a window this sparse says little on its own
  minRecent: 5,
};

export class Series {
  constructor(options = {}) {
    this.opts = { ...SERIES_DEFAULTS, ...options };
    this.lifetime = new Hist();
    this.baseline = new Hist();
    this.baselineFrom = null;
    this.firstAt = null;
    this.current = null;
    // The last closed window's Hist, so a report generated just after a
    // window rolled still has a full "recent" to compare.
    this.previous = null;
    // [windowStart, n, p50, p95, max]
    this.windows = [];
  }

  add(v, t = Date.now()) {
    if (typeof v !== 'number' || !(v >= 0) || v === Infinity) return;
    if (this.firstAt === null) {
      this.firstAt = t;
      this.baselineFrom = t + this.opts.warmupMs;
    }
    if (!this.current || t >= this.current.start + this.opts.windowMs) this.roll(t);
    this.current.hist.add(v);
    this.lifetime.add(v);
    if (t >= this.baselineFrom && this.baseline.n < this.opts.baselineSamples) this.baseline.add(v);
  }

  roll(t) {
    if (this.current && this.current.hist.n) {
      this.previous = this.current.hist;
      if (this.opts.keep > 0) {
        this.windows.push(compact(this.current));
        if (this.windows.length > this.opts.keep) this.windows.shift();
      }
    }
    const elapsed = t - this.firstAt;
    this.current = {
      start: this.firstAt + Math.floor(elapsed / this.opts.windowMs) * this.opts.windowMs,
      hist: new Hist(),
    };
  }

  // The current window once it has enough samples, else the last full one.
  recentHist() {
    if (this.current && this.current.hist.n >= this.opts.minRecent) return this.current.hist;
    return this.previous && this.previous.n >= this.opts.minRecent ? this.previous : null;
  }

  summary() {
    const recentHist = this.recentHist();
    const recent = recentHist ? recentHist.summary() : null;
    const baseline = this.baseline.n >= this.opts.minRecent ? this.baseline.summary() : null;
    const ratio = (key) => (recent && baseline && baseline[key] > 0 ? round(recent[key] / baseline[key]) : null);
    return {
      lifetime: this.lifetime.summary(),
      baseline,
      recent,
      // Means first: timings are quantized to the timer resolution, which
      // moves percentiles a whole tick at a time, while an average of
      // quantized samples stays accurate.
      trend: recent && baseline ? { mean: ratio('mean'), p50: ratio('p50'), p95: ratio('p95') } : null,
      windows: this.opts.keep > 0 && this.current && this.current.hist.n
        ? this.windows.concat([compact(this.current)])
        : this.windows.slice(),
    };
  }
}

// Below these a slowdown is not claimed: too few samples on either side,
// or work so short that a change is invisible to the player and within a
// few ticks of the timer (0.1 ms in most browsers) — in testing, a
// 0.2 → 0.3 ms move read as "×1.5".
export const SLOWDOWN_MIN_SAMPLES = 20;
export const SLOWDOWN_MIN_MS = 0.5;

/**
 * Recent mean ÷ session-baseline mean of a Series summary, oriented so
 * > 1 always means slower than this tab was (throughput inverted); null
 * when the guards above say it would be noise.
 */
export function slowdown(summary, higherIsBetter = false) {
  const { baseline, recent } = summary || {};
  if (!baseline || !recent) return null;
  if (baseline.n < SLOWDOWN_MIN_SAMPLES || recent.n < SLOWDOWN_MIN_SAMPLES) return null;
  if (!(baseline.mean > 0) || !(recent.mean > 0)) return null;
  if (!higherIsBetter && baseline.mean < SLOWDOWN_MIN_MS) return null;
  return round(higherIsBetter ? baseline.mean / recent.mean : recent.mean / baseline.mean);
}

function compact(window) {
  const h = window.hist;
  return [window.start, h.n, round(h.quantile(0.5)), round(h.quantile(0.95)), round(h.max)];
}

/** Series by name, capped: past `capacity` names, samples pool in "other". */
export class SeriesMap {
  constructor(options = {}, capacity = 32) {
    this.options = options;
    this.capacity = capacity;
    this.map = new Map();
  }

  get(name) {
    const existing = this.map.get(name);
    if (existing) return existing;
    const key = this.map.size < this.capacity ? name : 'other';
    if (!this.map.has(key)) this.map.set(key, new Series(this.options));
    return this.map.get(key);
  }

  entries() { return Array.from(this.map.entries()); }
}

/** The K largest samples, each with a detail object built only if it ranks. */
export class Worst {
  constructor(k = 15) {
    this.k = k;
    this.items = [];
  }

  add(value, detail) {
    const { items } = this;
    if (items.length >= this.k && value <= items[items.length - 1].ms) return;
    const entry = { ms: round(value), t: Date.now(), ...(typeof detail === 'function' ? detail() : detail) };
    let i = items.length;
    while (i > 0 && items[i - 1].ms < entry.ms) i -= 1;
    items.splice(i, 0, entry);
    if (items.length > this.k) items.pop();
  }

  toArray() { return this.items.slice(); }
}
