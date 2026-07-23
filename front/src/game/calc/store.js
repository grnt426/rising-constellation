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

// `ts` (creation instant) anchors note reminders; `base` (stockpiles at
// creation) fixes `until +N` relative targets. Both persist so meanings
// survive reloads.
let nextId = 1;
const makeLine = (src, acked = false, ts = null, base = null) => ({
  id: nextId++, src, acked, ts, base,
});

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
      // entries are plain strings (v1 blobs) or { src, acked, ts, base }
      // objects — accept both shapes in both lists
      const clean = (list, max) => (Array.isArray(list) ? list : [])
        .map((entry) => (typeof entry === 'string' ? { src: entry } : entry))
        .filter((e) => e && typeof e.src === 'string' && e.src.trim().length > 0)
        .slice(-max)
        .map((e) => makeLine(e.src.slice(0, LINE_MAX_LENGTH), e.acked === true, e.ts || null, e.base || null));

      state.recent = clean(blob.recent, RECENT_MAX);
      state.saved = clean(blob.saved, SAVED_MAX);
      state.hydrated = true;
    },
    // Reminder-kind lines (notes, until, afford) go straight into the
    // persistent list so they can't be evicted by scratch history and
    // notify without any pinning step. `acked` arrives pre-computed:
    // a reminder that is already satisfied at commit starts latched
    // instead of instantly popping.
    addLine(state, { src, ts, base, reminder, acked }) {
      const line = makeLine(src.slice(0, LINE_MAX_LENGTH), acked === true, ts || null, base || null);
      if (reminder) {
        state.saved.push(line);
        if (state.saved.length > SAVED_MAX) state.saved.shift();
      } else {
        state.recent.push(line);
        if (state.recent.length > RECENT_MAX) state.recent.shift();
      }
    },
    removeRecent(state, id) {
      state.recent = state.recent.filter((l) => l.id !== id);
    },
    clearRecent(state) {
      state.recent = [];
    },
    // pin moves a line out of recent so the document doesn't hold it
    // twice; purely organizational now that reminders fire regardless
    // of which list a line lives in.
    pin(state, id) {
      const idx = state.recent.findIndex((l) => l.id === id);
      if (idx === -1) return;
      const [line] = state.recent.splice(idx, 1);
      state.saved.push(line);
      if (state.saved.length > SAVED_MAX) state.saved.shift();
    },
    // unpin removes the line from the whole document (user expectation:
    // clearing it from Financials clears it from the quick bar too)
    unpin(state, id) {
      state.saved = state.saved.filter((l) => l.id !== id);
    },
    setAcked(state, { id, acked }) {
      const line = state.saved.find((l) => l.id === id) || state.recent.find((l) => l.id === id);
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
      const pack = (l) => ({
        src: l.src, acked: l.acked === true, ts: l.ts || null, base: l.base || null,
      });
      persistDebounced(commit, {
        recent: state.recent.map(pack),
        saved: state.saved.map(pack),
      });
    },
    commitLine({ commit, dispatch }, payload) {
      commit('addLine', payload);
      dispatch('persist');
    },
    pinLine({ commit, dispatch }, id) {
      commit('pin', id);
      dispatch('persist');
    },
    // delete a line wherever it lives (quick-bar rows mix both lists)
    removeLine({ state, commit, dispatch }, id) {
      if (state.saved.some((l) => l.id === id)) commit('removeSaved', id);
      else commit('removeRecent', id);
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
