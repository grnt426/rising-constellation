// Tracks the chart root's width so SVG charts can lay out in real pixels
// (crisp hairlines and text) instead of a scaled viewBox.
export default {
  data() {
    return { width: 0 };
  },
  methods: {
    measure() {
      if (this.$refs.root) this.width = this.$refs.root.clientWidth;
    },
  },
  mounted() {
    this.$nextTick(this.measure);
    if (window.ResizeObserver) {
      this.resizeObserver = new ResizeObserver(() => this.measure());
      this.resizeObserver.observe(this.$refs.root);
    } else {
      window.addEventListener('resize', this.measure);
    }
  },
  beforeDestroy() {
    if (this.resizeObserver) this.resizeObserver.disconnect();
    else window.removeEventListener('resize', this.measure);
  },
};
