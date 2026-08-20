<template>
  <div class="account-locked">
    <div class="locked-card">
      <h1>{{ $t('page.account_locked.header') }}</h1>

      <p v-if="daysLeft !== null">
        {{ $t('page.account_locked.days_left', { days: daysLeft }) }}
      </p>
      <p>{{ $t('page.account_locked.explain_locked') }}</p>
      <p>{{ $t('page.account_locked.explain_policy') }}</p>

      <div class="actions">
        <button
          class="default-button"
          :disabled="waiting"
          @click="cancelDeletion">
          {{ $t('page.account_locked.cancel') }}
        </button>
        <button
          class="default-button"
          :disabled="waiting"
          @click="continueDeletion">
          {{ $t('page.account_locked.continue') }}
        </button>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'account-locked',
  data() {
    return {
      daysLeft: null,
      waiting: false,
    };
  },
  async mounted() {
    try {
      const { data } = await this.$axios.get('/account/deletion');

      if (data.status !== 'deletion_pending') {
        // Nothing pending (stale state or a direct visit): back to the menu.
        this.$router.push('/');
        return;
      }

      this.daysLeft = data.days_left;
    } catch (_err) {
      // A failed status fetch should not trap the user without the page's
      // two actions; the texts render without the day count.
    }
  },
  methods: {
    async cancelDeletion() {
      this.waiting = true;

      try {
        await this.$axios.post('/account/deletion/cancel', {});
        const { data } = await this.$axios.get('/account');
        this.$store.commit('portal/account', data);
        this.$router.push('/');
      } catch (err) {
        this.$toastError(err);
        this.waiting = false;
      }
    },
    continueDeletion() {
      this.waiting = true;
      this.$store.dispatch('portal/logout');
    },
  },
};
</script>

<style lang="scss" scoped>
.account-locked {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;

  .locked-card {
    max-width: 560px;
    padding: 40px;

    h1 {
      margin-bottom: 20px;
    }

    p {
      margin-bottom: 12px;
      line-height: 1.5;
    }

    .actions {
      display: flex;
      gap: 12px;
      margin-top: 24px;
    }
  }
}
</style>
