<template>
  <div class="panel-content is-small">
    <div class="panel-header">
      <h1 v-html="$tmd('page.account_link_discord.header')" />

      <button
        v-if="account.discord_id"
        class="default-button"
        @click="refreshAccount">
        {{ $t('page.account_link_discord.refresh') }}
      </button>
    </div>

    <v-scrollbar class="content">
      <div
        class="account-link-discord-intro"
        v-html="$tmd('page.account_link_discord.intro')" />

      <!-- Already linked: status + unlink note -->
      <template v-if="account.discord_id">
        <div class="default-input">
          <label for="discord_id">
            {{ $t('page.account_link_discord.field_discord_id') }}
          </label>
          <input
            type="text"
            id="discord_id"
            disabled="true"
            :value="account.discord_id" />
        </div>

        <p
          class="hint"
          v-html="$tmd('page.account_link_discord.unlink_note')" />
      </template>

      <!-- Not linked: code generation flow -->
      <template v-else>
        <!-- Step 1: generate a code -->
        <div
          v-if="!code"
          class="account-link-discord-step">
          <button
            class="default-button"
            :disabled="waiting"
            @click="generateCode">
            <template v-if="waiting">...</template>
            <template v-else>{{ $t('page.account_link_discord.generate') }}</template>
          </button>
        </div>

        <!-- Step 2: code shown, instructions + copy + refresh -->
        <div
          v-else
          class="account-link-discord-step">
          <div class="default-input">
            <label for="code">{{ $t('page.account_link_discord.code_label') }}</label>
            <input
              type="text"
              id="code"
              readonly
              ref="codeInput"
              :value="code"
              @focus="$event.target.select()" />
          </div>

          <div class="account-link-discord-actions">
            <button
              class="default-button"
              @click="copyCode">
              {{ copied
                ? $t('page.account_link_discord.copied')
                : $t('page.account_link_discord.copy') }}
            </button>

            <button
              class="default-button is-secondary"
              @click="refreshAccount">
              {{ $t('page.account_link_discord.refresh') }}
            </button>
          </div>

          <p v-html="$tmd('page.account_link_discord.instructions', { code })" />

          <p class="hint">
            {{ $t('page.account_link_discord.expires_in', { minutes: 5 }) }}
          </p>
        </div>
      </template>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'account-link-discord',
  data() {
    return {
      // The most recently minted code (server returns one-shot value).
      // Cleared on successful link refresh.
      code: null,
      waiting: false,
      copied: false,
    };
  },
  computed: {
    account() {
      return this.$store.state.portal.account;
    },
  },
  methods: {
    async generateCode() {
      if (this.waiting) {
        return;
      }
      this.waiting = true;
      this.copied = false;

      try {
        const { data } = await this.$axios.post('/discord/link-code');
        this.code = data.code;
      } catch (err) {
        this.$toastError(err);
      }

      this.waiting = false;
    },

    async copyCode() {
      if (!this.code) {
        return;
      }

      // Prefer the async Clipboard API; fall back to selecting the input
      // (works on older browsers and when the page isn't served over HTTPS).
      try {
        await navigator.clipboard.writeText(this.code);
        this.copied = true;
        setTimeout(() => { this.copied = false; }, 2000);
      } catch (err) {
        if (this.$refs.codeInput) {
          this.$refs.codeInput.select();
        }
      }
    },

    async refreshAccount() {
      // Pull the latest account row. Used when the user comes back from
      // Discord after running /link — the store-cached account is stale
      // until we refetch.
      try {
        const { data } = await this.$axios.get('/account');
        this.$store.commit('portal/account', data);

        // Once linked, the generated code becomes uninteresting — clear it
        // so the UI flips cleanly to the "already linked" state.
        if (data.discord_id) {
          this.code = null;
          this.$toasted.success(this.$t('page.account_link_discord.refresh_success'));
        }
      } catch (err) {
        this.$toastError(err);
      }
    },
  },
  mounted() {
    // Auto-refresh on mount to catch the case where the user linked
    // elsewhere and is now viewing this page with a stale store.
    this.refreshAccount();
  },
};
</script>
