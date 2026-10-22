<template>
  <div class="scenario-scripts">
    <h3 class="scenario-scripts-title">
      <svgicon
        name="code"
        aria-hidden="true" />
      {{ $t('page.create.scenario_scripts.title') }}
    </h3>
    <p class="scenario-scripts-hint">{{ $t('page.create.scenario_scripts.hint') }}</p>

    <ul
      v-if="attached.length"
      class="scenario-scripts-list">
      <li
        v-for="(s, i) in attached"
        :key="`${s.id}-${i}`"
        class="scenario-script">
        <div class="scenario-script-head">
          <span class="scenario-script-name">{{ s.name }}</span>
          <span
            v-if="s.author"
            class="scenario-script-author">{{ $t('page.create.common.by') }} {{ s.author }}</span>
          <button
            type="button"
            class="scenario-script-remove"
            :aria-label="$t('page.create.scenario_scripts.remove_named', { name: s.name })"
            @click="remove(i)">{{ $t('page.create.scenario_scripts.remove') }}</button>
        </div>
        <p
          v-if="checking"
          class="scenario-script-state">{{ $t('page.create.scenario_scripts.checking') }}</p>
        <p
          v-else-if="checkFailed"
          class="scenario-script-state">{{ $t('page.create.scenario_scripts.check_failed') }}</p>
        <p
          v-else-if="checks[i] && !problems(checks[i]).length"
          class="scenario-script-state is-ok">{{ $t('page.create.scenario_scripts.fits') }}</p>
        <ul
          v-if="!checking && checks[i] && checks[i].diagnostics.length"
          class="scenario-script-problems">
          <li
            v-for="(d, j) in checks[i].diagnostics"
            :key="j"
            :class="`is-${d.severity}`">{{ d.message }}</li>
        </ul>
      </li>
    </ul>
    <p
      v-else
      class="scenario-scripts-none">{{ $t('page.create.scenario_scripts.none') }}</p>

    <button
      v-if="attached.length < max && !pickerOpen"
      type="button"
      class="default-button"
      @click="openPicker">{{ $t('page.create.scenario_scripts.attach') }}</button>
    <p
      v-else-if="attached.length >= max"
      class="scenario-scripts-none">{{ $t('page.create.scenario_scripts.max', { max }) }}</p>

    <div
      v-if="pickerOpen"
      class="scenario-scripts-picker"
      role="dialog"
      :aria-label="$t('page.create.scenario_scripts.attach')">
      <div
        class="scenario-scripts-tabs"
        role="tablist">
        <button
          v-for="t in ['mine', 'published']"
          :key="t"
          type="button"
          role="tab"
          :aria-selected="String(tab === t)"
          :class="{ 'is-active': tab === t }"
          @click="setTab(t)">{{ $t(`page.create.scenario_scripts.tab_${t}`) }}</button>
        <button
          type="button"
          class="scenario-scripts-close"
          :aria-label="$t('page.create.scenario_scripts.close')"
          @click="pickerOpen = false">×</button>
      </div>
      <input
        v-if="tab === 'published'"
        v-model="search"
        type="search"
        class="scenario-scripts-search"
        :placeholder="$t('page.create.scenario_scripts.search')"
        :aria-label="$t('page.create.scenario_scripts.search')"
        @input="searchSoon">
      <p
        v-if="loadingList"
        class="scenario-scripts-none">{{ $t('page.create.scenario_scripts.loading') }}</p>
      <p
        v-else-if="!choices.length"
        class="scenario-scripts-none">
        {{ $t(`page.create.scenario_scripts.empty_${tab}`) }}
        <router-link
          v-if="tab === 'mine'"
          to="/scenario-workshop">{{ $t('page.create.scenario_scripts.to_workshop') }}</router-link>
      </p>
      <ul
        v-else
        class="scenario-scripts-choices">
        <li
          v-for="s in choices"
          :key="s.id">
          <div class="scenario-script-head">
            <span class="scenario-script-name">{{ s.name }}</span>
            <span
              v-if="!s.mine && s.author"
              class="scenario-script-author">{{ $t('page.create.common.by') }} {{ s.author.name }}</span>
            <span
              v-if="s.mine && s.published_at"
              class="scenario-script-tag">{{ $t('page.create.scenario_scripts.published') }}</span>
            <button
              type="button"
              class="scenario-script-add"
              :disabled="isAttached(s)"
              @click="attach(s)">{{ isAttached(s) ? $t('page.create.scenario_scripts.attached') : $t('page.create.scenario_scripts.attach_one') }}</button>
          </div>
          <p
            v-if="s.description"
            class="scenario-script-description">{{ s.description }}</p>
          <p
            v-if="s.error_count"
            class="scenario-script-state is-warning">{{ $tc('page.create.scenario_scripts.has_errors', s.error_count, { count: s.error_count }) }}</p>
        </li>
      </ul>
    </div>

    <p class="scenario-scripts-privacy">{{ $t('page.create.scenario_scripts.privacy') }}</p>
  </div>
