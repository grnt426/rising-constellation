<template>
  <v-popover
    ref="popover"
    v-bind="$attrs"
    trigger="manual"
    :open="open"
    :auto-hide="false"
    :popover-class="popoverClass">
    <span
      class="hover-popover-trigger"
      @mouseenter="onTriggerEnter"
      @mouseleave="onTriggerLeave"
      @click="onTriggerClick">
      <slot />
    </span>
    <div
      slot="popover"
      class="hover-popover-content"
      @mouseenter="onContentEnter"
      @mouseleave="onContentLeave">
      <slot name="popover" />
    </div>
  </v-popover>
</template>

<script>
// A hover popover the pointer can actually reach. v-tooltip's hover trigger
// hides the moment the pointer leaves the trigger unless it lands directly
// inside the popover, so anything interactive in the popover (the manual's
// "?" in ResourceDetail) is unreachable across the gap. Same idea as
// HoverCardMixin for the side cards:
//
// - leaving the trigger starts a close grace; entering the popover cancels
//   it, leaving the popover starts it again;
// - clicking the trigger pins the popover (click again, click outside,
//   Esc, or opening a help page unpins it).
//
// Drop-in for `<v-popover trigger="hover">`: default slot = trigger,
// `popover` slot = content, other props/attrs pass through.
const CLOSE_GRACE_MS = 350;

export default {
  name: 'hover-popover',
  inheritAttrs: false,
  data() {
    return {
      open: false,
      pinned: false,
      closeTimer: null,
    };
  },
  computed: {
    popoverClass() {
      const base = this.$attrs.popoverClass || this.$attrs['popover-class'] || '';
      return this.pinned ? `${base} is-pinned`.trim() : base;
    },
  },
  methods: {
    show() {
      this.clearTimer();
      this.open = true;
    },
    scheduleClose() {
      if (this.pinned) return;
      this.clearTimer();
      this.closeTimer = setTimeout(() => this.close(), CLOSE_GRACE_MS);
    },
    close() {
      this.clearTimer();
      this.open = false;
      this.unpin();
    },
    clearTimer() {
      if (this.closeTimer) {
        clearTimeout(this.closeTimer);
        this.closeTimer = null;
      }
    },
    onTriggerEnter() { this.show(); },
    onTriggerLeave() { this.scheduleClose(); },
    onContentEnter() { this.clearTimer(); },
    onContentLeave() { this.scheduleClose(); },
    onTriggerClick() {
      if (this.pinned) {
        this.close();
      } else {
        this.pin();
      }
    },
    pin() {
      this.pinned = true;
      this.show();
      document.addEventListener('mousedown', this.onDocumentMouseDown, true);
      document.addEventListener('keydown', this.onDocumentKeyDown, true);
    },
    unpin() {
      if (!this.pinned) return;
      this.pinned = false;
      document.removeEventListener('mousedown', this.onDocumentMouseDown, true);
      document.removeEventListener('keydown', this.onDocumentKeyDown, true);
    },
    onDocumentMouseDown(event) {
      const inTrigger = this.$el && this.$el.contains(event.target);
      const inContent = event.target.closest && event.target.closest('.hover-popover-content');
      if (!inTrigger && !inContent) this.close();
    },
    onDocumentKeyDown(event) {
      if (event.key === 'Escape') this.close();
    },
  },
  mounted() {
    // Opening a manual page from the "?" is the end of the interaction.
    this.$root.$on('openHelp', this.close);
  },
  beforeDestroy() {
    this.$root.$off('openHelp', this.close);
    this.close();
  },
};
</script>
