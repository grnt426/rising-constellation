// Hover-intent timing for the side cards that hang next to a panel
// (build options, system bodies). Two timers make the card reachable
// without an explicit pin gesture:
//
// - swap dwell: while a card is up, a newly hovered tile must be dwelt
//   on briefly before the card swaps to it, so sweeping the pointer
//   across the tile grid toward the card doesn't hijack the card with
//   every tile crossed on the way.
// - close grace: after the pointer leaves a tile the card lingers, long
//   enough to travel into the card itself. Entering the card cancels the
//   close and marks it "pinned" (interactive: tooltips, level preview).
//
// Host components must implement:
// - hoverCardApply(payload): render the card for payload (null = none)
// - hoverCardVisible(): whether a card is currently rendered
const SWAP_DWELL_MS = 130;
const CLOSE_GRACE_MS = 350;

const HoverCardMixin = {
  data() {
    return {
      cardPinned: false,
    };
  },
  methods: {
    hoverCardShow(payload) {
      this.hoverCardClearTimers();

      if (this.hoverCardVisible()) {
        // hosts may define hoverCardSwapDwell to slow the swap — a
        // sticky dock far from its triggers needs more travel grace
        // than a card hanging right next to its tile grid
        const dwell = this.hoverCardSwapDwell || SWAP_DWELL_MS;

        this.hoverCardSwapTimer = setTimeout(() => {
          this.cardPinned = false;
          this.hoverCardApply(payload);
        }, dwell);
      } else {
        this.hoverCardApply(payload);
      }
    },
    hoverCardHide() {
      this.hoverCardClearTimers();
      this.hoverCardCloseTimer = setTimeout(() => this.hoverCardClose(), CLOSE_GRACE_MS);
    },
    hoverCardEnter() {
      if (!this.hoverCardVisible()) return;
      this.hoverCardClearTimers();
      this.cardPinned = true;
    },
    hoverCardLeave() {
      this.hoverCardHide();
    },
    hoverCardClose() {
      this.hoverCardClearTimers();
      this.cardPinned = false;
      this.hoverCardApply(null);
    },
    hoverCardClearTimers() {
      clearTimeout(this.hoverCardSwapTimer);
      clearTimeout(this.hoverCardCloseTimer);
    },
  },
  beforeDestroy() {
    this.hoverCardClearTimers();
  },
};

export default HoverCardMixin;
