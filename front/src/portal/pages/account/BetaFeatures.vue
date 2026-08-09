<template>
  <div class="panel-content is-small">
    <div class="panel-header">
      <h1 v-html="$tmd('page.account_beta_features.header')" />
    </div>

    <v-scrollbar class="content">
      <div
        class="account-beta-features-intro"
        v-html="$tmd('page.account_beta_features.intro')" />

      <div
        v-for="feature in featureList"
        :key="feature"
        class="account-beta-feature">
        <div class="checkbox-input">
          <input
            type="checkbox"
            :id="`beta-${feature}`"
            :checked="features[feature] === true"
            :disabled="saving"
            @change="toggle(feature, $event.target.checked)">
          <label :for="`beta-${feature}`">
            {{ $t(`page.account_beta_features.${feature}.label`) }}
          </label>
        </div>
        <p class="hint">
          {{ $t(`page.account_beta_features.${feature}.description`) }}
        </p>
      </div>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'account-beta-features',
  data() {
    return {
      saving: false,
      // Mirrors the backend whitelist (RC.Accounts.AccountFeature.known/0);
      // each key needs a label + description under
      // page.account_beta_features.<key> in the locales.
      featureList: ['agent_fan_display', 'calculator', 'mobile_ui'],
    };
  },
  computed: {
    features() {
      return this.$store.state.portal.features;
    },
  },
  methods: {
    async toggle(feature, enabled) {
      this.saving = true;

      try {
        await this.$store.dispatch('portal/setFeature', { feature, enabled });
        this.$toasted.success(this.$t('page.account_beta_features.saved'));
      } catch (err) {
        this.$toastError(err);
      }

      this.saving = false;
    },
  },
  mounted() {
    // Refresh on mount so the toggles reflect changes made elsewhere
    // (another tab, another device) rather than the boot-time snapshot.
    this.$store.dispatch('portal/fetchFeatures');
  },
};
</script>

<style scoped>
.account-beta-features-intro {
  margin-bottom: 1.5rem;
}

.account-beta-feature {
  margin-top: 0.5rem;
}

.account-beta-feature .hint {
  margin: 0.5rem 0 1.5rem;
}
</style>
