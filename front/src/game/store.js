import Vue from 'vue';
import Cookies from 'js-cookie';

const cookiesKeys = ['faction', 'instance', 'profile', 'registration_token', 'user_token'];

const setView = (state) => {
  // set view to last overlay, or to map if none
  // and change map status
  state.view = state.activeOverlay || 'map';
  state.isMapLocked = state.view !== 'map';

  return state;
};

// Replace one (sub-)body's tiles by uid for the player_production delta.
// Bodies nest (moons/asteroids live in body.bodies), so recurse. Only the
// changed path is rebuilt; untouched bodies keep their identity.
const patchBodyTiles = (bodies, uid, tiles) => (bodies || []).map((body) => {
  if (body.uid === uid) {
    return { ...body, tiles };
  }
  if (body.bodies && body.bodies.length) {
    return { ...body, bodies: patchBodyTiles(body.bodies, uid, tiles) };
  }
  return body;
});

const bodyUidExists = (bodies, uid) => (bodies || [])
  .some((body) => body.uid === uid || bodyUidExists(body.bodies, uid));

const loadAuthData = () => cookiesKeys.reduce((acc, key) => {
  const value = ['faction', 'instance', 'profile'].includes(key)
    ? parseInt(Cookies.get(key), 10) : Cookies.get(key);

  if (value) {
    acc[key] = value;
  }

  return acc;
}, {});

const defaultState = () => {
  console.log('Game store created');

  return {
    // connection process
    // also check that channels are all actives
    auth: loadAuthData(),
    connected: false,
    isDead: false,
    activeChannels: {
      global: false,
      faction: false,
      player: false,
    },

    // set current view
    view: 'map',
    activeOverlay: null,
    mapOverlay: null,
    isMapLocked: false,
    hasSystemTransition: false,

    // building box
    production: null,

    // affectation box
    assignment: null,

    // only for 'system' view
    selectedSystem: undefined,

    // selection
    selectedCharacter: undefined,

    // ouverture d'agent ou de joueur
    openedCharacter: undefined,
    openedPlayer: undefined,

    // The viewer's faction key, split out as a primitive. It can never
    // change mid-game, but `player` is REPLACED on every sync — and Vue 2
    // render watchers subscribe transitively through computeds/getters,
    // so anything whose render touches state.player (the `theme` getter
    // above all) re-renders on every replacement even when the derived
    // value is identical. Routing faction/theme reads through this field
    // keeps the always-mounted v-show panels (event feed, galactic
    // survey, help) from re-rendering on every construction delta and
    // resource tick.
    playerFaction: null,

    // reactive data from server
    onlinePlayers: {},

    // unread messages
    unreadMessages: 0,

    // shortkey characters' group
    charactersGroup: {},

    // tutorial active step
    tutorialStep: 0,

    // map
    mapPosition: { x: 0, y: 0, z: 0 },
    mapOptions: {
      mode: 'visibility',
      showCharacterLabel: true,
      // Master toggle for the player-icon layer; persists across the
      // session via the same updateMapOptions mutation as the other
      // map-options switches. The SystemIcons block reads this every
      // frame and short-circuits its faction-icon list to [] when
      // false, so toggling is instant.
      showSystemIcons: true,
    },

    // ruler tool: a passive measurement overlay. waypoints are the
    // committed (clicked) system ids the player has anchored; hovered
    // is the system id under the cursor, used to extend the path
    // preview from the last waypoint without committing.
    ruler: {
      active: false,
      waypoints: [],
      hoveredSystemId: null,
      // Filled by the map (Character block's pathfinder is the only one
      // wired up) every time waypoints/hoveredSystemId changes. Number
      // of game-time ticks the full path would take to traverse — null
      // when there's nothing to measure.
      travelTimeTicks: null,
    },

    // per-socket instance info from the global-channel join payload:
    // cheats_enabled (game-wide flag — gates the Cheats tab for every
    // player), cheat_creator (am I the game creator — unlocks the
    // creator-only cheat sections), speedup (runtime speed-cheat
    // multiplier, rescales every client-side timer).
    instanceInfo: {
      cheats_enabled: false,
      cheat_creator: false,
      speedup: 1,
    },

    data: {},
    time: {},
    galaxy: {},
    victory: {},
    character_market: {},
    faction: {},
    diplomacy: null,
    player: {},
    textNotifications: [],
    boxNotifications: [],
    systems: [],

    // news-ticker bulletins received live over the global channel
    // (newest first, capped). Seeded lazily; the portal pages fetch
    // history over REST instead.
    news: [],
  };
};

