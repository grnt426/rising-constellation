// Accessibility helpers installed app-wide:
//
// - `this.$announce(text)`: screen-reader announcements. Two visually
//   hidden live regions sit on <body> from boot (a region must already be
//   in the DOM when its text changes, or most screen readers stay
//   silent): polite for routine news, assertive for errors. Toasts are
//   routed through it too, since vue-toasted renders plain divs that
//   assistive tech never hears about.
// - `v-press`: turns a clickable <div>/<span> into a keyboard-operable
//   button (role, tab stop, Enter/Space fire its click). For new markup
//   prefer a real <button class="bare-button">; this is for the many
//   existing clickable divs whose styling depends on the element.
let regions = null;

function makeRegion(politeness) {
  const el = document.createElement('div');
  el.className = 'sr-only';
  el.setAttribute('aria-live', politeness);
  el.setAttribute('aria-atomic', 'true');
  document.body.appendChild(el);
  return el;
}

function ensureRegions() {
  if (!regions && typeof document !== 'undefined' && document.body) {
    regions = { polite: makeRegion('polite'), assertive: makeRegion('assertive') };
  }
  return regions;
}

// Toast messages may carry markup (i18n strings rendered with $tmd).
// DOMParser documents are inert — no script runs and no image loads —
// so this is safe to feed whatever the toast itself was given.
function plainText(message) {
  if (typeof message !== 'string') return '';
  if (!message.includes('<')) return message;
  return new DOMParser().parseFromString(message, 'text/html').body.textContent || '';
}

let pending = null;

export function announce(text, { assertive = false } = {}) {
  const r = ensureRegions();
  const message = plainText(text).trim();
  if (!r || !message) return;

  const el = assertive ? r.assertive : r.polite;
  // Clear, then set on a later task: re-announcing the same string (a
  // second "Order rejected") is otherwise a no-op change to the region.
  el.textContent = '';
  clearTimeout(pending);
  pending = setTimeout(() => { el.textContent = message; }, 60);
}

// `v-press` or `v-press="{ disabled: true }"`. A disabled element stays
// focusable (so its reason, e.g. "limit reached", can still be read) but
// is marked aria-disabled and ignores Enter/Space.
function applyPress(el, value) {
  const disabled = !!(value && value.disabled);
  el.pressDisabled = disabled;
  if (disabled) el.setAttribute('aria-disabled', 'true');
  else el.removeAttribute('aria-disabled');
}

const press = {
  bind(el, binding) {
    if (!el.hasAttribute('role')) el.setAttribute('role', 'button');
    if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '0');
    applyPress(el, binding.value);
    // Space is handled by spaceForFocusedButton below (it has to run
    // ahead of the game's hotkeys); this covers Enter, and Space wherever
    // that guard let the event through.
    el.pressKeydown = (event) => {
      if (event.target !== el || el.pressDisabled) return;
      if (event.key === 'Enter' || event.key === ' ') {
        // Space would otherwise scroll the page.
        event.preventDefault();
        el.click();
      }
    };
    el.addEventListener('keydown', el.pressKeydown);
  },
  update(el, binding) {
    applyPress(el, binding.value);
  },
  unbind(el) {
    el.removeEventListener('keydown', el.pressKeydown);
  },
};

// vue-shortkey listens on document in the capture phase and swallows
// every mapped key (preventDefault + stopPropagation) unless focus is in
// an input. In the game Space is mapped (center on agent), so Space could
// never press a focused button, native or v-press. Window capture runs
// before document capture: when a button has keyboard focus, Space is
// kept for it — a native <button> gets its default activation back, a
// role="button" element is clicked here. Only keyboard focus
// (:focus-visible): a button the mouse just clicked keeps focus too, and
// Space must still center the map for that player rather than press the
// button again.
function spaceForFocusedButton(event) {
  if (event.key !== ' ') return;
  const el = document.activeElement;
  if (!el || el === document.body || !el.matches || !el.matches(':focus-visible')) return;

  if (el.matches('button')) {
    event.stopPropagation();
  } else if (el.matches('[role="button"]')) {
    event.stopPropagation();
    event.preventDefault();
    const disabled = el.pressDisabled || el.getAttribute('aria-disabled') === 'true';
    if (event.type === 'keydown' && !event.repeat && !disabled) el.click();
  }
}

export default {
  install(Vue) {
    ensureRegions();
    Vue.prototype.$announce = announce;
    Vue.directive('press', press);

    window.addEventListener('keydown', spaceForFocusedButton, true);
    window.addEventListener('keyup', spaceForFocusedButton, true);

    // vue-toasted defines show/success/info/error as instance properties,
    // so wrapping them here covers every toast in the app, $toastError
    // included. Must run after Vue.use(VueToasted).
    const toasted = Vue.toasted;
    if (!toasted) return;
    ['show', 'success', 'info', 'error'].forEach((kind) => {
      const original = toasted[kind];
      if (typeof original !== 'function') return;
      toasted[kind] = function announcedToast(message, options) {
        announce(message, { assertive: kind === 'error' });
        return original.call(this, message, options);
      };
    });
  },
};
