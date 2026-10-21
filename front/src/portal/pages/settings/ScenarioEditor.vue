<template>
  <default-layout>
    <div class="fluid-panel is-not-full-sized">
      <v-scrollbar class="panel-aside">
        <settings-nav />

        <div class="panel-aside-bloc">
          <div class="radio-input">
            <div
              id="scenario-editor-accept"
              class="label">
              {{ $t('page.settings.scenario_editor.accept.title') }}
            </div>
            <div
              class="content"
              role="radiogroup"
              aria-labelledby="scenario-editor-accept">
              <div
                v-for="key in acceptKeys"
                :key="key"
                class="content-item">
                <input
                  type="radio"
                  :id="`scenario-accept-${key}`"
                  :value="key"
                  v-model="accept"
                  @change="save">
                <label :for="`scenario-accept-${key}`">
                  <strong>{{ $t(`page.settings.scenario_editor.accept.${key.replace('+', '_')}`) }}</strong>
                </label>
              </div>
            </div>
          </div>

          <div class="checkbox-input">
            <input
              type="checkbox"
              id="scenario-editor-suggest"
              v-model="suggest"
              @change="save">
            <label for="scenario-editor-suggest">
              {{ $t('page.settings.scenario_editor.suggest') }}
            </label>
          </div>
        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-small">
        <div class="panel-header">
          <h1>
            <strong>{{ $t('page.settings.scenario_editor.title') }}</strong>
          </h1>
        </div>

        <v-scrollbar class="content">
          <p class="scenario-editor-intro">{{ $t('page.settings.scenario_editor.intro') }}</p>
          <ul class="scenario-editor-keys">
            <li>{{ $t('page.settings.scenario_editor.keys.navigate') }}</li>
            <li>{{ $t('page.settings.scenario_editor.keys.accept', { key: $t(`page.settings.scenario_editor.accept.${accept.replace('+', '_')}`) }) }}</li>
            <li>{{ $t('page.settings.scenario_editor.keys.close') }}</li>
            <li>{{ $t('page.settings.scenario_editor.keys.open') }}</li>
          </ul>
          <p class="scenario-editor-note">{{ $t('page.settings.scenario_editor.note') }}</p>
          <hr class="margin">
        </v-scrollbar>
      </div>
    </div>
  </default-layout>
</template>

<script>
import DefaultLayout from '@/portal/layouts/Default.vue';
import SettingsNav from '@/portal/components/SettingsNav.vue';
import { ACCEPT_KEYS } from '@/portal/workshop/editor-settings';

// Settings → Scenario editor: how the Scenario Workshop's code view offers
// suggestions (Account.settings.scenario_editor).
export default {
  name: 'scenario-editor-settings',
  components: { DefaultLayout, SettingsNav },
  data() {
    const saved = this.$store.getters['portal/scenarioEditor'];
    return { acceptKeys: ACCEPT_KEYS, accept: saved.accept, suggest: saved.suggest };
  },
  methods: {
    save() {
      this.$store.dispatch('portal/setScenarioEditor', { accept: this.accept, suggest: this.suggest });
    },
  },
};
</script>

<style lang="scss" scoped>
.scenario-editor-intro,
.scenario-editor-note {
  margin-bottom: 12px;
  line-height: 1.5;
}

.scenario-editor-keys {
  margin: 0 0 12px 18px;
  list-style: disc;
  line-height: 1.6;
}
</style>
