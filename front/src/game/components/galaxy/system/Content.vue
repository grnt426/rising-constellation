<template>
  <div
    ref="container"
    class="system-content-container">
    <template v-if="system.contact.value > 0">
      <div class="system-content-menu">
        <template v-if="tabs.length > 1">
          <div
            v-for="(tab, index) in tabs"
            class="system-tab-item"
            :key="`tab-${index}`"
            :class="{ 'active': index === activeTab }"
            @click="activeTab = index">
          </div>
        </template>

        <div
          class="system-tab-item is-tool"
          v-tooltip.left="$t(isCollapsed
            ? 'galaxy.system.content.expand_bodies'
            : 'galaxy.system.content.collapse_bodies')"
          @click="isCollapsed = !isCollapsed">
          <svgicon :name="isCollapsed ? 'caret-down' : 'caret-up'" />
        </div>
        <div
          class="system-tab-item is-tool"
          v-tooltip.left="$t('galaxy.system.content.copy_screenshot')"
          @click="copyScreenshot">
          <svgicon :name="isCapturing ? 'spinner' : 'camera'" />
        </div>
      </div>

      <v-scrollbar
        v-if="system.bodies.length > 0"
        :settings="{ wheelPropagation: false }"
        :class="{ 'is-collapsed': isCollapsed && showsBodies }"
        class="system-content-scrollbar">
        <system-bodies
          v-if="showsBodies && !isCollapsed"
          :system="system"
          :isOwnSystem="isOwnSystem"
          :color="color"
          :hoveredOrbit="hoveredOrbit"
          @enterOrbit="enterOrbit"
          @leaveOrbit="$emit('leaveOrbit')" />

        <system-details
          v-if="activeTab >= 0 && tabs[activeTab].includes('details')"
          :system="system"
          :isOwnSystem="isOwnSystem"
          :color="color" />

        <system-state
          v-if="activeTab >= 0 && tabs[activeTab].includes('state')"
          :system="system"
          :isOwnProperty="isOwnProperty"
          :color="color" />
      </v-scrollbar>

      <div
        v-else
        class="system-content-orphan">
        <div class="system-content-group-header">
          <div class="main">{{ $t(`system.empty_system.label`) }}</div>
        </div>
        <p>{{ $t(`system.empty_system.content`) }}</p>
      </div>
    </template>

    <template v-else>
      <div class="system-content-orphan">
        <div class="system-content-group-header">
          <div class="main">{{ $t(`system.hidden_system.label`) }}</div>
        </div>
        <p>{{ $t(`system.hidden_system.content`) }}</p>
      </div>
    </template>
  </div>
</template>

<script>
import { TimelineLite, Expo } from 'gsap';

import SystemBodies from '@/game/components/galaxy/system/Bodies.vue';
import SystemDetails from '@/game/components/galaxy/system/Details.vue';
import SystemState from '@/game/components/galaxy/system/State.vue';
import { captureElementToBlob, copyPngToClipboard, downloadBlob } from '@/utils/screenshot';

export default {
  name: 'system-content',
  data() {
    return {
      activeTab: 0,
      isCollapsed: false,
      isCapturing: false,
    };
  },
  props: {
    system: Object,
    isOwnSystem: Boolean,
    isOwnProperty: Boolean,
    color: String,
    hoveredOrbit: Number,
  },
  computed: {
    tabs() {
      if (['uninhabitable', 'uninhabited'].includes(this.system.status)) {
        return [['bodies', 'state']];
      }
      return [['bodies'], ['details'], ['state']];
    },
    showsBodies() {
      return this.activeTab >= 0 && this.tabs[this.activeTab].includes('bodies');
    },
  },
  methods: {
    enterOrbit(orbitId) {
      this.$emit('enterOrbit', orbitId);
    },
    async copyScreenshot() {
      if (this.isCapturing) return;
      this.isCapturing = true;

      // capture the whole right-hand panel (population + bodies), not just
      // this component; the temporary class un-clips the scroll container so
      // content taller than the window is included too
      const el = this.$el.closest('.system-info') || this.$el;
      el.classList.add('is-screenshotting');

      try {
        await this.$nextTick();
        let background = getComputedStyle(document.body).backgroundColor;
        if (!background || background === 'transparent' || background === 'rgba(0, 0, 0, 0)') {
          background = '#14161c';
        }
        const blob = await captureElementToBlob(el, background);

        if (await copyPngToClipboard(blob)) {
          this.$toasted.success(this.$t('galaxy.system.content.screenshot_copied'));
        } else {
          const name = (this.system.name || 'system').toLowerCase().replace(/[^a-z0-9]+/gi, '-');
          if (downloadBlob(blob, `${name}.png`)) {
            this.$toasted.success(this.$t('galaxy.system.content.screenshot_downloaded'));
          } else {
            this.$toasted.error(this.$t('galaxy.system.content.screenshot_failed'));
          }
        }
      } catch (e) {
        this.$toasted.error(this.$t('galaxy.system.content.screenshot_failed'));
      } finally {
        el.classList.remove('is-screenshotting');
        this.isCapturing = false;
      }
    },
  },
  mounted() {
    new TimelineLite()
      .set(this.$refs.container, { left: -500 })
      .to(this.$refs.container, { left: 0, ease: Expo.easeOut, duration: 1 }, 0);
  },
  components: {
    SystemBodies,
    SystemDetails,
    SystemState,
  },
};
</script>
