<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.debug_title') }}
      </h1>

      <p class="help-debug-intro">{{ $t('panel.help.debug_intro') }}</p>

      <h2 class="help-debug-heading">{{ $t('panel.help.debug_default_title') }}</h2>
      <ul class="help-debug-list">
        <li
          v-for="item in defaultItems"
          :key="item">
          {{ $t(`panel.help.debug_default_${item}`) }}
        </li>
      </ul>
      <p class="help-debug-never">{{ $t('panel.help.debug_never') }}</p>

      <h2 class="help-debug-heading">{{ $t('panel.help.debug_optin_title') }}</h2>
      <label
        v-for="option in optIns"
        :key="option.key"
        class="help-debug-option"
        :class="{ 'is-checked': option.value }">
        <input
          type="checkbox"
          :checked="option.value"
          @change="setOption(option.key, $event.target.checked)">
        <span class="help-debug-option-text">
          <span class="help-debug-option-label">{{ $t(`panel.help.debug_${option.key}_label`) }}</span>
          <span class="help-debug-option-desc">{{ $t(`panel.help.debug_${option.key}_desc`) }}</span>
        </span>
      </label>
      <p class="help-debug-note">{{ $t('panel.help.debug_optin_note') }}</p>

      <h2 class="help-debug-heading">{{ $t('panel.help.debug_description_label') }}</h2>
      <textarea
        v-model="description"
        class="help-debug-textarea"
        maxlength="4000"
        :placeholder="$t('panel.help.debug_description_placeholder')"></textarea>

      <div class="help-debug-actions">
        <button
          class="help-debug-button"
          :class="{ disabled: busy }"
          :disabled="busy"
          @click="generate">
          {{ busy ? $t('panel.help.debug_generating') : $t('panel.help.debug_generate') }}
        </button>
      </div>

      <p
        v-if="failure"
        class="help-debug-failure">
        {{ $t('panel.help.debug_failed', { error: failure }) }}
      </p>

      <div
        v-if="report"
        class="help-debug-result">
        <h2 class="help-debug-heading">{{ $t('panel.help.debug_ready', { size: sizeLabel }) }}</h2>
        <table class="help-debug-summary">
          <tbody>
            <tr
              v-for="row in summaryRows"
              :key="row.key"
              :class="{ 'is-alert': row.alert }">
              <th>{{ $t(`panel.help.debug_summary_${row.key}`) }}</th>
              <td>{{ row.value }}</td>
            </tr>
          </tbody>
        </table>

        <div class="help-debug-actions">
          <button
            class="help-debug-button"
            @click="download">
            {{ $t('panel.help.debug_download') }}
          </button>
          <button
            class="help-debug-button"
            @click="copy">
            {{ $t('panel.help.debug_copy') }}
          </button>
          <button
            class="help-debug-button is-secondary"
            @click="togglePreview">
            {{ showPreview ? $t('panel.help.debug_hide_preview') : $t('panel.help.debug_show_preview') }}
          </button>
        </div>
        <p class="help-debug-note">{{ $t('panel.help.debug_send_hint', { file: filename }) }}</p>

        <pre
          v-if="showPreview"
          class="help-debug-preview">{{ previewText }}</pre>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
import { buildReport, reportFilename } from '@/game/debug/report';
import { scrubString } from '@/game/debug/sanitize';
import { copyToClipboard } from '@/utils/clipboard';

// The <pre> preview renders at most this much; the download has it all.
const PREVIEW_CHARS = 200000;

