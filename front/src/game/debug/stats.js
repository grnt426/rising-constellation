// Exact percentiles over small sample lists (HTTP durations and the like);
// the high-rate timing distributions live in series.js.
//
// Pure (no store, no Vue, no DOM), so it runs under plain node:
//   node --test front/src/game/debug/__tests__/debug.test.mjs

const round = (n, digits = 2) => {
  const f = 10 ** digits;
  return Math.round(n * f) / f;
};

const percentile = (sorted, p) => {
  if (!sorted.length) return null;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
};

/** min / max / mean / p50 / p90 / p99 of a list of numbers (null when empty). */
export function summarize(values) {
  const nums = (values || []).filter((v) => typeof v === 'number' && Number.isFinite(v));
  if (!nums.length) return { n: 0 };
  const sorted = nums.slice().sort((x, y) => x - y);
  const sum = sorted.reduce((acc, v) => acc + v, 0);
  return {
    n: sorted.length,
    min: round(sorted[0]),
    p50: round(percentile(sorted, 50)),
    p90: round(percentile(sorted, 90)),
    p99: round(percentile(sorted, 99)),
    max: round(sorted[sorted.length - 1]),
    mean: round(sum / sorted.length),
  };
}
