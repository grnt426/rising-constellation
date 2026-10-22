<template>
  <div class="wk-account">
    <section class="wk-account-current">
      <template v-if="current">
        <p class="wk-account-open">
          <span class="wk-account-label">{{ $t('page.scenario_workshop.account.open') }}</span>
          <strong>{{ current.name }}</strong>
          <span
            v-if="!current.mine && current.author"
            class="wk-muted"> · {{ $t('page.scenario_workshop.account.by', { name: current.author.name }) }}</span>
        </p>
        <p class="wk-account-state">
          <span
            v-if="current.mine"
            class="wk-account-tag">{{ current.published_at ? $t('page.scenario_workshop.account.published') : $t('page.scenario_workshop.account.private') }}</span>
          <span v-if="!current.mine">{{ $t('page.scenario_workshop.account.theirs') }}</span>
          <span v-else-if="dirty">{{ $t('page.scenario_workshop.account.unsaved') }}</span>
          <span v-else>{{ $t('page.scenario_workshop.account.saved') }}</span>
        </p>
        <div class="wk-account-actions">
          <button
            v-if="current.mine"
            type="button"
            class="wk-mini"
            data-test="account-save"
            :disabled="saving || !dirty"
            @click="$emit('save', { asNew: false })">{{ $t('page.scenario_workshop.account.save') }}</button>
          <button
            type="button"
            class="wk-mini"
            data-test="account-save-new"
            :disabled="saving || full"
            @click="$emit('save', { asNew: true })">{{ current.mine ? $t('page.scenario_workshop.account.save_new') : $t('page.scenario_workshop.account.save_copy') }}</button>
          <button
            v-if="current.mine && !current.published_at"
            type="button"
            class="wk-mini"
            data-test="account-publish"
            :disabled="saving || dirty"
            :title="dirty ? $t('page.scenario_workshop.account.publish_save_first') : $t('page.scenario_workshop.account.publish_hint')"
            @click="$emit('publish')">{{ $t('page.scenario_workshop.account.publish') }}</button>
          <button
            v-if="current.mine && current.published_at"
            type="button"
            class="wk-mini"
            data-test="account-unpublish"
            :disabled="saving"
            @click="$emit('unpublish')">{{ $t('page.scenario_workshop.account.unpublish') }}</button>
        </div>
        <p
          v-if="current.mine && current.published_at"
          class="wk-muted wk-account-note">{{ $t('page.scenario_workshop.account.published_note') }}</p>
      </template>
      <template v-else>
        <p class="wk-muted">{{ $t('page.scenario_workshop.account.not_saved') }}</p>
        <button
          type="button"
          class="wk-mini"
          data-test="account-save-new"
          :disabled="saving || full"
          @click="$emit('save', { asNew: true })">{{ $t('page.scenario_workshop.account.save_first') }}</button>
      </template>
      <p
        v-if="full && (!current || !current.mine)"
        class="wk-muted">{{ $t('page.scenario_workshop.account.full', { limit }) }}</p>
    </section>

    <section>
      <h3 class="wk-account-title">{{ $t('page.scenario_workshop.account.mine', { count: mine.length, limit }) }}</h3>
      <p
        v-if="!mine.length"
        class="wk-muted">{{ $t('page.scenario_workshop.account.mine_empty') }}</p>
      <ul class="wk-account-list">
        <li
          v-for="s in mine"
          :key="s.id"
          :class="{ 'is-current': current && current.id === s.id }">
          <div class="wk-account-row">
            <span class="wk-account-name">{{ s.name }}</span>
            <span
              v-if="s.published_at"
              class="wk-account-tag">{{ $t('page.scenario_workshop.account.published') }}</span>
            <span
              v-if="s.error_count"
              class="wk-account-tag is-alert">{{ $tc('page.scenario_workshop.account.errors', s.error_count, { count: s.error_count }) }}</span>
            <button
              type="button"
              class="wk-mini"
              :disabled="saving"
              @click="$emit('open', s)">{{ $t('page.scenario_workshop.account.open_one') }}</button>
            <button
              type="button"
              class="wk-mini"
              :aria-label="$t('page.scenario_workshop.account.delete_named', { name: s.name })"
              :disabled="saving"
              @click="remove(s)">{{ $t('page.scenario_workshop.account.delete') }}</button>
          </div>
          <p
            v-if="s.description"
            class="wk-muted wk-account-description">{{ s.description }}</p>
        </li>
      </ul>
    </section>

    <section>
      <h3 class="wk-account-title">{{ $t('page.scenario_workshop.account.published_title') }}</h3>
      <input
        v-model="search"
        type="search"
        class="wk-account-search"
        :placeholder="$t('page.scenario_workshop.account.search')"
        :aria-label="$t('page.scenario_workshop.account.search')"
        @input="searchSoon">
      <p
        v-if="published && !published.length"
        class="wk-muted">{{ $t('page.scenario_workshop.account.published_empty') }}</p>
      <ul class="wk-account-list">
        <li
          v-for="s in published || []"
          :key="s.id">
          <div class="wk-account-row">
            <span class="wk-account-name">{{ s.name }}</span>
            <span
              v-if="s.author"
              class="wk-muted">{{ $t('page.scenario_workshop.account.by', { name: s.author.name }) }}</span>
            <button
              type="button"
              class="wk-mini"
              :disabled="saving"
              @click="$emit('open', s)">{{ $t('page.scenario_workshop.account.open_one') }}</button>
          </div>
          <p
            v-if="s.description"
            class="wk-muted wk-account-description">{{ s.description }}</p>
        </li>
      </ul>
    </section>
  </div>
</template>

<script>
// The Scripts tab: the script open in the workshop as the account knows it,
// the account's saved scripts (ten at most) and the published ones. Saving,
// opening and publishing go through the workshop, which holds the program.
export default {
  name: 'account-scripts',
  props: {
    current: { type: Object, default: null },
    dirty: { type: Boolean, default: false },
    saving: { type: Boolean, default: false },
  },
  data() {
    return {
      mine: [], limit: 10, published: null, search: '', searchTimer: null,
    };
  },
  computed: {
    full() { return this.mine.length >= this.limit; },
  },
  mounted() { this.refresh(); },
  beforeDestroy() { clearTimeout(this.searchTimer); },
  methods: {
    async refresh() {
      try {
        const [mine, published] = await Promise.all([
          this.$axios.get('/edict/scripts'),
          this.$axios.get('/edict/scripts/published', { params: { search: this.search || undefined } }),
        ]);
        this.mine = mine.data.scripts;
        this.limit = mine.data.limit;
        this.published = published.data.scripts;
      } catch (e) {
        this.$toasted.error(this.$t('page.scenario_workshop.account.load_failed'));
      }
    },
    searchSoon() {
      clearTimeout(this.searchTimer);
      this.searchTimer = setTimeout(async () => {
        try {
          const { data } = await this.$axios.get('/edict/scripts/published', { params: { search: this.search || undefined } });
          this.published = data.scripts;
        } catch (e) {
          // keep the last list
        }
      }, 300);
    },
    async remove(s) {
      if (!window.confirm(this.$t('page.scenario_workshop.account.delete_confirm', { name: s.name }))) return;
      try {
        await this.$axios.delete(`/edict/scripts/${s.id}`);
        this.$emit('deleted', s);
        await this.refresh();
      } catch (e) {
        this.$toasted.error(this.$t('page.scenario_workshop.account.failed'));
      }
    },
  },
};
</script>
