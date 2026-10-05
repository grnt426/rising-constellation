<template>
  <!-- The settings screens. `exact`: /settings is also the start of every
       other screen's path. -->
  <nav
    class="panel-aside-links"
    :aria-label="$t('page.settings.title')">
    <router-link
      to="/settings"
      exact>
      {{ $t('page.settings.nav.general') }}
    </router-link>

    <router-link to="/settings/crosshair">
      {{ $t('page.settings.nav.crosshair') }}
    </router-link>
  </nav>
</template>

<script>
export default {
  name: 'settings-nav',
};
</script>
