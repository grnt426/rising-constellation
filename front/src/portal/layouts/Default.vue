<template>
  <div class="portal-context">
    <div class="layout">
      <div class="layout-topbar">
        <div class="navbar top">
          <div class="navbar-left">
            <router-link
              class="navbar-main-button"
              to="/">
              <div class="navbar-main-button-icon">
                <svgicon class="icon" name="logo/simple" />
              </div>
            </router-link>

            <router-link
              class="navbar-button-title"
              to="/play">
              {{ $t('layout.default.play') }}
            </router-link>

            <!--
              Forge Stage 2 — the Forge link is now visible to any signed-in
              account, not just admins. account is always present here
              because Default.vue only renders inside the authenticated
              router scope.
            -->
            <template v-if="account">
              <router-link
                class="navbar-button-title"
                to="/create">
                {{ $t('layout.default.forge') }}
              </router-link>

              <!--
              <a
                class="navbar-button-title disabled"
                href="#">
                Arène
              </a>

              <a
                class="navbar-button-title disabled"
                href="#">
                Citadelle
              </a>
              -->
            </template>

            <router-link
              class="navbar-button-title"
              to="/standings">
              {{ $t('layout.default.standings') }}
            </router-link>

            <router-link
              class="navbar-button-title"
              to="/invites">
              {{ $t('layout.default.invites') }}
            </router-link>

            <router-link
              class="navbar-button-title"
              to="/fight-simulator">
              {{ $t('layout.default.simulator') }}
            </router-link>
          </div>

          <div class="navbar-right">
            <div class="navbar-group-buttons right">
              <router-link
                class="navbar-button-account"
                to="/account">
                <div class="name">{{ activeProfile.name }}</div>
                <div class="info">online</div>
              </router-link>

              <router-link
                class="navbar-button-icon"
                v-tooltip="$t('layout.default.settings')"
                to="/settings">
                <svgicon class="icon" name="options" />
              </router-link>
              <a
                class="navbar-button-icon disabled"
                v-tooltip="$t('layout.default.not_yet_available')"
                href="#">
                <svgicon class="icon" name="infinite" />
              </a>
            </div>

            <router-link
              class="navbar-main-button"
              :to="`/profiles/${activeProfile.id}?mode=edit`">
              <div class="navbar-main-button-image">
                <img :src="avatarProfile" />
              </div>
            </router-link>
          </div>
        </div>
      </div>

      <div
        v-if="account && account.status === 'registered'"
        class="verify-email-banner">
        <!-- Hard bounce recorded (SES → /api/mail/events): resending to a
             dead address is pointless, so the resend button is replaced by
             a "sign up again" notice. -->
        <template v-if="account.email_delivery_failed_at">
          <span>{{ $t('layout.default.verify_email_bounced') }}</span>
        </template>
        <template v-else>
          <span>{{ $t('layout.default.verify_email') }}</span>
          <button
            class="default-button"
            :disabled="verifySent"
            @click="resendVerification">
            <template v-if="verifySent">{{ $t('layout.default.verify_email_sent') }}</template>
            <template v-else>{{ $t('layout.default.verify_email_resend') }}</template>
          </button>
        </template>
      </div>

      <div class="layout-content">
        <slot />
      </div>
    </div>
  </div>
</template>

<script>
import Path from '@/utils/path';

export default {
  name: 'default-layout',
  data() {
    return { verifySent: false };
  },
  computed: {
    account() { return this.$store.state.portal.account; },
    activeProfile() { return this.$store.state.portal.activeProfile; },
    avatarProfile() { return Path.relative(`data/avatars/${this.activeProfile.avatar}`); },
  },
  methods: {
    async resendVerification() {
      this.verifySent = true;

      try {
        await this.$axios.post('/accounts/request-email-verification', { email: this.account.email });
        this.$toasted.success(this.$t('layout.default.verify_email_sent'));
      } catch (err) {
        this.verifySent = false;
        this.$toastError(err);
      }
    },
  },
};
</script>

<style lang="scss" scoped>
.verify-email-banner {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 16px;
  padding: 8px 16px;
  background-color: rgba(193, 154, 61, 0.15);
  border-bottom: 1px solid rgba(193, 154, 61, 0.4);
}
</style>
