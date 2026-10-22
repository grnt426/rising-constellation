// A Scenario Workshop playtest runs as a daily-style game; this marks the
// instance so the game's exits go back to the workshop instead of the daily
// page. Session storage: it survives a reload of the tab, not the tab.
const KEY = 'edict.playtest.instance';

export function markPlaytest(instanceId) {
  try {
    sessionStorage.setItem(KEY, String(instanceId));
  } catch (e) {
    // blocked storage: exits fall back to the daily page
  }
}

export function isPlaytest(instanceId) {
  try {
    return instanceId != null && sessionStorage.getItem(KEY) === String(instanceId);
  } catch (e) {
    return false;
  }
}
