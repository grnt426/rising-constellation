<template>
  <div
    v-if="visible"
    class="system-icon-picker"
    :style="rootStyle"
    @click.stop>
    <button
      v-for="(kind, i) in kinds"
      :key="kind"
      class="system-icon-picker__btn"
      :class="{ 'is-active': existingKind === kind }"
      :style="buttonStyle(i)"
      v-tooltip="$t(`galaxy.map.icons.kinds.${kind}`)"
      @click="onPick(kind)">
      <svgicon :name="iconName(kind)" />
    </button>
    <button
      v-if="existingKind"
      class="system-icon-picker__btn system-icon-picker__btn--remove"
      v-tooltip="$t('galaxy.map.icons.actions.remove')"
      @click="onRemove">
      <svgicon name="close" />
    </button>
  </div>
</template>

<script>
import eventBus from '@/plugins/event-bus';

// 7 placement choices, intentionally generic so a faction's Discord
// agreement (rather than the icon's literal art) defines the meaning.
// Order is the radial layout order — clockwise starting from the top.
const KINDS = ['shield', 'attack', 'flag', 'target', 'danger', 'path', 'question'];

// Four icons reuse existing in-game art (consistency with the rest of
// the UI); the four marker/* SVGs were added for this feature. The
// `shield` (Defend) kind originally pointed at ship/shield but read
// too literal against the game's aesthetic — ship/hull (a 4-wedge
// diamond) is what's used on the map and what the picker shows here,
// so the radial preview matches the placed marker.
const ICON_NAME_BY_KIND = {
  attack: 'marker/attack',
  danger: 'ship/explosive_strikes',
  flag: 'marker/flag',
  path: 'marker/path',
  question: 'marker/question',
  shield: 'ship/hull',
  target: 'ship/energy_strikes',
};

const RADIUS_PX = 64;

export default {
  name: 'system-icon-picker',
  data() {
    return {
      visible: false,
      screenX: 0,
      screenY: 0,
      systemId: null,
      kinds: KINDS,
    };
  },
  computed: {
    rootStyle() {
      return {
        left: `${this.screenX}px`,
        top: `${this.screenY}px`,
      };
    },
    factionIcons() {
      // Backend ships every faction icon on the faction state struct
      // (see Faction.Faction#icons); the channel handler keeps Vuex in
      // sync, so reading from state is enough to know what's already
      // on this system.
      return (this.$store.state.game.faction && this.$store.state.game.faction.icons) || [];
    },
    existing() {
      if (this.systemId == null) return null;
      return this.factionIcons.find((i) => i.system_id === this.systemId) || null;
    },
    existingKind() {
      return this.existing ? this.existing.kind : null;
    },
  },
  mounted() {
    eventBus.$on('system-icon-picker:show', this.show);
    eventBus.$on('system-icon-picker:hide', this.hide);
    // pointerdown covers both mouse and touch; the map canvas binds
    // its own pointerdown handler in bubble phase, so listening here
    // in capture phase guarantees we see every gesture before the
    // canvas decides what to do with it. Found this from the issue
    // report that clicking outside didn't dismiss the picker — bare
    // `mousedown` was firing inconsistently next to the canvas's
    // pointerdown handler.
    document.addEventListener('pointerdown', this.onDocumentPointerDown, true);
    document.addEventListener('keydown', this.onKeyDown, true);
  },
  beforeDestroy() {
    eventBus.$off('system-icon-picker:show', this.show);
    eventBus.$off('system-icon-picker:hide', this.hide);
    document.removeEventListener('pointerdown', this.onDocumentPointerDown, true);
    document.removeEventListener('keydown', this.onKeyDown, true);
  },
  methods: {
    iconName(kind) { return ICON_NAME_BY_KIND[kind]; },
    show({ systemId, screen }) {
      this.systemId = systemId;
      // Clamp to viewport so the radial doesn't spill off-screen on
      // edge clicks. The picker is ~160px square (RADIUS + button half
      // on each side); 90 is a safe margin.
      const margin = 90;
      this.screenX = Math.min(Math.max(screen.x, margin), window.innerWidth - margin);
      this.screenY = Math.min(Math.max(screen.y, margin), window.innerHeight - margin);
      this.visible = true;
    },
    hide() {
      this.visible = false;
      this.systemId = null;
    },
    onDocumentPointerDown(event) {
      if (!this.visible) return;
      // Any pointerdown inside the picker (root or buttons) walks up
      // to find .system-icon-picker via closest(). Everything else
      // (canvas, other UI) closes us. The map canvas's own
      // pointerdown handler runs in bubble phase, after this — but
      // that's fine: clicking on a system with the picker already
      // open should close the picker AND let the canvas do whatever
      // it normally would for that click.
      if (event.target && event.target.closest && event.target.closest('.system-icon-picker')) return;
      this.hide();
    },
    onKeyDown(event) {
      if (this.visible && event.key === 'Escape') {
        this.hide();
      }
    },
    buttonStyle(i) {
      // -90° start = top; clockwise.
      const angle = ((i / KINDS.length) * 2 * Math.PI) - (Math.PI / 2);
      const x = Math.cos(angle) * RADIUS_PX;
      const y = Math.sin(angle) * RADIUS_PX;
      return {
        transform: `translate(${x - 18}px, ${y - 18}px)`,
      };
    },
    onPick(kind) {
      const systemId = this.systemId;
      // Hide immediately so the radial doesn't linger while the
      // round-trip happens. If the server rejects, we surface a toast
      // — the optimistic state isn't critical here because the
      // faction_faction broadcast on success will update the map.
      this.hide();
      this.$socket.faction.push('place_icon', { system_id: systemId, icon_kind: kind })
        .receive('error', (data) => {
          // $toastError looks up toast.error.<reason> in errors.json,
          // matching the pattern Chat.vue uses for push_chat_message.
          this.$toastError((data && data.reason) || 'invalid_payload');
        });
    },
    onRemove() {
      const systemId = this.systemId;
      this.hide();
      this.$socket.faction.push('remove_icon', { system_id: systemId })
        .receive('error', (data) => {
          this.$toastError((data && data.reason) || 'invalid_payload');
        });
    },
  },
};
</script>

<style lang="scss" scoped>
.system-icon-picker {
  position: fixed;
  z-index: 200;
  width: 0;
  height: 0;
  pointer-events: none;
}

.system-icon-picker__btn {
  position: absolute;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  border: 1px solid rgba(255, 255, 255, 0.35);
  background: rgba(20, 24, 32, 0.85);
  color: rgba(220, 220, 220, 0.85);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  pointer-events: auto;
  transition: background 120ms, border-color 120ms, transform 120ms;
  padding: 0;

  // Desaturated palette so the markers sit quietly on top of the map
  // without competing with the faction colors and system glyphs.
  ::v-deep svg {
    width: 18px;
    height: 18px;
    fill: rgba(220, 220, 220, 0.85);
  }

  &:hover {
    background: rgba(40, 48, 60, 0.95);
    border-color: rgba(255, 255, 255, 0.65);

    ::v-deep svg { fill: rgba(255, 255, 255, 0.95); }
  }

  &.is-active {
    border-color: rgba(180, 220, 255, 0.85);
    background: rgba(50, 70, 100, 0.95);
  }

  &--remove {
    transform: translate(-18px, -18px);
    background: rgba(60, 20, 20, 0.9);
    border-color: rgba(200, 100, 100, 0.6);

    &:hover {
      background: rgba(100, 30, 30, 0.95);
    }
  }
}
</style>
