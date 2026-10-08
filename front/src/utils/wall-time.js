// A wall-clock instant as a short local time, with only as much date as its
// distance from `now` needs: "14:05" within the day ahead, "Thu 14:05"
// within the week, "Thu, Oct 15, 14:05" beyond.

// Three fixed opts variants × locale. Cached because Intl.DateTimeFormat
// construction is expensive and callers format on a 1 s pulse.
const cache = new Map();

export function formatWallTime(ms, now, locale) {
  const delta = ms - now;
  const opts = { hour: '2-digit', minute: '2-digit', hour12: false };
  let variant = 'time';
  if (delta >= 20 * 3600 * 1000) {
    opts.weekday = 'short';
    variant = 'weekday';
  }
  if (delta >= 6 * 86400 * 1000) {
    opts.day = 'numeric';
    opts.month = 'short';
    variant = 'date';
  }

  const key = `${locale}:${variant}`;
  let formatter = cache.get(key);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat(locale, opts);
    cache.set(key, formatter);
  }
  return formatter.format(new Date(ms));
}

export default formatWallTime;
