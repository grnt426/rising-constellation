import { DateTime } from 'luxon';

/* eslint-disable import/prefer-default-export */
import Vue from 'vue';
import formatNumber from '@/utils/format';

// number filters
Vue.filter('integer', formatNumber.integer);
Vue.filter('float', formatNumber.float);
Vue.filter('mixed', formatNumber.mixed);
Vue.filter('signed', (value) => formatNumber.integer(value, true));
Vue.filter('obfuscate', formatNumber.obfuscate);
// Per-tick income/upkeep values — scaled to per-hour (and compressed above
// five figures) when the income-per-hour display setting is active.
Vue.filter('income', formatNumber.income);
// Already-converted real-time rates — compression only.
Vue.filter('compact', formatNumber.compact);

// date filters
// Formatters are built once per format, not per call: Intl.DateTimeFormat
// construction spins up ICU state each time, and these filters run per
// row per re-render (event feeds, message lists, report tables).
const dateFormatter = (format) => {
  let formatter = null;
  return (date) => {
    if (!formatter) {
      formatter = new Intl.DateTimeFormat(navigator.language, format);
    }
    return formatter.format(new Date(date));
  };
};

const datetimeLong = dateFormatter({
  day: 'numeric',
  month: 'long',
  year: 'numeric',
  hour: 'numeric',
  minute: 'numeric',
});

Vue.filter('datetime-short', dateFormatter({
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  hour: 'numeric',
}));

Vue.filter('datetime-long', datetimeLong);

Vue.filter('date-short', dateFormatter({
  day: 'numeric',
  month: 'short',
  year: 'numeric',
}));

Vue.filter('date-long', dateFormatter({
  day: 'numeric',
  month: 'long',
  year: 'numeric',
}));

Vue.filter('counter', ((remainingSeconds) => {
  if (remainingSeconds === Infinity) {
    return '--:--:--';
  }

  const hours = Math.floor(remainingSeconds / 3600).toString();
  remainingSeconds %= 3600;
  const minutes = Math.floor(remainingSeconds / 60).toString();
  const seconds = Math.round(remainingSeconds % 60).toString();

  return `${hours.padStart(2, '0')}:${minutes.padStart(2, '0')}:${seconds.padStart(2, '0')}`;
}));

Vue.filter('luxon-std', ((timestamp) => DateTime.fromMillis(timestamp).toLocaleString(DateTime.DATETIME_MED_WITH_SECONDS)));

const { replace } = '';
const detect = /[&<>'"]/g;
const lookup = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  "'": '&#39;',
  '"': '&quot;',
};
const replacer = (character) => lookup[character];
const escape = (input) => replace.call(input, detect, replacer);
Vue.filter('escape', escape);
export { escape };
