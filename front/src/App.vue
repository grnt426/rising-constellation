<template>
  <div id="app">
    <app-loading
      v-if="loading"
      @loaded="loading = false" />

    <template v-else>
      <div
        v-if="isInMaintenance"
        class="maintenance">
        <div class="maintenance-content">
          {{ $t('loading_messages.ongoing_maintenance') }}
        </div>

        <div
          class="exit-button"
          @click="logout">
          {{ $t('page.menu.exit') }}
        </div>
      </div>

      <transition :name="transition">
        <router-view />
      </transition>
    </template>
  </div>
</template>

<script>
import '@/styles/main.scss';

import { mapState } from 'vuex';
import { DEEP_LINK_KEY } from '@/router';
import AppLoading from '@/portal/components/AppLoading.vue';

export default {
  name: 'App',
  data() {
    return {
      transition: 'default',
      loading: true,
    };
  },
  computed: mapState('portal', [
    'isInMaintenance',
  ]),
  watch: {
    // eslint-disable-next-line
    '$route'(to, from) {
      this.transition = from.name === null || from.name === 'menu'
        ? 'menu' : 'default';
    },
    // Replay a deep link that a router guard stashed during boot (see
    // stashDeepLink in router.js). Only once sign-in finished AND the
    // account has an active profile — a profile-less account still
    // belongs in the new-player flow, so the stash is just dropped.
    loading(isLoading) {
      if (isLoading) return;
      const target = sessionStorage.getItem(DEEP_LINK_KEY);
      if (!target) return;
      sessionStorage.removeItem(DEEP_LINK_KEY);
      const { isSignedIn, activeProfile } = this.$store.state.portal;
      if (isSignedIn && activeProfile && target.startsWith('/')) {
        this.$router.push(target).catch(() => {});
      }
    },
  },
  methods: {
    logout() {
      this.$store.dispatch('portal/logout');
    },
  },
  components: { AppLoading },
};
</script>
