// A scenario script's length of time as scripts write it: 900 -> "15m",
// 5400 -> "1h30m", 90 -> "1m30s".
export default function scriptDuration(seconds) {
  const s = Math.round(seconds);
  const parts = [[Math.floor(s / 3600), 'h'], [Math.floor((s % 3600) / 60), 'm'], [s % 60, 's']]
    .filter(([n]) => n > 0)
    .map(([n, unit]) => `${n}${unit}`);
  return parts.length ? parts.join('') : '0s';
}
