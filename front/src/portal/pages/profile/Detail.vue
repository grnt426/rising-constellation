<template>
  <div class="panel-fragment">
    <div class="panel-content is-square">
      <div class="panel-header">
        <h1 v-html="$tmd('page.profile_detail.header')" />
      </div>

      <v-scrollbar
        v-if="loaded"
        class="content">
        <!-- Mirrors the Discord /player card: identity block up top,
             legacy + daily panels side by side, factions strip below.
             Everything editable is edited in place; the pickers live in
             the aside and appear only when summoned. -->
        <div
          class="profile-hero"
          :style="{ '--hero-accent': factionColor }">
          <div class="hero-accent" />

          <div class="hero-topline">
            <div
              v-if="editing === 'name'"
              :class="{ 'has-error': !nameValid }"
              class="hero-name-input default-input">
              <input
                ref="edit-name"
                type="text"
                maxlength="30"
                autocomplete="off"
                v-model="profile.name"
                @keyup.enter="stopEditing"
                @blur="stopEditing" />
            </div>
            <h2
              v-else
              class="hero-name"
              :class="{ 'has-error': !nameValid }"
              :title="$t('page.profile_detail.edit_hint')"
              @click="startEditing('name')">
              {{ profile.name || '…' }}
              <span class="hero-pencil">✎</span>
            </h2>
            <div class="hero-kicker">{{ $t('page.profile_detail.kicker') }}</div>
          </div>

          <div class="hero-identity">
            <div class="hero-portrait">
              <img :src="avatarPath" />
              <button
                class="hero-badge"
                type="button"
                :title="$t('page.profile_detail.favorite_icon')"
                @click="togglePicker('icon')">
                <svgicon
                  v-if="profile.favorite_icon"
                  :name="profile.favorite_icon" />
                <span v-else>+</span>
              </button>
              <button
                class="hero-portrait-edit"
                type="button"
                :title="$t('page.profile_detail.profile_picture')"
                @click="togglePicker('avatar')">
                ✎
              </button>
            </div>

            <div class="hero-text">
              <div
                v-if="editing === 'full_name'"
                :class="{ 'has-error': profile.full_name.length > 120 }"
                class="default-input hero-title-input">
                <input
                  ref="edit-full_name"
                  type="text"
                  maxlength="120"
                  autocomplete="off"
                  v-model="profile.full_name"
                  @keyup.enter="stopEditing"
                  @blur="stopEditing" />
                <button
                  class="default-button action"
                  @mousedown.prevent
                  @click="generateName">
                  ↺
                </button>
              </div>
              <div
                v-else
                class="hero-title"
                :class="{ 'is-placeholder': !profile.full_name }"
                :title="$t('page.profile_detail.edit_hint')"
                @click="startEditing('full_name')">
                {{ profile.full_name || $t('page.profile_detail.placeholder_title') }}
                <span class="hero-pencil">✎</span>
              </div>

              <div
                v-if="editing === 'description'"
                :class="{ 'has-error': profile.description.length > 120 }"
                class="default-input">
                <input
                  ref="edit-description"
                  type="text"
                  maxlength="120"
                  autocomplete="off"
                  v-model="profile.description"
                  @keyup.enter="stopEditing"
                  @blur="stopEditing" />
              </div>
              <div
                v-else
                class="hero-maxim"
                :class="{ 'is-placeholder': !profile.description }"
                :title="$t('page.profile_detail.edit_hint')"
                @click="startEditing('description')">
                {{ profile.description || $t('page.profile_detail.placeholder_maxim') }}
                <span class="hero-pencil">✎</span>
              </div>

              <button
                class="hero-allegiance"
                type="button"
                :title="$t('page.profile_detail.favorite_faction')"
                @click="togglePicker('faction')">
                <span class="hero-allegiance-label">{{ $t('page.profile_detail.favorite_faction') }}</span>
                <span
                  v-if="profile.favorite_faction"
                  class="hero-faction-chip"
                  :style="{ background: factionColor }">
                  <svgicon :name="`faction/${profile.favorite_faction}-small`" />
                </span>
                <span
                  v-if="profile.favorite_faction"
                  class="hero-allegiance-name"
                  :style="{ color: factionColor }">
                  {{ $t(`data.faction.${profile.favorite_faction}.name`) }}
                </span>
                <span
                  v-else
                  class="hero-allegiance-name is-placeholder">
                  {{ $t('page.profile_detail.favorite_none') }}
                </span>
              </button>
            </div>
          </div>

          <div
            v-if="profile.stats"
            class="hero-stats">
            <div class="hero-panel">
              <div class="hero-panel-title">{{ $t('page.profile_detail.panel_legacy') }}</div>
              <div class="hero-big-number">{{ profile.stats.legacy.wins }}</div>
              <div class="hero-big-label">{{ $t('page.profile_detail.legacy_wins_label') }}</div>
              <div class="hero-panel-foot">
                {{ $t('page.profile_detail.legacy_entered', { count: profile.stats.legacy.participations }) }}
              </div>
            </div>

            <div class="hero-panel">
              <div class="hero-panel-title">{{ $t('page.profile_detail.panel_daily') }}</div>
              <div class="hero-medals">
                <div
                  v-for="medal in medals"
                  :key="medal.key"
                  :class="{ 'is-dim': medal.count === 0 }"
                  class="hero-medal">
                  <span
                    class="hero-medal-disc"
                    :style="{ background: medal.color }">★</span>
                  <span class="hero-medal-count">{{ medal.count }}</span>
                  <span class="hero-medal-label">{{ $t(`page.profile_detail.medal_${medal.key}`) }}</span>
                </div>
              </div>
              <div class="hero-panel-foot">
                {{ $t('page.profile_detail.daily_completed_line', {
                  completed: profile.stats.daily.completed,
                  played: profile.stats.daily.played,
                }) }}
              </div>
            </div>
          </div>

          <div
            v-if="profile.stats"
            class="hero-panel hero-factions">
            <div class="hero-panel-title">{{ $t('page.profile_detail.panel_factions') }}</div>
            <div class="hero-factions-row">
              <div
                v-for="faction in factions"
                :key="`stat-${faction.key}`"
                :class="{ 'is-dim': !factionCount(faction.key) }"
                class="hero-faction-col">
                <span
                  class="hero-faction-chip is-large"
                  :style="{ background: faction.color }">
                  <svgicon :name="`faction/${faction.key}-small`" />
                </span>
                <span class="hero-faction-count">{{ factionCount(faction.key) }}</span>
                <span class="hero-faction-name">{{ $t(`data.faction.${faction.key}.name`) }}</span>
              </div>
            </div>
            <div class="hero-panel-foot is-note">{{ $t('page.profile_detail.factions_note') }}</div>
          </div>

          <div class="hero-actions">
            <button
              v-show="mode === 'new'"
              :disabled="!isValid"
              @click="createFirstProfile"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.profile_detail.begin') }}</template>
            </button>

            <button
              v-show="mode === 'edit'"
              :disabled="!isValid"
              @click="save"
              class="default-button">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.profile_detail.save') }}</template>
            </button>
          </div>
        </div>

        <hr class="margin">
      </v-scrollbar>
      <loading-mask v-else />
    </div>

    <v-scrollbar
      class="panel-aside"
      v-if="loaded && activePicker">
      <div class="panel-aside-bloc">
        <div class="picker-header">
          <div class="label">
            {{ $t(`page.profile_detail.${pickerLabelKey}`) }}
          </div>
          <button
            class="picker-close"
            type="button"
            @click="activePicker = null">
            ✕
          </button>
        </div>

        <!-- portrait picker -->
        <div
          v-if="activePicker === 'avatar'"
          class="radio-input is-image">
          <div class="content">
            <div
              v-for="(avatar, i) in avatars"
              :key="`avatar-${i}`"
              class="content-item">
              <input
                type="radio"
                :id="`avatar-${i}`"
                :value="avatar"
                v-model="profile.avatar"
                @change="activePicker = null">
              <label :for="`avatar-${i}`">
                <img :src="resolvePath(avatar)">
              </label>
            </div>
          </div>
        </div>

        <!-- favorite faction picker -->
        <div
          v-if="activePicker === 'faction'"
          class="favorite-faction-row">
          <div
            v-for="faction in factions"
            :key="`fav-faction-${faction.key}`"
            class="favorite-faction-item">
            <input
              type="radio"
              :id="`fav-faction-${faction.key}`"
              :value="faction.key"
              v-model="profile.favorite_faction"
              @change="activePicker = null">
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
              v-model="profile.favorite_faction"
              @change="activePicker = null">
            <label
              for="fav-faction-none"
              :title="$t('page.profile_detail.favorite_none')">
              ✕
            </label>
          </div>
        </div>

        <!-- favorite icon picker -->
        <template v-if="activePicker === 'icon'">
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
                v-model="profile.favorite_icon"
                @change="activePicker = null">
              <label
                :for="`fav-icon-${icon}`"
                :style="profile.favorite_icon === icon ? selectedIconStyle : {}"
                :title="icon">
                <svgicon :name="icon" />
              </label>
            </div>
          </div>
        </template>
      </div>

      <hr class="margin">
    </v-scrollbar>
  </div>
