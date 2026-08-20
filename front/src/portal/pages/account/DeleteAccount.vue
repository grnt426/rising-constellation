<template>
  <div class="panel-content is-small">
    <div class="panel-header">
      <h1 v-html="$tmd('page.account_delete.header')" />

      <button
        v-if="!sent"
        class="default-button"
        :disabled="!isValid"
        @click="requestDeletion">
        <template v-if="waiting">...</template>
        <template v-else>{{ $t('page.account_delete.request') }}</template>
      </button>
    </div>

    <v-scrollbar class="content">
      <template v-if="sent">
        <p>{{ $t('page.account_delete.sent') }}</p>
      </template>
      <template v-else>
        <p>{{ $t('page.account_delete.explain_1') }}</p>
        <p>{{ $t('page.account_delete.explain_2') }}</p>
        <p>{{ $t('page.account_delete.explain_3') }}</p>

        <div class="default-input">
          <label for="delete-password">{{ $t('page.account_delete.password') }}</label>
          <input
            type="password"
            id="delete-password"
            placeholder="___"
            v-model="password" />
        </div>
      </template>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'account-delete',
  data() {
    return {
      password: '',
      waiting: false,
      sent: false,
    };
  },
  computed: {
    isValid() { return this.password !== '' && !this.waiting; },
  },
  methods: {
    async requestDeletion() {
      if (!this.isValid) return;
      this.waiting = true;

      try {
        await this.$axios.post('/account/deletion', { password: this.password });
        this.sent = true;
        this.password = '';
      } catch (err) {
        const message = err.response && err.response.data && err.response.data.message;
        if (message === 'invalid_password') {
          this.$toasted.error(this.$t('page.account_delete.invalid_password'));
        } else {
          this.$toastError(err);
        }
      }

      this.waiting = false;
    },
  },
};
</script>
