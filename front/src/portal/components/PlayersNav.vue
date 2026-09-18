<template>
  <!-- Rankings and Invites are one destination in the top bar
       ("Players"); this is how you get between them once you are there. -->
  <nav class="players-nav">
    <router-link
      class="players-nav-item"
      to="/standings">
      {{ $t('page.standings.title') }}
    </router-link>
    <router-link
      v-if="isSignedIn"
      class="players-nav-item"
      to="/invites">
      {{ $t('page.invites.title') }}
    </router-link>
  </nav>
</template>

<script>
export default {
  name: 'players-nav',
  computed: {
    // Invites are gated behind onlySignedInGuard, so offering the tab to
    // anyone else would just bounce them to the landing page.
    isSignedIn() { return this.$store.state.portal.isSignedIn; },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.players-nav {
  display: flex;
  gap: 4px;
  padding: 0 25px;
  background: rgba(0, 0, 0, .1);
  border-bottom: solid 1px $grey-default;
}

.players-nav-item {
  padding: 10px 14px;
  border-bottom: solid 2px transparent;
  color: inherit;
  font-size: 1.3rem;
  text-transform: uppercase;
  opacity: .6;
  white-space: nowrap;

  &:hover { opacity: .85; }

  &.router-link-active {
    opacity: 1;
    border-bottom-color: $primary;
    font-weight: bold;
  }
}

@media screen and (max-width: $mobile-breakpoint) {
  .players-nav {
    padding: 0 10px;
  }
}
</style>
