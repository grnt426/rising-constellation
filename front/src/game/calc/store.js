// Vuex module for the calculator notepad. One shared document, two views:
// the QuickCalc overlay (hotkey X) shows the tail of `recent`; the Empire →
// Financials tab shows everything. Only line sources are persisted — results
// are always recomputed live against the current game state.
//
// Persistence rides the Account.settings blob (same round-trip as the mute
// lists): settings.calc_notepad = { recent: [src], saved: [{src, acked}] }.
// Writes are debounced because every save POSTs the whole settings object.
//
// `acked` is the reminder latch on pinned lines: false = will fire a box
// notification the next time the line evaluates as reached (including the
// first evaluation after login, which is how targets completed while
// offline get presented). The QuickCalc watcher flips it back to false
// when a line un-reaches, re-arming the reminder.

import { debounce } from 'lodash';

const RECENT_MAX = 20;
const SAVED_MAX = 50;
const LINE_MAX_LENGTH = 200;

let nextId = 1;
const makeLine = (src, acked = false) => ({ id: nextId++, src, acked });

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
      // entries are plain strings (recent, and pre-acked saved blobs) or
      // { src, acked } objects — accept both shapes in both lists
      const clean = (list, max) => (Array.isArray(list) ? list : [])
        .map((entry) => (typeof entry === 'string' ? { src: entry } : entry))
        .filter((e) => e && typeof e.src === 'string' && e.src.trim().length > 0)
        .slice(-max)
        .map((e) => makeLine(e.src.slice(0, LINE_MAX_LENGTH), e.acked === true));

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
    // pin moves a line out of recent so the document doesn't hold it twice.
    // `acked` reflects whether the line is ALREADY reached at pin time —
    // pinning a completed target shouldn't immediately pop a reminder.
    pin(state, { id, acked }) {
      const idx = state.recent.findIndex((l) => l.id === id);
      if (idx === -1) return;
      const [line] = state.recent.splice(idx, 1);
      line.acked = acked === true;
      state.saved.push(line);
      if (state.saved.length > SAVED_MAX) state.saved.shift();
    },
    // unpin removes the line from the whole document (user expectation:
    // clearing it from Financials clears it from the quick bar too)
    unpin(state, id) {
      state.saved = state.saved.filter((l) => l.id !== id);
    },
    setAcked(state, { id, acked }) {
      const line = state.saved.find((l) => l.id === id);
      if (line) line.acked = acked;
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
        saved: state.saved.map((l) => ({ src: l.src, acked: l.acked === true })),
      });
    },
    commitLine({ commit, dispatch }, src) {
      commit('addRecent', src);
      dispatch('persist');
    },
    pinLine({ commit, dispatch }, payload) {
      commit('pin', payload);
      dispatch('persist');
    },
    ackLine({ commit, dispatch }, payload) {
      commit('setAcked', payload);
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
