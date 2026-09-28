<template>
  <div class="custom-select">
    <div
      v-show="label"
      class="custom-select-label">
      {{ label }}
    </div>
    <div class="custom-select-input">
      <v-select
        :options="filteredOptions"
        :filterable="false"
        :multiple="multiple"
        v-model="value"
        @search="fetchOptions"
        @input="input">
        <template slot="no-options">
          {{ $t('toast.error.select_no_result') }}
        </template>
      </v-select>
    </div>
  </div>
</template>

<script>
export default {
  name: 'profile-select',
  props: {
    multiple: {
      type: Boolean,
      default: false,
    },
    instanceId: {
      type: Number,
      required: true,
    },
    label: {
      type: String,
      required: false,
    },
    initials: {
      type: Array,
      default: (() => []),
    },
    discardedIds: {
      type: Array,
      default: (() => []),
    },
    // when set, only players of this faction key can be picked (the search
    // endpoint is instance-wide)
    factionKey: {
      type: String,
      default: null,
    },
  },
  data() {
    return {
      options: [],
      value: null,
    };
  },
  computed: {
    filteredOptions() {
      const options = this.options.filter((p) => !this.discardedIds.includes(p.id));
      if (!this.factionKey) return options;
      const players = (this.$store.state.game.galaxy || {}).players || {};
      return options.filter((p) => players[p.id] && players[p.id].faction === this.factionKey);
    },
  },
  methods: {
    async fetchOptions(search, loading) {
      if (search.length) {
        loading(true);
        const { data } = await this.$axios.get(`/profile/search/${this.instanceId}/${search}`);
        this.options = data.map((p) => ({ label: p.name, id: p.id }));
        loading(false);
      }
    },
    input(value) {
      this.$emit('input', value);
    },
  },
  mounted() {
    this.options = this.initials;
  },
};
</script>
