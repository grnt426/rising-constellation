import { Socket, Presence } from 'phoenix';

import store from '@/store';
import config from '@/config';
import eventBus from '@/plugins/event-bus';
import {
  currentAccessToken,
  refreshAccessToken,
  isExpiringSoon,
  isFatalRefreshError,
  handleAuthFailure,
} from '@/plugins/auth';

const CHANNEL_JOIN_TIMEOUT = 120 * 1000;

// Minimum spacing between selected-system/character refetch rounds. The
// player channel broadcasts the full player struct on every state change
// (each construction click, resource ticks, ...), and every broadcast
// used to trigger its own get_system + get_character round trip — a
// rapid build burst multiplied into a payload storm that froze the UI
// for the whole burst. Leading+trailing coalescing keeps the first
// refetch instant and folds everything else into one trailing call, so
// the UI is at most this many ms stale.
const SELECTION_RELOAD_COALESCE_MS = 250;

// Construction orders arrive as slim `player_production` deltas that the
// store patches directly — no refetch on that hot path. One full
// selection reload this long after the LAST delta self-heals anything
// the slim payload doesn't carry (unknown side effects, derived values).
const SETTLE_SYNC_MS = 2000;

// Standing stale-cache safety net: a silent full sync (player struct +
// selected system/character) on this cadence, plus on tab-visibility
// regain. Bounds drift from any missed or slimmed message without the
// user ever noticing a refresh.
const BACKGROUND_SYNC_MS = 60 * 1000;

function tryRefreshIfStale() {
  if (!isExpiringSoon(currentAccessToken())) return;
  refreshAccessToken().catch((err) => {
    const message = err && err.response && err.response.data && err.response.data.message;
    if (isFatalRefreshError(message)) {
      handleAuthFailure();
    }
  });
}

const channelReconnectTimeouts = {
  instance: null,
  global: null,
  faction: null,
  player: null,
  profile: null,
};

