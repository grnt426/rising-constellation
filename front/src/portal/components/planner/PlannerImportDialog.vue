<template>
  <div
    class="planner-dialog-root"
    @keydown.esc="$emit('close')">
    <div
      class="planner-dialog-backdrop"
      @click="$emit('close')" />
    <div
      class="planner-dialog"
      role="dialog"
      aria-modal="true"
      :aria-label="$t('page.system_planner.import_title')">
      <h2>{{ $t('page.system_planner.import_title') }}</h2>
      <p class="planner-dialog-hint">{{ $t('page.system_planner.import_hint') }}</p>

      <textarea
        ref="text"
        v-model="text"
        class="planner-dialog-text"
        spellcheck="false"
        :placeholder="$t('page.system_planner.import_placeholder')"
        @input="error = null" />

      <p
        v-if="error"
        class="planner-dialog-error"
        role="alert">
        {{ error }}
      </p>

      <div class="planner-dialog-actions">
        <label class="default-button is-small planner-dialog-file">
          {{ $t('page.system_planner.import_file') }}
          <input
            type="file"
            accept=".json,application/json"
            @change="readFile">
        </label>
        <span class="planner-dialog-spacer" />
        <button
          type="button"
          class="default-button is-small"
          @click="$emit('close')">
          {{ $t('page.system_planner.cancel') }}
        </button>
        <button
          type="button"
          class="default-button"
          :disabled="!text.trim()"
          @click="submit">
          {{ $t('page.system_planner.import') }}
        </button>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'planner-import-dialog',
  data() {
    return { text: '', error: null };
  },
  mounted() {
    this.$nextTick(() => this.$refs.text && this.$refs.text.focus());
  },
  methods: {
    submit() {
      let raw;
      try {
        raw = JSON.parse(this.text);
      } catch (e) {
        this.error = this.$t('page.system_planner.import_error.invalid_json');
        return;
      }
      this.$emit('import', raw, (code) => {
        this.error = this.$t(`page.system_planner.import_error.${code}`);
      });
    },
    readFile(event) {
      const [file] = event.target.files || [];
      if (!file) return;
      // a plan is a few kilobytes; anything huge is not one
      if (file.size > 1024 * 1024) {
        this.error = this.$t('page.system_planner.import_error.not_a_plan');
        return;
      }
      const reader = new FileReader();
      reader.onload = () => {
        this.text = String(reader.result || '');
        this.error = null;
      };
      reader.readAsText(file);
      // eslint-disable-next-line no-param-reassign
      event.target.value = '';
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.planner-dialog-root {
  position: fixed;
  top: 0; left: 0; right: 0; bottom: 0;
  z-index: 400;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
}

.planner-dialog-backdrop {
  position: absolute;
  top: 0; left: 0; right: 0; bottom: 0;
  background: rgba(0, 0, 0, .55);
}

.planner-dialog {
  position: relative;
  width: 560px;
  max-width: 100%;
  padding: 20px;
  background: $grey-darker;
  border: solid 1px rgba(255, 255, 255, .15);
  box-shadow: 0 12px 30px rgba(0, 0, 0, .6);

  h2 {
    margin: 0 0 6px;
    text-transform: uppercase;
  }
}

.planner-dialog-hint {
  margin: 0 0 12px;
  opacity: .7;
}

.planner-dialog-text {
  width: 100%;
  height: 220px;
  padding: 8px;
  resize: vertical;
  border: solid 1px rgba(255, 255, 255, .2);
  background: rgba(0, 0, 0, .35);
  color: $white;
  font-family: monospace;
  font-size: 1.2rem;
}

.planner-dialog-error {
  margin: 8px 0 0;
  color: $color-alert;
}

.planner-dialog-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin-top: 14px;
}

.planner-dialog-spacer {
  flex: 1 1 auto;
}

.planner-dialog-file {
  position: relative;
  overflow: hidden;
  cursor: pointer;

  input {
    position: absolute;
    inset: 0;
    opacity: 0;
    cursor: pointer;
  }
}
</style>
