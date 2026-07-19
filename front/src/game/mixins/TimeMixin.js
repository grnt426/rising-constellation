const TimeMixin = {
  data() {
    return {
      mixinInterval: undefined,
      mixinWorker: undefined,
    };
  },
  computed: {
    time() { return this.$store.state.game.time; },
    utInSeconds() { return this.$store.getters['game/effectiveSpeedFactor'] / this.$config.TIME.UNIT_TIME_DIVIDER; },
  },
  methods: {
    startWorker() {
      this.mixinWorker = setInterval(() => {
        if (this.time.is_running) {
          this.updateValue((this.utInSeconds * (this.getTime() - this.mixinInterval)) / 1000);
          this.mixinInterval = this.getTime();
        }
      }, 1000 / this.$config.TIME.REFRESH_RATE);
    },
    stopWorker() {
      clearInterval(this.mixinWorker);
    },
    updateValue(factor) {
      return factor;
    },
    getTime() {
      return Date.now();
    },
    correctValue(receivedAt) {
      this.updateValue((this.utInSeconds * (this.getTime() - receivedAt)) / 1000);
    },
  },
  mounted() {
    this.mixinInterval = this.getTime();
    this.startWorker();
  },
  destroyed() {
    this.stopWorker();
  },
};

export default TimeMixin;
