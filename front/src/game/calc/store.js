// Vuex module for the calculator notepad. One shared document, two views:
// the QuickCalc overlay (hotkey X) shows the tail of `recent`; the Empire →
// Financials tab shows everything. Only line sources are persisted — results
// are always recomputed live against the current game state.
//
// Persistence rides the Account.settings blob (same round-trip as the mute
// lists): settings.calc_notepad = { recent: [src], saved: [src] }. Writes
// are debounced because every save POSTs the whole settings object.

import { debounce } from 'lodash';

const RECENT_MAX = 20;
const SAVED_MAX = 50;
const LINE_MAX_LENGTH = 200;

let nextId = 1;
const makeLine = (src) => ({ id: nextId++, src });

const persistDebounced = debounce((commit, payload) => {
  commit('portal/updateSettings', { calc_notepad: payload }, { root: true });
}, 1500);

const calcStore = {
  namespaced: true,
  state: {
    hydrated: false,
    recent: [], // [{ id, src }] oldest first
    saved: [], // [{ id, src }] pin order
  },
  mutations: {
    hydrate(state, blob) {
      const clean = (list, max) => (Array.isArray(list) ? list : [])
        .filter((src) => typeof src === 'string' && src.trim().length > 0)
        .slice(-max)
        .map((src) => makeLine(src.slice(0, LINE_MAX_LENGTH)));

      state.recent = clean(blob.recent, RECENT_MAX);
      state.saved = clean(blob.saved, SAVED_MAX);
      state.hydrated = true;
    },
    addRecent(state, src) {
      state.recent.push(makeLine(src.slice(0, LINE_MAX_LENGTH)));
      if (state.recent.length > RECENT_MAX) state.recent.shift();
    },
    removeRecent(state, id) {
      state.recent = state.recent.filter((l) => l.id !== id);
    },
    clearRecent(state) {
      state.recent = [];
    },
    // pin moves a line out of recent so the document doesn't hold it twice
    pin(state, id) {
      const idx = state.recent.findIndex((l) => l.id === id);
      if (idx === -1) return;
      const [line] = state.recent.splice(idx, 1);
      state.saved.push(line);
      if (state.saved.length > SAVED_MAX) state.saved.shift();
    },
    unpin(state, id) {
      const idx = state.saved.findIndex((l) => l.id === id);
      if (idx === -1) return;
      const [line] = state.saved.splice(idx, 1);
      state.recent.push(line);
      if (state.recent.length > RECENT_MAX) state.recent.shift();
    },
    removeSaved(state, id) {
      state.saved = state.saved.filter((l) => l.id !== id);
    },
  },
  actions: {
    hydrate({ state, commit, rootState }) {
      if (state.hydrated) return;
      const blob = (rootState.portal.settings && rootState.portal.settings.calc_notepad) || {};
      commit('hydrate', blob);
    },
    persist({ state, commit }) {
      persistDebounced(commit, {
        recent: state.recent.map((l) => l.src),
        saved: state.saved.map((l) => l.src),
      });
    },
    commitLine({ commit, dispatch }, src) {
      commit('addRecent', src);
      dispatch('persist');
    },
    pinLine({ commit, dispatch }, id) {
      commit('pin', id);
      dispatch('persist');
    },
    unpinLine({ commit, dispatch }, id) {
      commit('unpin', id);
      dispatch('persist');
    },
    removeRecentLine({ commit, dispatch }, id) {
      commit('removeRecent', id);
      dispatch('persist');
    },
    removeSavedLine({ commit, dispatch }, id) {
      commit('removeSaved', id);
      dispatch('persist');
    },
    clearRecentLines({ commit, dispatch }) {
      commit('clearRecent');
      dispatch('persist');
    },
  },
};

export default calcStore;
