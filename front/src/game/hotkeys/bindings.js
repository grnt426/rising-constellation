// Game hotkeys: the default bindings and the pure helpers that turn the
// player's saved overrides into the map Game.vue hands to v-shortkey.
//
// A binding is an array of key names in vue-shortkey's vocabulary: any of
// the modifiers, then exactly one key (['ctrl', '1'], ['esc'], ['f']). Key
// names come from KeyboardEvent.key, so a binding follows the character
// the layout produces, not the physical key. An empty array is an action
// with no shortcut.
//
// Only the differences from the defaults are saved (Account.settings.hotkeys,
// see the portal store), so a default that changes in a later release still
// reaches every action the player never touched.
//
// Two shortcut sets ("presets"), each with its own saved differences:
// - 'standard': single keys.
// - 'screen_reader': Alt + Shift + a letter. Windows screen readers (NVDA,
//   JAWS, Narrator) keep single letters for their own navigation while
//   reading a page (browse mode), so single-key shortcuts never reach the
//   game unless the player switches modes; Alt + Shift combinations go
//   through. Actions that only move the camera or draw on the map, and the
//   agent groups (Alt + Shift + digit types a symbol on most layouts), have
//   no key in this set; any of them can still be given one.
// Letters were picked to avoid Chrome's own Alt + Shift shortcuts (A, I, T).

const GROUP_NUMBERS = [1, 2, 3, 4, 5, 6, 7, 8, 9];

// `id` is what the player's overrides are keyed by and what Game.vue's
// onShortkey receives as srcKey: renaming one orphans saved bindings.
// `keys` is the standard default, `sr` the screen-reader default (none
// when absent).
const AS = (letter) => ['alt', 'shift', letter];

export const HOTKEYS = [
  { id: 'faction', keys: ['o'], sr: AS('o'), section: 'panels' },
  { id: 'empire', keys: ['s'], sr: AS('s'), section: 'panels' },
  { id: 'operations', keys: ['a'], sr: AS('d'), section: 'panels' },
  { id: 'ranking', keys: ['r'], sr: AS('r'), section: 'panels' },
  { id: 'victory', keys: ['v'], sr: AS('v'), section: 'panels' },
  { id: 'patent', keys: ['p'], sr: AS('p'), section: 'panels' },
  { id: 'doctrine', keys: ['l'], sr: AS('l'), section: 'panels' },
  { id: 'character_market', keys: ['m'], sr: AS('m'), section: 'panels' },
  { id: 'help', keys: ['h'], sr: AS('h'), section: 'panels' },
  { id: 'settings', keys: ['esc'], sr: ['esc'], section: 'panels' },

  { id: 'search', keys: ['f'], sr: AS('f'), section: 'tools' },
  { id: 'calc', keys: ['x'], sr: AS('x'), section: 'tools' },
  { id: 'copy', keys: ['c'], sr: AS('c'), section: 'tools' },
  { id: 'ruler', keys: ['z'], section: 'tools' },
  // keyboard / screen-reader play (docs/accessibility.md)
  { id: 'agent_orders', keys: ['g'], sr: AS('g'), section: 'tools' },
  { id: 'system_briefing', keys: ['b'], sr: AS('b'), section: 'tools' },

  { id: 'first_system', keys: ['home'], sr: AS('k'), section: 'navigation' },
  { id: 'next_system', keys: ['.'], sr: AS('n'), section: 'navigation' },
  { id: 'next_agent', keys: [','], sr: AS('j'), section: 'navigation' },
  { id: 'center_character', keys: ['space'], section: 'navigation' },

  ...GROUP_NUMBERS.map((n) => (
    { id: `select_group_${n}`, keys: [`${n}`], section: 'groups', label: 'select_group_n', n }
  )),
  ...GROUP_NUMBERS.map((n) => (
    { id: `create_group_${n}`, keys: ['ctrl', `${n}`], section: 'groups', label: 'create_group_n', n }
  )),
];

export const SECTIONS = ['panels', 'tools', 'navigation', 'groups'];

export const PRESETS = ['standard', 'screen_reader'];

const BY_ID = new Map(HOTKEYS.map((hotkey) => [hotkey.id, hotkey]));