const formatBytes = (n) => {
  if (n < 1024) return `${n} B`;
  if (n < 1048576) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1048576).toFixed(1)} MB`;
};

const formatDuration = (ms) => {
  if (typeof ms !== 'number') return '—';
  const minutes = Math.floor(ms / 60000);
  if (minutes < 1) return `${Math.round(ms / 1000)} s`;
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
};

export default {
  name: 'help-debug-panel',
  // Game.vue provides its MapData singleton (not in the store).
  inject: { mapData: { default: null } },
  data() {
    return {
      // Per report, never persisted: every report starts game-only.
      includeSystem: false,
      includeBrowser: false,
      description: '',
      busy: false,
      failure: null,
      report: null,
      json: '',
      showPreview: false,
      defaultItems: ['game', 'sync', 'errors', 'connection', 'performance', 'rendering'],
    };
  },
  computed: {
    optIns() {
      return [
        { key: 'system', value: this.includeSystem },
        { key: 'browser', value: this.includeBrowser },
      ];
    },
    filename() { return this.report ? reportFilename(this.report) : ''; },
    sizeLabel() { return formatBytes(new Blob([this.json]).size); },
    previewText() {
      return this.json.length > PREVIEW_CHARS
        ? `${this.json.slice(0, PREVIEW_CHARS)}\n…${this.$t('panel.help.debug_preview_truncated')}`
        : this.json;
    },
    summaryRows() {
      const s = (this.report && this.report.summary) || {};
      const session = (this.report && this.report.session) || {};
      const none = this.$t('panel.help.debug_summary_none');
      const drift = typeof s.clockDriftMs === 'number' ? s.clockDriftMs : null;
      return [
        { key: 'open', value: formatDuration(session.pageOpenMs) },
        {
          key: 'errors',
          value: `${s.errorsCaptured || 0} / ${s.consoleErrors || 0}`,
          alert: (s.errorsCaptured || 0) > 0,
        },
        {
          key: 'desync',
          value: this.desyncLabel(s, none),
          alert: !!(s.desyncedStructs && s.desyncedStructs.length),
        },
        {
          key: 'clock',
          value: drift === null ? '—' : `${drift > 0 ? '+' : ''}${drift} ms`,
          alert: drift !== null && Math.abs(drift) > 2000,
        },
        { key: 'disconnects', value: s.disconnects || 0, alert: (s.disconnects || 0) > 0 },
        { key: 'fps', value: s.medianFps == null ? '—' : s.medianFps },
        {
          key: 'frame',
          value: s.mapFrameMs
            ? `${s.mapFrameMs.p50} / ${s.mapFrameMs.p95} ms (${this.$t(`panel.help.debug_view_${s.mapFrameMs.view}`)})`
            : '—',
        },
        { key: 'decode', value: s.decodeMBps == null ? '—' : `${Math.round(s.decodeMBps)} MB/s` },
        {
          key: 'slowdown',
          value: s.slowdown ? `×${s.slowdown.ratio}` : '—',
          alert: !!(s.slowdown && s.slowdown.ratio >= 1.5),
        },
        { key: 'stalls', value: s.freezesOver250ms || 0, alert: (s.freezesOver250ms || 0) > 0 },
        { key: 'heap', value: s.heapMB == null ? '—' : `${s.heapMB} MB` },
      ];
    },
  },
  methods: {
    desyncLabel(s, none) {
      if (!s.structsCompared) return '—';
      const found = s.desyncedStructs && s.desyncedStructs.length ? s.desyncedStructs.join(', ') : none;
      return s.extrapolatedValuesDrifting
        ? `${found} ${this.$t('panel.help.debug_summary_drifting', { n: s.extrapolatedValuesDrifting })}`
        : found;
    },
    setOption(key, value) {
      if (key === 'system') this.includeSystem = value;
      if (key === 'browser') this.includeBrowser = value;
      // A generated report reflects the options it was built with; a
      // stale one must not be sent by mistake with more (or less) than
      // the boxes now say.
      this.discard();
    },
    discard() {
      this.report = null;
      this.json = '';
      this.showPreview = false;
    },
    async generate() {
      if (this.busy) return;
      this.busy = true;
      this.failure = null;
      this.discard();
      try {
        const report = await buildReport({
          socket: this.$socket,
          mapData: this.mapData,
          includeSystem: this.includeSystem,
          includeBrowser: this.includeBrowser,
          description: this.description,
        });
        this.json = JSON.stringify(report, null, 2);
        // Frozen: the report is read-only and can be large.
        this.report = Object.freeze(report);
      } catch (e) {
        this.failure = (e && e.message) || String(e);
      } finally {
        this.busy = false;
      }
    },
    // The description box stays editable after generating: fold its
    // current text in before the report leaves, instead of making the
    // player regenerate (and re-probe the server) for a typo.
    syncDescription() {
      const text = this.description.trim().slice(0, 4000);
      const value = text ? scrubString(text) : undefined;
      if (!this.report || this.report.description === value) return;
      this.report = Object.freeze({ ...this.report, description: value });
      this.json = JSON.stringify(this.report, null, 2);
    },
    togglePreview() {
      this.syncDescription();
      this.showPreview = !this.showPreview;
    },
    download() {
      this.syncDescription();
      const blob = new Blob([this.json], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = this.filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      // Some browsers start the download asynchronously.
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    },
    async copy() {
      this.syncDescription();
      const ok = await copyToClipboard(this.json);
      if (ok) this.$toasted.success(this.$t('panel.help.debug_copied'));
      else this.$toasted.error(this.$t('panel.help.debug_copy_failed'));
    },
  },
};
</script>
