<template>
  <section
    class="cheat-section"
    :class="{ 'is-collapsed': collapsed }">
    <button
      type="button"
      class="cheat-section-head"
      :aria-expanded="collapsed ? 'false' : 'true'"
      @click="toggle">
      <svgicon
        class="cheat-section-caret"
        name="caret-down" />
      <span class="cheat-section-title">{{ title }}</span>
      <slot name="aside" />
    </button>
    <div
      v-show="!collapsed"
      class="cheat-section-body">
      <slot />
    </div>
  </section>
</template>

<script>
// Collapsed Cheats-tab sections, remembered per browser across games.
const STORAGE_KEY = 'rc.cheats.collapsed';

function readCollapsed() {
  try {
    return JSON.parse(window.localStorage.getItem(STORAGE_KEY)) || {};
  } catch (e) {
    return {};
  }
}

export default {
  name: 'cheat-section',
  props: {
    // stable id the collapsed state is remembered under
    section: {
      type: String,
      required: true,
    },
    title: {
      type: String,
      required: true,
    },
  },
  data() {
    return {
      collapsed: !!readCollapsed()[this.section],
    };
  },
  methods: {
    toggle() {
      this.collapsed = !this.collapsed;
      try {
        const stored = readCollapsed();
        stored[this.section] = this.collapsed;
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
      } catch (e) {
        // no storage: the section still toggles for this session
      }
    },
  },
};
</script>

<style scoped>
.cheat-section + .cheat-section {
  margin-top: 1.25rem;
  padding-top: 1.25rem;
  border-top: 1px solid rgba(255, 255, 255, 0.12);
}
.cheat-section-head {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 0;
  background: none;
  border: none;
  color: inherit;
  font: inherit;
  font-size: 1.2rem;
  text-align: left;
  text-transform: uppercase;
  cursor: pointer;
}
.cheat-section-title,
.cheat-section-caret {
  opacity: 0.7;
}
.cheat-section-head:hover .cheat-section-title,
.cheat-section-head:hover .cheat-section-caret {
  opacity: 1;
}
.cheat-section-caret {
  width: 12px;
  height: 12px;
  fill: currentColor;
  transition: transform 0.15s;
}
.is-collapsed .cheat-section-caret {
  transform: rotate(-90deg);
}
.cheat-section-body {
  margin-top: 0.75rem;
}
</style>
