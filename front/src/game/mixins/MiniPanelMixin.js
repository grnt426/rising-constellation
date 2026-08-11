import { HORIZONTAL_SCROLL_SETTINGS } from '@/utils/scrollbar';
import viewport from '@/utils/viewport';

const MiniPanelMixin = {
  data() {
    return {
      activeTab: undefined,
      counter: 0,
      // stable identity — see utils/scrollbar.js for why an inline
      // template literal here breaks scrollbar-thumb dragging
      scrollbarSettings: HORIZONTAL_SCROLL_SETTINGS,
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
