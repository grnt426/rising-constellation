// Vuex module for the in-game help manual. One bundle per (language,
// speed), fetched lazily from GET /api/help/:lang the first time a help
// surface needs it (or eagerly by Game.vue once the instance speed is
// known, so the "?" buttons can decide whether their page exists).
//
// Gated by the `help_manual` account beta: while it is off, `enabled` is
// false, nothing is fetched and every "?" stays hidden.

import { createAxiosInstance } from '@/plugins/axios';
import { i18n } from '@/plugins/i18n';

let axios = null;

const helpStore = {
  namespaced: true,
  state: {
    bundle: null, // { lang, speed, pages: [], categories: [], glossary: [] }
    loading: false,
    error: null,
    requested: null, // `${lang}/${speed}` of the in-flight or loaded bundle
  },
  getters: {
    enabled(state, getters, rootState) {
      const features = rootState.portal.features || {};
      return features.help_manual === true;
    },
    // Instance speed the manual should show numbers for. Dailies use Legacy content.
    speed(state, getters, rootState) {
      const speed = rootState.game.time && rootState.game.time.speed;
      return speed && speed !== 'daily' ? speed : 'slow';
    },
    pagesBySlug(state) {
      const map = {};
      if (state.bundle) state.bundle.pages.forEach((p) => { map[p.slug] = p; });
      return map;
    },
    aliases(state) {
      const map = {};
      if (state.bundle) {
        state.bundle.pages.forEach((p) => {
          (p.aliases || []).forEach((a) => { map[a] = p.slug; });
        });
      }
      return map;
    },
    resolve: (state, getters) => (slug) => {
      if (!slug) return null;
      if (getters.pagesBySlug[slug]) return slug;
      return getters.aliases[slug] || null;
    },
    page: (state, getters) => (slug) => {
      const canonical = getters.resolve(slug);
      return canonical ? getters.pagesBySlug[canonical] : null;
    },
    available: (state, getters) => (slug) => getters.enabled && !!getters.page(slug),
  },
  mutations: {
    loading(state, key) {
      state.loading = true;
      state.error = null;
      state.requested = key;
    },
    loaded(state, bundle) {
      state.bundle = bundle;
      state.loading = false;
    },
    failed(state, error) {
      state.loading = false;
      state.error = error;
    },
  },
  actions: {
    // Idempotent: a second call for the same lang/speed is a no-op, a call
    // for a different speed (instance changed) refetches.
    async load({ state, getters, commit }) {
      if (!getters.enabled) return;
      const lang = i18n.locale || 'en';
      const speed = getters.speed;
      const key = `${lang}/${speed}`;
      if (state.requested === key && (state.loading || state.bundle)) return;

      commit('loading', key);
      try {
        if (!axios) axios = createAxiosInstance();
        const { data } = await axios.get(`/help/${lang}`, { params: { speed } });
        // Ignore a stale response if the speed changed while loading.
        if (state.requested === key) commit('loaded', data);
      } catch (e) {
        if (state.requested === key) commit('failed', e);
      }
    },
  },
};

export default helpStore;
