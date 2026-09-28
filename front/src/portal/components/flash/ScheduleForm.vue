<template>
  <form
    class="schedule-form"
    @submit.prevent="save">
    <h2>
      {{ schedule ? $t('page.flash_schedule.form.edit_title') : $t('page.flash_schedule.form.new_title') }}
    </h2>

    <div class="schedule-form-grid">
      <div class="default-input">
        <label for="sf-name">{{ $t('page.flash_schedule.form.name') }}</label>
        <input
          id="sf-name"
          type="text"
          maxlength="80"
          required
          v-model="form.name" />
      </div>

      <div class="default-input">
        <label for="sf-weekday">{{ $t('page.flash_schedule.form.weekday') }}</label>
        <select
          id="sf-weekday"
          v-model.number="form.weekday"
          @change="onWeekdayChange">
          <option
            v-for="d in 7"
            :key="`wd-${d}`"
            :value="d">
            {{ weekdayName(d) }}
          </option>
        </select>
      </div>

      <div class="default-input">
        <label for="sf-time">{{ $t('page.flash_schedule.form.time') }}</label>
        <input
          id="sf-time"
          type="time"
          required
          v-model="form.time" />
      </div>

      <div class="radio-input is-horizontal">
        <div class="label">{{ $t('page.flash_schedule.form.mode') }}</div>
        <div class="content">
          <div
            v-for="mode in ['casual', 'ranked']"
            :key="`mode-${mode}`"
            class="content-item">
            <input
              type="radio"
              :id="`sf-mode-${mode}`"
              :value="mode"
              v-model="form.game_mode_type"
              @change="modeTouched = true">
            <label :for="`sf-mode-${mode}`">
              <strong>{{ $t(`page.flash_schedule.${mode}`) }}</strong>
            </label>
          </div>
        </div>
      </div>

      <div class="default-input">
        <label for="sf-min">{{ $t('page.flash_schedule.form.min_players') }}</label>
        <input
          id="sf-min"
          type="number"
          min="2"
          max="200"
          required
          v-model.number="form.min_players" />
      </div>

      <div class="default-input">
        <label for="sf-capacity">{{ $t('page.flash_schedule.form.capacity') }}</label>
        <input
          id="sf-capacity"
          type="number"
          min="1"
          max="200"
          :placeholder="$t('page.flash_schedule.form.capacity_default')"
          v-model="form.faction_capacity" />
      </div>
    </div>

    <div class="default-input">
      <label for="sf-description">{{ $t('page.flash_schedule.form.description') }}</label>
      <textarea
        id="sf-description"
        maxlength="2000"
        :placeholder="$t('page.flash_schedule.form.description_placeholder')"
        v-model="form.description" />
    </div>

    <div class="schedule-form-section">
      <div class="schedule-form-label">{{ $t('page.flash_schedule.form.maps') }}</div>
      <p class="schedule-form-help">{{ $t('page.flash_schedule.form.maps_help') }}</p>

      <ol class="schedule-form-maps">
        <li
          v-for="(id, index) in form.scenario_ids"
          :key="`pool-${id}-${index}`">
          <span class="name">{{ scenarioName(id) }}</span>
          <button
            type="button"
            class="default-button"
            :class="{ disabled: index === 0 }"
            @click="move(index, -1)">
            <svgicon class="icon" name="caret-up" />
          </button>
          <button
            type="button"
            class="default-button"
            :class="{ disabled: index === form.scenario_ids.length - 1 }"
            @click="move(index, 1)">
            <svgicon class="icon" name="caret-down" />
          </button>
          <button
            type="button"
            class="default-button"
            @click="form.scenario_ids.splice(index, 1)">
            <svgicon class="icon" name="close" />
          </button>
        </li>
      </ol>

      <div class="default-input">
        <select
          v-model="mapToAdd"
          @change="addMap">
          <option value="">{{ $t('page.flash_schedule.form.add_map') }}</option>
          <option
            v-for="s in availableScenarios"
            :key="`sc-${s.id}`"
            :value="s.id">
            {{ s.game_metadata.name }} · {{ $t(`map.size.${s.game_metadata.size}.toast`) }}
            · {{ s.game_metadata.factions.length }}F
          </option>
        </select>
      </div>
    </div>

    <div class="schedule-form-section">
      <div class="radio-input is-horizontal">
        <div class="label">{{ $t('page.flash_schedule.form.mutators') }}</div>
        <div class="content">
          <div
            v-for="mode in ['map', 'none', 'custom']"
            :key="`mm-${mode}`"
            class="content-item">
            <input
              type="radio"
              :id="`sf-mm-${mode}`"
              :value="mode"
              v-model="mutatorMode">
            <label :for="`sf-mm-${mode}`">
              <strong>{{ $t(`page.flash_schedule.form.mutator_mode.${mode}`) }}</strong>
            </label>
          </div>
        </div>
      </div>

      <div
        v-if="mutatorMode === 'custom'"
        class="schedule-form-mutators">
        <div
          v-for="m in implementedMutators"
          :key="m.key"
          class="checkbox-input has-small-bm">
          <input
            type="checkbox"
            :id="`sf-mut-${m.key}`"
            :value="m.key"
            v-model="form.mutator_keys" />
          <label :for="`sf-mut-${m.key}`">
            <strong>{{ $t(`data.mutator.${m.key}.name`) }}</strong>
            {{ $t(`data.mutator.${m.key}.description`) }}
          </label>
        </div>
      </div>
    </div>

    <div class="checkbox-input">
      <input
        type="checkbox"
        id="sf-enabled"
        v-model="form.enabled" />
      <label for="sf-enabled">{{ $t('page.flash_schedule.form.enabled') }}</label>
    </div>

    <div class="schedule-form-actions">
      <button
        type="submit"
        class="default-button"
        :class="{ disabled: saving || !valid }">
        {{ $t('page.flash_schedule.form.save') }}
      </button>
      <button
        type="button"
        class="default-button"
        @click="$emit('cancel')">
        {{ $t('page.flash_schedule.form.cancel') }}
      </button>
      <button
        v-if="schedule"
        type="button"
        class="default-button is-danger"
        @click="remove">
        {{ $t('page.flash_schedule.form.delete') }}
      </button>
    </div>
  </form>
