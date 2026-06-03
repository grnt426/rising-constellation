<template>
  <div class="panel-content is-medium">
    <div class="reports-tabs">
      <div
        class="reports-tab"
        :class="{ 'is-active': activeTab === 'combat' }"
        @click="activeTab = 'combat'">
        {{ $t('panel.operations.tabs.combat') }}
      </div>
      <div
        class="reports-tab"
        :class="{ 'is-active': activeTab === 'icon_log' }"
        @click="activeTab = 'icon_log'">
        {{ $t('panel.operations.tabs.icon_log') }}
      </div>
    </div>
    <v-scrollbar class="has-padding">
      <template v-if="activeTab === 'combat'">
        <template v-if="!current">
          <div
            class="pcb-report"
            v-for="(report, i) in reports"
            :key="`report-${i}`"
            :class="{ 'active': current && current.id === report.id }"
            @click="toggleReport(report)">
            <div class="icon">
              <svgicon :name="`action/${report.type}`" />
            </div>
            <div class="title">
              <strong>{{ formatName(report) }}</strong>
              {{ $t(`report.${report.metadata.result}`) }}
            </div>
          </div>
        </template>
        <div
          class="report"
          v-else>
          <div class="report-toolbox">
            <div
              class="button"
              @click="current = null">
              <div>{{ $t('panel.operations.return') }}</div>
            </div>
            <div
              class="button"
              @click="deleteReport(current.id)">
              <div>{{ $t('panel.operations.delete') }}</div>
            </div>
          </div>
          <fight-report
            v-if="current.type === 'fight'"
            :report="current.report" />
        </div>
      </template>

      <template v-else-if="activeTab === 'icon_log'">
        <div
          v-if="iconLogEntries.length === 0"
          class="reports-empty">
          {{ $t('panel.operations.tabs.no_entries') }}
        </div>
        <div
          v-for="entry in iconLogEntries"
          :key="`icon-log-${entry.id}`"
          class="icon-log-entry">
          <div class="icon-log-message" v-html="formatIconLogEntry(entry)"></div>
          <div class="icon-log-timestamp">{{ entry.inserted_at | datetime-long }}</div>
        </div>
      </template>
    </v-scrollbar>
  </div>
</template>

<script>
import FightReport from '@/game/components/panel/operation/report/FightReport.vue';