// Display order. vue-shortkey reads them in its own order (see comboId).
export const MODIFIERS = ['ctrl', 'alt', 'shift', 'meta'];

// KeyboardEvent.key → vue-shortkey key name, for the keys that are not a
// single character. Lock keys, AltGraph and the media keys the library
// also knows are left out: they toggle state or never reach a page.
const NAMED_KEYS = {
  ArrowUp: 'arrowup',
  ArrowDown: 'arrowdown',
  ArrowLeft: 'arrowleft',
  ArrowRight: 'arrowright',
  Escape: 'esc',
  Enter: 'enter',
  Tab: 'tab',
  ' ': 'space',
  PageUp: 'pageup',
  PageDown: 'pagedown',
  Home: 'home',
  End: 'end',
  Delete: 'del',
  Backspace: 'backspace',
  Insert: 'insert',
  Pause: 'pause',
};

const NAMED_KEY_SET = new Set(Object.values(NAMED_KEYS));

const KEY_LABELS = {
  ctrl: 'Ctrl',
  alt: 'Alt',
  shift: 'Shift',
  meta: 'Meta',
  arrowup: '↑',
  arrowdown: '↓',
  arrowleft: '←',
  arrowright: '→',
  esc: 'Esc',
  enter: 'Enter',
  tab: 'Tab',
  space: 'Space',
  pageup: 'PgUp',
  pagedown: 'PgDn',
  home: 'Home',
  end: 'End',
  del: 'Del',
  backspace: 'Backspace',
  insert: 'Ins',
  pause: 'Pause',
};

const FUNCTION_KEY = /^f([1-9]|1\d|2[0-4])$/;

function isKeyName(name) {
  if (typeof name !== 'string' || MODIFIERS.includes(name)) return false;
  if (NAMED_KEY_SET.has(name) || FUNCTION_KEY.test(name)) return true;
  // a printable character, as vue-shortkey indexes it: lower-cased
  return name.length === 1 && name !== ' ' && name === name.toLowerCase();
}

export function isModifierKey(key) {
  return key === 'Control' || key === 'Alt' || key === 'Shift' || key === 'Meta';
}

// The binding a keydown stands for, or null when the key cannot carry one
// (a modifier on its own, a dead key, a key the library has no name for).
export function keysFromEvent(event) {
  const { key } = event;
  if (typeof key !== 'string' || isModifierKey(key)) return null;

  let name = NAMED_KEYS[key];
  if (!name) {
    const lowered = key.toLowerCase();
    if (!isKeyName(lowered)) return null;
    name = lowered;
  }

  return [...MODIFIERS.filter((modifier) => event[`${modifier}Key`]), name];
}

// A saved binding brought back to canonical form, or null when it is not
// one. Settings come from the server as plain JSON: nothing here is trusted.
export function normalizeKeys(keys) {
  if (!Array.isArray(keys)) return null;
  if (keys.length === 0) return [];

  const names = keys.filter((key) => !MODIFIERS.includes(key));
  if (names.length !== 1 || !isKeyName(names[0])) return null;

  return [...MODIFIERS.filter((modifier) => keys.includes(modifier)), names[0]];
}

// The same index vue-shortkey files a binding under (its encodeKey), so two
// bindings are equal here exactly when one would shadow the other there.
export function comboId(keys) {
  const modifiers = ['shift', 'ctrl', 'meta', 'alt'].filter((modifier) => keys.includes(modifier));
  return modifiers.join('') + keys.filter((key) => !MODIFIERS.includes(key)).join('');
}