const socket = {
  ws: null,
  instance: null,
  global: null,
  faction: null,
  player: null,
  profile: null,
  users: null,
  user: null,
  cheat: null,

  selectionReloadTimer: null,
  selectionReloadPending: false,
  settleSyncTimer: null,
  backgroundSyncTimer: null,
  onVisibilityChange: null,
  // Monotonic count of applied player_production deltas. get_player
  // replies snapshot the player BEFORE any order that lands while they
  // are in flight; committing such a reply would revert the delta
  // (credits jump back up). The counter lets silentSync discard replies
  // older than the newest delta.
  productionDeltaSeq: 0,

  init() {
    console.log('Creating socket');

    if (!currentAccessToken()) {
      console.log('user_token is missing');
      return false;
    }

    // eslint-disable-next-line no-shadow
    this.ws = new Socket(config.WEBSOCKET.URL, {
      // Function form: Phoenix re-evaluates this on every connect AND
      // every reconnect attempt. So a refresh fired in onError lands on
      // the next reconnect via the freshly-stored access token, with no
      // hand-rolled disconnect/reconnect plumbing.
      params: () => ({ token: currentAccessToken() }),
    });

    this.ws.connect();
    console.log('Socket created');
    this.ws.onError((err) => {
      console.log('Socket general error');
      console.error(err);
      // If the current access token is at/near exp, the server very
      // likely just rejected the connect with :token_expired. Kick off
      // a refresh — single-flight in auth.js means concurrent errors
      // collapse to one POST. The next Phoenix backoff-reconnect picks
      // up the new token via the params() callback above.
      tryRefreshIfStale();
    });
    this.ws.onClose((err) => {
      console.log('Socket closed');
      console.error(err);
      tryRefreshIfStale();
    });

    // connect to portal channel for all users and this user
    this.users = this.ws.channel('portal:user:*', {});
    // The join reply carries the current deploy flag: broadcasts predate
    // a late join, so a client connecting mid-deploy learns about it
    // here (and again on every automatic rejoin after a reconnect).
    this.users.join(CHANNEL_JOIN_TIMEOUT).receive('ok', (data = {}) => {
      if (typeof data.deploy_flag !== 'undefined') {
        store.commit('portal/deployOngoing', data.deploy_flag);
      }
    });
    this.users.on('broadcast', (data = {}) => {
      if (typeof data.maintenance_flag !== 'undefined') {
        store.commit('portal/isInMaintenance', data.maintenance_flag);
      }
      if (typeof data.min_client_version !== 'undefined') {
        store.dispatch('portal/updateVersion', data.min_client_version);
      }
      if (typeof data.deploy_flag !== 'undefined') {
        store.commit('portal/deployOngoing', data.deploy_flag);
      }
    });
    this.user = this.ws.channel(`portal:user:${store.state.portal.account.id}`, {});
    this.user.join(CHANNEL_JOIN_TIMEOUT);
  },

  joinGame() {
    if (!this.ws) {
      this.init();
    }

    console.log('Socket joined game');

    // Defensive reset: leaveGame clears these on the SPA path, but a
    // stray pending timer from a previous session must never fire into
    // a fresh game's channels.
    if (this.selectionReloadTimer) {
      this.selectionReloadTimer = clearTimeout(this.selectionReloadTimer);
    }
    this.selectionReloadPending = false;
    if (this.settleSyncTimer) {
      this.settleSyncTimer = clearTimeout(this.settleSyncTimer);
    }

    const instanceID = store.state.game.auth.instance;
    const factionID = store.state.game.auth.faction;
    const profileID = store.state.game.auth.profile;
    const registrationToken = store.state.game.auth.registration_token;

    // connect to global channel
    this.global = this.ws.channel(`instance:global:${instanceID}`, {
      registration: registrationToken,
    });

    this.global.onError(() => {
      if (!channelReconnectTimeouts.global) {
        channelReconnectTimeouts.global = setTimeout(() => {
          store.commit('game/statusChannel', { channel: 'global', status: false });
        }, 10000);
      }
    });
    this.global.onClose(() => store.commit('game/statusChannel', { channel: 'global', status: false }));
    this.global.on('broadcast', (data) => this.handleReceive(data));

    this.global
      .join(CHANNEL_JOIN_TIMEOUT)
      .receive('ok', (data) => {
        if (channelReconnectTimeouts.global) {
          channelReconnectTimeouts.global = clearTimeout(channelReconnectTimeouts.global);
        }

        this.handleReceive(data);
        store.commit('game/statusChannel', { channel: 'global', status: true });
      })
      .receive('error', (error) => this.handleError('global', error))
      .receive('timeout', () => this.handleTimeout('global'));

    // connect to faction channel
    this.faction = this.ws.channel(`instance:faction:${instanceID}:${factionID}`, {
      registration: registrationToken,
    });

    this.faction.onError(() => {
      if (!channelReconnectTimeouts.faction) {
        channelReconnectTimeouts.faction = setTimeout(() => {
          store.commit('game/statusChannel', { channel: 'faction', status: false });
        }, 10000);
      }
    });
    this.faction.onClose(() => store.commit('game/statusChannel', { channel: 'faction', status: false }));
    this.faction.on('broadcast', (data) => this.handleReceive(data));

    this.faction.on('presence_state', (state) => {
      store.commit('game/updateOnlinePlayers', Presence.syncState(store.state.game.onlinePlayers, state));
    });
    this.faction.on('presence_diff', (diff) => {
      store.commit('game/updateOnlinePlayers', Presence.syncDiff(store.state.game.onlinePlayers, diff));
    });

    this.faction
      .join(CHANNEL_JOIN_TIMEOUT)
      .receive('ok', (data) => {
        if (channelReconnectTimeouts.faction) {
          channelReconnectTimeouts.faction = clearTimeout(channelReconnectTimeouts.faction);
        }

        this.handleReceive(data);
        store.commit('game/statusChannel', { channel: 'faction', status: true });
      })
      .receive('error', (error) => this.handleError('faction', error))
      .receive('timeout', () => this.handleTimeout('faction'));

    // connect to player channel
    this.player = this.ws.channel(`instance:player:${instanceID}:${profileID}`, {
      registration: registrationToken,
    });

    this.player.onError(() => {
      if (!channelReconnectTimeouts.player) {
        channelReconnectTimeouts.player = setTimeout(() => {
          store.commit('game/statusChannel', { channel: 'player', status: false });
        }, 10000);
      }
    });

    this.player.onClose(() => store.commit('game/statusChannel', { channel: 'player', status: false }));

    this.player
      .on('broadcast', (data) => {
        const isDelta = !!data.player_production && !data.player_player;
        if (isDelta) {
          this.productionDeltaSeq += 1;
        }

        // try/finally: a throw inside a store commit (mutations are
        // synchronous) must not skip scheduling the heal — that would
        // leave a partially-applied payload with nothing pending.
        try {
          this.handleReceive(data);
        } finally {
          if (isDelta) {
            // Slim construction delta: the store patch already updated
            // everything the order changed. Defer one full sync to the
            // end of the burst instead of refetching per broadcast.
            this.scheduleSettleSync();
          } else {
            this.scheduleSelectionReload();
          }
        }
      });

    this.player
      .join(CHANNEL_JOIN_TIMEOUT)
      .receive('ok', (data) => {
        if (channelReconnectTimeouts.player) {
          channelReconnectTimeouts.player = clearTimeout(channelReconnectTimeouts.player);
        }

        this.handleReceive(data);
        store.commit('game/statusChannel', { channel: 'player', status: true });

        // Phoenix re-runs this on every automatic rejoin after a socket
        // drop. The join payload re-primes the player struct, but the
        // selected system/character would otherwise keep their pre-drop
        // snapshots until the next broadcast — refresh them too.
        this.scheduleSelectionReload();
      })
      .receive('error', (error) => this.handleError('player', error))
      .receive('timeout', () => this.handleTimeout('player'));

    this.startBackgroundSync();
  },

  scheduleSelectionReload() {
    // A full reload supersedes any pending settle sync.
    if (this.settleSyncTimer) {
      this.settleSyncTimer = clearTimeout(this.settleSyncTimer);
    }

    if (this.selectionReloadTimer) {
      this.selectionReloadPending = true;
      return;
    }

    store.dispatch('game/reloadSystem', this);
    store.dispatch('game/reloadSelectedCharacter', this);

    this.selectionReloadTimer = setTimeout(() => {
      this.selectionReloadTimer = null;
      if (this.selectionReloadPending) {
        this.selectionReloadPending = false;
        // Re-enter so a burst longer than the window keeps coalescing.
        this.scheduleSelectionReload();
      }
    }, SELECTION_RELOAD_COALESCE_MS);
  },

  // Trailing-only debounce: every slim delta pushes the timer back, so a
  // click burst ends with exactly one full sync. It must be silentSync,
  // not just a selection reload: the delta patches THREE roots (player,
  // system, character) and only get_player re-verifies the player one —
  // e.g. the roster entry a ship order updates.
  scheduleSettleSync() {
    if (this.settleSyncTimer) {
      clearTimeout(this.settleSyncTimer);
    }

    this.settleSyncTimer = setTimeout(() => {
      this.settleSyncTimer = null;
      this.silentSync();
    }, SETTLE_SYNC_MS);
  },

  // Silent full sync: the standing stale-cache mechanism. Re-pulls the
  // full player struct and the open system/character in the background on
  // a slow cadence and whenever the tab becomes visible again. All
  // commits are whole-object replacements of frozen roots, so this is
  // cheap and invisible unless something actually drifted.
  silentSync() {
    if (!store.state.game.connected) {
      return;
    }

    const seqAtPush = this.productionDeltaSeq;

    this.player
      .push('get_player', {})
      .receive('ok', (data) => {
        if (this.productionDeltaSeq !== seqAtPush) {
          // A delta landed while this reply was in flight — the reply's
          // snapshot predates it. Committing it would revert the order
          // (the credit counter would visibly refund). Discard and let
          // the delta's own settle sync re-pull a fresh snapshot.
          return;
        }
        this.handleReceive(data);
      })
      .receive('timeout', () => this.scheduleSettleSync());

    this.scheduleSelectionReload();
  },

  startBackgroundSync() {
    this.stopBackgroundSync();

    this.backgroundSyncTimer = setInterval(() => this.silentSync(), BACKGROUND_SYNC_MS);

    this.onVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        this.silentSync();
      }
    };
    document.addEventListener('visibilitychange', this.onVisibilityChange);
  },

  stopBackgroundSync() {
    if (this.backgroundSyncTimer) {
      this.backgroundSyncTimer = clearInterval(this.backgroundSyncTimer);
    }
    if (this.onVisibilityChange) {
      document.removeEventListener('visibilitychange', this.onVisibilityChange);
      this.onVisibilityChange = null;
    }
  },

  handleReceive(data) {
    if (data.new_conversation) {
      store.commit('portal/newConversation', data.new_conversation);
      return;
    }

    if (data.new_message) {
      store.commit('portal/newMessage', data.new_message);
      return;
    }

    Object.keys(data).forEach((key) => {
      // Scalar payloads exist (e.g. signal: "close_game"); assigning a
      // property to a string primitive throws in strict mode, which
      // would abort the whole receive.
      if (data[key] && typeof data[key] === 'object') {
        data[key].receivedAt = Date.now();
      }
      console.log(`receive: ${key}`);
    });

    if (data.signal) {
      eventBus.$emit(`signal:${data.signal}`);
    }

    store.commit('game/update', data);
    eventBus.$emit('map/update', data);
  },

  handleError(channel, error) {
    console.log('Unable to join');
    console.log(error);
    store.commit('game/statusChannel', { channel, status: false });
  },

  handleTimeout(channel) {
    console.log(`Networking issue: ${channel}`);
    store.commit('game/statusChannel', { channel, status: false });
  },

  // Lazily joined by the Cheats tab (rendered for every player of a
  // cheats-enabled instance; creator-only sections gated inside — the
  // server re-checks access on join and on every push). Idempotent:
  // returns the existing channel once joined.
  joinCheat() {
    if (this.cheat) return this.cheat;

    const instanceID = store.state.game.auth.instance;
    const profileID = store.state.game.auth.profile;

    this.cheat = this.ws.channel(`cheat:player:${instanceID}:${profileID}`, {});
    this.cheat
      .join(CHANNEL_JOIN_TIMEOUT)
      .receive('error', (error) => {
        console.log('Unable to join cheat channel');
        console.log(error);
        this.cheat = null;
      })
      .receive('timeout', () => {
        console.log('Networking issue: cheat.join');
        this.cheat = null;
      });

    return this.cheat;
  },

  leaveGame() {
    console.log('Socket leave game');

    if (this.selectionReloadTimer) {
      this.selectionReloadTimer = clearTimeout(this.selectionReloadTimer);
      this.selectionReloadPending = false;
    }
    if (this.settleSyncTimer) {
      this.settleSyncTimer = clearTimeout(this.settleSyncTimer);
    }
    this.stopBackgroundSync();

    this.global.leave();
    this.faction.leave();
    this.player.leave();

    if (this.cheat) {
      this.cheat.leave();
      this.cheat = null;
    }
  },

  joinInstance(instanceID) {
    console.log('Socket joined instance');

    // connect to instance channel
    this.instance = this.ws.channel(`portal:instance:${instanceID}`);

    this.instance.onError(() => {
      if (!channelReconnectTimeouts.instance) {
        channelReconnectTimeouts.instance = setTimeout(() => false, 10000);
      }
    });

    this.instance.onClose(() => false);

    this.instance.join(CHANNEL_JOIN_TIMEOUT).receive('ok', (data) => {
      if (channelReconnectTimeouts.instance) {
        channelReconnectTimeouts.instance = clearTimeout(channelReconnectTimeouts.instance);
      }

      console.log(data);
    }).receive('error', (error) => {
      console.log('Unable to join');
      console.log(error);
    }).receive('timeout', () => {
      console.log('Networking issue: instance.join ');
    });
  },

  connectProfile(profileId) {
    console.log('Socket connect profile');
    if (this.profile) {
      this.profile.leave();
    }
    // connect to profile channel
    this.profile = this.ws.channel(`portal:profile:${profileId}`);

    this.profile.onError(() => {
      if (!channelReconnectTimeouts.profile) {
        channelReconnectTimeouts.profile = setTimeout(() => false, 10000);
      }
    });

    this.profile.onClose(() => false);

    this.profile.join(CHANNEL_JOIN_TIMEOUT)
      .receive('ok', () => {
        if (channelReconnectTimeouts.profile) {
          channelReconnectTimeouts.profile = clearTimeout(channelReconnectTimeouts.profile);
        }
      })
      .receive('error', (error) => {
        console.log('Unable to join');
        console.log(error);
      })
      .receive('timeout', () => {
        console.log('Networking issue: profile.join');
      });

    this.profile.on('broadcast', (data) => {
      this.handleReceive(data);
    });
  },

  leaveInstance() {
    console.log('Socket leave instance');
    this.instance.leave();
  },
};

export default {
  socket,
  install(Vue) {
    Vue.prototype.$socket = socket;
  },
};
