<template>
  <div class="panel-content is-small">
    <div class="panel-header">
      <h1 v-html="$tmd('page.account_password.header')" />

      <!-- Submits the form below (form= attribute), so Enter in a field
           works too. aria-disabled rather than disabled: a disabled
           default button blocks that implicit submit, and update() checks
           the fields anyway. -->
      <button
        type="submit"
        form="account-password-form"
        class="default-button"
        :class="{ disabled: !isValid }"
        :aria-disabled="!isValid ? 'true' : null">
        <template v-if="waiting">...</template>
        <template v-else>{{ $t('page.account_password.modify') }}</template>
      </button>
    </div>

    <v-scrollbar class="content">
      <form
        id="account-password-form"
        @submit.prevent="update">
        <div class="default-input">
          <label for="password1">{{ $t('page.account_password.password') }}</label>
          <input
            ref="password1"
            type="password"
            id="password1"
            autocomplete="new-password"
            v-model="password" />
        </div>

        <div class="default-input">
          <label for="password2">{{ $t('page.account_password.password_confirmation') }}</label>
          <input
            ref="password2"
            type="password"
            id="password2"
            autocomplete="new-password"
            :aria-invalid="mismatch ? 'true' : 'false'"
            :aria-describedby="mismatch ? 'password-mismatch' : null"
            v-model="passwordConfirmation" />
          <p
            v-if="mismatch"
            id="password-mismatch"
            class="field-error"
            role="alert">
            {{ $t('a11y_portal.passwords_mismatch') }}
          </p>
        </div>
      </form>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'account-password',
  data() {
    return {
      password: '',
      passwordConfirmation: '',
      waiting: false,
    };
  },
  computed: {
    account() { return this.$store.state.portal.account; },
    // Said only once both fields have something in them.
    mismatch() {
      return this.password !== '' && this.passwordConfirmation !== ''
        && this.password !== this.passwordConfirmation;
    },
    isValid() {
      return this.password !== '' && this.passwordConfirmation !== ''
        && this.password === this.passwordConfirmation
        && !this.waiting;
    },
  },
  methods: {
    async update() {
      if (!this.isValid) {
        // Send the user to the field that needs them.
        if (this.waiting) return;
        const field = this.password === '' ? 'password1' : 'password2';
        if (this.$refs[field]) this.$refs[field].focus();
        return;
      }

      this.waiting = true;

      try {
        await this.$axios.put(`/accounts/${this.account.id}`, {
          account: { password: this.password },
        });

        this.password = '';
        this.passwordConfirmation = '';
        this.$toasted.success(this.$t('page.account_password.update_success'));
      } catch (err) {
        this.$toastError(err);
      }

      this.waiting = false;
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.field-error {
  padding: 0 10px 8px;
  font-size: 1.3rem;
  color: $color-alert;
}
</style>
