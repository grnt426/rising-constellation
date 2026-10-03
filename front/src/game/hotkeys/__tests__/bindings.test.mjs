// Hotkey binding helpers — plain node, no webpack:
//   node --test front/src/game/hotkeys/__tests__/bindings.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  HOTKEYS, SECTIONS, keysFromEvent, normalizeKeys, comboId, isReserved, sanitizeOverrides,
  resolveBindings, shortkeyMap, rebind, isDefaultBinding, keyLabels, bindingLabel,
} from '../bindings.js';

// vue-shortkey 3.1.7's own index for a keydown (src/index.js,
// createShortcutIndex), restricted to the keys keysFromEvent accepts. A
// captured binding only fires if both sides agree on it.
function libraryIndexOfEvent(event) {
  let k = '';
  if (event.key === 'Shift' || event.shiftKey) k += 'shift';
  if (event.key === 'Control' || event.ctrlKey) k += 'ctrl';
  if (event.key === 'Meta' || event.metaKey) k += 'meta';
  if (event.key === 'Alt' || event.altKey) k += 'alt';
  const named = {
    ArrowUp: 'arrowup',
    ArrowLeft: 'arrowleft',
    ArrowRight: 'arrowright',
    ArrowDown: 'arrowdown',
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
  if (named[event.key]) k += named[event.key];
  if ((event.key && event.key !== ' ' && event.key.length === 1) || /F\d{1,2}|\//g.test(event.key)) {
    k += event.key.toLowerCase();
  }
  return k;
}

const press = (key, modifiers = {}) => ({
  key, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...modifiers,
});

test('defaults are well-formed and never collide', () => {
  const combos = new Set();
  HOTKEYS.forEach(({ id, keys, section }) => {
    assert.deepEqual(normalizeKeys(keys), keys, id);
    assert.ok(SECTIONS.includes(section), id);
    assert.ok(!combos.has(comboId(keys)), `${id} reuses ${keys}`);
    combos.add(comboId(keys));
  });
  assert.equal(new Set(HOTKEYS.map((h) => h.id)).size, HOTKEYS.length);
});

test('with no overrides every action keeps its default', () => {
  const bindings = resolveBindings(undefined);
  HOTKEYS.forEach(({ id, keys }) => assert.deepEqual(bindings[id], keys));
  assert.deepEqual(resolveBindings(null), bindings);
  assert.deepEqual(resolveBindings('nope'), bindings);
  assert.equal(Object.keys(shortkeyMap(bindings)).length, HOTKEYS.length);
});

test('a keydown becomes a binding vue-shortkey indexes the same way', () => {
  const events = [
    press('g'),
    press('G', { shiftKey: true }),
    press('!', { shiftKey: true }),
    press('1', { ctrlKey: true }),
    press('k', { ctrlKey: true, altKey: true, shiftKey: true, metaKey: true }),
    press(' '),
    press(' ', { shiftKey: true }),
    press('Escape'),
    press('Home'),
    press('ArrowLeft', { altKey: true }),
    press('Delete'),
    press('F5'),
    press('F12', { ctrlKey: true }),
    press('/'),
    press('.'),
    press('é'),
    press('ф'),
  ];
  events.forEach((event) => {
    const keys = keysFromEvent(event);
    assert.ok(keys, `no binding for ${event.key}`);
    assert.equal(comboId(keys), libraryIndexOfEvent(event), event.key);
    assert.deepEqual(normalizeKeys(keys), keys, event.key);
  });

  assert.deepEqual(keysFromEvent(press('G', { shiftKey: true })), ['shift', 'g']);
  assert.deepEqual(keysFromEvent(press('1', { ctrlKey: true })), ['ctrl', '1']);
  assert.deepEqual(keysFromEvent(press(' ')), ['space']);
});

test('keys that cannot carry a binding are refused', () => {
  ['Shift', 'Control', 'Alt', 'Meta', 'Dead', 'Unidentified', 'CapsLock', 'AltGraph',
    'AudioVolumeUp', 'Process', 'F25'].forEach((key) => {
    assert.equal(keysFromEvent(press(key)), null, key);
  });
  assert.equal(keysFromEvent({}), null);
});

test('saved bindings are validated and put in canonical order', () => {
  assert.deepEqual(normalizeKeys(['k', 'shift', 'ctrl']), ['ctrl', 'shift', 'k']);
  assert.deepEqual(normalizeKeys([]), []);
  [null, 'k', ['ctrl'], ['a', 'b'], ['K'], [' '], ['ctrl', 7], ['capslock'], ['f25'], [''],
    { 0: 'k' }].forEach((bad) => assert.equal(normalizeKeys(bad), null, JSON.stringify(bad)));
});

test('overrides keep only known actions, valid bindings and real changes', () => {
  assert.deepEqual(
    sanitizeOverrides({
      empire: ['e'],
      faction: ['o'], // the default: implied
      ranking: [], // explicitly unbound
      help: ['ctrl'], // not a binding
      nonsense: ['q'],
      copy: 'c',
    }),
    { empire: ['e'], ranking: [] },
  );
});

test('rebinding to a free key only touches that action', () => {
  const { overrides, displaced } = rebind({}, 'empire', ['e']);
  assert.deepEqual(overrides, { empire: ['e'] });
  assert.deepEqual(displaced, []);

  const bindings = resolveBindings(overrides);
  assert.deepEqual(bindings.empire, ['e']);
  assert.deepEqual(bindings.operations, ['a']);
  assert.equal(shortkeyMap(bindings).empire, bindings.empire);
});

test('taking a key leaves its previous owner without one', () => {
  const { overrides, displaced } = rebind({}, 'empire', ['a']);
  assert.deepEqual(displaced, ['operations']);
  assert.deepEqual(overrides, { empire: ['a'], operations: [] });

  const bindings = resolveBindings(overrides);
  assert.deepEqual(bindings.empire, ['a']);
  assert.deepEqual(bindings.operations, []);
  assert.ok(!('operations' in shortkeyMap(bindings)));
});

test('two rebinds swap a pair of keys', () => {
  const first = rebind({}, 'empire', ['a']);
  const second = rebind(first.overrides, 'operations', ['s']);
  assert.deepEqual(second.displaced, []);
  assert.deepEqual(second.overrides, { empire: ['a'], operations: ['s'] });
});

test('restoring a default drops the override and evicts the squatter', () => {
  let { overrides } = rebind({}, 'empire', ['e']);
  ({ overrides } = rebind(overrides, 'ranking', ['s']));
  const restored = rebind(overrides, 'empire', ['s']);
  assert.deepEqual(restored.displaced, ['ranking']);
  assert.deepEqual(restored.overrides, { ranking: [] });
  assert.deepEqual(resolveBindings(restored.overrides).empire, ['s']);
});

test('an action can be left without a key, and invalid requests change nothing', () => {
  const cleared = rebind({}, 'center_character', []);
  assert.deepEqual(cleared.overrides, { center_character: [] });
  assert.deepEqual(resolveBindings(cleared.overrides).center_character, []);

  assert.deepEqual(rebind({ empire: ['e'] }, 'empire', ['shift']).overrides, { empire: ['e'] });
  assert.deepEqual(rebind({ empire: ['e'] }, 'nonsense', ['q']).overrides, { empire: ['e'] });
});

test('bindings never collide, whatever was saved', () => {
  // two overrides on one key (hand-edited settings): the first action wins
  const dirty = resolveBindings({ empire: ['g'], ranking: ['g'] });
  assert.deepEqual(dirty.empire, ['g']);
  assert.deepEqual(dirty.ranking, []);

  // an override on another action's default: the player's choice wins
  const shadowed = resolveBindings({ ranking: ['s'] });
  assert.deepEqual(shadowed.ranking, ['s']);
  assert.deepEqual(shadowed.empire, []);

  [dirty, shadowed].forEach((bindings) => {
    const combos = Object.values(shortkeyMap(bindings)).map(comboId);
    assert.equal(new Set(combos).size, combos.length);
    assert.ok(!combos.includes(''));
  });
});

test('modifier order does not make two bindings different', () => {
  assert.equal(comboId(['ctrl', 'shift', 'k']), comboId(['shift', 'ctrl', 'k']));
  const { displaced } = rebind({ empire: ['ctrl', 'shift', 'k'] }, 'ranking', ['shift', 'ctrl', 'k']);
  assert.deepEqual(displaced, ['empire']);
});

test('browser-owned combinations are flagged', () => {
  [['ctrl', 'w'], ['ctrl', 'shift', 't'], ['meta', 'n'], ['meta', 'q'], ['ctrl', 'tab'], ['alt', 'f4']]
    .forEach((keys) => assert.ok(isReserved(keys), keys.join('+')));
  [['w'], ['shift', 't'], ['ctrl', '1'], ['f4'], ['alt', 'w'], ['tab']]
    .forEach((keys) => assert.ok(!isReserved(keys), keys.join('+')));
});

test('labels', () => {
  assert.deepEqual(keyLabels(['ctrl', '1']), ['Ctrl', '1']);
  assert.equal(bindingLabel(['ctrl', 'shift', 'k']), 'Ctrl + Shift + K');
  assert.equal(bindingLabel(['esc']), 'Esc');
  assert.equal(bindingLabel(['f5']), 'F5');
  assert.equal(bindingLabel(['arrowleft']), '←');
  assert.equal(bindingLabel([]), '');
  assert.equal(bindingLabel(undefined), '');
  assert.ok(isDefaultBinding('empire', ['s']));
  assert.ok(!isDefaultBinding('empire', []));
});
