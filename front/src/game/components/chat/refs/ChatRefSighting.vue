<template>
  <button
    v-if="sighting"
    type="button"
    class="chat-ref chat-ref-sighting"
    :class="[`is-faction-${theme}`, { 'is-lost': isLost }]"
    :aria-label="description"
    v-tooltip="{ content: tooltip, html: true }"
    @mouseenter="now = Date.now()"
    @click.stop="onClick">
    <svgicon
      v-if="factionIcon"
      class="chat-ref-emblem"
      :name="factionIcon" />
    <svgicon
      class="chat-ref-emblem"
      :name="`agent/${sighting.agent_type}`" />
    <span class="chat-ref-label">{{ place }}</span>
    <span
      v-if="isLost"
      class="chat-ref-doubt">?</span>
  </button>
  <span
    v-else
    class="chat-ref chat-ref-unknown"
    v-tooltip="$t('in_game_chat.ref.sighting_gone')">
    <span class="chat-ref-icon">◌</span>
    <span class="chat-ref-label">{{ label || $t('in_game_chat.ref.sighting_gone_short') }}</span>
  </span>
</template>

<script>
import { navigateRef } from '../refNavigation';

// Factions the icon registry has an emblem for.
const EMBLEMS = ['ark', 'cardan', 'myrmezir', 'rebellion', 'synelle', 'tetrarchy'];

// Agent type names when the active locale has none (partial locales
// carry empty strings there, which the i18n fallback does not catch).
const TYPE_NAMES = { admiral: 'Navarch', spy: 'Erased', speaker: 'Siderian' };

/**
 * Renders a `[[spot:17]]` chip: an enemy fleet or agent a faction member
 * reported. The chip is drawn from the faction's live sighting record,
 * not from the message, so every copy of it changes together when the
 * server stops seeing the thing:
 *
 *   live  — solid, in the enemy faction's colour: still there, click to
 *           go and look.
 *   lost  — dashed, greyed, with a trailing "?": LAST KNOWN. The hover
 *           text says when it was lost and how; click still flies to
 *           where it was last seen.
 *
 * The chip stays short on purpose: emblem + agent type + place. Faction
 * name, reporter and timing live in the hover text (and the aria-label).
 *
 * Shift+click puts a copy of the chip in the composer, to talk about it.
 */
export default {
  name: 'chat-ref-sighting',
  inject: {
    mapData: { default: null },
  },
  props: {
    id: { type: String, required: true },
    label: { type: String, default: null },
  },
  data() {
    return { now: Date.now() };
  },
  computed: {
    sighting() {
      const id = parseInt(this.id, 10);
      return Number.isFinite(id) ? this.$store.getters['game/sightingById'](id) : null;
    },
    isLost() { return this.sighting.status !== 'live'; },
    isFleet() { return this.sighting.kind === 'fleet'; },
    theme() { return this.$store.getters['game/themeByKey'](this.sighting.faction); },
    factionIcon() {
      return EMBLEMS.includes(this.sighting.faction) ? `faction/${this.sighting.faction}-small` : null;
    },
    factionName() { return this.$t(`data.faction.${this.sighting.faction}.name`); },
    typeName() {
      const type = this.sighting.agent_type;
      return this.$tc(`data.character.${type}.name`, 1) || TYPE_NAMES[type] || type;
    },
    systemName() {
      const id = this.sighting.system_id;
      if (id == null) return null;
      // mapData is not reactive; the galaxy root is, and is replaced
      // whenever the systems (re)load. The read is the dependency.
      const galaxyGeneration = this.$store.state.game.galaxy;
      if (!galaxyGeneration || !this.mapData || !this.mapData.systems) return null;
      const system = this.mapData.systems.find((s) => s.id === id);
      return system ? system.name : null;
    },
    // The visible label: where, and whether it was going there or is there.
    place() {
      const system = this.systemName || this.$t('in_game_chat.ref.unknown_system');
      if (!this.isFleet) return `@ ${system}`;
      return this.sighting.system_id == null ? '→ …' : `→ ${system}`;
    },
    // One plain sentence: what was seen. Also the composer-chip label.
    summary() {
      const params = {
        faction: this.factionName,
        type: this.typeName,
        name: this.sighting.name,
        system: this.systemName || this.$t('in_game_chat.ref.unknown_system'),
      };

      if (!this.isFleet) return this.$t('in_game_chat.sighting.agent', params);
      return this.sighting.system_id == null
        ? this.$t('in_game_chat.sighting.fleet_no_heading', params)
        : this.$t('in_game_chat.sighting.fleet', params);
    },
    // What is known of it now.
    state() {
      if (!this.isLost) {
        return this.$t(`in_game_chat.sighting.live_${this.sighting.kind}`, {
          age: this.age(this.sighting.spotted_at),
        });
      }

      const reason = this.$te(`in_game_chat.sighting.lost.${this.sighting.reason}`)
        ? this.sighting.reason
        : 'unknown';

      return this.$t(`in_game_chat.sighting.lost.${reason}`, {
        age: this.age(this.sighting.lost_at || this.sighting.spotted_at),
        system: this.systemName || this.$t('in_game_chat.ref.unknown_system'),
      });
    },
    description() { return `${this.summary}. ${this.state}`; },
    tooltip() {
      const heading = this.isLost
        ? `<strong>${this.escape(this.$t('in_game_chat.sighting.last_known'))}</strong><br>`
        : '';

      return `${heading}${this.escape(this.summary)}<br>${this.escape(this.state)}`;
    },
  },
  methods: {
    age(timestamp) {
      const seconds = Math.max(0, Math.floor(this.now / 1000) - (timestamp || 0));
      if (seconds < 60) return this.$t('in_game_chat.age.now');
      if (seconds < 3600) return this.$t('in_game_chat.age.minutes', { n: Math.floor(seconds / 60) });
      if (seconds < 86400) return this.$t('in_game_chat.age.hours', { n: Math.floor(seconds / 3600) });
      return this.$t('in_game_chat.age.days', { n: Math.floor(seconds / 86400) });
    },
    // The tooltip is HTML and carries an agent's (player-chosen) name.
    escape(text) {
      return String(text)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    },
    onClick(event) {
      if (event.shiftKey) {
        this.$root.$emit('chat:insertRef', { kind: 'spot', id: this.id, label: this.summary });
        return;
      }

      navigateRef(this, 'spot', this.id);
    },
  },
};
</script>
