<template>
  <default-layout>
    <div class="panel-content is-small">
      <div class="panel-header">
        <h1>
          <strong>{{ $t('page.invites.title') }}</strong>
        </h1>
      </div>

      <v-scrollbar class="content">
        <section v-html="$tmd('page.invites.description')" />

        <hr class="margin">

        <button
          class="default-button"
          :disabled="generating"
          @click="generate">
          <template v-if="generating">...</template>
          <template v-else>{{ $t('page.invites.generate_button') }}</template>
        </button>

        <div
          v-if="link"
          class="default-input"
          style="margin-top: 24px;">
          <label for="invite-link">{{ $t('page.invites.link_label') }}</label>
          <input
            type="text"
            id="invite-link"
            readonly
            :value="link"
            @focus="$event.target.select()" />
        </div>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import { copyToClipboard } from '@/utils/clipboard';

export default {
  name: 'invites',
  data() {
    return {
      link: null,
      generating: false,
    };
  },
  methods: {
    async generate() {
      if (this.generating) return;
      this.generating = true;

      try {
        const { data } = await this.$axios.post('/invites');
        this.link = data.url;

        const copied = await copyToClipboard(data.url);
        if (copied) {
          this.$toasted.success(this.$t('page.invites.copied'));
        } else {
          this.$toasted.success(this.$t('page.invites.generated_no_copy'));
        }
      } catch (err) {
        const message = err.response && err.response.data && err.response.data.message;
        if (message === 'invite_generation_disabled') {
          this.$toastError(this.$t('page.invites.error_disabled'));
        } else if (message === 'rate_limited') {
          this.$toastError(this.$t('page.invites.error_rate_limited'));
        } else {
          this.$toastError(this.$t('page.invites.error_generic'));
        }
      }

      this.generating = false;
    },
  },
  components: {
    DefaultLayout,
  },
};
</script>
