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

      <!-- Discord presence preferences — timezone tag + profile card.
           Editable pre-link too (they only take effect once linked). -->
      <div class="discord-presence">
        <h2>{{ $t('page.account_link_discord.presence_header') }}</h2>

        <div class="default-input">
          <label for="timezone">{{ $t('page.account_link_discord.timezone_label') }}</label>
          <select
            id="timezone"
            :disabled="saving"
            :value="account.timezone || ''"
            @change="saveField('timezone', $event.target.value || null)">
            <option value="">{{ $t('page.account_link_discord.timezone_none') }}</option>
            <optgroup
              v-for="group in timezoneGroups"
              :key="group.region"
              :label="group.region">
              <option
                v-for="zone in group.zones"
                :key="zone"
                :value="zone">
                {{ zone }}
              </option>
            </optgroup>
          </select>
        </div>

        <div class="discord-presence-detect">
          <button
            v-if="detectedTimezone && detectedTimezone !== account.timezone"
            class="default-button is-secondary"
            :disabled="saving"
            @click="saveField('timezone', detectedTimezone)">
            {{ $t('page.account_link_discord.timezone_detect', { zone: detectedTimezone }) }}
          </button>
          <p
            v-else-if="detectedTimezone"
            class="hint">
            {{ $t('page.account_link_discord.timezone_detect_match') }}
          </p>
        </div>

        <div class="discord-presence-option">
          <div class="checkbox-input">
            <input
              type="checkbox"
              id="discord_timezone_role"
              :checked="account.discord_timezone_role === true"
              :disabled="saving || !account.timezone"
              @change="saveField('discord_timezone_role', $event.target.checked)">
            <label for="discord_timezone_role">
              {{ $t('page.account_link_discord.timezone_role_label') }}
            </label>
          </div>
          <p class="hint">
            {{ $t('page.account_link_discord.timezone_role_hint') }}
          </p>
        </div>

        <div class="discord-presence-option">
          <div class="checkbox-input">
            <input
              type="checkbox"
              id="show_profile_in_discord"
              :checked="account.show_profile_in_discord === true"
              :disabled="saving"
              @change="saveField('show_profile_in_discord', $event.target.checked)">
            <label for="show_profile_in_discord">
              {{ $t('page.account_link_discord.show_profile_label') }}
            </label>
          </div>
          <p class="hint">
            {{ $t('page.account_link_discord.show_profile_hint') }}
          </p>
        </div>
      </div>

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
      saving: false,
      // IANA zone list from the browser; empty on engines without
      // Intl.supportedValuesOf (the select then only offers "none",
      // which is still a valid state).
      timezones: (typeof Intl.supportedValuesOf === 'function')
        ? Intl.supportedValuesOf('timeZone')
        : [],
    };
  },
  computed: {
    account() {
      return this.$store.state.portal.account;
    },
    // What the browser itself reports — one click beats scrolling 400+
    // zones. null if the engine can't say.
    detectedTimezone() {
      try {
        return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
      } catch (err) {
        return null;
      }
    },
    // The flat IANA list grouped by region prefix (America, Europe, …)
    // so manual hunting scans one optgroup instead of the whole planet.
    timezoneGroups() {
      const groups = new Map();
      this.timezones.forEach((zone) => {
        const region = zone.includes('/') ? zone.split('/')[0] : 'Other';
        if (!groups.has(region)) {
          groups.set(region, []);
        }
        groups.get(region).push(zone);
      });
      return Array.from(groups, ([region, zones]) => ({ region, zones }));
    },
  },
  methods: {
    async saveField(field, value) {
      this.saving = true;

      try {
        const { data } = await this.$axios.put(
          `/accounts/${this.account.id}`,
          { account: { [field]: value } },
        );
        this.$store.commit('portal/account', data);
      } catch (err) {
        this.$toastChangesetError(err);
      }

      this.saving = false;
    },

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

<style scoped>
/* The intro paragraph sits flush against the box below it without
   margin help — the default-input rule comes from a shared sheet
   that's tight on top spacing. Add breathing room here so the layout
   feels less cramped, matching the rhythm on the Info / Password
   sub-pages where each block has air around it. */
.account-link-discord-intro {
  margin-bottom: 1.5rem;
}

.account-link-discord-step {
  margin-top: 0.5rem;
}

.account-link-discord-actions {
  display: flex;
  gap: 0.75rem;
  margin: 1rem 0;
}

/* Space between the input/box and any following paragraph (e.g. the
   unlink note when linked, or the instructions when a code is shown). */
.account-link-discord-step .default-input + .account-link-discord-actions,
.account-link-discord-step .default-input + p,
.account-link-discord-step p + p {
  margin-top: 1rem;
}

/* Same spacing for the linked-state view (input + hint). */
.panel-content .default-input + .hint {
  margin-top: 1rem;
}

.discord-presence {
  margin-top: 2rem;
}

.discord-presence h2 {
  margin-bottom: 1rem;
}

.discord-presence select {
  width: 100%;
  padding: 6px;
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
}

.discord-presence-option {
  margin-top: 1rem;
}

.discord-presence-detect {
  margin-top: 0.75rem;
}
</style>
