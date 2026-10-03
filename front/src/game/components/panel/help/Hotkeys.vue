<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.hotkeys_title') }}
      </h1>

      <p class="help-hotkeys-intro">{{ $t('panel.help.hotkeys_intro') }}</p>

      <!-- The two choices a screen-reader player needs first: game
           shortcuts off altogether, or the set that still works while the
           reader is in browse mode (docs/accessibility.md). -->
      <div class="help-hotkeys-options">
        <label class="help-hotkeys-option">
          <input
            type="checkbox"
            :checked="enabled"
            @change="setEnabled($event.target.checked)">
          {{ $t('panel.help.hotkeys_enabled') }}
        </label>
        <p class="help-hotkeys-hint">
          {{ $t(enabled ? 'panel.help.hotkeys_enabled_hint' : 'panel.help.hotkeys_disabled_hint') }}
        </p>

        <fieldset class="help-hotkeys-presets">
          <legend>{{ $t('panel.help.hotkeys_preset') }}</legend>
          <label
            v-for="p in PRESETS"
            :key="p"
            class="help-hotkeys-option">
            <input
              type="radio"
              name="help-hotkeys-preset"
              :value="p"
              :checked="preset === p"
              @change="setPreset(p)">
            {{ $t(`panel.help.hotkeys_preset_${p}`) }}
          </label>
          <p class="help-hotkeys-hint">{{ $t(`panel.help.hotkeys_preset_${preset}_hint`) }}</p>
        </fieldset>
      </div>

      <template v-for="section in sections">
        <h2
          class="help-legend-section"
          :key="`${section.key}-title`">
          {{ $t(`panel.help.hotkeys_section.${section.key}`) }}
        </h2>
        <table
          class="help-hotkeys-table"
          :class="{ 'is-off': !enabled }"
          :key="section.key">
          <tbody>
            <tr
              v-for="row in section.rows"
              :key="row.id"
              :data-hotkey="row.id"
              :class="{
                'is-capturing': capturing === row.id,
                'is-modified': !row.isDefault,
                'is-unbound': !row.labels.length,
              }">
              <th>
                <!-- While a row waits for its key it is a text field:
                     screen readers switch to typing (focus) mode on one,
                     so the key reaches the page instead of the reader's
                     own navigation. Nothing is ever typed into it. -->
                <input
                  v-if="capturing === row.id"
                  ref="captureInput"
                  class="help-hotkeys-binding help-hotkeys-capture"
                  type="text"
                  autocomplete="off"
                  :aria-label="$t('panel.help.hotkeys_capture_label', { action: row.description })"
                  :placeholder="$t('panel.help.hotkeys_press')">
                <button
                  v-else
                  :ref="`binding-${row.id}`"
                  type="button"
                  class="help-hotkeys-binding"
                  :aria-label="bindingName(row)"
                  @click="toggleCapture(row.id)">
                  <template v-if="row.labels.length">
                    <span
                      v-for="(k, i) in row.labels"
                      :key="i">
                      <kbd>{{ k }}</kbd><template v-if="i < row.labels.length - 1"> + </template>
                    </span>
                  </template>
                  <template v-else>
                    {{ $t('panel.help.hotkeys_unbound') }}
                  </template>
                </button>
              </th>
              <td>
                {{ row.description }}
                <div
                  v-if="capturing === row.id"
                  class="help-hotkeys-actions">
                  <button
                    type="button"
                    class="help-hotkeys-action"
                    :disabled="row.isDefault"
                    @click="restore(row.id)">
                    {{ $t('panel.help.hotkeys_default', { key: row.defaultLabel || $t('panel.help.hotkeys_unbound') }) }}
                  </button>
                  <button
                    type="button"
                    class="help-hotkeys-action"
                    :disabled="!row.labels.length"
                    @click="clear(row.id)">
                    {{ $t('panel.help.hotkeys_clear') }}
                  </button>
                  <button
                    type="button"
                    class="help-hotkeys-action"
                    @click="cancelCapture">
                    {{ $t('panel.help.hotkeys_cancel') }}
                  </button>
                </div>
                <p
                  v-if="capturing === row.id && refused"
                  class="help-hotkeys-refused">
                  {{ refused }}
                </p>
              </td>
            </tr>
          </tbody>
        </table>
      </template>

      <div class="help-hotkeys-footer">
        <button
          type="button"
          class="help-hotkeys-action"
          :disabled="!isCustomized"
          @mouseleave="disarmReset"
          @blur="disarmReset"
          @click="resetAll">
          {{ confirmingReset ? $t('panel.help.hotkeys_reset_confirm') : $t('panel.help.hotkeys_reset_all') }}
        </button>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import {
  HOTKEYS, SECTIONS, PRESETS, keysFromEvent, isModifierKey, reservedReason, rebind, defaultKeys,
  isDefaultBinding, keyLabels, bindingLabel,
} from '@/game/hotkeys/bindings';

