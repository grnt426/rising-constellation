<template>
  <div class="panel-fragment">
    <div class="panel-content is-square">
      <div class="panel-header">
        <h1 v-html="$tmd('page.profile_detail.header')" />
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <div class="column-container is-two">
          <div class="column-item">
            <div class="cards-container is-centered">
              <div>
                <player-card
                  :profile="profile"
                  class="is-highlighted" />
                <br />

                <button
                  v-show="mode === 'new'"
                  style="position: relative; z-index: 1; margin-top: 10px; width: 300px;"
                  :disabled="!isValid"
                  @click="createFirstProfile"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.profile_detail.begin') }}</template>
                </button>

                <button
                  v-show="mode === 'edit'"
                  style="position: relative; z-index: 1; margin-top: 10px; width: 300px;"
                  :disabled="!isValid"
                  @click="save"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.profile_detail.save') }}</template>
                </button>
              </div>
            </div>
          </div>

          <div class="column-item">
            <div
              :class="{ 'has-error': !(profile.name.length <= 30) }"
              class="default-input">
              <label for="name">{{ $t('page.profile_detail.field_name') }}</label>
              <input
                type="text"
                id="name"
                autocomplete="off"
                v-model="profile.name" />
            </div>

            <div
              :class="{ 'has-error': !(profile.full_name.length <= 120) }"
              class="default-input">
              <label for="full_name">{{ $t('page.profile_detail.field_full_name') }}</label>
              <input
                type="text"
                id="full_name"
                autocomplete="off"
                v-model="profile.full_name" />
              <button
                @click="generateName"
                class="default-button action">
                ↺
              </button>
            </div>

            <div
              :class="{ 'has-error': !(profile.description.length <= 120) }"
              class="default-input">
              <label for="description">{{ $t('page.profile_detail.field_description') }}</label>
              <input
                type="text"
                id="description"
                autocomplete="off"
                v-model="profile.description" />
            </div>

            <div
              :class="{ 'has-error': !(profile.long_description.length <= 1200) }"
              class="default-input">
              <label for="long_description">{{ $t('page.profile_detail.field_long_description') }}</label>
              <textarea
                id="long_description"
                v-model="profile.long_description">
              </textarea>
            </div>
          </div>
        </div>

        <hr class="margin">
      </v-scrollbar>
      <loading-mask v-else />
    </div>

    <v-scrollbar
      class="panel-aside"
      v-if="loaded">
      <div class="panel-aside-bloc">
        <div class="radio-input is-image">
          <div class="label">
            {{ $t('page.profile_detail.profile_picture') }}
          </div>
          <div class="content">
            <div
              v-for="(avatar, i) in avatars"
              :key="`avatar-${i}`"
              class="content-item">
              <input
                type="radio"
                :id="`avatar-${i}`"
                :value="avatar"
                v-model="profile.avatar">
              <label :for="`avatar-${i}`">
                <img :src="resolvePath(avatar)">
              </label>
            </div>
          </div>
        </div>
      </div>

      <div class="panel-aside-bloc">
        <div class="favorite-picker">
          <div class="label">
            {{ $t('page.profile_detail.favorite_faction') }}
          </div>
          <div class="favorite-faction-row">
            <div
              v-for="faction in factions"
              :key="`fav-faction-${faction.key}`"
              class="favorite-faction-item">
              <input
                type="radio"
                :id="`fav-faction-${faction.key}`"
                :value="faction.key"
                v-model="profile.favorite_faction">
              <label
                :for="`fav-faction-${faction.key}`"
                :style="profile.favorite_faction === faction.key ? { color: faction.color, borderColor: faction.color } : {}"
                :title="$t(`data.faction.${faction.key}.name`)">
                <svgicon :name="`faction/${faction.key}`" />
              </label>
            </div>
            <div class="favorite-faction-item">
              <input
                type="radio"
                id="fav-faction-none"
                :value="null"
                v-model="profile.favorite_faction">
              <label
                for="fav-faction-none"
                :title="$t('page.profile_detail.favorite_none')">
                ✕
              </label>
            </div>
          </div>
        </div>
      </div>

      <div class="panel-aside-bloc">
        <div class="favorite-picker">
          <div class="label">
            {{ $t('page.profile_detail.favorite_icon') }}
          </div>
          <select
            v-model="iconCategory"
            class="favorite-icon-category">
            <option :value="null">{{ $t('page.profile_detail.favorite_none') }}</option>
            <option
              v-for="category in iconCategories"
              :key="`icon-cat-${category}`"
              :value="category">
              {{ $t(`page.profile_detail.icon_category.${category}`) }}
            </option>
          </select>

          <div
            v-if="iconCategory"
            class="favorite-icon-grid">
            <div
              v-for="icon in iconsInCategory"
              :key="`fav-icon-${icon}`"
              class="favorite-icon-item">
              <input
                type="radio"
                :id="`fav-icon-${icon}`"
                :value="icon"
                v-model="profile.favorite_icon">
              <label
                :for="`fav-icon-${icon}`"
                :style="profile.favorite_icon === icon ? selectedIconStyle : {}"
                :title="icon">
                <svgicon :name="icon" />
              </label>
            </div>
          </div>
        </div>
      </div>

      <hr class="margin">
    </v-scrollbar>
    <loading-mask
      v-else
      class="panel-aside" />
  </div>