</template>

<script>
const TUESDAY = 2;

export default {
  name: 'schedule-form',
  props: {
    schedule: Object,
    scenarios: Array,
    mutators: Array,
  },
  data() {
    const s = this.schedule;

    let mutatorMode = 'map';
    if (s && Array.isArray(s.mutator_keys)) {
      mutatorMode = s.mutator_keys.length ? 'custom' : 'none';
    }

    return {
      saving: false,
      mapToAdd: '',
      // Existing schedules keep their mode; a new one follows the weekday
      // default (Tuesday = ranked) until the admin picks a mode.
      modeTouched: !!s,
      mutatorMode,
      form: {
        name: s ? s.name : '',
        description: s ? s.description : '',
        enabled: s ? s.enabled : true,
        weekday: s ? s.weekday : TUESDAY,
        time: s ? s.start_time.slice(0, 5) : '20:00',
        game_mode_type: s ? s.game_mode_type : 'ranked',
        min_players: s ? s.min_players : 2,
        faction_capacity: s && s.faction_capacity ? s.faction_capacity : '',
        scenario_ids: s ? [...s.scenario_ids] : [],
        mutator_keys: s && Array.isArray(s.mutator_keys) ? [...s.mutator_keys] : [],
      },
    };
  },
  computed: {
    availableScenarios() {
      return this.scenarios.filter((sc) => !this.form.scenario_ids.includes(sc.id));
    },
    implementedMutators() {
      return this.mutators.filter((m) => m.implemented);
    },
    valid() {
      return this.form.name.trim() && this.form.time && this.form.scenario_ids.length > 0
        && this.form.min_players >= 2;
    },
  },
  methods: {
    weekdayName(d) {
      // 2024-01-01 was a Monday (ISO weekday 1).
      return new Date(Date.UTC(2024, 0, d)).toLocaleDateString(this.$i18n.locale, { weekday: 'long', timeZone: 'UTC' });
    },
    onWeekdayChange() {
      if (!this.modeTouched) {
        this.form.game_mode_type = this.form.weekday === TUESDAY ? 'ranked' : 'casual';
      }
    },
    scenarioName(id) {
      const sc = this.scenarios.find((s) => s.id === id);
      return sc ? sc.game_metadata.name : `#${id}`;
    },
    addMap() {
      if (this.mapToAdd !== '') {
        this.form.scenario_ids.push(this.mapToAdd);
      }
      this.mapToAdd = '';
    },
    move(index, delta) {
      const target = index + delta;
      if (target < 0 || target >= this.form.scenario_ids.length) { return; }

      const ids = [...this.form.scenario_ids];
      [ids[index], ids[target]] = [ids[target], ids[index]];
      this.form.scenario_ids = ids;
    },
    payload() {
      let mutatorKeys = null;
      if (this.mutatorMode === 'none') { mutatorKeys = []; }
      if (this.mutatorMode === 'custom') { mutatorKeys = this.form.mutator_keys; }

      return {
        name: this.form.name.trim(),
        description: this.form.description,
        enabled: this.form.enabled,
        weekday: this.form.weekday,
        start_time: `${this.form.time}:00`,
        game_mode_type: this.form.game_mode_type,
        min_players: this.form.min_players,
        faction_capacity: this.form.faction_capacity === '' ? null : Number(this.form.faction_capacity),
        scenario_ids: this.form.scenario_ids,
        mutator_keys: mutatorKeys,
      };
    },
    async save() {
      if (this.saving || !this.valid) { return; }
      this.saving = true;

      try {
        const body = { schedule: this.payload() };
        const { data } = this.schedule
          ? await this.$axios.put(`/flash/schedules/${this.schedule.id}`, body)
          : await this.$axios.post('/flash/schedules', body);
        this.$emit('saved', data);
      } catch (err) {
        this.$toastError(this.errorText(err));
      } finally {
        this.saving = false;
      }
    },
    async remove() {
      if (!window.confirm(this.$t('page.flash_schedule.form.delete_confirm', { name: this.schedule.name }))) {
        return;
      }

      try {
        await this.$axios.delete(`/flash/schedules/${this.schedule.id}`);
        this.$emit('deleted', this.schedule);
      } catch (err) {
        this.$toastError(this.errorText(err));
      }
    },
    errorText(err) {
      const message = err.response && err.response.data && err.response.data.message;
      if (message && typeof message === 'object') {
        return Object.entries(message).map(([field, errors]) => `${field}: ${[].concat(errors).join(', ')}`).join(' · ');
      }
      return message || err.message;
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.schedule-form {
  margin-bottom: 25px;
  padding: 15px;
  background: rgba(0, 0, 0, .2);
  border: solid 1px $primary;
  border-radius: 3px;

  h2 {
    margin-bottom: 15px;
    font-size: 1.8rem;
    text-transform: uppercase;
  }

  textarea {
    height: 80px;
  }
}

.schedule-form-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  column-gap: 15px;
}

.schedule-form-section {
  margin-bottom: 20px;
}

.schedule-form-label {
  font-size: 1.2rem;
  text-transform: uppercase;
  color: $white-alt-1;
}

.schedule-form-help {
  margin: 4px 0 8px;
  font-size: 1.2rem;
  color: $white-alt-2;
}

.schedule-form-maps {
  margin: 0 0 10px;
  padding: 0;
  list-style: none;
  counter-reset: pool;

  li {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 4px;
    padding: 4px 6px;
    background: rgba(0, 0, 0, .15);
    border-radius: 3px;
    counter-increment: pool;

    &:before {
      content: counter(pool) '.';
      min-width: 22px;
      color: $white-alt-1;
    }

    .name {
      flex-grow: 1;
    }

    .default-button {
      padding: 2px 6px;
    }
  }
}

.schedule-form-mutators {
  max-height: 260px;
  overflow-y: auto;
}

.schedule-form-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;

  .is-danger {
    margin-left: auto;
    border-color: $color-alert;
    color: $color-alert;
  }
}
</style>