</template>

<script>
import VueSvgIcon from 'vue-svgicon';

import Loading from '@/portal/mixins/Loading';
import Path from '@/utils/path';

import LoadingMask from '@/portal/components/LoadingMask.vue';
import { FACTIONS, factionColor } from '@/utils/factions';

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

const medalColors = { gold: '#e3b341', silver: '#b8c0cc', bronze: '#c98a52' };

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
      // Which inline field is being edited ('name' | 'full_name' |
      // 'description'), and which aside picker is open ('avatar' |
      // 'faction' | 'icon'). Pickers close themselves on selection.
      editing: null,
      activePicker: null,
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
    nameValid() {
      return !!this.profile.name && this.profile.name.length <= 30;
    },
    isValid() {
      if (this.profile) {
        return this.nameValid
          && availableAvatars.includes(this.profile.avatar)
          && !this.waiting;
      }

      return false;
    },
    avatarPath() {
      return Path.relative(`data/avatars/${this.profile.avatar || 'empty.jpg'}`);
    },
    factionColor() {
      return factionColor(this.profile.favorite_faction);
    },
    medals() {
      const daily = this.profile.stats.daily;
      return ['gold', 'silver', 'bronze'].map((key) => ({ key, color: medalColors[key], count: daily[key] }));
    },
    pickerLabelKey() {
      return {
        avatar: 'profile_picture',
        faction: 'favorite_faction',
        icon: 'favorite_icon',
      }[this.activePicker];
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
      return { color: this.factionColor, borderColor: this.factionColor };
    },
  },
  methods: {
    factionCount(key) {
      return (this.profile.stats && this.profile.stats.factions[key]) || 0;
    },
    startEditing(field) {
      this.editing = field;
      this.$nextTick(() => {
        const input = this.$refs[`edit-${field}`];
        if (input) {
          input.focus();
        }
      });
    },
    stopEditing() {
      this.editing = null;
    },
    togglePicker(picker) {
      this.activePicker = this.activePicker === picker ? null : picker;
    },
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
  watch: {
    iconCategory(category) {
      // Changing category invalidates a selection from another group;
      // picking "none" clears the favorite outright.
      if (!category || (this.profile.favorite_icon && !this.profile.favorite_icon.startsWith(`${category}/`))) {
        this.profile.favorite_icon = null;
      }
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
  components: {
    LoadingMask,
  },
};
</script>

<style lang="scss" scoped>
// The Discord /player card's look, transplanted: dark translucent
// panels, faction-colored accent, portrait with the favorite-icon
// badge riding the bottom-LEFT corner (the right edge stays clear —
// on the swipeable cards that side hosts the panel arrows).
.profile-hero {
  position: relative;
  max-width: 760px;
  margin: 0 auto;
  padding: 0 8px 16px;
}

.hero-accent {
  height: 4px;
  margin-bottom: 18px;
  background: var(--hero-accent, rgba(255, 255, 255, 0.14));
}

.hero-topline {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  padding-bottom: 10px;
  margin-bottom: 18px;

  .hero-name {
    margin: 0;
    font-size: 28px;
    letter-spacing: 1px;
    text-transform: uppercase;
    cursor: pointer;

    &.has-error {
      outline: 1px solid rgba(220, 50, 50, 0.8);
    }
  }

  .hero-name-input {
    flex: 0 1 320px;
  }

  .hero-kicker {
    font-size: 13px;
    font-weight: 800;
    letter-spacing: 2px;
    color: rgba(230, 230, 230, 0.55);
    text-transform: uppercase;
  }
}

.hero-pencil {
  font-size: 14px;
  opacity: 0;
  transition: opacity 0.15s;
}

.hero-name:hover .hero-pencil,
.hero-title:hover .hero-pencil,
.hero-maxim:hover .hero-pencil {
  opacity: 0.6;
}

.hero-identity {
  display: flex;
  gap: 20px;
  padding: 20px;
  margin-bottom: 20px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;
}

.hero-portrait {
  position: relative;
  flex: 0 0 340px;

  img {
    display: block;
    width: 340px;
    height: 170px;
    object-fit: cover;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.18);
  }
}

// The favorite-icon badge doubles as its own picker button.
.hero-badge {
  position: absolute;
  left: 8px;
  bottom: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 52px;
  height: 52px;
  background: rgba(14, 16, 19, 0.92);
  border: 2px solid var(--hero-accent, rgba(230, 230, 230, 0.55));
  border-radius: 50%;
  color: var(--hero-accent, rgba(230, 230, 230, 0.55));
  font-size: 24px;
  cursor: pointer;

  svg {
    width: 28px;
    height: 28px;
    fill: currentColor;
  }

  &:hover {
    filter: brightness(1.25);
  }
}

.hero-portrait-edit {
  position: absolute;
  right: 8px;
  top: 8px;
  width: 34px;
  height: 34px;
  background: rgba(14, 16, 19, 0.92);
  border: 1px solid rgba(255, 255, 255, 0.3);
  border-radius: 50%;
  color: rgba(230, 230, 230, 0.8);
  font-size: 15px;
  cursor: pointer;

  &:hover {
    border-color: rgba(255, 255, 255, 0.7);
    color: #fff;
  }
}

.hero-text {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;

  .hero-title {
    font-family: inherit;
    font-size: 20px;
    font-weight: 700;
    cursor: pointer;
  }

  .hero-title-input {
    display: flex;
    gap: 6px;
  }

  .hero-maxim {
    margin-top: 10px;
    font-size: 15px;
    font-style: italic;
    color: rgba(230, 230, 230, 0.6);
    cursor: pointer;
  }

  .is-placeholder {
    color: rgba(230, 230, 230, 0.35);
    font-style: italic;
  }
}

.hero-allegiance {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: auto;
  padding: 6px 0 0;
  background: none;
  border: none;
  color: inherit;
  font-size: 15px;
  font-weight: 800;
  cursor: pointer;
  text-align: left;

  .hero-allegiance-label {
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: rgba(230, 230, 230, 0.5);
  }

  &:hover .hero-allegiance-label {
    color: rgba(230, 230, 230, 0.8);
  }
}

.hero-faction-chip {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border-radius: 50%;
  box-shadow: inset 0 0 0 2px rgba(0, 0, 0, 0.35);

  svg {
    width: 16px;
    height: 16px;
    fill: #0e1013;
  }

  &.is-large {
    width: 44px;
    height: 44px;

    svg {
      width: 27px;
      height: 27px;
    }
  }
}

.hero-stats {
  display: flex;
  gap: 20px;
  margin-bottom: 20px;
}

.hero-panel {
  flex: 1;
  padding: 16px 18px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;

  .hero-panel-title {
    padding-bottom: 8px;
    margin-bottom: 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.12);
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.92);
  }

  .hero-panel-foot {
    margin-top: 12px;
    padding-top: 10px;
    border-top: 1px solid rgba(255, 255, 255, 0.12);
    text-align: center;
    font-size: 14px;
    color: rgba(230, 230, 230, 0.75);

    &.is-note {
      border-top: none;
      padding-top: 0;
      font-size: 12px;
      color: rgba(230, 230, 230, 0.45);
    }
  }

  .hero-big-number {
    text-align: center;
    font-size: 56px;
    font-weight: 700;
    line-height: 1.1;
  }

  .hero-big-label {
    text-align: center;
    font-size: 13px;
    font-weight: 800;
    letter-spacing: 4px;
    text-transform: uppercase;
    color: rgba(230, 230, 230, 0.55);
  }
}