</template>

<script>
import VueSvgIcon from 'vue-svgicon';

import Loading from '@/portal/mixins/Loading';
import Path from '@/utils/path';

import LoadingMask from '@/portal/components/LoadingMask.vue';
import PlayerCard from '@/portal/components/card/PlayerCard.vue';
import { FACTIONS } from '@/utils/factions';

const genders = ['male', 'female'];
const availableAvatars = [
  'avatarM_001.jpg', 'avatarM_002.jpg', 'avatarM_003.jpg', 'avatarM_004.jpg', 'avatarM_005.jpg', 'avatarM_006.jpg', 'avatarM_007.jpg',
  'avatarF_001.jpg', 'avatarF_002.jpg', 'avatarF_003.jpg', 'avatarF_004.jpg', 'avatarF_005.jpg', 'avatarF_006.jpg', 'avatarF_007.jpg',
];

// Mirrors the backend registry (bin/gen_profile_icons.exs): game-flavored
// icon groups only, no UI chrome, no frame_* container art. The picker
// enumerates the vue-svgicon runtime registry so it never goes stale
// against the actual icon files.
const iconGroups = [
  'action', 'agent', 'building', 'doctrine', 'faction', 'marker', 'patent',
  'reaction', 'resource', 'ship', 'stellar_body', 'stellar_system',
];