const gameStore = {
  namespaced: true,
  state: defaultState(),
  getters: {
    theme(state) {
      // Reads playerFaction (stable primitive), NOT state.player: nearly
      // every component's render depends on this getter, and a
      // state.player read here would re-render all of them on every
      // player replacement (see the playerFaction comment in state).
      if (state.connected && state.data.faction && state.playerFaction) {
        return state.data.faction
          .find((f) => f.key === state.playerFaction)
          .theme;
      }

      return '';
    },
    themeByKey(state) {
      return ((key) => {
        const faction = state.data.faction.find((f) => f.key === key);
        return faction ? faction.theme : '';
      });
    },
    onlinePlayersNumber(state) {
      return Object.keys(state.onlinePlayers).length;
    },
    // The wall-clock↔game-time rate actually in effect: base speed factor ×
    // the runtime speed-cheat multiplier. Every client-side conversion
    // between real time and game time must go through this (or the tickTo*
    // getters below) — reading data.speed's raw factor renders 1× on
    // speed-cheated games. Undefined until the join payload primes the store.
    effectiveSpeedFactor(state) {
      if (!state.data.speed || !state.time.speed) return undefined;
      const speed = state.data.speed.find((s) => s.key === state.time.speed);
      return speed ? speed.factor * (state.instanceInfo.speedup || 1) : undefined;
    },
    tickToMilisecondFactor(state, getters) {
      return (180 / getters.effectiveSpeedFactor) * 1000;
    },
    tickToSecondFactor(state, getters) {
      return (180 / getters.effectiveSpeedFactor);
    },
    // Cheats tab: visible to every player of a cheats-enabled instance.
    cheatsAvailable(state) {
      return !!state.instanceInfo.cheats_enabled;
    },
    // Creator-only cheat sections (speed, settle, election timers) — the
    // server independently re-checks this on every op.
    cheatCreator(state) {
      return !!(state.instanceInfo.cheats_enabled && state.instanceInfo.cheat_creator);
    },
  },
  mutations: {
    init(state, payload) {
      console.log('Game store initialized');

      cookiesKeys.forEach((key) => {
        if (payload[key]) {
          Cookies.set(key, payload[key]);
        }
      });

      state.auth = loadAuthData();
    },
    clear(state) {
      Object.assign(state, defaultState());
    },
    statusChannel(state, payload) {
      const { channel, status } = payload;

      state.activeChannels[channel] = status;
      state.connected = state.activeChannels.global
        && state.activeChannels.faction
        && state.activeChannels.player;
    },

    discardTextNotification(state, payload) {
      const index = state.textNotifications.findIndex((notif) => notif.id === payload);

      if (index > -1) {
        state.textNotifications.splice(index, 1);
      }
    },
    discardFirstBoxNotification(state) {
      state.boxNotifications.shift();
    },

    startSystemTransition(state) {
      state.hasSystemTransition = true;
    },
    finishSystemTransition(state) {
      state.hasSystemTransition = false;
    },

    addOverlay(state, overlay) {
      // set overlay to active if no other overlay is already active
      if (!state.activeOverlay) { // eslint-disable-line
        state.activeOverlay = overlay;
      }

      state = setView(state);
    },
    removeOverlay(state) {
      // remove overlay, if exist
      state.activeOverlay = null;

      state = setView(state);
    },

    addMapOverlay(state, payload) {
      state.mapOverlay = payload;
    },

    clearMapOverlay(state) {
      state.mapOverlay = null;
    },

    prepareProduction(state, payload) {
      state.production = payload;
    },
    clearProduction(state) {
      state.production = undefined;
    },

    prepareAssignment(state, payload) {
      state.assignment = payload;
    },
    clearAssignment(state) {
      state.assignment = null;
    },

    tutorialNextStep(state) {
      state.tutorialStep += 1;
    },
    tutorialPrevStep(state) {
      state.tutorialStep -= 1;
    },

    setDiplomacy(state, diplomacy) {
      state.diplomacy = diplomacy;
    },

    updateOnlinePlayers(state, onlinePlayers) {
      state.onlinePlayers = onlinePlayers;
    },

    updateUnreadMessages(state, unreadMessages) {
      if (unreadMessages > 99) unreadMessages = '99+';
      state.unreadMessages = unreadMessages;
    },

    updateCharactersGroup(state, { key, characterId }) {
      // remove previous group for same character
      Object.keys(state.charactersGroup).forEach((k) => {
        if (state.charactersGroup[k] === characterId) {
          Vue.set(state.charactersGroup, k, null);
        }
      });

      Vue.set(state.charactersGroup, key, characterId);
    },

    updateMapPosition(state, position) {
      state.mapPosition = position;
    },

    updateMapOptions(state, { key, value }) {
      state.mapOptions[key] = value;
    },

    setRulerActive(state, value) {
      state.ruler.active = value;
      if (!value) {
        state.ruler.waypoints = [];
        state.ruler.hoveredSystemId = null;
        state.ruler.travelTimeTicks = null;
      }
    },

    addRulerWaypoint(state, systemId) {
      // Cap at 10 waypoints. Clicks past the cap silently no-op so the
      // player can keep moving the cursor without the path snapping.
      if (state.ruler.waypoints.length >= 10) return;
      const last = state.ruler.waypoints[state.ruler.waypoints.length - 1];
      if (last === systemId) return;
      state.ruler.waypoints.push(systemId);
    },

    clearRulerWaypoints(state) {
      state.ruler.waypoints = [];
      state.ruler.hoveredSystemId = null;
      state.ruler.travelTimeTicks = null;
    },

    setRulerHoveredSystem(state, systemId) {
      state.ruler.hoveredSystemId = systemId;
    },

    setRulerTravelTime(state, ticks) {
      state.ruler.travelTimeTicks = ticks;
    },

    // The player/system/character payloads below are frozen for the same
    // reason global_data is in `update`: they arrive as whole-object
    // replacements (nothing patches them in place), so top-level
    // reference reactivity is all the UI needs. Left unfrozen, Vue 2
    // deep-walks every nested key of these large structs on every
    // commit — and the player struct arrives on *every* player-channel
    // broadcast — which allocated hard enough to force multi-hundred-ms
    // major GC pauses during construction-click bursts. Freeze is
    // shallow, but Vue skips the whole tree once the root is
    // non-extensible.
    setPlayer(state, player) {
      // Guarded write: only assign when it actually differs so the
      // stable-primitive dependents (theme etc.) never get notified.
      if (state.playerFaction !== player.faction) {
        state.playerFaction = player.faction;
      }

      player.receivedAt = Date.now();
      // Resource extrapolation (calc env) anchors on this; it is also
      // stamped by applyProductionDelta, which refreshes ONLY the
      // resource values — receivedAt stays the whole-struct anchor for
      // queue_remaining_time / cooldown consumers.
      player.resourcesReceivedAt = player.receivedAt;
      state.player = Object.freeze(player);

      if (player.is_dead) {
        state.isDead = true;
      }
    },

    setNotifications(state, notifications) {
      const notifs = notifications.reduce((acc, notif, i) => {
        if (notif.type === 'sound') {
          this._vm.$ambiance.sound(`notif-${notif.key}`);
          return acc;
        }

        if (notif.type === 'text') {
          const id = state.textNotifications.length + i;
          const timestamp = Date.now();

          this._vm.$ambiance.sound('new-text-notif');
          notif = Object.assign(notif, { id, timestamp });

          acc.text.push(notif);
        }

        if (notif.type === 'box') {
          this._vm.$ambiance.sound('new-box-notif');
          acc.box.push(notif);
        }

        return acc;
      }, { text: [], box: [] });

      state.textNotifications = state.textNotifications.concat(notifs.text);
      // Box notifications only leave the array when the player clicks
      // them away, so a long unattended session accumulated them without
      // bound. Keep the newest 50 — far more than the UI ever shows.
      state.boxNotifications = state.boxNotifications.concat(notifs.box).slice(-50);
    },

    selectSystem(state, selectedSystem) {
      if (selectedSystem) {
        selectedSystem.receivedAt = Date.now();
      }

      state.selectedSystem = selectedSystem ? Object.freeze(selectedSystem) : selectedSystem;
    },

    // Slim construction delta (`player_production` broadcast): patches only
    // what an order/cancel can change, instead of the full player struct +
    // full system/character refetch the old path used. Every touched root
    // is rebuilt and re-frozen so reference reactivity fires; credit/
    // technology/ideology arrive as fresh objects from the wire, which the
    // Bottombar's DynamicValueMixin needs (it watches object identity, not
    // value).
    //
    // Anchor discipline: `player.receivedAt` is NOT re-stamped — it anchors
    // queue_remaining_time / cooldown consumers whose values this delta
    // does not refresh (re-stamping made every OTHER system's ETA tooltip
    // rewind). Only `resourcesReceivedAt` (calc extrapolation of the three
    // refreshed resources) moves. The system's receivedAt IS re-stamped:
    // its queue is fresh and Production.vue's ETA math anchors on it.
    applyProductionDelta(state, delta) {
      const receivedAt = Date.now();

      const player = { ...state.player, resourcesReceivedAt: receivedAt };
      if (delta.credit) player.credit = delta.credit;
      if (delta.technology) player.technology = delta.technology;
      if (delta.ideology) player.ideology = delta.ideology;
      if (delta.stellar_system && Array.isArray(player.stellar_systems)) {
        player.stellar_systems = player.stellar_systems
          .map((s) => (s.id === delta.stellar_system.id ? delta.stellar_system : s));
      }
      if (delta.player_character && Array.isArray(player.characters)) {
        player.characters = player.characters
          .map((c) => (c.id === delta.player_character.id ? delta.player_character : c));
      }
      state.player = Object.freeze(player);

      const system = state.selectedSystem;
      if (system && system.id === delta.system_id) {
        const patched = { ...system, receivedAt };
        if (delta.queue) patched.queue = delta.queue;
        if (typeof delta.used_workforce === 'number') patched.used_workforce = delta.used_workforce;
        if (delta.body_tiles) {
          if (!bodyUidExists(system.bodies, delta.body_tiles.body_uid)) {
            // A uid mismatch degrades to "tiles never repaint" with zero
            // diagnostics — make this class of regression visible.
            console.warn('applyProductionDelta: body_tiles uid matched nothing', delta.body_tiles.body_uid);
          }
          patched.bodies = patchBodyTiles(system.bodies, delta.body_tiles.body_uid, delta.body_tiles.tiles);
        }
        state.selectedSystem = Object.freeze(patched);
      }

      if (delta.character && state.selectedCharacter && state.selectedCharacter.id === delta.character.id) {
        state.selectedCharacter = Object.freeze({ ...delta.character, receivedAt });
      }
    },

    selectCharacter(state, selectedCharacter) {
      const character = typeof selectedCharacter === 'object' ? selectedCharacter : undefined;

      if (character) {
        character.receivedAt = Date.now();
      }

      state.selectedCharacter = character ? Object.freeze(character) : character;
    },

    update(state, payload) {
      if (payload.global_data) {
        state.data = Object.freeze(payload.global_data);
      }

      // Pairwise-private diplomacy view, pushed on the FACTION channel --
      // each faction only ever receives the pairs it belongs to.
      if (payload.faction_diplomacy) {
        state.diplomacy = payload.faction_diplomacy;
      }

      if (payload.global_instance) {
        state.instanceInfo = { ...state.instanceInfo, ...payload.global_instance };
      }

      // Runtime speed-cheat change broadcast (impersonal — cheat_creator
      // stays whatever the join payload said).
      if (payload.global_speedup) {
        state.instanceInfo = { ...state.instanceInfo, speedup: payload.global_speedup.multiplier };
      }

      if (payload.global_time) {
        // Stamp arrival time so serverMonotonicNow can rebase now_monotonic
        // against client wall-clock. now_monotonic alone is a server-side
        // snapshot from when the agent answered; once we know when we
        // received it, we can extrapolate forward by Date.now() delta.
        state.time = { ...payload.global_time, receivedAt: Date.now() };
      }

      // remove systems ?
      if (payload.global_galaxy) {
        state.galaxy = payload.global_galaxy;
      }

      if (payload.global_galaxy_sector) {
        state.galaxy.sectors = payload.global_galaxy_sector;
      }

      if (payload.global_galaxy_player) {
        state.galaxy.players = payload.global_galaxy_player;
      }

      if (payload.global_character_market) {
        state.character_market = payload.global_character_market;
      }

      if (payload.global_victory) {
        state.victory = payload.global_victory;
      }

      if (payload.player_player) {
        this.commit('game/setPlayer', payload.player_player);
      }

      if (payload.player_production) {
        this.commit('game/applyProductionDelta', payload.player_production);
      }

      if (payload.player_notifs) {
        this.commit('game/setNotifications', payload.player_notifs);
      }

      // Breaking news from the wire: stash the bulletin for ticker UIs
      // and surface a text toast. The headline is pre-rendered here
      // because text notifs interpolate flat params into
      // `notification.text.<key>` templates.
      if (payload.global_news) {
        state.news = [payload.global_news, ...state.news].slice(0, 20);

        // renderNews needs $t/$te — the root vm carries the i18n plugin.
        // Required lazily to dodge a circular import at module load.
        // eslint-disable-next-line global-require
        const { renderNews } = require('@/utils/news');
        const viewerFaction = state.playerFaction;
        const headline = renderNews(this._vm, payload.global_news, viewerFaction);

        this.commit('game/setNotifications', [
          { type: 'text', key: 'breaking_news', data: { headline } },
        ]);
      }

      // remove detected_objects ?
      // remove radars ?
      if (payload.faction_faction) {
        state.faction = payload.faction_faction;
      }
    },
  },
  actions: {
    async openSystem(store, { vm, id }) {
      return new Promise((resolve, reject) => {
        vm.$socket.faction.push('get_system', { system_id: id })
          .receive('ok', ({ system }) => {
            this.commit('game/startSystemTransition');
            this.commit('game/selectSystem', system);
            this.commit('game/addOverlay', 'system');
            this.commit('game/clearProduction');

            vm.$root.$emit('enterSystem', system);
            resolve(system);
          })
          .receive('error', (data) => {
            Vue.toasted.error(data.reason);
            reject();
          });
      });
    },
    reloadSystem(store, socket) {
      if (store.state.selectedSystem) {
        const requestedId = store.state.selectedSystem.id;

        socket.faction
          .push('get_system', { system_id: requestedId })
          .receive('ok', ({ system }) => {
            // Replies commit asynchronously: guard against the user
            // having switched/closed the selection while this was in
            // flight (a stale reply used to clobber the new selection
            // and then self-sustain, refetching the wrong system), and
            // against non-struct payloads.
            const current = store.state.selectedSystem;
            if (system && typeof system === 'object'
              && current && current.id === requestedId && system.id === requestedId) {
              this.commit('game/selectSystem', system);
            }
          })
          .receive('timeout', () => {
            // Channel mid-rejoin etc. — retry via the settle path so a
            // failed reload isn't a silent hole until the 60s sync.
            if (socket.scheduleSettleSync) socket.scheduleSettleSync();
          });
      }
    },
    closeSystem(store, vm) {
      // Only close a system when no pending transitions
      if (!store.state.hasSystemTransition) {
        this.commit('game/selectSystem', undefined);
        this.commit('game/removeOverlay', 'system');
        vm.$root.$emit('exitSystem');
      }
    },

    selectCharacter(store, { vm, id }) {
      vm.$socket.player.push('get_character', { character_id: id })
        .receive('ok', ({ character }) => {
          this.commit('game/selectCharacter', character);
        })
        .receive('error', (data) => {
          Vue.toasted.error(data.reason);
        });
    },
    unselectCharacter() {
      this.commit('game/clearProduction');
      this.commit('game/selectCharacter', undefined);
    },
    reloadSelectedCharacter(store, socket) {
      if (store.state.selectedCharacter) {
        const requestedId = store.state.selectedCharacter.id;

        socket.player
          .push('get_character', { character_id: requestedId })
          .receive('ok', ({ character }) => {
            // Same in-flight guards as reloadSystem: a stale reply used
            // to resurrect a character the user had just deselected.
            const current = store.state.selectedCharacter;
            if (character && typeof character === 'object'
              && current && current.id === requestedId && character.id === requestedId) {
              this.commit('game/selectCharacter', character);
            }
          })
          .receive('timeout', () => {
            if (socket.scheduleSettleSync) socket.scheduleSettleSync();
          });
      }
    },

    openCharacter(store, { vm, id }) {
      vm.$socket.faction.push('get_character', { character_id: id })
        .receive('ok', ({ character }) => {
          store.state.openedCharacter = typeof character === 'object' ? character : undefined;
        })
        .receive('error', (data) => {
          Vue.toasted.error(data.reason);
        });
    },
    closeCharacter(store) {
      store.state.openedCharacter = undefined;
    },

    openPlayer(store, { vm, id }) {
      vm.$socket.global.push('get_player', { player_id: id })
        .receive('ok', ({ player }) => {
          store.state.openedPlayer = typeof player === 'object' ? player : undefined;
        })
        .receive('error', (data) => {
          Vue.toasted.error(data.reason);
        });
    },
    closePlayer(store) {
      store.state.openedPlayer = undefined;
    },
  },
};

export default gameStore;
