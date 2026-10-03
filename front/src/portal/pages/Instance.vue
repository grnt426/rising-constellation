<template>
  <default-layout>
    <div class="fluid-panel">
      <v-scrollbar class="panel-aside is-lobby-aside">
        <template v-if="loaded">
          <template v-if="instance.scheduled">
            <scheduled-lobby
              :instance="instance"
              :registered="registered"
              @changed="loadData(lobbyRef())" />

            <hr class="separator">
          </template>

          <template v-if="account.role === 'admin' || account.id === instance.account_id">
            <section class="panel-aside-info is-manage">
              <h2>
                {{ $t('page.instance.manage') }}
                <!-- Phones: the status rides in the heading instead of a line of its own. -->
                <span
                  v-if="isMobile"
                  class="toast">{{ $t(`instance.state.${instance.state}.name`) }}</span>
              </h2>
              <p v-if="!isMobile">
                {{ $t('page.instance.status_is') }}
                <strong>{{ $t(`instance.state.${instance.state}.name`) }}</strong>.
              </p>

              <div class="instance-action">
                <button
                  @click="doAction('publish')"
                  v-show="instance.state === 'created'"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.publish') }}</template>
                </button>
                <button
                  @click="doAction('start')"
                  v-show="instance.state === 'open' && !instance.scheduled"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.start') }}</template>
                </button>
                <button
                  @click="doAction('pause')"
                  v-show="instance.state === 'running'"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.pause') }}</template>
                </button>
                <button
                  @click="doAction('resume')"
                  v-show="instance.state === 'paused'"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.resume') }}</template>
                </button>
                <button
                  @click="doAction('restart')"
                  v-show="instance.state === 'not_running'"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.restart') }}</template>
                </button>
                <button
                  @click="doAction('finish')"
                  v-show="instance.state === 'paused'"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.stop') }}</template>
                </button>
              </div>

              <p
                v-if="startingProgress.step !== 0"
                class="starting-progress">
                <span class="label">{{ startingProgress.step }}</span>
                <span class="value">
                  {{ $t(`page.instance.start_steps.${startingProgress.status}`) }}
                </span>
              </p>

              <router-link
                v-if="isWave && isAdmin"
                :to="`/instance/${instance.id}/rebellion`"
                class="default-button">
                {{ $t('page.instance.wave.diagnostics') }}
              </router-link>

              <p
                v-if="account.id !== instance.account_id && account.role === 'admin'"
                style="color: red;">
                {{ $t('page.instance.admin_warning') }}
              </p>
              <p v-else-if="!isMobile">
                {{ $t('page.instance.owner_warning') }}
              </p>
            </section>
            
            <hr class="separator">
          </template>

          <!-- Phones drop Overview: re-tapping the active faction goes back. -->
          <!-- v-press, not <button>: these cards are block layouts that a
               <button> may not contain. aria-pressed marks the open one. -->
          <template v-if="!isMobile">
            <div
              v-press
              class="instance-button"
              :class="{ 'active': selected === null }"
              :aria-pressed="selected === null ? 'true' : 'false'"
              @click="selected = null">
              <div class="instance-button-content">
                <strong>{{ $t('page.instance.overview') }}</strong>
              </div>
            </div>

            <hr class="separator">
          </template>

          <div
            class="instance-factions"
            role="group"
            :aria-label="$t('a11y_portal.factions')">
            <div
              v-for="f in lobbyFactions"
              v-press
              class="instance-button"
              :class="[
                getTheme(f.faction_ref),
                {
                  'active': selected === f.id,
                  'is-bot-faction': isBotFaction(f),
                },
              ]"
              :aria-pressed="selected === f.id ? 'true' : 'false'"
              :key="`faction-${f.id}`"
              @click="selectFaction(f.id)">
              <div class="instance-logo">
                <svgicon class="icon" :name="`faction/${f.faction_ref}`" aria-hidden="true" />
              </div>
              <div class="instance-button-content">
                <strong>
                  {{ $t(`data.faction.${f.faction_ref}.name`) }}
                  <span v-show="chosenFaction === f.id"><span aria-hidden="true">★</span><span class="sr-only">{{ $t('a11y_portal.your_faction') }}</span></span>
                </strong>
                <!-- Rebel Defense: the Rebellion is the enemy, not a seat. -->
                <span
                  v-if="isBotFaction(f)"
                  class="bot-faction-tag">
                  {{ $t('page.instance.wave.enemy_tag') }}
                </span>
                <span
                  v-else
                  class="instance-button-capacity">
                  <span class="label">
                    {{ f.registrations_count }}/{{ f.capacity }}
                  </span>
                  <span
                    class="gauge-container"
                    aria-hidden="true">
                    <span
                      class="gauge-content"
                      :style="`width: ${(f.registrations_count / f.capacity) * 100}%`">
                    </span>
                  </span>
                </span>
              </div>
            </div>
          </div>

          <hr class="margin">
        </template>
      </v-scrollbar>

      <div
        class="panel-content is-square"
        ref="container">
        <template v-if="loaded">
          <router-link
            class="close-button"
            :to="`/play/${instance.game_metadata.speed}`">
            {{ $t('page.instance.back') }}
          </router-link>
          <div class="panel-header is-hover">
            <h1><strong>{{ instance.name }}</strong></h1>

            <router-link
              v-if="instance.winner_faction && instance.archive_id"
              :to="`/play/slow/archive/${instance.archive_id}`"
              class="default-button">
              <svgicon class="icon" name="ranking" aria-hidden="true" />
              {{ $t('page.play.archive.view_archive') }}
            </router-link>

            <button
              @click="play"
              v-show="instance.state !== 'created' && instance.state !== 'ended'"
              class="default-button"
              :aria-disabled="instance.state !== 'running' ? 'true' : null"
              :class="{
                'disabled': instance.state !== 'running',
                'instance-play-button': instance.state === 'running',
              }">
              <template v-if="!registered">
                {{ $t('page.instance.choose_faction') }}
              </template>
              <template v-else-if="instance.state !== 'running'">
                {{ $t('page.instance.wait') }}
              </template>
              <template v-else>
                <template v-if="waiting">...</template>
                <template v-else>{{ $t('page.instance.play') }}</template>
              </template>
              <span
                v-show="instance.state === 'running'"
                class="instance-play-button-icon">
                <svgicon class="icon" name="action/fight" aria-hidden="true" />
              </span>
            </button>
          </div>

          <div class="content is-instance">
            <instance-map
              :selected="getSelectedFactionKey()"
              :size="containerSize"
              :scenario="instance" />
          </div>
        </template>

        <loading-mask v-else />
      </div>

      <v-scrollbar class="panel-aside is-lobby-aside">
        <template v-if="loaded">
          <template v-if="!selected">
            <section
              v-if="isWave"
              class="panel-aside-info wave-rules">
              <h2>{{ $t('page.wave.name') }}</h2>
              <p class="is-large">
                {{ $t('page.instance.wave.intro', { faction: $t(`data.faction.${humanFactionRef}.name`) }) }}
              </p>
              <ul>
                <li>{{ $t('page.instance.wave.rule_coop') }}</li>
                <li>{{ $t('page.instance.wave.rule_rebellion') }}</li>
                <li>{{ $t('page.instance.wave.rule_win') }}</li>
              </ul>
            </section>

            <section class="panel-aside-info">
              <h2>{{ $t('page.instance.description') }}</h2>
              <p
                class="is-large"
                v-html="nl2br(instance.description)"></p>
            </section>

            <section class="panel-aside-info">
              <h2>{{ $t('page.instance.find_players') }}</h2>
              <p>{{ $t('page.instance.ea_note') }}</p>
              <div
                v-if="isSteam"
                class="default-input has-m10">
                <label for="instance-discord-link">{{ $t('page.instance.discord_link') }}</label>
                <input
                  id="instance-discord-link"
                  v-model="discordLink"
                  type="text"
                  disabled />
                <button
                  @click="copyToClipboard(discordLink)"
                  v-tooltip="$t('page.instance.clipboard_copy')"
                  :aria-label="$t('page.instance.clipboard_copy')"
                  class="default-button action">
                  <span aria-hidden="true">⇪</span>
                </button>
              </div>
              <a
                v-else
                class="default-button has-m10"
                target="_blank"
                rel="noopener"
                :href="discordLink">
                {{ $t('page.tutorial.join_discord') }}
                <span class="sr-only">{{ $t('a11y_portal.new_tab') }}</span>
              </a>
            </section>

            <news-ticker :iid="lobbyRef()" />
          </template>

          <template v-else>
            <!-- Rebel Defense: nobody joins the Rebellion; say who does. -->
            <section
              v-if="isBotFaction(faction)"
              class="panel-aside-info wave-rules">
              <h2>{{ $t('page.instance.wave.enemy_heading') }}</h2>
              <p class="is-large">
                {{ $t('page.instance.wave.enemy_info', { faction: $t(`data.faction.${humanFactionRef}.name`) }) }}
              </p>
              <button
                class="default-button"
                @click="selected = humanFaction && humanFaction.id">
                {{ $t('page.instance.wave.join_humans', { faction: $t(`data.faction.${humanFactionRef}.name`) }) }}
              </button>
            </section>

            <section
              v-else
              class="panel-aside-info">
              <div class="instance-action">
                <button
                  v-if="instance.registration_status !== 'open'"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.registration_closed') }}
                </button>
                <button
                  v-else-if="registered && registered.faction.id !== faction.id"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.already_registered') }}
                </button>
                <button
                  v-else-if="emptySeats.length === 0"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.no_empty_seats') }}
                </button>
                <button
                  v-else-if="!registered && faction.starting_system_available === false"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.no_starting_system') }}
                </button>
                <button
                  v-else-if="registered && ['running', 'paused'].includes(instance.state)"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.game_already_running') }}
                </button>
                <button
                  v-else-if="registered && registered.faction.id === faction.id && registered.ready"
                  class="default-button disabled"
                  aria-disabled="true">
                  {{ $t('page.instance.scheduled.unready_to_switch') }}
                </button>
                <button
                  v-else-if="registered && registered.faction.id === faction.id"
                  @click="unjoin(registered.faction.id, registered.profile.id)"
                  class="default-button">
                  <template v-if="waiting">...</template>
                  <template v-else>{{ $t('page.instance.unregister') }}</template>
                </button>
                <button
                  v-else
                  @click="join()"
                  v-tooltip="account.is_free
                    ? $t('page.instance.join_money_info')
                    : ''"
                  class="default-button"
                  :aria-disabled="!enoughMoney ? 'true' : null"
                  :class="{ 'disabled': !enoughMoney }">
                  {{ $t('page.instance.register') }}
                  <template v-if="account.is_free">
                    ({{ $t('page.instance.join_money_amount', { amount: 500 }) }})
                  </template>
                </button>
              </div>

              <p>
                <button
                  type="button"
                  class="bare-button link-button"
                  :aria-expanded="showRegistration ? 'true' : 'false'"
                  @click="showRegistration = !showRegistration">
                  <template v-if="showRegistration">{{ $t('page.instance.hide_members') }}</template>
                  <template v-else>{{ $t('page.instance.show_members') }}</template>
                </button>
                <template v-if="isMobile">
                  ·
                  <button
                    type="button"
                    class="bare-button link-button"
                    @click="selected = null">
                    {{ $t('page.instance.overview') }}
                  </button>
                </template>
              </p>
            </section>
            
            <hr class="separator">

            <table
              v-if="showRegistration"
              class="default-table profiles-table">
              <tr
                v-for="r in takenSeats"
                :key="`registration-${r.id}`">
                <td>
                  <strong>{{ r.profile.name }}</strong>
                  <span v-if="registered && registered.profile.id === r.profile.id"><span aria-hidden="true">★</span><span class="sr-only">{{ $t('a11y_portal.you') }}</span></span>
                  <span
                    v-if="instance.scheduled && r.ready"
                    class="ready-mark">{{ $t('page.instance.scheduled.ready') }}</span>
                </td>
              </tr>
              <tr
                v-for="i in emptySeats"
                :key="`free-registration-${i}`">
                <td>{{ $t('page.instance.free_spot') }}</td>
              </tr>
            </table>

            <template v-else>
              <section class="panel-aside-info">
                <h2>{{ $t(`data.faction.${faction.faction_ref}.name`) }}</h2>
                <p
                  class="is-large"
                  v-html="nl2br($t(`data.faction.${faction.faction_ref}.description`))"></p>
              </section>

              <section class="panel-aside-info">
                <h2>{{ $t('page.instance.initial_character') }}</h2>
                <p class="is-large">
                  <strong>{{ $tc(`data.character.${factionData.initial_character_type}.name`) }}</strong>
                  (<strong>{{
                    $tc(`data.character.${factionData.initial_character_type}.specializations.${factionData.initial_character_spec1}`)
                  }}</strong>)
                </p>
              </section>

              <section class="panel-aside-info">
                <h2>{{ $t('page.instance.tradition') }}</h2>
                <p
                  v-for="tradition in factionData.traditions"
                  :key="tradition.key"
                  class="is-large">
                  <strong>{{ $t(`data.tradition.${tradition.key}.name`) }}</strong>
                  ({{ traditionBonus(tradition) }})<br>
                  {{ $t(`data.tradition.${tradition.key}.description`) }}
                </p>
              </section>
            </template>
          </template>

          <hr class="margin">
        </template>
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import config from '@/config';