export default {
  name: 'help-hotkeys-panel',
  data() {
    return {
      // id of the action waiting for its new key, if any
      capturing: null,
      // why the last key pressed was not accepted
      refused: null,
      confirmingReset: false,
      PRESETS,
    };
  },
  computed: {
    preset() { return this.$store.getters['portal/hotkeyPreset']; },
    enabled() { return this.$store.getters['portal/hotkeysEnabled']; },
    overrides() { return this.$store.getters['portal/hotkeyOverrides']; },
    bindings() { return this.$store.getters['portal/hotkeys']; },
    isCustomized() {
      return HOTKEYS.some(({ id }) => !isDefaultBinding(id, this.bindings[id], this.preset));
    },
    sections() {
      return SECTIONS.map((key) => ({
        key,
        rows: HOTKEYS.filter((hotkey) => hotkey.section === key).map((hotkey) => ({
          id: hotkey.id,
          description: this.describe(hotkey),
          labels: keyLabels(this.bindings[hotkey.id]),
          isDefault: isDefaultBinding(hotkey.id, this.bindings[hotkey.id], this.preset),
          defaultLabel: bindingLabel(defaultKeys(hotkey.id, this.preset)),
        })),
      }));
    },
  },
  methods: {
    describe(hotkey) {
      return this.$t(`panel.help.hotkey.${hotkey.label || hotkey.id}`, { n: hotkey.n });
    },
    actionName(id) {
      return this.describe(HOTKEYS.find((h) => h.id === id));
    },
    // "Open the empire panel: S. Press to change" — a key alone ("S,
    // button") says nothing about which action it belongs to.
    bindingName(row) {
      return row.labels.length
        ? this.$t('panel.help.hotkeys_binding_label', { action: row.description, key: row.labels.join(' + ') })
        : this.$t('panel.help.hotkeys_binding_unbound_label', { action: row.description });
    },
    // Refs inside v-for come back as arrays.
    firstRef(name) {
      const ref = this.$refs[name];
      return Array.isArray(ref) ? ref[0] : ref;
    },
    focusBinding(id) {
      this.$nextTick(() => {
        const button = this.firstRef(`binding-${id}`);
        if (button) button.focus();
      });
    },
    setEnabled(enabled) {
      this.stopCapture();
      this.$store.dispatch('portal/setHotkeysEnabled', enabled);
      this.$announce(this.$t(enabled ? 'panel.help.hotkeys_now_on' : 'panel.help.hotkeys_now_off'));
    },
    setPreset(preset) {
      this.stopCapture();
      this.$store.dispatch('portal/setHotkeyPreset', preset);
      this.$announce(this.$t('panel.help.hotkeys_preset_now', { preset: this.$t(`panel.help.hotkeys_preset_${preset}`) }));
    },
    toggleCapture(id) {
      if (this.capturing === id) {
        this.cancelCapture();
      } else {
        this.startCapture(id);
      }
    },
    // Window capture-phase listeners: they run ahead of vue-shortkey's own
    // (document, capture), so while a row waits for its key nothing the
    // player presses reaches the live hotkeys.
    startCapture(id) {
      this.stopCapture();
      this.capturing = id;
      this.disarmReset();
      window.addEventListener('keydown', this.onCaptureKeydown, true);
      window.addEventListener('keyup', this.onCaptureKeyup, true);
      window.addEventListener('mousedown', this.onCaptureMousedown, true);
      window.addEventListener('focusin', this.onCaptureFocusin, true);
      this.$nextTick(() => {
        const input = this.firstRef('captureInput');
        if (input) input.focus();
      });
    },
    stopCapture() {
      this.capturing = null;
      this.refused = null;
      this.heldCode = null;
      window.removeEventListener('keydown', this.onCaptureKeydown, true);
      window.removeEventListener('keyup', this.onCaptureKeyup, true);
      window.removeEventListener('mousedown', this.onCaptureMousedown, true);
      window.removeEventListener('focusin', this.onCaptureFocusin, true);
    },
    // Back out without changing anything, returning to the row's button.
    cancelCapture() {
      const id = this.capturing;
      this.stopCapture();
      if (id) this.focusBinding(id);
    },
    // The capture ends on a keydown, with that key still held. Its
    // auto-repeat must not reach the live hotkeys (it would fire the
    // shortcut it was just given), so the listeners stay until it is let go.
    endCaptureOn(event) {
      const id = this.capturing;
      this.capturing = null;
      this.refused = null;
      this.heldCode = event.code;
      if (id) this.focusBinding(id);
    },
    onCaptureKeydown(event) {
      if (!this.capturing) {
        if (event.repeat && event.code === this.heldCode) {
          event.preventDefault();
          event.stopPropagation();
        } else {
          this.stopCapture();
        }
        return;
      }

      // the drawer was closed from under the capture
      if (!this.$el.getClientRects().length) {
        this.stopCapture();
        return;
      }

      // Nothing pressed while a row waits reaches the game's shortcuts.
      event.stopPropagation();

      if (event.key === 'Escape') {
        event.preventDefault();
        this.cancelCapture();
        return;
      }

      // Tab moves on to Default / Remove / Cancel (it can't be a shortcut),
      // and on those buttons keys work them as usual.
      if (event.key === 'Tab' || event.target !== this.firstRef('captureInput')) return;

      event.preventDefault();
      if (event.repeat || isModifierKey(event.key)) return;

      const keys = keysFromEvent(event);
      const reason = keys && reservedReason(keys);
      if (!keys) {
        this.refuse(this.$t('panel.help.hotkeys_unsupported'));
      } else if (reason === 'navigation') {
        this.refuse(this.$t('panel.help.hotkeys_reserved_navigation', { key: bindingLabel(keys) }));
      } else if (reason) {
        this.refuse(this.$t('panel.help.hotkeys_reserved', { key: bindingLabel(keys) }));
      } else {
        const id = this.capturing;
        this.rebind(id, keys);
        this.endCaptureOn(event);
        this.$announce(this.$t('panel.help.hotkeys_set', { action: this.actionName(id), key: bindingLabel(keys) }));
      }
    },
    refuse(message) {
      this.refused = message;
      this.$announce(message, { assertive: true });
    },
    onCaptureKeyup(event) {
      if (!this.capturing && event.code === this.heldCode) this.stopCapture();
    },
    onCaptureMousedown(event) {
      if (!this.capturing || !event.target.closest('.help-hotkeys-table tr.is-capturing')) {
        this.stopCapture();
      }
    },
    // Tabbing past Cancel (or anywhere outside the row) backs out.
    onCaptureFocusin(event) {
      if (this.capturing && !event.target.closest('.help-hotkeys-table tr.is-capturing')) {
        this.stopCapture();
      }
    },
    restore(id) {
      const keys = defaultKeys(id, this.preset);
      this.rebind(id, keys);
      this.cancelCapture();
      this.$announce(keys.length
        ? this.$t('panel.help.hotkeys_set', { action: this.actionName(id), key: bindingLabel(keys) })
        : this.$t('panel.help.hotkeys_cleared', { action: this.actionName(id) }));
    },
    clear(id) {
      this.rebind(id, []);
      this.cancelCapture();
      this.$announce(this.$t('panel.help.hotkeys_cleared', { action: this.actionName(id) }));
    },
    rebind(id, keys) {
      const { overrides, displaced } = rebind(this.overrides, id, keys, this.preset);
      // pressing the key the action already has saves nothing
      if (JSON.stringify(overrides) === JSON.stringify(this.overrides)) return;
      this.$store.dispatch('portal/setHotkeys', overrides);

      displaced.forEach((other) => {
        this.$toasted.info(this.$t('panel.help.hotkeys_displaced', {
          key: bindingLabel(keys),
          action: this.actionName(other),
        }));
      });
    },
    // Two presses: the first arms (and says so), the second resets. Armed
    // only for a few seconds, and never past the pointer or focus leaving.
    resetAll() {
      if (!this.confirmingReset) {
        this.confirmingReset = true;
        clearTimeout(this.resetTimer);
        this.resetTimer = setTimeout(this.disarmReset, 5000);
        this.$announce(this.$t('panel.help.hotkeys_reset_confirm'));
        return;
      }
      this.disarmReset();
      this.stopCapture();
      this.$store.dispatch('portal/setHotkeys', {});
      this.$announce(this.$t('panel.help.hotkeys_reset_done'));
    },
    disarmReset() {
      clearTimeout(this.resetTimer);
      this.confirmingReset = false;
    },
  },
  beforeDestroy() {
    this.stopCapture();
    clearTimeout(this.resetTimer);
  },
};
</script>
