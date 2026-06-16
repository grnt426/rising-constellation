<template>
  <div class="mp-content-wrapper">
    <div class="mpc-header is-sparse-x">
      <div>
        <h2>{{ $t('minipanel.contracts.create.title') }}</h2>
      </div>
    </div>

    <div
      v-if="availableCategories.length === 0"
      class="mpc-empty-state">
      <p>{{ $t('minipanel.contracts.create.no_agents') }}</p>
    </div>

    <template v-else>
      <div class="mpc-offers-list">
        <div
          v-for="cat in availableCategories"
          :key="cat"
          @click="category = cat"
          class="mpc-offer-item is-header"
          :class="{ 'is-active': category === cat }">
          {{ $t(`minipanel.contracts.category.${cat}`) }}
        </div>
      </div>

      <div class="mpc-form" style="margin-right: 10px;">
        <div class="mpc-form-bloc">
          <div class="mpc-h-input">
            <label for="ct-action">{{ $t('minipanel.contracts.create.action_type') }}</label>
            <div class="mpc-h-input-i">
              <input id="ct-action" v-model="actionType" maxlength="40">
            </div>
          </div>

          <div class="mpc-h-input">
            <label for="ct-target">{{ $t('minipanel.contracts.create.target_system') }}</label>
            <div class="mpc-h-input-i">
              <input id="ct-target" v-model.number="targetSystemId" type="number">
            </div>
          </div>

          <div class="mpc-h-input">
            <label for="ct-bounty">{{ $t('minipanel.contracts.create.bounty') }}</label>
            <div class="mpc-h-input-i">
              <input id="ct-bounty" v-model.number="bounty" type="number">
              <svgicon name="resource/credit" />
            </div>
          </div>

          <div class="mpc-h-input">
            <label for="ct-duration">{{ $t('minipanel.contracts.create.duration') }}</label>
            <div class="mpc-h-input-i">
              <input id="ct-duration" v-model.number="duration" type="number">
            </div>
          </div>

          <div class="mpc-h-input">
            <label for="ct-strikes">{{ $t('minipanel.contracts.create.max_strikes') }}</label>
            <div class="mpc-h-input-i">
              <input id="ct-strikes" v-model.number="maxStrikes" type="number">
            </div>
          </div>
        </div>
      </div>

      <div class="mpc-form">
        <div class="mpc-form-bloc">
          <div class="mpc-v-input">
            <label for="ct-note">{{ $t('minipanel.contracts.create.note') }}</label>
            <textarea id="ct-note" v-model="note" rows="3" maxlength="280"></textarea>
          </div>
        </div>

        <div class="mpc-form-bloc">
          <button
            class="mpc-button"
            @click="create">
            <div>{{ $t('minipanel.contracts.create.publish') }}</div>
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<script>
export default {
  name: 'contract-create',
  data() {
    return {
      category: null,
      actionType: '',
      targetSystemId: null,
      bounty: 100000,
      duration: 30,
      maxStrikes: 5,
      note: '',
    };
  },
  computed: {
    // Categories the player can actually issue: they must own a deployed agent of
    // that type. The server enforces the full gate (incl. the agent being in an
    // owned system); this is just a helpful filter so the dropdown isn't a trap.
    availableCategories() {
      const chars = this.$store.state.game.player.characters || [];
      const deployed = new Set(
        chars
          .filter((c) => ['on_board', 'governor'].includes(c.status))
          .map((c) => c.type),
      );
      return ['spy', 'speaker', 'admiral'].filter((t) => deployed.has(t));
    },
  },
  watch: {
    availableCategories: {
      immediate: true,
      handler(cats) {
        if (!this.category && cats.length > 0) {
          this.category = cats[0];
        }
      },
    },
  },
  methods: {
    create() {
      if (!this.category) {
        this.$toastError('missing_agent_for_category');
        return;
      }
      if (!Number.isInteger(this.bounty) || this.bounty <= 0) {
        this.$toastError('invalid_bounty');
        return;
      }

      this.$socket.player.push('create_contract', {
        action_category: this.category,
        action_type: this.actionType || null,
        target_system_id: this.targetSystemId || null,
        bounty: this.bounty,
        duration: this.duration,
        max_claimant_strikes: this.maxStrikes,
        note: this.note || '',
      }).receive('ok', () => {
        this.reset();
        this.$emit('created');
      }).receive('error', (data) => {
        this.$toastError(data.reason);
      });
    },
    reset() {
      this.actionType = '';
      this.targetSystemId = null;
      this.bounty = 100000;
      this.duration = 30;
      this.maxStrikes = 5;
      this.note = '';
    },
  },
};
</script>
