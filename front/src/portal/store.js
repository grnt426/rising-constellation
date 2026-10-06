// import { App, Window } from 'nw.gui';
import { createAxiosInstance } from '@/plugins/axios';
import { loadLanguage, setLanguage, defaultLanguage } from '@/plugins/i18n';
import { ambiance } from '@/plugins/ambiance';
import { setNumberLocale, setIncomePerHour } from '@/utils/format';
import { resolveBindings, bindingLabel, PRESETS } from '@/game/hotkeys/bindings';
import { normalizeCrosshair } from '@/utils/crosshair';

// Where each shortcut set's saved differences live in Account.settings.
const HOTKEY_OVERRIDES_KEY = { standard: 'hotkeys', screen_reader: 'hotkeys_screen_reader' };
import config from '@/config';

let axios;

const portalStore = {
  namespaced: true,
  state: {
    isSignedIn: null,
    isInMaintenance: null,
    // Server deployment in flight (RC.Deploy flag, portal:user:* socket).
    // Drives the news-marquee override and the in-game deploy headband.
    deployOngoing: false,
    // The game server's build {version, live_since, deploying} (RC.Build),
    // from the portal:user:* join reply: as first seen when this tab
    // loaded, and as of the latest rejoin. utils/build.js compares them
    // with this bundle's own revision.
    serverBuildAtLoad: null,
    serverBuild: null,
    hasConnectivity: true,

    isAdmin: false,
    account: undefined,
    activeProfile: null,
    data: {},
    apiToken: '',

    // opt-in beta feature flags: { feature_key: boolean }
    features: {},

    settings: {
      ambiance: ambiance.settings,
      // Declared up front so Vue 2 tracks it: initSettings/updateSettings
      // Object.assign into this object, and a key added that way is not
      // reactive (the help manual's per tick / per hour switch read a stale
      // value until reload).
      incomePerHour: false,
      // Pre-declared so the key is reactive from the start: updateSettings
      // merges with Object.assign, and Vue 2 can't detect keys added to a
      // reactive object after the fact — the in-game list panels' height
      // computeds would go stale on the first resize of a fresh account.
      list_heights: {},
      // Rebound game hotkeys, { action id: keys }: only what differs from
      // the defaults in game/hotkeys/bindings.js. Declared up front for the
      // same reason, and always replaced whole (see setHotkeys). One map
      // per shortcut set: `hotkeys` for 'standard', `hotkeys_screen_reader`
      // for the screen-reader set.
      hotkeys: {},
      hotkeys_screen_reader: {},
      // Which shortcut set is in use, and whether game shortcuts are on at
      // all (off leaves Esc only). Help → Keyboard shortcuts.
      hotkeys_preset: 'standard',
      hotkeys_enabled: true,
      // The galaxy map's crosshair (utils/crosshair.js; Settings → Galaxy
      // crosshair). Declared up front for the same reason, and always
      // replaced whole (see setCrosshair).
      crosshair: {},
    },
    conversations: [],
  },
  getters: {
    conversations(state) {
      return (instanceId) => {
        const conversations = instanceId
          ? state.conversations.filter((c) => c.iid === instanceId)
          : state.conversations.filter((c) => c.iid === null);

        return Array.from(conversations)
          .sort((a, b) => new Date(b.last_message_update) - new Date(a.last_message_update));
      };
    },
    unreadMessages(state) {
      return (instanceId) => {
        const conversations = instanceId
          ? state.conversations.filter((c) => c.iid === instanceId && c.unread > 0)
          : state.conversations.filter((c) => c.iid === null && c.unread > 0);

        return conversations.reduce((acc, c) => acc + c.unread, 0);
      };
    },
    conversation(state) {
      return (conversationId) => state.conversations.find(({ id }) => id === conversationId);
    },
    // Per-account mutes live in `Account.settings` (already round-trips
    // via /accounts/settings) and are keyed by profile_id — cross-game
    // stable, unlike the in-game display name. Two independent lists:
    // `muted_chat` filters faction chat (client-side) and Messenger
    // DMs (server-side drop). `muted_icons` filters map markers
    // (client-side). Getters return curried predicates so components
    // can write `isChatMuted(player.id)` inline in `v-show` etc.
    mutedChatIds: (state) => state.settings.muted_chat || [],
    mutedIconIds: (state) => state.settings.muted_icons || [],
    isChatMuted: (state) => (profileId) =>
      (state.settings.muted_chat || []).includes(profileId),
    isIconMuted: (state) => (profileId) =>
      (state.settings.muted_icons || []).includes(profileId),
    // Height cap of the in-game bottom-anchored lists ('systems' |
    // 'agents'), as a percent of the between-navbars content area.
    // Stored per-account in `Account.settings.list_heights` (written by
    // the panels' resize grip, rounded to hundredths); clamped here so a
    // corrupt or out-of-range stored value can never wedge a panel into
    // an unreachable size.
    listHeightPct: (state) => (key) => {
      const stored = (state.settings.list_heights || {})[key];
      const pct = typeof stored === 'number' ? stored : parseFloat(stored);
      if (!Number.isFinite(pct)) return 60;
      return Math.min(85, Math.max(15, pct));
    },
    hotkeyPreset: (state) => (PRESETS.includes(state.settings.hotkeys_preset)
      ? state.settings.hotkeys_preset : 'standard'),
    hotkeysEnabled: (state) => state.settings.hotkeys_enabled !== false,
    // The active set's saved differences from its defaults.
    hotkeyOverrides: (state, getters) => state.settings[HOTKEY_OVERRIDES_KEY[getters.hotkeyPreset]] || {},
    // Every game hotkey's effective binding in the active set, { action id:
    // keys }. Account-level like the rest of the settings, so it holds in
    // every game mode.
    hotkeys: (state, getters) => resolveBindings(getters.hotkeyOverrides, getters.hotkeyPreset),
    // ' (Z)' to append where a label names an action's key, or '' when the
    // player left that action without one or turned shortcuts off.
    hotkeyHint: (state, getters) => (id) => {
      const label = getters.hotkeysEnabled ? bindingLabel(getters.hotkeys[id]) : '';
      return label ? ` (${label})` : '';
    },
    // The galaxy map's crosshair, complete and in range whatever is saved:
    // an account that never changed it gets the original black lines.
    crosshair: (state) => normalizeCrosshair(state.settings.crosshair),
  },
  mutations: {
    isSignedIn(state, payload) {
      state.isSignedIn = payload;
    },
    isInMaintenance(state, payload) {
      state.isInMaintenance = payload;
    },
    deployOngoing(state, payload) {
      state.deployOngoing = payload === true;
    },
    serverBuild(state, build) {
      if (!build || typeof build !== 'object') return;
      state.serverBuild = Object.freeze({ ...build });
      if (!state.serverBuildAtLoad) state.serverBuildAtLoad = state.serverBuild;
    },
    hasConnectivity(state, payload) {
      state.hasConnectivity = payload;
    },
    isAdmin(state, payload) {
      state.isAdmin = payload;
    },
    account(state, payload) {
      state.account = payload;

      if (state.account && state.account.email && state.account.email.endsWith('@steam')) {
        const [steamId] = state.account.email.split('@');
        state.account.steam_id = steamId;
        state.account.email = '';
      }
    },
    updateAccountMoney(state, amount) {
      state.account.money += amount;
    },
    features(state, payload) {
      state.features = payload || {};
    },
    updateData(state, payload) {
      state.data = payload;
    },
    apiToken(state, payload) {
      state.apiToken = payload;
    },
    initSettings(state) {
      if (!state.account.settings.lang) {
        state.account.settings.lang = state.settings.lang;
      }

      Object.assign(state.settings, state.account.settings);
      if (!state.settings.lang) {
        state.settings.lang = 'en';
      } else {
        localStorage.setItem('lang', state.settings.lang);
      }

      // Number format defaults to the language's customary format. The user
      // can override via the Settings page; the override sticks until they
      // change language again, at which point it re-syncs.
      if (!state.settings.numberFormat) {
        state.settings.numberFormat = state.settings.lang;
      }

      // Income display defaults to per-tick; sync the format module with the
      // persisted preference (only takes visual effect on Legacy instances).
      setIncomePerHour(state.settings.incomePerHour === true);

      // Default resource-copy flavor for the in-game C hotkey. Plaintext
      // (padded, Discord-friendly) replaced the old spreadsheet grid as
      // the default; the grid remains selectable.
      if (!state.settings.resourceCopyMode) {
        state.settings.resourceCopyMode = 'plaintext';
      }

      if (config.IS_STEAM) {
        const nwin = Window.get();
        nwin.zoomLevel = state.account.settings.uiScale || 0;
      }

      ambiance.init(state.settings.ambiance, 'portal');
    },
    initActiveProfile(state, profiles) {
      if (profiles.length > 0) {
        if (state.settings.activeProfileId) {
          const profile = profiles.find((p) => p.id === state.settings.activeProfileId);
          state.activeProfile = profile;
        } else {
          state.activeProfile = profiles[0];
        }
        this._vm.$socket.connectProfile(state.activeProfile.id);
      }
    },
    updateSettings(state, payload) {
      Object.assign(state.settings, payload);
      axios.post('/accounts/settings', { settings: state.settings });
    },
    // Flip a profile id in/out of one of the two mute lists and
    // round-trip the full settings blob through the same endpoint
    // updateSettings uses. `kind` is 'chat' | 'icons' — keeps callers
    // honest without exposing the underlying storage keys.
    toggleMute(state, { kind, profileId }) {
      const key = kind === 'chat' ? 'muted_chat' : 'muted_icons';
      const current = state.settings[key] || [];
      const idx = current.indexOf(profileId);
      const next = current.slice();
      if (idx >= 0) {
        next.splice(idx, 1);
      } else {
        next.push(profileId);
      }
      state.settings[key] = next;
      axios.post('/accounts/settings', { settings: state.settings });
    },
    addConversations(state, conversations) {
      conversations.forEach((conversation) => {
        if (!state.conversations.find(({ id: conversationId }) => conversationId === conversation.id)) {
          if (!conversation.messages) {
            conversation.messages = [];
          }

          state.conversations.push(conversation);
        }
      });
    },
    updateConversation(state, { id, messages, page, isLastPage }) {
      const conversation = state.conversations.find(({ id: conversationId }) => conversationId === id);

      if (!conversation) {
        state.conversations.push(conversation);
      }

      mergeMessages(conversation, messages, state.activeProfile);
      conversation.page = page;
      conversation.isLastPage = isLastPage;
    },
    updateConversationUnread(state, { id }) {
      const conversation = state.conversations.find(({ id: conversationId }) => conversationId === id);
      this._vm.$socket.profile.push('read_conv', { cid: id })
        .receive('ok', (data) => {
          conversation.lastSeen = data.last_seen;
        });

      conversation.unread = 0;
    },
    updateConversationMembers(state, { id, members }) {
      const conversation = state.conversations.find(({ id: conversationId }) => conversationId === id);
      conversation.members = members;
    },
    newConversation(state, conversation) {
      if (!conversation.messages) {
        conversation.messages = [];
      }

      state.conversations.push(conversation);
    },
    newMessage(state, { conversation, message }) {
      const { cid, id, content_html: content, inserted_at: date, cm_id: cmId } = message;
      const pid = conversation.members.find((member) => member.id === message.cm_id).iid;
      const conv = state.conversations.find(({ id: conversationId }) => conversationId === cid);
      const name = conv.members.find(({ id: memberId }) => memberId === cmId).name;

      conv.isLastPage = false;
      conv.last_message_update = conversation.last_message_update;

      mergeMessages(conv, [{ content_html: content, date, id, name, pid }], state.activeProfile);
    },
  },
  actions: {
    async init({ commit, dispatch }) {
      console.log('Portal store created');

      axios = createAxiosInstance();

      // Only /profiles needs the account id. /features and /data depend on
      // nothing but auth, so start them now instead of queueing them behind
      // the account round trips — every serial hop is a full trip to the
      // us-east-1 origin, which is what players far from it wait on. (A
      // stale token is safe here: refreshAccessToken is single-flight.)
      const featuresLoaded = dispatch('fetchFeatures');
      const gameData = axios.get('/data');
      // Awaited in the try below; this only stops a rejection that lands
      // after an earlier failure (e.g. signed out) from going unhandled.
      gameData.catch(() => {});

      try {
        const account = await axios.get('/account');
        const profiles = await axios.get(`/accounts/${account.data.id}/profiles`);

        commit('account', account.data);
        commit('initSettings');

        // connect websockets
        this._vm.$socket.init();

        commit('initActiveProfile', profiles.data);
        commit('isAdmin', account.data.role === 'admin');
        // Awaited BEFORE the isSignedIn commit: AppLoading un-gates the
        // routes the moment isSignedIn flips, and the game socket's
        // capability announcement (slim_sync → player_production) reads
        // these features at channel join — they must be loaded before
        // Game.vue can possibly mount.
        await featuresLoaded;
        // Portal DMs are retired — conversations are only fetched in-game
        // (Game.vue dispatches initConversations with the instance id).
        commit('isSignedIn', true);
        await dispatch('initLanguage');

        // load game data
        const { data } = await gameData;
        commit('updateData', data);
      } catch (err) {
        console.error(err);
        return false;
      }

      return true;
    },
    setApiToken({ commit }, apiToken) {
      commit('apiToken', apiToken);
    },
    async fetchFeatures({ commit }) {
      try {
        const { data } = await axios.get('/features');
        commit('features', data.features);
      } catch (err) {
        console.error(err);
      }
    },
    async setFeature({ commit }, { feature, enabled }) {
      const { data } = await axios.put('/features', { feature, enabled });
      commit('features', data.features);
    },
    async initLanguage({ state }) {
      await loadLanguage(defaultLanguage);
      let { lang } = state.settings;
      if (!lang && localStorage.getItem('lang')) {
        lang = localStorage.getItem('lang');
      }
      await setLanguage(lang);

      // Sync the number-format module with the persisted preference (which
      // defaults to lang). Done here, after settings are merged, so the very
      // first formatted number rendered after boot already uses the right
      // grouping/decimal separators.
      setNumberLocale(state.settings.numberFormat || lang);
    },
    async setLanguage({ commit }, lang) {
      await setLanguage(lang);
      localStorage.setItem('lang', lang);

      // Language change re-syncs the number format to the new language's
      // customary format. The user can still pick a different format from
      // the Settings page afterward; that explicit choice will hold until
      // the next language change.
      setNumberLocale(lang);
      commit('updateSettings', { lang, numberFormat: lang });
    },
    async setNumberFormat({ commit }, format) {
      setNumberLocale(format);
      commit('updateSettings', { numberFormat: format });
    },
    async setIncomePerHour({ commit }, enabled) {
      setIncomePerHour(enabled);
      commit('updateSettings', { incomePerHour: enabled });
    },
    async setResourceCopyMode({ commit }, mode) {
      commit('updateSettings', { resourceCopyMode: mode });
    },
    // `hotkeys` is the active set's full override map
    // (game/hotkeys/bindings.js rebind).
    async setHotkeys({ commit, getters }, hotkeys) {
      commit('updateSettings', { [HOTKEY_OVERRIDES_KEY[getters.hotkeyPreset]]: hotkeys });
    },
    async setHotkeyPreset({ commit }, preset) {
      if (PRESETS.includes(preset)) commit('updateSettings', { hotkeys_preset: preset });
    },
    async setHotkeysEnabled({ commit }, enabled) {
      commit('updateSettings', { hotkeys_enabled: !!enabled });
    },
    async setCrosshair({ commit }, crosshair) {
      commit('updateSettings', { crosshair: normalizeCrosshair(crosshair) });
    },
    async updateActiveProfile({ state, commit }, profile) {
      state.activeProfile = profile;
      this._vm.$socket.connectProfile(profile.id);
      commit('updateSettings', { activeProfileId: profile.id });
    },
    // Partial updates merge into the saved levels: the top-bar sound toggle
    // sends only { muted }, the Settings sliders only the volumes.
    async updateAmbiance({ state, commit }, settings) {
      Object.keys(settings).forEach((type) => ambiance.updateVolume(type, settings[type]));
      commit('updateSettings', { ambiance: { ...state.settings.ambiance, ...settings } });
    },
    async initConversations({ state, commit }, instanceId) {
      const query = instanceId
        ? `/messenger/${state.activeProfile.id}/instance/${instanceId}`
        : `/messenger/${state.activeProfile.id}`;

      axios.get(query).then(({ data }) => {
        commit('addConversations', data);
      });
    },
    async loadConversation({ state, commit }, conversationId) {
      const conversation = state.conversations.find(({ id }) => id === conversationId);
      const page = conversation.page ? conversation.page + 1 : 1;

      if (!conversation.isLastPage) {
        return axios.get(`/messenger/${state.activeProfile.id}/${conversationId}?page=${page}`).then(({ data, headers }) => {
          const isLastPage = page >= headers['total-pages'];
          commit('updateConversation', { id: conversationId, messages: data, page, isLastPage });
          commit('updateConversationUnread', { id: conversationId });
        });
      }

      commit('updateConversationUnread', { id: conversationId });
    },
    // `destination` defaults to the public landing for explicit user-driven
    // logout (header menu, etc.) but callers on the dead-credential path
    // pass `/login` so the user lands on the form that gets them back in
    // rather than the marketing page's sign-up CTA.
    async logout({ commit }, { destination = config.BASE_URL } = {}) {
      commit('isSignedIn', false);
      commit('isAdmin', false);
      commit('account', undefined);

      try {
        await axios.post('/logout', {});
      } catch (err) {
        // console.error(err)
      }

      if (config.IS_STEAM) {
        // eslint-disable-next-line no-undef
        App.quit();
      } else {
        window.location = destination;
      }
    },
  },
};

function mergeMessages(conversation, messages, activeProfile) {
  const existingMessageIDs = conversation.messages.map(({ id }) => id);

  let unread = 0;
  messages.forEach((message) => {
    if (!existingMessageIDs.includes(message.id)) {
      conversation.messages.push(message);

      if (message.pid !== activeProfile.id) {
        unread += 1;
      }
    }
  });
  conversation.unread = unread;

  conversation.messages.sort(({ id: id1 }, { id: id2 }) => id2 - id1);
}

export default portalStore;