</template>

<script>
// The scripts a Forge scenario attaches (Edict): picked from the author's
// own and the published ones, checked against this map as they change.
// The scenario keeps only their ids here; saving freezes each one's current
// version on the server (RC.Scripts.attach/3).
export default {
  name: 'scenario-scripts',
  props: {
    gameData: { type: Object, required: true },
    scenarioId: { type: [Number, String], default: null },
  },
  data() {
    return {
      max: 3,
      checks: [],
      checking: false,
      checkFailed: false,
      checkSeq: 0,
      checkTimer: null,
      pickerOpen: false,
      tab: 'mine',
      mine: null,
      published: null,
      search: '',
      searchTimer: null,
      loadingList: false,
    };
  },
  computed: {
    attached() {
      const list = this.gameData.scripts;
      return Array.isArray(list) ? list.filter((s) => s && s.id != null) : [];
    },
    choices() { return (this.tab === 'mine' ? this.mine : this.published) || []; },
    // what the check depends on besides the scripts themselves
    mapKey() {
      const gd = this.gameData;
      return JSON.stringify([gd.speed, gd.time_limit, (gd.factions || []).map((f) => f.key), (gd.systems || []).length]);
    },
  },
  watch: {
    attached() { this.checkSoon(); },
    mapKey() { this.checkSoon(); },
  },
  mounted() { this.checkSoon(); },
  beforeDestroy() {
    clearTimeout(this.checkTimer);
    clearTimeout(this.searchTimer);
  },
  methods: {
    isAttached(s) { return this.attached.some((a) => a.id === s.id); },
    // warnings and errors; notes ("info") are worth knowing, not problems
    problems(check) { return check.diagnostics.filter((d) => d.severity !== 'info'); },
    emit(list) { this.$emit('change', list); },
    attach(s) {
      if (this.isAttached(s) || this.attached.length >= this.max) return;
      this.emit([...this.attached, {
        id: s.id, name: s.name, description: s.description, author: s.author && s.author.name,
      }]);
      if (this.attached.length + 1 >= this.max) this.pickerOpen = false;
    },
    remove(i) { this.emit(this.attached.filter((_, j) => j !== i)); },
    async openPicker() {
      this.pickerOpen = true;
      await this.setTab(this.tab);
    },
    async setTab(t) {
      this.tab = t;
      if (t === 'mine' && this.mine === null) await this.load('mine');
      if (t === 'published' && this.published === null) await this.load('published');
    },
    searchSoon() {
      clearTimeout(this.searchTimer);
      this.searchTimer = setTimeout(() => this.load('published'), 300);
    },
    async load(which) {
      this.loadingList = true;
      try {
        if (which === 'mine') {
          const { data } = await this.$axios.get('/edict/scripts');
          this.mine = data.scripts;
        } else {
          const { data } = await this.$axios.get('/edict/scripts/published', { params: { search: this.search || undefined } });
          this.published = data.scripts;
        }
      } catch (e) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      } finally {
        this.loadingList = false;
      }
    },
    checkSoon() {
      clearTimeout(this.checkTimer);
      if (!this.attached.length) {
        this.checks = [];
        return;
      }
      this.checking = true;
      this.checkTimer = setTimeout(() => this.check(), 300);
    },
    // Each script against this map: its setup, and a dry start for a player
    // of every faction (Edict.Attachment). The map goes without its systems'
    // details: only their count matters.
    async check() {
      this.checkSeq += 1;
      const seq = this.checkSeq;
      const gd = this.gameData;
      const slim = {
        speed: gd.speed,
        time_limit: gd.time_limit,
        factions: gd.factions || [],
        systems: (gd.systems || []).map(() => null),
        game_mode_type: gd.game_mode_type,
      };
      try {
        const { data } = await this.$axios.post('/edict/check-scenario', {
          game_data: slim,
          scripts: this.attached.map((s) => s.id),
          scenario_id: this.scenarioId || undefined,
        });
        if (seq !== this.checkSeq) return;
        this.checks = data.checks;
        this.max = data.max_scripts || this.max;
        this.checkFailed = false;
      } catch (e) {
        if (seq === this.checkSeq) this.checkFailed = true;
      } finally {
        if (seq === this.checkSeq) this.checking = false;
      }
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.scenario-scripts {
  margin: 10px 0;
}

.scenario-scripts-title {
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 0 0 4px;
  font-size: 1.4rem;
  text-transform: uppercase;

  svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
  }
}

.scenario-scripts-hint,
.scenario-scripts-none,
.scenario-scripts-privacy,
.scenario-script-description {
  margin: 4px 0;
  opacity: 0.75;
}

.scenario-scripts-list,
.scenario-scripts-choices,
.scenario-script-problems {
  margin: 6px 0;
  padding: 0;
  list-style: none;
}

.scenario-script,
.scenario-scripts-choices > li {
  margin-bottom: 8px;
  padding: 6px 8px;
  border: solid 1px rgba(255, 255, 255, 0.15);
}

.scenario-script-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px;
}

