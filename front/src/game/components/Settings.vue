<template>
  <div class="settings">
    <ul>
      <li @click="close">
        <template v-if="isTutorial">
          {{ $t('in_game_settings.exit_tutorial') }}
        </template>
        <template v-else>
          {{ $t('in_game_settings.exit') }}
        </template>
      </li>
    </ul>
    <ul>
      <li @click="$emit('close')">
        {{ $t('in_game_settings.back') }}
      </li>
    </ul>
  </div>
</template>

<script>
import eventBus from '@/plugins/event-bus';

export default {
  name: 'settings',
  data() {
    return {
      waiting: false,
    };
  },
  computed: {
    isTutorial() { return this.$store.state.game.galaxy.tutorial_id; },
    isDaily() { return this.$store.state.game.time.speed === 'daily'; },
    instanceId() { return this.$store.state.game.auth.instance; },
  },
  methods: {
    async close() {
      if (!this.waiting) {
        this.waiting = true;

        const { auth } = this.$store.state.game;
        const isTutorial = this.isTutorial;
        // Capture before game/clear wipes the store.
        const isDaily = this.isDaily;

        if (isTutorial) {
          this.$socket.global.push('kill_instance', {});
        } else if (isDaily) {
          // Intentional exit: record the final score and tear the daily down
          // now. (A plain disconnect deliberately doesn't — see the player
          // agent — so a transient drop can't end the run.) Pushed before
          // leaveGame so it flushes on the still-open channel.
          this.$socket.player.push('quit_daily', {});
        }

        this.$ambiance.changeContext('portal');
        this.$socket.leaveGame();
        this.$store.commit('game/clear');

        if (isTutorial) {
          this.$router.push('/play/tutorial');
        } else if (isDaily) {
          // Straight back to the daily page — the player sees the leaderboard
          // (now including their just-recorded run) and can retry. The explicit
          // quit_daily push above tore the instance down server-side.
          this.$router.push('/play/daily');
        } else if (auth) {
          this.$router.push(`/instance/${auth.instance}`);
        } else {
          this.$router.push('/play');
        }
      }
    },
  },
  mounted() {
    eventBus.$on('signal:close_game', () => { this.close(); });
  },
};
</script>
