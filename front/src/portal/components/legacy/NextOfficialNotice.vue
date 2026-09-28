<template>
  <div
    v-if="visible"
    class="next-official">
    <div class="next-official-main">
      <div class="next-official-label">
        <span class="official-badge">{{ $t('page.play.slow.official') }}</span>
        {{ $t('page.play.slow.next_official') }}
      </div>

      <template v-if="nextOfficial">
        <div class="next-official-date">{{ formattedDate }}</div>
        <div class="next-official-time">{{ formattedTime }}</div>
      </template>
      <div
        v-else
        class="next-official-time">
        {{ $t('page.play.slow.next_official_unset') }}
      </div>

      <div
        v-if="isAdmin && officialActive"
        class="next-official-note">
        {{ $t('page.play.slow.next_official_hidden_note') }}
      </div>
    </div>

    <template v-if="isAdmin">
      <button
        v-if="!editing"
        class="default-button"
        @click="startEditing">
        {{ $t('page.play.slow.edit') }}
      </button>

      <form
        v-else
        class="next-official-form"
        @submit.prevent="save">
        <div class="default-input">
          <label for="next-official-date">{{ $t('page.play.slow.date') }}</label>
          <input
            id="next-official-date"
            type="date"
            v-model="draftDate"
            required />
        </div>
        <div class="default-input">
          <label for="next-official-time">{{ $t('page.play.slow.time_optional') }}</label>
          <input
            id="next-official-time"
            type="time"
            v-model="draftTime" />
        </div>
        <div class="next-official-actions">
          <button
            type="submit"
            class="default-button"
            :class="{ disabled: saving || !draftDate }">
            {{ $t('page.play.slow.save') }}
          </button>
          <button
            v-if="nextOfficial"
            type="button"
            class="default-button"
            @click="clear">
            {{ $t('page.play.slow.clear') }}
          </button>
          <button
            type="button"
            class="default-button"
            @click="editing = false">
            {{ $t('page.play.slow.cancel') }}
          </button>
        </div>
      </form>
    </template>
  </div>
</template>

<script>
const pad = (n) => String(n).padStart(2, '0');

export default {
  name: 'next-official-notice',
  props: {
    nextOfficial: Object,
    officialActive: Boolean,
  },
  data() {
    return {
      editing: false,
      saving: false,
      draftDate: '',
      draftTime: '',
    };
  },
  computed: {
    isAdmin() { return this.$store.state.portal.isAdmin; },
    visible() {
      return this.isAdmin || (!this.officialActive && !!this.nextOfficial);
    },
    startsAt() {
      return this.nextOfficial && this.nextOfficial.starts_at
        ? new Date(this.nextOfficial.starts_at)
        : null;
    },
    formattedDate() {
      const opts = {
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
      };

      if (this.startsAt) {
        return this.startsAt.toLocaleDateString(this.$i18n.locale, opts);
      }

      // Date-only announcements are a calendar day, not an instant: build
      // it in local time so no timezone shift moves it to the day before.
      const [y, m, d] = this.nextOfficial.date.split('-').map(Number);
      return new Date(y, m - 1, d).toLocaleDateString(this.$i18n.locale, opts);
    },
    formattedTime() {
      if (!this.startsAt) {
        return this.$t('page.play.slow.time_tba');
      }

      return this.startsAt.toLocaleTimeString(this.$i18n.locale, {
        hour: '2-digit', minute: '2-digit', timeZoneName: 'short',
      });
    },
  },
  methods: {
    startEditing() {
      if (this.startsAt) {
        const s = this.startsAt;
        this.draftDate = `${s.getFullYear()}-${pad(s.getMonth() + 1)}-${pad(s.getDate())}`;
        this.draftTime = `${pad(s.getHours())}:${pad(s.getMinutes())}`;
      } else {
        this.draftDate = this.nextOfficial ? this.nextOfficial.date : '';
        this.draftTime = '';
      }

      this.editing = true;
    },
    async save() {
      if (!this.draftDate || this.saving) { return; }

      // The time is entered in the admin's own timezone; send the instant.
      const startsAt = this.draftTime
        ? new Date(`${this.draftDate}T${this.draftTime}`).toISOString()
        : null;

      await this.submit({ date: this.draftDate, starts_at: startsAt });
    },
    async clear() {
      await this.submit({ date: null, starts_at: null });
    },
    async submit(body) {
      this.saving = true;

      try {
        const { data } = await this.$axios.put('/legacy/next-official', body);
        this.$emit('updated', data.next_official);
        this.editing = false;
      } catch (e) {
        this.$toastError(e.response ? e.response.data.message : e.message);
      } finally {
        this.saving = false;
      }
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.next-official {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 15px;
  margin-bottom: 15px;
  padding: 15px;

  background: rgba($primary, .08);
  border: solid 1px $primary;
  border-radius: 3px;
}

.next-official-main {
  flex-grow: 1;
}

.next-official-label {
  font-size: 1.2rem;
  text-transform: uppercase;
  color: $white-alt-1;
}

.official-badge {
  display: inline-block;
  margin-right: 6px;
  padding: 0 6px;
  border-radius: 3px;
  background: $primary;
  color: $black;
  font-weight: bold;
}

.next-official-date {
  margin-top: 6px;
  font-size: 2rem;
  font-weight: bold;
  text-transform: uppercase;
}

.next-official-time {
  margin-top: 2px;
  font-size: 1.4rem;
  color: $white-alt-1;
}

.next-official-note {
  margin-top: 8px;
  font-size: 1.2rem;
  font-style: italic;
  color: $white-alt-2;
}

.next-official-form {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 10px;

  .default-input {
    margin-bottom: 0;
  }
}

.next-official-actions {
  display: flex;
  gap: 10px;
}
</style>
