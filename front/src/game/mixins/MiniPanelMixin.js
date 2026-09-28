import { HORIZONTAL_SCROLL_SETTINGS, BOTH_AXES_SCROLL_SETTINGS } from '@/utils/scrollbar';
import viewport from '@/utils/viewport';

const MiniPanelMixin = {
  data() {
    return {
      activeTab: undefined,
      counter: 0,
    };
  },
  props: {
    defaultTab: {
      type: String,
      required: false,
    },
    height: Number,
  },
  computed: {
    tabs() { return []; },
    isMobileView() { return viewport.isMobile; },
    // Frozen module-level singletons, so the identity only changes when
    // the viewport actually crosses the breakpoint — see
    // utils/scrollbar.js for why a fresh object here kills thumb drags.
    scrollbarSettings() {
      return this.isMobileView ? BOTH_AXES_SCROLL_SETTINGS : HORIZONTAL_SCROLL_SETTINGS;
    },
  },
  methods: {
    switchTab(key) {
      if (this.tabs.includes(key)) {
        this.activeTab = key;
        this.counter += 1;
      }
    },
    close() {
      this.$emit('close');
    },
  },
  mounted() {
    if (this.defaultTab === undefined || this.defaultTab === '') {
      this.switchTab(this.tabs[0]);
    } else {
      this.switchTab(this.defaultTab);
    }
  },
};

export default MiniPanelMixin;