.scenario-script-name {
  font-weight: bold;
}

.scenario-script-author,
.scenario-script-tag {
  opacity: 0.7;
}

.scenario-script-remove,
.scenario-script-add {
  margin-left: auto;
  padding: 1px 8px;
  border: solid 1px rgba(255, 255, 255, 0.4);
  background: transparent;
  color: inherit;
  cursor: pointer;

  &:disabled {
    opacity: 0.5;
    cursor: default;
  }
}

.scenario-script-state {
  margin: 4px 0 0;
  opacity: 0.8;

  &.is-ok::before {
    content: '✓ ';
  }

  &.is-warning {
    color: $color-alert;
  }
}

.scenario-script-problems li {
  margin-top: 4px;

  &.is-warning,
  &.is-error {
    color: $color-alert;
  }

  &.is-error {
    font-weight: bold;
  }

  &.is-info {
    opacity: .85;
  }
}

.scenario-scripts-picker {
  margin: 8px 0;
  padding: 8px;
  border: solid 1px rgba(255, 255, 255, 0.3);
  background: rgba(0, 0, 0, 0.3);
}

.scenario-scripts-tabs {
  display: flex;
  gap: 4px;
  margin-bottom: 6px;

  button {
    padding: 2px 8px;
    border: solid 1px rgba(255, 255, 255, 0.25);
    background: transparent;
    color: inherit;
    cursor: pointer;

    &.is-active {
      background: rgba(255, 255, 255, 0.15);
    }
  }

  .scenario-scripts-close {
    margin-left: auto;
  }
}

.scenario-scripts-search {
  width: 100%;
  margin-bottom: 6px;
  padding: 3px 6px;
}
</style>