export default {
  name: 'operation-reports-panel',
  props: {
    initial: {
      type: Number,
      default: 0,
    },
  },
  data() {
    return {
      reports: [],
      current: null,
      activeTab: 'combat',
      iconLogEntries: [],
      iconLogLoaded: false,
    };
  },
  watch: {
    activeTab(tab) {
      // Lazy-load each tab on first visit. The combat report
      // payloads can be heavy and the icon log isn't worth pulling
      // until the player actually looks at it.
      if (tab === 'icon_log' && !this.iconLogLoaded) {
        this.loadIconEventLog();
      }
    },
  },
  methods: {
    loadReports() {
      this.$socket.player
        .push('get_reports', {})
        .receive('ok', (response) => {
          this.reports = response.reports.map((report) => {
            report.metadata = this.parseMetadata(report.metadata);
            return report;
          });

          if (this.initial !== 0) {
            const report = this.reports.find((r) => r.id === this.initial);
            this.toggleReport(report);
          }
        })
        .receive('error', (data) => {
          this.$toastError(data.reason);
        });
    },
    toggleReport(report) {
      this.current = this.current !== null && this.current.id === report.id
        ? null : report;
    },
    deleteReport(reportId) {
      this.$socket.player
        .push('hide_report', { report_id: reportId })
        .receive('ok', () => {
          this.current = null;
          this.loadReports();
        })
        .receive('error', (data) => {
          this.$toastError(data.reason);
        });
    },
    parseMetadata(metadata) {
      try {
        return JSON.parse(metadata);
      } catch (error) {
        this.$toastError(error);
      }

      return {};
    },
    loadIconEventLog() {
      this.$socket.faction
        .push('get_icon_event_log', {})
        .receive('ok', (response) => {
          this.iconLogEntries = (response.entries || []).map((entry) => {
            // Payload is stored as a JSON string on the server side
            // so the schema doesn't have to track per-event-type
            // columns. Parse defensively — a single corrupt row
            // shouldn't break the whole list.
            try {
              entry.payload = typeof entry.payload === 'string'
                ? JSON.parse(entry.payload) : entry.payload;
            } catch (e) {
              entry.payload = {};
            }
            return entry;
          });
          this.iconLogLoaded = true;
        })
        .receive('error', (data) => {
          this.$toastError(data.reason);
        });
    },
    formatIconLogEntry(entry) {
      // Names get cached into the payload at write time so deleted
      // profiles still render readably. Fall back to a translated
      // "former member" when the snapshot is missing (very-old rows
      // pre-feature, defensive only).
      const formerMember = this.$t('report.former_member');
      const unknownSystem = this.$t('report.unknown_system');
      const p = entry.payload || {};
      const actor = p.actor_name || formerMember;
      const target = p.target_name || formerMember;
      const system = p.system_name || unknownSystem;
      const kindLabel = (k) => k ? this.$t(`galaxy.map.icons.kinds.${k}`) : '';

      if (entry.event_type === 'icon_replaced') {
        return this.$t('report.icon_replaced', {
          actor,
          target,
          previous_kind: kindLabel(p.previous_kind),
          new_kind: kindLabel(p.new_kind),
          system,
        });
      }
      return this.$t('report.icon_removed', {
        actor,
        target,
        kind: kindLabel(p.icon_kind),
        system,
      });
    },
    formatName(report) {
      if (report.type === 'fight') {
        const { scale } = report.metadata;
        let scaleName = 'fight_scale_xsmall';

        if (scale > 2000) { scaleName = 'fight_scale_xxbig'; }
        if (scale > 1000) { scaleName = 'fight_scale_xbig'; }
        if (scale > 600) { scaleName = 'fight_scale_big'; }
        if (scale > 300) { scaleName = 'fight_scale_medium'; }
        if (scale > 100) { scaleName = 'fight_scale_small'; }

        return this.$t(`report.${scaleName}`, { name: report.metadata.system });
      }

      const { status } = report.metadata;
      return this.$t(`report.${report.type}_${status}`, { name: report.metadata.system });
    },
  },
  mounted() {
    this.loadReports();
  },
  components: {
    FightReport,
  },
};
</script>

<style lang="scss" scoped>
.reports-tabs {
  display: flex;
  border-bottom: 1px solid rgba(255, 255, 255, 0.15);
}

.reports-tab {
  flex: 1;
  padding: 0.5rem 0.75rem;
  text-align: center;
  cursor: pointer;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  font-size: 0.85em;
  color: rgba(220, 220, 220, 0.6);
  border-bottom: 2px solid transparent;
  transition: color 120ms, border-color 120ms, background 120ms;

  &:hover {
    color: rgba(255, 255, 255, 0.9);
    background: rgba(255, 255, 255, 0.04);
  }

  &.is-active {
    color: rgba(255, 255, 255, 0.95);
    border-bottom-color: rgba(180, 220, 255, 0.7);
  }
}

.reports-empty {
  padding: 1.5rem 1rem;
  text-align: center;
  color: rgba(200, 200, 200, 0.55);
  font-style: italic;
}

// Dedicated class on icon-log entries so the existing `.pcb-report
// .title strong { display: block; }` rule doesn't stack our
// "<actor> removed <target>'s …" template onto separate lines. The
// rest of the panel uppercases its content — we let that cascade
// through so the new tab visually matches the combat reports.
.icon-log-entry {
  padding: 0.6rem 0.75rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);

  ::v-deep strong {
    display: inline;
    font-weight: 700;
  }
}

.icon-log-message {
  line-height: 1.35;
}

.icon-log-timestamp {
  margin-top: 0.25rem;
  font-size: 0.8em;
  opacity: 0.6;
}
</style>
