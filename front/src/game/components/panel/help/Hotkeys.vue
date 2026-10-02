<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.hotkeys_title') }}
      </h1>

      <p class="help-hotkeys-intro">{{ $t('panel.help.hotkeys_intro') }}</p>

      <template v-for="section in sections">
        <h2
          class="help-legend-section"
          :key="`${section.key}-title`">
          {{ $t(`panel.help.hotkeys_section.${section.key}`) }}
        </h2>
        <table
          class="help-hotkeys-table"
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
                <button
                  class="help-hotkeys-binding"
                  @click="toggleCapture(row.id)">
                  <template v-if="capturing === row.id">
                    {{ $t('panel.help.hotkeys_press') }}
                  </template>
                  <template v-else-if="row.labels.length">
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
                    class="help-hotkeys-action"
                    :disabled="row.isDefault"
                    @click="restore(row.id)">
                    {{ $t('panel.help.hotkeys_default', { key: row.defaultLabel }) }}
                  </button>
                  <button
                    class="help-hotkeys-action"
                    :disabled="!row.labels.length"
                    @click="clear(row.id)">
                    {{ $t('panel.help.hotkeys_clear') }}
                  </button>
                  <button
                    class="help-hotkeys-action"
                    @click="stopCapture">
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
          class="help-hotkeys-action"
          :disabled="!isCustomized"
          @mouseleave="confirmingReset = false"
          @click="resetAll">
          {{ confirmingReset ? $t('panel.help.hotkeys_reset_confirm') : $t('panel.help.hotkeys_reset_all') }}
        </button>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import {
  HOTKEYS, SECTIONS, keysFromEvent, isModifierKey, isReserved, rebind, defaultKeys,
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
    };
  },
  computed: {
    overrides() { return this.$store.state.portal.settings.hotkeys; },
    bindings() { return this.$store.getters['portal/hotkeys']; },
    isCustomized() { return HOTKEYS.some(({ id }) => !isDefaultBinding(id, this.bindings[id])); },
    sections() {
      return SECTIONS.map((key) => ({
        key,
        rows: HOTKEYS.filter((hotkey) => hotkey.section === key).map((hotkey) => ({
          id: hotkey.id,
          description: this.describe(hotkey),
          labels: keyLabels(this.bindings[hotkey.id]),
          isDefault: isDefaultBinding(hotkey.id, this.bindings[hotkey.id]),
          defaultLabel: bindingLabel(hotkey.keys),
        })),
      }));
    },
  },
  methods: {
    describe(hotkey) {
      return this.$t(`panel.help.hotkey.${hotkey.label || hotkey.id}`, { n: hotkey.n });
    },
    toggleCapture(id) {
      if (this.capturing === id) {
        this.stopCapture();
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
      this.confirmingReset = false;
      window.addEventListener('keydown', this.onCaptureKeydown, true);
      window.addEventListener('keyup', this.onCaptureKeyup, true);
      window.addEventListener('mousedown', this.onCaptureMousedown, true);
    },
    stopCapture() {
      this.capturing = null;
      this.refused = null;
      this.heldCode = null;
      window.removeEventListener('keydown', this.onCaptureKeydown, true);
      window.removeEventListener('keyup', this.onCaptureKeyup, true);
      window.removeEventListener('mousedown', this.onCaptureMousedown, true);
    },
    // The capture ends on a keydown, with that key still held. Its
    // auto-repeat must not reach the live hotkeys (it would fire the
    // shortcut it was just given), so the listeners stay until it is let go.
    endCaptureOn(event) {
      this.capturing = null;
      this.refused = null;
      this.heldCode = event.code;
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

      event.preventDefault();
      event.stopPropagation();
      if (event.repeat || isModifierKey(event.key)) return;

      if (event.key === 'Escape') {
        this.endCaptureOn(event);
        return;
      }

      const keys = keysFromEvent(event);
      if (!keys) {
        this.refused = this.$t('panel.help.hotkeys_unsupported');
      } else if (isReserved(keys)) {
        this.refused = this.$t('panel.help.hotkeys_reserved', { key: bindingLabel(keys) });
      } else {
        this.rebind(this.capturing, keys);
        this.endCaptureOn(event);
      }
    },
    onCaptureKeyup(event) {
      if (!this.capturing && event.code === this.heldCode) this.stopCapture();
    },
    onCaptureMousedown(event) {
      if (!this.capturing || !event.target.closest('.help-hotkeys-table tr.is-capturing')) {
        this.stopCapture();
      }
    },
    restore(id) {
      this.rebind(id, defaultKeys(id));
      this.stopCapture();
    },
    clear(id) {
      this.rebind(id, []);
      this.stopCapture();
    },
    rebind(id, keys) {
      const { overrides, displaced } = rebind(this.overrides, id, keys);
      // pressing the key the action already has saves nothing
      if (JSON.stringify(overrides) === JSON.stringify(this.overrides)) return;
      this.$store.dispatch('portal/setHotkeys', overrides);

      displaced.forEach((other) => {
        const hotkey = HOTKEYS.find((h) => h.id === other);
        this.$toasted.info(this.$t('panel.help.hotkeys_displaced', {
          key: bindingLabel(keys),
          action: this.describe(hotkey),
        }));
      });
    },
    resetAll() {
      if (!this.confirmingReset) {
        this.confirmingReset = true;
        return;
      }
      this.confirmingReset = false;
      this.stopCapture();
      this.$store.dispatch('portal/setHotkeys', {});
    },
  },
  beforeDestroy() {
    this.stopCapture();
  },
};
</script>
