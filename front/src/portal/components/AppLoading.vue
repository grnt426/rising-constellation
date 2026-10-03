<template>
  <div class="app-loading">
    <!-- Each check's state was shown by colour (and a glyph) only: the
         sr-only word says it, and the list is a live region so a failure
         is heard without hunting for it. -->
    <div
      class="app-loading-content"
      role="status">
      <div
        class="app-loading-item"
        :class="{
          'pending': hasConnectivity === null,
          'failed': hasConnectivity === false,
          'success': hasConnectivity === true,
        }">
        {{ $t('loading_messages.connectivity_check') }}
        <span class="sr-only">{{ checkState(hasConnectivity, true) }}</span>
      </div>
      <div
        class="app-loading-item"
        :class="{
          'pending': isInMaintenance === null,
          'failed': isInMaintenance === true,
          'success': isInMaintenance === false,
        }">
        {{ $t('loading_messages.maintenance_check') }}
        <span class="sr-only">{{ checkState(isInMaintenance, false) }}</span>
      </div>
      <div
        class="app-loading-item"
        :class="{
          'pending': isSignedIn === null,
          'failed': isSignedIn === false,
          'success': isSignedIn === true,
        }">
        {{ $t('loading_messages.signin') }}
        <span class="sr-only">{{ checkState(isSignedIn, true) }}</span>
      </div>
    </div>

    <button
      type="button"
      class="exit-button bare-button"
      @click="logout">
      {{ $t('page.menu.exit') }}
    </button>
  </div>
</template>

<script>
import { mapState } from 'vuex';
import { maintenanceCheck, connectivityCheck } from '@/utils/loader';
import config from '@/config';
// import { steamInit, steamTicket, steamAuth } from '../../../steam-libs';

export default {
  name: 'app-loading',
  data() {
    return {
      isSteam: config.IS_STEAM,
    };
  },
  computed: mapState('portal', [
    'isSignedIn',
    'isInMaintenance',
    'hasConnectivity',
  ]),
  async mounted() {
    const start = Date.now();
    try {
      await Promise.all([
        this.$store.dispatch('portal/initLanguage'),
        maintenanceCheck().then((isInMaintenance) => { this.$store.commit('portal/isInMaintenance', isInMaintenance); }),
        connectivityCheck().then((hasConnectivity) => { this.$store.commit('portal/hasConnectivity', hasConnectivity); }),
        this.signIn().then((signInResult) => { this.$store.commit('portal/isSignedIn', signInResult); }),
      ]);
    } catch (err) {
      console.warn('AppLoading.mounted error');
      console.error(err);
      console.error(err.stack);
    }
    console.log(`Loaded in ${Date.now() - start}ms`);

    if (!this.isSignedIn && !this.isSteam) {
      // web version doesn't automatically sign you in, redirect to /login
      // so the visitor lands on the sign-in form rather than the public
      // landing's sign-up CTA.
      window.location = `${config.BASE_URL}/login`;
    }
  },
  watch: {
    isSignedIn() { this.start(); },
    isInMaintenance() { this.start(); },
    hasConnectivity() { this.start(); },
  },
  methods: {
    async signIn() {
      if (config.IS_STEAM) {
        return this.steamSignIn();
      }
      return this.$store.dispatch('portal/init');
    },
    async steamSignIn() {
      // eslint-disable-next-line no-undef
      const steam = await steamInit();
      if (steam.error) {
        console.log('steam init error');
        console.error(steam.message);
        console.error(steam.stack);
        return false;
      }

      if (steam.lang) {
        this.$store.state.portal.settings.lang = steam.lang;
        localStorage.setItem('lang', steam.lang);
      }

      // if there's existing local connection token and account, try to use them
      const localApiToken = localStorage.getItem('apiToken');
      const localaccountId = localStorage.getItem('accountId');
      if (localApiToken && localaccountId) {
        await this.$store.dispatch('portal/setApiToken', localApiToken);
        const validTokens = await this.$store.dispatch('portal/init');
        if (validTokens) {
          console.log('logged in using localStorage');
          return true;
        }
        // localStorage API token was not valid
        await this.$store.dispatch('portal/setApiToken', '');
      }

      // eslint-disable-next-line no-undef
      const { ticketHex, steamid } = await steamTicket();
      if (!steamid) {
        return false;
      }
      // eslint-disable-next-line no-undef
      const { account, apiToken, refreshToken } = await steamAuth({ ticketHex, steamid });
      localStorage.setItem('accountId', account.id);
      localStorage.setItem('apiToken', apiToken);
      // Stored alongside apiToken so it survives a restart of the Steam
      // client. auth.js reads it when calling /api/auth/refresh — without
      // it, the only recovery path is a fresh Steam ticket dance.
      if (refreshToken) {
        localStorage.setItem('refreshToken', refreshToken);
      }
      await this.$store.dispatch('portal/setApiToken', apiToken);
      await this.$store.dispatch('portal/init');
      return true;
    },
    logout() {
      this.$store.dispatch('portal/logout');
    },
    // null = still checking; `good` is the value that means it passed.
    checkState(value, good) {
      if (value === null) return this.$t('a11y_portal.check_pending');
      return value === good ? this.$t('a11y_portal.check_done') : this.$t('a11y_portal.check_failed');
    },
    start() {
      if (this.isInMaintenance === false && this.hasConnectivity === true && this.isSignedIn) {
        this.$emit('loaded');
      }
    },
  },
};
</script>
