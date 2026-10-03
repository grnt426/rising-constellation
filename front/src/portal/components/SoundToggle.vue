<template>
  <!-- Sound on/off for the whole app (music and effects), kept in the
       account's ambiance settings. The theme starts on the first click or
       Enter/Space, so this sits in the top bar where it can be reached
       right away (WCAG 1.4.2). -->
  <button
    type="button"
    class="sound-toggle bare-button"
    :class="{ 'is-muted': muted }"
    :aria-pressed="muted ? 'true' : 'false'"
    :aria-label="$t('a11y_portal.mute_sound')"
    v-tooltip="$t('a11y_portal.mute_sound')"
    @click="toggle">
    <svg
      class="icon"
      viewBox="0 0 20 20"
      aria-hidden="true"
      focusable="false">
      <path
        fill="currentColor"
        d="M3 7h3l5-4v14l-5-4H3z" />
      <path
        v-if="muted"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        d="M13 7.5l5 5M18 7.5l-5 5" />
      <path
        v-else
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        d="M13.5 6.5a5 5 0 0 1 0 7M15.5 4a8.5 8.5 0 0 1 0 12" />
    </svg>
  </button>
</template>

<script>
export default {
  name: 'sound-toggle',
  computed: {
    muted() {
      const { ambiance } = this.$store.state.portal.settings;
      return !!(ambiance && ambiance.muted);
    },
  },
  methods: {
    toggle() {
      this.$store.dispatch('portal/updateAmbiance', { muted: !this.muted });
    },
  },
};
</script>
