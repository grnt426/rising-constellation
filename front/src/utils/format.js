// Number formatting for the game UI.
//
// The locale used here is independent of the i18n language so a user can play
// in (say) English but display numbers FR-style (1.234.567,89) or vice
// versa. The portal Settings page lets the user pick. Defaults follow the
// language; the user can override.
//
// Reactivity: `state.locale` is a Vue.observable. Filters access it during
// render, so Vue's dependency tracker registers each rendering component as
// a dep — switching the format via setNumberLocale will trigger a re-render
// of every component that currently displays a formatted number, with no
// per-call-site changes required.

import Vue from 'vue';

const LOCALE_FOR_LANG = {
  en: 'en-US',
  fr: 'fr-FR',
  de: 'de-DE',
};

// Reactive state. Mutated by setNumberLocale; read by every formatter.
const state = Vue.observable({ locale: LOCALE_FOR_LANG.en });

// Intl.NumberFormat instances are expensive to construct, so cache them per
// (locale, fractionDigits) pair. Cleared when the user changes format.
const formatterCache = new Map();

function getFormatter(decimals) {
  const locale = state.locale; // triggers reactive dep registration
  const key = `${locale}|${decimals}`;
  let f = formatterCache.get(key);
  if (!f) {
    f = new Intl.NumberFormat(locale, {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
      useGrouping: true,
    });
    formatterCache.set(key, f);
  }
  return f;
}

export function setNumberLocale(lang) {
  const next = LOCALE_FOR_LANG[lang];
  if (!next || next === state.locale) return;
  state.locale = next;
  formatterCache.clear();
}

export function getNumberLocaleLang() {
  // Reverse-lookup the lang key from the active locale. Useful for the
  // Settings page so we don't have to thread the lang through everywhere.
  return Object.keys(LOCALE_FOR_LANG)
    .find((k) => LOCALE_FOR_LANG[k] === state.locale) || 'en';
}

const addSign = (value = '0', bothSign) => {
  if (bothSign && !value.startsWith('-') && !value.startsWith('−')) {
    return `+${value}`;
  }
  // Replace ASCII minus with the typographic minus the rest of the UI uses.
  return value.replace('-', '−');
};

const integer = (value = 0, bothSign = false) => addSign(
  getFormatter(0).format(Math.round(value)),
  bothSign,
);

const float = (value = 0, decimals = 2, bothSign = false) => addSign(
  getFormatter(decimals).format(value),
  bothSign,
);

const obfuscate = (value = 0, number, hidden) => (value === null || value === 'hidden'
  ? hidden
  : number);

const mixed = (value = 0, decimals = 1, bothSign = false) => (Number.isInteger(value)
  ? integer(value, bothSign)
  : float(value, decimals, bothSign));

// Spell out a duration in whole units ("2d 7h", "4h 51min", "6min 51s").
// Coarse on purpose: once days are shown minutes are noise, once hours are
// shown seconds are noise. `t` is an i18n translate function; the unit
// templates live under `duration.*` in the game locale files.
export function formatDuration(seconds, t) {
  const s = Math.max(0, Math.round(seconds));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const secs = s % 60;

  const parts = [];
  if (days > 0) parts.push(t('duration.day', { n: days }));
  if (hours > 0) parts.push(t('duration.hour', { n: hours }));
  if (minutes > 0 && days === 0) parts.push(t('duration.minute', { n: minutes }));
  if (secs > 0 && days === 0 && hours === 0) parts.push(t('duration.second', { n: secs }));

  if (parts.length === 0) return t('duration.second', { n: 0 });
  return parts.join(' ');
}

// Example string for the Settings page preview. Always renders the same
// reference number (1,000,000.00 in EN) under the *given* lang's locale,
// regardless of which locale is currently active.
export function exampleForLang(lang) {
  const locale = LOCALE_FOR_LANG[lang] || LOCALE_FOR_LANG.en;
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
    useGrouping: true,
  }).format(1000000);
}

export default {
  addSign,
  integer,
  float,
  obfuscate,
  mixed,
};
