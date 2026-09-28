import viewport from '@/utils/viewport';

// Which trigger a <v-popover> should use for "show me the breakdown".
//
// Touch has no hover. A tap fires mouseenter and click back to back,
// and v-tooltip's hover trigger treats that click as the CLOSE event
// (hideOnTargetClick), so a hover popover opens and vanishes in the
// same gesture — which is why resource figures were unreadable on a
// phone. Tap-to-toggle instead; the pointer keeps hover.
export default {
  computed: {
    popoverTrigger() { return viewport.isMobile ? 'click' : 'hover'; },
  },
};
