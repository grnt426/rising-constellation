// The Scenario Workshop's code editor settings (Settings → Scenario editor),
// saved in Account.settings.scenario_editor.

// The key that accepts a suggestion. Tab is the usual; the others are there
// because Tab is also how screen readers and keyboard users move between
// controls, and some browsers or extensions take it.
export const ACCEPT_KEYS = ['tab', 'enter', 'shift+enter', 'shift+tab'];

export function normalizeScenarioEditor(saved) {
  const s = saved && typeof saved === 'object' ? saved : {};
  return {
    accept: ACCEPT_KEYS.includes(s.accept) ? s.accept : 'tab',
    // suggestions open as you type; off, only Ctrl+Space opens them
    suggest: s.suggest !== false,
  };
}

// Whether a keydown is the accept key.
export function isAcceptKey(e, accept) {
  if (e.ctrlKey || e.altKey || e.metaKey) return false;
  switch (accept) {
    case 'enter': return e.key === 'Enter' && !e.shiftKey;
    case 'shift+enter': return e.key === 'Enter' && e.shiftKey;
    case 'shift+tab': return e.key === 'Tab' && e.shiftKey;
    default: return e.key === 'Tab' && !e.shiftKey;
  }
}
