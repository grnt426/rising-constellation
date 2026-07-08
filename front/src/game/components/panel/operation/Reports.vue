<template>
  <div class="panel-content is-medium">
    <div class="reports-tabs">
      <div
        class="reports-tab"
        :class="{ 'is-active': activeTab === 'reports' }"
        @click="activeTab = 'reports'">
        {{ $t('panel.operations.tabs.reports') }}
        <span
          v-if="unreadCount > 0"
          class="reports-tab-badge">{{ unreadCount }}</span>
      </div>
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
    <v-scrollbar
      class="has-padding"
      @ps-y-reach-end="onReachEnd">

      <!-- Reports: the player's own agent-action summary cards. Same card the
           player sees pop up live / on login, now re-readable + manageable. -->
      <template v-if="activeTab === 'reports'">
        <div
          v-if="events.length > 0"
          class="reports-toolbox">
          <div
            class="button"
            :class="{ 'is-disabled': unreadCount === 0 }"
            @click="markAllRead">
            {{ $t('panel.operations.mark_all_read') }}
          </div>
          <div
            class="button"
            @click="deleteRead">
            {{ $t('panel.operations.delete_read') }}
          </div>
          <div
            class="button is-danger"
            @click="deleteAll">
            {{ $t('panel.operations.delete_all') }}
          </div>
        </div>

        <div
          v-if="events.length === 0 && eventsLoaded"
          class="reports-empty">
          {{ $t('panel.operations.tabs.no_entries') }}
        </div>

        <div
          v-for="event in events"
          :key="`event-${event.id}`"
          class="event-report"
          :class="{ 'is-unread': !event.is_read, 'is-open': expandedEventId === event.id }">
          <div
            class="event-report-header"
            @click="toggleEvent(event)">
            <span
              class="event-report-dot"
              v-if="!event.is_read"></span>
            <div class="event-report-icon">
              <svgicon :name="`action/${event.key}`" />
              <svgicon
                v-if="event.data.side === 'defender'"
                name="resource/defense" />
            </div>
            <span
              class="event-report-title"
              v-html="$tmd(`notification.short_box.${event.key}`, { system: event.data.system.name })"></span>
            <span
              class="event-report-outcome"
              v-if="event.data.outcome">
              <template v-if="event.key === 'fight'">
                {{ $t(`notification.box.fight.outcome.${event.data.outcome}`) }}
              </template>
              <template v-else>
                {{ $t(`notification.box.outcome.${event.data.side}.${event.data.outcome}`) }}
              </template>
            </span>
            <span class="event-report-date">{{ event.inserted_at | datetime-long }}</span>
          </div>
          <div
            v-if="expandedEventId === event.id"
            class="box-notification-item">
            <notif-dispatcher :notification="event" />
          </div>
        </div>
      </template>

      <!-- Combat: the legacy per-round fight log, kept reachable (e.g. the
           "view report" deep-link) but no longer the default landing tab. -->
      <template v-else-if="activeTab === 'combat'">
        <template v-if="!current">
          <div
            v-if="reports.length === 0"
            class="reports-empty">
            {{ $t('panel.operations.tabs.no_entries') }}
          </div>
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
import NotifDispatcher from '@/game/components/box-notification/NotifDispatcher.vue';

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
      // combat (legacy fight log)
      reports: [],
      current: null,
      combatLoaded: false,
      // reports (player_events box cards)
      events: [],
      eventsPage: 1,
      eventsMaxPage: 1,
      eventsLoading: false,
      eventsLoaded: false,
      expandedEventId: null,
      // icon log
      iconLogEntries: [],
      iconLogLoaded: false,
      // A report deep-link (FightNotif "view report") lands on combat; an
      // ordinary open lands on the new summary Reports tab.
      activeTab: this.initial !== 0 ? 'combat' : 'reports',
    };
  },
  computed: {
    // Approximate: counts unread among the events loaded so far. Good enough
    // for the tab badge; "mark all read" clears it server-side regardless.
    unreadCount() {
      return this.events.filter((e) => !e.is_read).length;
    },
  },
  watch: {
    activeTab(tab) {
      // Lazy-load each tab on first visit.
      if (tab === 'reports' && !this.eventsLoaded) {
        this.loadPlayerEvents();
      }
      if (tab === 'combat' && !this.combatLoaded) {
        this.loadReports();
      }
      if (tab === 'icon_log' && !this.iconLogLoaded) {
        this.loadIconEventLog();
      }
    },
  },
  methods: {
    // --- Reports tab (player_events) ---
    loadPlayerEvents() {
      if (this.eventsLoading || this.eventsPage > this.eventsMaxPage) {
        return;
      }

      this.eventsLoading = true;
      this.$socket.player
        .push('get_player_events', { page: this.eventsPage })
        .receive('ok', (data) => {
          // Tutorial short-circuits server-side with no `events` key.
          if (!data || !data.events) {
            this.eventsLoaded = true;
            this.eventsLoading = false;
            return;
          }

          const events = data.events.map((e) => {
            // `data` is stored as a JSON string so the schema stays generic.
            e.data = this.parseMetadata(e.data);
            return e;
          });

          this.events.push(...events);
          this.eventsPage += 1;
          this.eventsMaxPage = data.total_pages;
          this.eventsLoaded = true;
          this.eventsLoading = false;
        })
        .receive('error', (data) => {
          this.eventsLoading = false;
          this.$toastError(data.reason);
        });
    },
    reloadPlayerEvents() {
      this.events = [];
      this.eventsPage = 1;
      this.eventsMaxPage = 1;
      this.expandedEventId = null;
      this.eventsLoaded = false;
      this.loadPlayerEvents();
    },
    toggleEvent(event) {
      this.expandedEventId = this.expandedEventId === event.id ? null : event.id;

      // Opening a report counts as reading it.
      if (this.expandedEventId === event.id && !event.is_read) {
        this.markRead(event);
      }
    },
    markRead(event) {
      // Optimistic — the card is already on screen; a failed write just leaves
      // it unread, which is harmless.
      this.$set(event, 'is_read', true);
      this.$socket.player.push('mark_event_read', { event_id: event.id });
    },
    markAllRead() {
      if (this.unreadCount === 0) {
        return;
      }

      this.$socket.player
        .push('mark_all_events_read', {})
        .receive('ok', () => {
          this.events.forEach((e) => this.$set(e, 'is_read', true));
        })
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    deleteRead() {
      if (!window.confirm(this.$t('panel.operations.confirm_delete_read'))) {
        return;
      }

      this.$socket.player
        .push('delete_read_events', {})
        .receive('ok', () => this.reloadPlayerEvents())
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    deleteAll() {
      if (!window.confirm(this.$t('panel.operations.confirm_delete_all'))) {
        return;
      }

      this.$socket.player
        .push('delete_all_events', {})
        .receive('ok', () => this.reloadPlayerEvents())
        .receive('error', (data) => { this.$toastError(data.reason); });
    },
    onReachEnd() {
      if (this.activeTab === 'reports') {
        this.loadPlayerEvents();
      }
    },
    // --- Combat tab (legacy player_report) ---
    loadReports() {
      this.$socket.player
        .push('get_reports', {})
        .receive('ok', (response) => {
          this.reports = response.reports.map((report) => {
            report.metadata = this.parseMetadata(report.metadata);
            return report;
          });
          this.combatLoaded = true;

          if (this.initial !== 0) {
            const report = this.reports.find((r) => r.id === this.initial);
            if (report) {
              this.toggleReport(report);
            }
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
    if (this.initial !== 0) {
      this.loadReports();
    } else {
      this.loadPlayerEvents();
    }
  },
  components: {
    FightReport,
    NotifDispatcher,
  },
};
</script>

<style lang="scss" scoped>
.reports-tabs {
  display: flex;
  border-bottom: 1px solid rgba(255, 255, 255, 0.15);
}

.reports-tab {
  position: relative;
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

.reports-tab-badge {
  display: inline-block;
  min-width: 1.4em;
  margin-left: 0.3em;
  padding: 0 0.35em;
  border-radius: 0.7em;
  background: rgba(180, 220, 255, 0.85);
  color: #06121f;
  font-size: 0.85em;
  font-weight: 700;
  line-height: 1.4em;
}

.reports-toolbox {
  display: flex;
  gap: 0.5rem;
  padding: 0.5rem 0;
  flex-wrap: wrap;

  .button {
    flex: 1;
    text-align: center;
    white-space: nowrap;

    &.is-disabled {
      opacity: 0.4;
      pointer-events: none;
    }

    &.is-danger {
      color: rgba(255, 170, 170, 0.95);
    }
  }
}

.reports-empty {
  padding: 1.5rem 1rem;
  text-align: center;
  color: rgba(200, 200, 200, 0.55);
  font-style: italic;
}

.event-report {
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);

  &.is-unread .event-report-title {
    color: rgba(255, 255, 255, 0.95);
    font-weight: 700;
  }

  &.is-open {
    background: rgba(255, 255, 255, 0.03);
  }
}

.event-report-header {
  display: flex;
  align-items: center;
  gap: 0.45rem;
  padding: 0.55rem 0.5rem;
  cursor: pointer;

  &:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .svg-icon {
    width: 1.1em;
    height: 1.1em;
    flex-shrink: 0;
  }
}

.event-report-dot {
  width: 0.5em;
  height: 0.5em;
  flex-shrink: 0;
  border-radius: 50%;
  background: rgba(180, 220, 255, 0.95);
}

.event-report-icon {
  display: flex;
  align-items: center;
  gap: 0.15rem;
  flex-shrink: 0;
}

.event-report-title {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: rgba(220, 220, 220, 0.75);

  ::v-deep strong {
    font-weight: 700;
  }
}

.event-report-outcome {
  flex-shrink: 0;
  font-size: 0.8em;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  opacity: 0.75;
}

.event-report-date {
  flex-shrink: 0;
  font-size: 0.78em;
  opacity: 0.5;
}

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
