// Number helpers shared by the Legacy archive charts.

function trim(n) {
  const r = Math.abs(n) >= 100 ? Math.round(n) : Math.round(n * 10) / 10;
  return `${r}`;
}

// 1,284 / 12.9k / 4.2M — compact enough for axis ticks and tooltips.
export function compact(v) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  const a = Math.abs(v);
  if (a >= 1e9) return `${trim(v / 1e9)}B`;
  if (a >= 1e6) return `${trim(v / 1e6)}M`;
  if (a >= 1e4) return `${trim(v / 1e3)}k`;
  if (a >= 100) return Math.round(v).toLocaleString('en-US');
  return trim(v);
}

export function percent(v) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  return `${Math.round(v * 100)}%`;
}

function niceStep(range, count) {
  const raw = range / Math.max(1, count);
  const mag = 10 ** Math.floor(Math.log10(raw));
  const norm = raw / mag;
  let step = 10;
  if (norm <= 1) step = 1;
  else if (norm <= 2) step = 2;
  else if (norm <= 2.5) step = 2.5;
  else if (norm <= 5) step = 5;
  return step * mag;
}

// Clean tick values covering [min, max]; the domain snaps to the outer ticks.
export function niceTicks(min, max, count = 4) {
  let lo = min;
  let hi = max;
  if (hi === lo) hi = lo + 1;
  const step = niceStep(hi - lo, count);
  lo = Math.floor(lo / step) * step;
  hi = Math.ceil(hi / step) * step;
  const ticks = [];
  for (let t = lo; t <= hi + step / 2; t += step) ticks.push(Math.round(t * 1e6) / 1e6);
  return ticks;
}

export function lastValue(values) {
  if (!values) return null;
  for (let i = values.length - 1; i >= 0; i -= 1) {
    if (values[i] !== null && values[i] !== undefined) return values[i];
  }
  return null;
}

export function sum(values) {
  return (values || []).reduce((acc, v) => acc + (v || 0), 0);
}

// Vue 2 would walk and reactify every nested array of a match payload;
// the archive is read-only, so freeze it once on arrival.
export function deepFreeze(obj) {
  if (obj && typeof obj === 'object' && !Object.isFrozen(obj)) {
    Object.values(obj).forEach(deepFreeze);
    Object.freeze(obj);
  }
  return obj;
}