import { formatBonusValue } from '@/utils/bonus';
import viewport from '@/utils/viewport';

import Loading from '@/portal/mixins/Loading';

import LoadingMask from '@/portal/components/LoadingMask.vue';
import InstanceMap from '@/portal/components/InstanceMap.vue';
import NewsTicker from '@/portal/components/NewsTicker.vue';
import ScheduledLobby from '@/portal/components/flash/ScheduledLobby.vue';

import DefaultLayout from '@/portal/layouts/Default.vue';

export default {
  name: 'instance',
  mixins: [Loading],
  data() {
    return {
      isSteam: config.IS_STEAM,
      containerSize: 0,
      selected: null,
      instance: null,
      registrations: [],
      registered: null,
      waiting: false,
      polling: null,
      showRegistration: false,
      startingProgress: {
        step: 0,
        status: '',
      },
    };
  },
  computed: {
    data() { return this.$store.state.portal.data; },
    account() { return this.$store.state.portal.account; },
    activeProfile() { return this.$store.state.portal.activeProfile; },
    discordLink() { return `https://discord.gg/${this.$t('link.discord_invite')}`; },
    faction() {
      return this.instance.factions.find((f) => f.id === this.selected);
    },
    factionData() {
      return this.data.faction.find((f) => f.key === this.faction.faction_ref);
    },
    emptySeats() {
      if (this.faction) {
        const length = this.faction.capacity - this.faction.registrations_count;
        return Array.from({ length }, (x, i) => i);
      }
      return [];
    },
    takenSeats() {
      return this.registrations.filter((r) => r.faction.id === this.faction.id);
    },
    chosenFaction() {
      return this.registered
        ? this.registered.faction.id
        : null;
    },
    enoughMoney() {
      if (this.account.is_free) {
        return this.account.money >= 500;
      }

      return true;
    },
    bonusOut() { return this.data.bonus_pipeline_out || []; },
    isAdmin() { return this.$store.state.portal.isAdmin; },
    isMobile() { return viewport.isMobile; },
    // Rebel Defense: every human plays one faction against the bot-run
    // Rebellion (game_data.wave.bot_faction).
    isWave() { return !!this.instance && this.instance.game_data.game_mode_type === 'wave'; },
    botFactionRef() {
      const wave = this.isWave && this.instance.game_data.wave;
      return (wave && wave.bot_faction) || 'rebellion';
    },
    humanFaction() {
      return this.isWave ? this.instance.factions.find((f) => f.faction_ref !== this.botFactionRef) : null;
    },
    humanFactionRef() { return this.humanFaction ? this.humanFaction.faction_ref : 'tetrarchy'; },
    // The joinable faction first, the enemy after it.
    lobbyFactions() {
      if (!this.isWave) return this.instance.factions;
      return [...this.instance.factions].sort((a, b) => Number(this.isBotFaction(a)) - Number(this.isBotFaction(b)));
    },
  },
  methods: {
    selectFaction(id) {
      this.selected = this.isMobile && this.selected === id ? null : id;
    },
    isBotFaction(faction) {
      return this.isWave && !!faction && faction.faction_ref === this.botFactionRef;
    },
    // Label from i18n, number derived from the engine's own bonus value —
    // see utils/bonus.js for why the number isn't in the locale files.
    traditionBonus(tradition) {
      return this.$t('page.instance.tradition_bonus', {
        label: this.$t(`data.tradition.${tradition.key}.bonus_label`),
        value: formatBonusValue(tradition.bonus, this.bonusOut),
      });
    },
    // Lobby reads go through the share token once we know it: a token
    // opens a private lobby for whoever was sent the link, where the
    // numeric id would be refused. The route param covers the first load.
    lobbyRef() {
      return (this.instance && this.instance.share_token) || this.$route.params.iid;
    },
    async loadData(iid, releaseWaiting = false) {
      try {
        const [instance, registrations] = await this.waitFor([
          this.$axios.get(`/instances/${iid}`),
          this.$axios.get(`/instances/${iid}/registrations`),
        ]);

        // disallow entering not slow instane for free account
        if (this.account.is_free && instance.data.game_data.speed !== 'slow') {
          this.$router.push('/');
        }

        this.instance = instance.data;
        // Numeric URLs are legacy (and enumerable): show the share-token
        // form in the address bar so a copied URL is the shareable one.
        if (this.instance.share_token && this.$route.params.iid !== this.instance.share_token) {
          this.$router.replace(`/instance/${this.instance.share_token}`).catch(() => {});
        }
        this.registrations = registrations.data;
        this.registered = this.registrations.find((r) => this.activeProfile.id === r.profile.id);

        // Stage 2 #7 — the listing endpoint omits `:token` for everyone.
        // If we have a registration here, fetch the show endpoint to
        // pick up our own token. That endpoint 404s for anyone else's id.
        if (this.registered) {
          const { data: mine } = await this.$axios.get(`/registrations/${this.registered.id}`);
          this.registered = { ...this.registered, token: mine.token };
        }

        this.loaded = true;

        if (releaseWaiting) {
          this.waiting = false;
        }
      } catch (err) {
        if (!this.instance) {
          // Never loaded: unknown id, or a private lobby opened by its
          // numeric id without access (it needs the share link).
          this.$router.push('/play');
          this.$toastError(this.$t('page.instance.not_found'));
          return;
        }
        this.$toastError('Erreur');
      }
    },
    async join() {
      if (this.enoughMoney && !this.waiting) {
        this.waiting = true;

        try {
          await this.$axios.post(
            `/registrations/profile/${this.activeProfile.id}`,
            { instance_id: this.instance.id, faction_id: this.selected },
          );

          if (this.account.is_free && this.instance.game_data.speed === 'slow') {
            this.$store.commit('portal/updateAccountMoney', -500);
          }

          await this.loadData(this.lobbyRef());
        } catch (err) {
          this.$toastError(err.response.data.message);
        }

        this.waiting = false;
      }
    },
    async unjoin(factionId) {
      if (!this.waiting) {
        this.waiting = true;

        try {
          await this.$axios.put(`/registrations/profile/${this.activeProfile.id}/cancel`, { faction_id: factionId });

          if (this.account.is_free && this.instance.game_data.speed === 'slow') {
            this.$store.commit('portal/updateAccountMoney', 500);
          }

          await this.loadData(this.lobbyRef());
        } catch (err) {
          this.$toastError(err.response.data.message);
        }

        this.waiting = false;
      }
    },
    async play() {
      if (!this.waiting && this.registered && this.instance.state === 'running') {
        this.waiting = true;

        try {
          const { data } = await this.$axios
            .get(`/instances/${this.instance.id}/game/start/${this.registered.token}`);

          this.$ambiance.sound('play');
          this.$store.commit('game/init', data);
          this.$ambiance.changeContext('game');

          this.$router.push('/game');
        } catch (err) {
          this.$toastError(err.response.data.message);
        }
      }
    },
    async doAction(action) {
      if (!this.waiting) {
        this.waiting = true;

        if (action === 'start' || action === 'restart') {
          this.$socket.user.on('broadcast', ({ status, instanceId }) => {
            if (this.instance.id !== instanceId) return;
              this.startingProgress = {
                step: this.startingProgress.step + 1,
                status,
              };
          });
          this.pushStart(false);
          return;
        }

        try {
          await this.$axios.put(`/instances/${this.instance.id}/${action}`);
          await this.loadData(this.lobbyRef());
        } catch (err) {
          this.$toastError(err.response.data.message);
        }

        this.waiting = false;
      }
    },
    pushStart(confirmFreshStart) {
      const payload = confirmFreshStart ? { confirm_fresh_start: true } : {};
      this.$socket.instance.push('start', payload, 30 * 60 * 1000)
        .receive('ok', () => {
          this.startingProgress = { step: 0, status: '' };
          this.loadData(this.lobbyRef(), true);
        })
        .receive('timeout', () => {
          this.startingProgress = { step: 0, status: '' };
          this.waiting = false;
          this.$toasted.error('Timeout');
        })
        .receive('error', ({ reason }) => {
          this.startingProgress = { step: 0, status: '' };

          // No snapshot exists — confirm before wiping game progress.
          // Backend will only execute the destructive create_from_model
          // path if we re-send with confirm_fresh_start.
          if (reason === 'fresh_start_required') {
            if (window.confirm(this.$t('page.instance.restart_fresh_confirm'))) {
              this.pushStart(true);
              return;
            }
            this.waiting = false;
            return;
          }

          if (reason === 'snapshot_load_failed') {
            this.waiting = false;
            this.$toastError(this.$t('page.instance.snapshot_load_failed'));
            return;
          }

          this.waiting = false;
          this.$toastError(reason);
        });
    },
    async copyToClipboard() {
      await navigator.clipboard.writeText(this.discordLink);
    },
    nl2br(text) {
      return text.replace(/([^>\r\n]?)(\r\n|\n\r|\r|\n)/g, '$1<br />$2');
    },
    getTheme(key) {
      if (this.data.faction) {
        return key
          ? `theme-${this.data.faction.find((f) => f.key === key).theme}`
          : '';
      }
    },  
    getSelectedFactionKey() {
      if (this.selected) {
        return this.instance.factions.find((f) => f.id === this.selected).faction_ref;
      }
      return null;
    },
    async copyToClipboard(text) {
      await navigator.clipboard.writeText(text);
    },
  },
  async mounted() {
    this.containerSize = ((this.$refs.container.clientWidth - (25 * 2)));
    await this.loadData(this.lobbyRef());
    if (!this.instance) return;

    // Phones: the panel is full-width, so its width is only final once the
    // loaded page is tall enough to scroll; .content padding is 12px there
    // (styles/portal/mobile.scss).
    if (this.isMobile) {
      await this.$nextTick();
      this.containerSize = this.$refs.container.clientWidth - (12 * 2);
    }
    this.$socket.joinInstance(this.instance.id);

    this.polling = setInterval(() => {
      this.loadData(this.lobbyRef());
    }, this.$config.POLLING.SHORT);
  },
  beforeDestroy() {
    this.$socket.leaveInstance();
    clearInterval(this.polling);
  },
  components: {
    LoadingMask,
    InstanceMap,
    NewsTicker,
    ScheduledLobby,
    DefaultLayout,
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

// Rebel Defense: the rules blurb and the enemy card, in the Rebellion's
// orange so the bot-run side never reads as a seat you can take.
.wave-rules {
  h2 { color: $theme-rebellion; }

  ul {
    margin: 8px 0 0 18px;
    list-style: disc;

    li { margin-bottom: 4px; }
  }
}

.bot-faction-tag {
  display: inline-block;
  margin-top: 4px;
  padding: 0 6px;
  border-radius: 3px;
  border: solid 1px $theme-rebellion;
  color: $theme-rebellion;
  font-size: 1.1rem;
  font-weight: bold;
  text-transform: uppercase;
}

.instance-button.is-bot-faction {
  opacity: .85;
}

.ready-mark {
  margin-left: 8px;
  padding: 0 6px;
  border-radius: 3px;
  background: $primary;
  color: $black;
  font-size: 1.1rem;
  font-weight: bold;
  text-transform: uppercase;
}
</style>