// The keys keyboard and screen-reader players move and act with: Tab moves
// focus, Enter presses, the arrows walk lists, sliders and text. A game
// shortcut swallows its key everywhere in the game (vue-shortkey cancels it
// before any control sees it), so none of them can carry one, with or
// without modifiers.
const NAVIGATION_KEYS = ['tab', 'enter', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright'];

// Why `keys` can't be a shortcut: 'navigation' (above), 'browser' (the
// browser acts on it before the page can stop it: close tab, new tab, new
// window, quit, switch tab), or null when it can.
export function reservedReason(keys) {
  const name = keys[keys.length - 1];
  if (NAVIGATION_KEYS.includes(name)) return 'navigation';
  if (keys.includes('alt') && name === 'f4') return 'browser';
  if ((keys.includes('ctrl') || keys.includes('meta')) && ['w', 't', 'n', 'q'].includes(name)) return 'browser';
  return null;
}

export function isReserved(keys) {
  return reservedReason(keys) !== null;
}

export function defaultKeys(id, preset = 'standard') {
  const hotkey = BY_ID.get(id);
  if (!hotkey) return [];
  const keys = preset === 'screen_reader' ? hotkey.sr : hotkey.keys;
  return keys ? keys.slice() : [];
}

// Saved overrides reduced to what still means something: known actions,
// well-formed bindings that aren't reserved (one saved before a key became
// reserved falls back to the default), and not the default (implied).
export function sanitizeOverrides(overrides, preset = 'standard') {
  const clean = {};
  if (!overrides || typeof overrides !== 'object') return clean;

  HOTKEYS.forEach(({ id }) => {
    if (!Object.prototype.hasOwnProperty.call(overrides, id)) return;
    const keys = normalizeKeys(overrides[id]);
    if (!keys || (keys.length && isReserved(keys))) return;
    if (comboId(keys) !== comboId(defaultKeys(id, preset))) clean[id] = keys;
  });

  return clean;
}

// Every action's effective binding: { id: keys }, [] when it has none.
// No two actions ever share a binding. The player's own choices are placed
// first, so a default that collides with one of them (a shortcut added in
// a later release, say) is the one left without a key.
export function resolveBindings(overrides, preset = 'standard') {
  const clean = sanitizeOverrides(overrides, preset);
  const taken = new Set();
  const bindings = {};

  const place = (id, keys) => {
    const combo = comboId(keys);
    if (keys.length === 0 || taken.has(combo)) {
      bindings[id] = [];
    } else {
      taken.add(combo);
      bindings[id] = keys;
    }
  };

  HOTKEYS.forEach(({ id }) => { if (clean[id]) place(id, clean[id]); });
  HOTKEYS.forEach(({ id }) => { if (!clean[id]) place(id, defaultKeys(id, preset)); });

  return bindings;
}

// The v-shortkey value. Actions without a key are left out: the library
// would file them under the empty index, which is also what it reads from
// any key it has no name for.
// With `enabled` false (the player turned game shortcuts off) only Esc's
// action stays: it is not a character key, and it is the keyboard's only
// way to close the open system or overlay.
export function shortkeyMap(bindings, enabled = true) {
  const map = {};
  Object.keys(bindings).forEach((id) => {
    if (!bindings[id].length) return;
    if (enabled || comboId(bindings[id]) === 'esc') map[id] = bindings[id];
  });
  return map;
}

// Give `id` the binding `keys` ([] to leave it without one). Whichever
// action held that binding loses it and is reported in `displaced`.
export function rebind(overrides, id, binding, preset = 'standard') {
  const next = sanitizeOverrides(overrides, preset);
  const displaced = [];
  const keys = normalizeKeys(binding);
  if (!BY_ID.has(id) || !keys || (keys.length && isReserved(keys))) return { overrides: next, displaced };

  const bindings = resolveBindings(next, preset);
  if (keys.length) {
    const combo = comboId(keys);
    HOTKEYS.forEach((other) => {
      if (other.id !== id && bindings[other.id].length && comboId(bindings[other.id]) === combo) {
        next[other.id] = [];
        displaced.push(other.id);
      }
    });
  }
  next[id] = keys;

  return { overrides: sanitizeOverrides(next, preset), displaced };
}

export function isDefaultBinding(id, keys, preset = 'standard') {
  return comboId(keys) === comboId(defaultKeys(id, preset));
}

// ['ctrl', '1'] → ['Ctrl', '1']
export function keyLabels(keys) {
  return keys.map((key) => KEY_LABELS[key] || key.toUpperCase());
}

// ['ctrl', '1'] → 'Ctrl + 1'; '' for an action without a key.
export function bindingLabel(keys) {
  return keyLabels(keys || []).join(' + ');
}