.hero-medals {
  display: flex;
  justify-content: space-around;

  .hero-medal {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;

    &.is-dim {
      opacity: 0.35;
    }
  }

  .hero-medal-disc {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 38px;
    height: 38px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 2px rgba(0, 0, 0, 0.3);
    color: rgba(0, 0, 0, 0.4);
    font-size: 17px;
  }

  .hero-medal-count {
    font-size: 22px;
    font-weight: 700;
  }

  .hero-medal-label {
    font-size: 10px;
    font-weight: 800;
    letter-spacing: 2px;
    color: rgba(230, 230, 230, 0.5);
  }
}

.hero-factions {
  margin-bottom: 20px;

  .hero-factions-row {
    display: flex;
    justify-content: space-around;
  }

  .hero-faction-col {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 5px;

    &.is-dim {
      opacity: 0.35;
    }
  }

  .hero-faction-count {
    font-size: 22px;
    font-weight: 700;
  }

  .hero-faction-name {
    font-size: 11px;
    font-weight: 800;
    color: rgba(230, 230, 230, 0.7);
  }
}

.hero-actions {
  display: flex;
  justify-content: center;

  .default-button {
    width: 300px;
  }
}

// --- aside pickers ---------------------------------------------------

.picker-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 10px;

  .label {
    font-size: 14px;
    text-transform: uppercase;
    opacity: 0.7;
  }

  .picker-close {
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 4px;
    width: 26px;
    height: 26px;
    color: rgba(230, 230, 230, 0.7);
    cursor: pointer;

    &:hover {
      border-color: rgba(255, 255, 255, 0.5);
      color: #fff;
    }
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
  max-height: 420px;
  overflow-y: auto;
}
</style>
