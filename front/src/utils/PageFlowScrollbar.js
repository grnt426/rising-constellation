import VueCustomScrollbar from 'vue-custom-scrollbar';

import viewport from '@/utils/viewport';

// The global <v-scrollbar>: vue-custom-scrollbar, except that on phones
// (mobile UI active) it leaves perfect-scrollbar off for any scroller
// inside a portal page.
//
// At phone widths the portal stacks its panels and scrolls the whole page
// in .layout-content (styles/portal/mobile.scss), so a portal scroller is
// just a block in that page flow. Left on, perfect-scrollbar binds its
// own touchmove on each of them, and on Chrome it cancels any downward
// swipe that starts on an element already at its top whenever
// window.scrollY is 0 (a pull-to-refresh guard). The portal never scrolls
// the window, so the page could not be scrolled back up from any panel.
// With perfect-scrollbar off the element keeps no `.ps` class (so no
// forced overflow:hidden) and the browser's native scrolling applies.
//
// Game scrollers are untouched: in-game panels are real bounded scroll
// areas, and the game's mobile layout relies on perfect-scrollbar for
// them (see MiniPanelMixin.scrollbarSettings). Desktop is untouched too.
export default {
  name: 'v-scrollbar',
  extends: VueCustomScrollbar,
  data() {
    return {
      inPortal: false,
    };
  },
  computed: {
    isPageFlow() {
      return viewport.isMobile && this.inPortal;
    },
  },
  watch: {
    // Rotating the phone or flipping the mobile_ui beta toggle.
    isPageFlow(pageFlow) {
      if (pageFlow) {
        this.__uninit();
      } else {
        this.__init();
      }
    },
  },
  methods: {
    __init() {
      // Settled here, not in our own mounted(): the base component's
      // mounted() runs first and calls __init(). The element is already
      // in the document by then (Vue inserts before firing mounted).
      if (this.$el && this.$el.closest) {
        this.inPortal = !!this.$el.closest('.portal-context');
      }

      if (this.isPageFlow) return;

      VueCustomScrollbar.methods.__init.call(this);
    },
  },
};