export default {
  name: 'profile-detail',
  mixins: [Loading],
  data() {
    return {
      mode: '',
      waiting: false,
      avatars: [],
      factions: FACTIONS,
      iconCategory: null,
      profile: {
        avatar: '',
        name: '',
        full_name: '',
        description: '',
        long_description: '',
        favorite_faction: null,
        favorite_icon: null,
        // filled by GET /profiles/:pid — pre-declared so the Object.assign
        // in loadData stays reactive (Vue 2 can't observe new keys)
        stats: null,
      },
    };
  },
  computed: {
    account() { return this.$store.state.portal.account; },
    culture() { return this.$store.state.portal.data.culture; },
    isValid() {
      if (this.profile) {
        return this.profile.name
          && availableAvatars.includes(this.profile.avatar)
          && !this.waiting;
      }

      return false;
    },
    allIcons() {
      return Object.keys(VueSvgIcon.icons)
        .filter((name) => {
          const [group, base] = name.split('/');
          return base && iconGroups.includes(group)
            && !base.startsWith('frame_') && !base.endsWith('-small');
        })
        .sort();
    },
    iconCategories() {
      return iconGroups.filter((group) => this.allIcons.some((name) => name.startsWith(`${group}/`)));
    },
    iconsInCategory() {
      return this.allIcons.filter((name) => name.startsWith(`${this.iconCategory}/`));
    },
    selectedIconStyle() {
      const faction = FACTIONS.find((f) => f.key === this.profile.favorite_faction);
      const color = faction ? faction.color : '#e6e6e6';
      return { color, borderColor: color };
    },
  },
  methods: {
    async createFirstProfile() {
      if (this.isValid) {
        this.waiting = true;

        try {
          // create new profile
          const resp = await this.$axios.post(
            `/accounts/${this.account.id}/profiles`,
            { aid: this.account.id, profile: this.profile },
          );

          // set profile to store and settings
          const { data } = await this.$axios.get(`/accounts/${this.account.id}/profiles`);
          const profile = data.find((p) => p.id === resp.data.id);
          await this.$store.dispatch('portal/updateActiveProfile', profile);

          // redirect
          this.$router.push('/play/tutorial');
        } catch (err) {
          this.$toastChangesetError(err);
        }

        this.waiting = false;
      }
    },
    async save() {
      if (this.isValid) {
        this.waiting = true;

        try {
          await this.$axios.put(`/profiles/${this.profile.id}`, { profile: this.profile });

          // update profile to store and settings
          const { data } = await this.$axios.get(`/accounts/${this.account.id}/profiles`);
          const profile = data.find((p) => p.id === this.profile.id);
          await this.$store.dispatch('portal/updateActiveProfile', profile);
        } catch (err) {
          this.$toastChangesetError(err);
        }

        this.waiting = false;
      }
    },
    async loadData(pid) {
      const { data } = await this.$axios.get(`/profiles/${pid}`);
      Object.keys(data).forEach((key) => {
        // The favorites stay null-able — null is the legitimate
        // "no favorite" value the radio inputs bind against.
        if (data[key] === null && !['favorite_faction', 'favorite_icon', 'stats'].includes(key)) {
          data[key] = '';
        }
      });
      Object.assign(this.profile, data);
      if (this.profile.favorite_icon) {
        [this.iconCategory] = this.profile.favorite_icon.split('/');
      }
      this.releaseLoading(0);
    },
    async generateName() {
      this.profile.full_name = await this.loadName();
    },
    async loadName() {
      const culture = this.culture[Math.floor(Math.random() * this.culture.length)];
      const gender = genders[Math.floor(Math.random() * genders.length)];

      const [firstname, lastname] = await Promise.all([
        this.$axios.get(`/name/${culture.firstname_repo[gender]}/1`),
        this.$axios.get(`/name/${culture.lastname_repo}/1`),
      ]);

      return `${firstname.data[0]} ${lastname.data[0]}`;
    },
    resolvePath(filename) {
      return Path.relative(`data/avatars/${filename}`);
    },
  },
  async mounted() {
    const shuffledAvatars = availableAvatars.sort(() => Math.random() - 0.5);
    this.avatars = shuffledAvatars;

    // fetch query params, setup mode
    this.mode = !this.$route.query.mode
      ? 'new'
      : this.$route.query.mode;

    if (this.mode === 'new') {
      this.profile = {
        avatar: shuffledAvatars[0],
        name: this.account.name,
        full_name: '',
        description: '',
        long_description: '',
        favorite_faction: null,
        favorite_icon: null,
        stats: null,
      };
      this.releaseLoading(0);
    } else {
      this.loadData(this.$route.params.pid);
    }
  },
  watch: {
    iconCategory(category) {
      // Changing category invalidates a selection from another group;
      // picking "none" clears the favorite outright.
      if (!category || (this.profile.favorite_icon && !this.profile.favorite_icon.startsWith(`${category}/`))) {
        this.profile.favorite_icon = null;
      }
    },
  },
  components: {
    LoadingMask,
    PlayerCard,
  },
};
</script>

<style lang="scss" scoped>
.favorite-picker {
  .label {
    margin-bottom: 8px;
    font-size: 14px;
    text-transform: uppercase;
    opacity: 0.7;
  }
}

.favorite-faction-row {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.favorite-faction-item,
.favorite-icon-item {
  input {
    display: none;
  }

  label {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 42px;
    height: 42px;
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 4px;
    color: rgba(230, 230, 230, 0.55);
    cursor: pointer;

    &:hover {
      border-color: rgba(255, 255, 255, 0.5);
      color: rgba(230, 230, 230, 0.9);
    }

    svg {
      width: 26px;
      height: 26px;
      fill: currentColor;
    }
  }
}

.favorite-icon-category {
  width: 100%;
  margin-bottom: 8px;
  padding: 6px;
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: inherit;
}

.favorite-icon-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  max-height: 260px;
  overflow-y: auto;
}
</style>
