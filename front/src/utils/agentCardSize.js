import Vue from 'vue';

// Phone agent cards come in two sizes: compact (the 234px mobile card,
// orders beside it) and expanded (the desktop card scaled to the
// screen's width, orders and fleet under it). The selected-agent sheet
// and the system screen's agent dock share the choice, and it is kept
// per device: whoever prefers the big card wants it everywhere.

const KEY = 'rc:agent-card-expanded';

function read() {
  try {
    return window.localStorage.getItem(KEY) === '1';
  } catch (e) {
    return false; // private mode / blocked site data
  }
}

const state = Vue.observable({ expanded: read() });

export default {
  get expanded() { return state.expanded; },
  toggle() {
    state.expanded = !state.expanded;
    try {
      window.localStorage.setItem(KEY, state.expanded ? '1' : '0');
    } catch (e) {
      // the toggle still works for this session
    }
  },
};
