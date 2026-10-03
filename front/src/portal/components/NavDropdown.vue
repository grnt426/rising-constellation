<template>
  <!-- A top-bar entry that opens a menu of pages instead of going to one
       (Sandbox: the battle simulator and the system planner). The menu
       is fixed-positioned under the button: below 1080px the bar becomes
       a sideways-scrolling row (navbar/topbar.scss), which would clip an
       absolutely positioned child. -->
  <div
    class="navbar-dropdown"
    @keydown.esc="close(true)">
    <button
      ref="toggle"
      type="button"
      class="navbar-button-title navbar-dropdown-toggle"
      :class="{ 'router-link-active': active, 'is-open': open }"
      aria-haspopup="true"
      :aria-expanded="open ? 'true' : 'false'"
      @click="toggle"
      @keydown.down.prevent="openAndFocus(0)">
      {{ label }}
      <svgicon
        class="navbar-dropdown-caret"
        name="caret-down" />
    </button>

    <div
      v-if="open"
      ref="menu"
      class="navbar-dropdown-menu"
      role="menu"
      :style="menuStyle"
      @keydown.down.prevent="moveFocus(1)"
      @keydown.up.prevent="moveFocus(-1)">
      <router-link
        v-for="item in items"
        :key="item.to"
        class="navbar-dropdown-item"
        :class="{ 'is-current': $route.path === item.to }"
        role="menuitem"
        :to="item.to"
        @click.native="close(false)">
        <svgicon
          class="navbar-dropdown-item-icon"
          :name="item.icon" />
        <span class="navbar-dropdown-item-text">
          <span class="navbar-dropdown-item-label">{{ item.label }}</span>
          <span
            v-if="item.hint"
            class="navbar-dropdown-item-hint">{{ item.hint }}</span>
        </span>
      </router-link>
    </div>
  </div>
</template>

<script>
export default {
  name: 'nav-dropdown',
  props: {
    label: { type: String, required: true },
    // [{ to, label, hint?, icon }]
    items: { type: Array, required: true },
    // the current page is one of the items (bound by the layout, like
    // the Players entry: router-link only knows its own path)
    active: { type: Boolean, default: false },
  },
  data() {
    return {
      open: false,
      menuStyle: {},
    };
  },
  watch: {
    $route() { this.close(false); },
  },
  beforeDestroy() {
    this.unlisten();
  },
  methods: {
    toggle() {
      if (this.open) this.close(false);
      else this.show();
    },
    show() {
      this.place();
      this.open = true;
      // next tick: the click that opened the menu must not close it
      this.$nextTick(() => {
        document.addEventListener('pointerdown', this.onOutside, true);
        window.addEventListener('resize', this.onViewportChange);
        window.addEventListener('scroll', this.onViewportChange, true);
      });
    },
    close(refocus) {
      if (!this.open) return;
      this.open = false;
      this.unlisten();
      if (refocus && this.$refs.toggle) this.$refs.toggle.focus();
    },
    unlisten() {
      document.removeEventListener('pointerdown', this.onOutside, true);
      window.removeEventListener('resize', this.onViewportChange);
      window.removeEventListener('scroll', this.onViewportChange, true);
    },
    place() {
      const rect = this.$refs.toggle.getBoundingClientRect();
      const width = 260;
      const left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
      this.menuStyle = { top: `${rect.bottom}px`, left: `${left}px`, width: `${width}px` };
    },
    onOutside(event) {
      if (!this.$el.contains(event.target)) this.close(false);
    },
    // the bar scrolls sideways on narrow screens: a menu left behind by
    // its button would point at the wrong entry
    onViewportChange(event) {
      if (event && event.target && this.$refs.menu && this.$refs.menu.contains(event.target)) return;
      this.close(false);
    },
    openAndFocus(index) {
      if (!this.open) this.show();
      this.$nextTick(() => this.focusItem(index));
    },
    focusItem(index) {
      const links = this.$refs.menu ? this.$refs.menu.querySelectorAll('.navbar-dropdown-item') : [];
      if (links.length) links[(index + links.length) % links.length].focus();
    },
    moveFocus(step) {
      const links = Array.from(this.$refs.menu.querySelectorAll('.navbar-dropdown-item'));
      this.focusItem(links.indexOf(document.activeElement) + step);
    },
  },
};
</script>

<style lang="scss" scoped>
@import '~@/styles/shared/variables';

.navbar-dropdown {
  display: inline-block;
}

// <button> reset; the look comes from .navbar-button-title (topbar.scss)
.navbar-dropdown-toggle {
  border: none;
  border-right: solid 1px rgba(255, 255, 255, .1);
  background: none;
  font-family: inherit;

  &.is-open {
    color: $white;
    background: rgba(255, 255, 255, .05);
  }
}

.navbar-dropdown-caret {
  width: 10px;
  height: 10px;
  margin-left: 4px;
  vertical-align: 1px;
  opacity: .7;
  transition: transform 150ms ease;

  .is-open & {
    transform: rotate(180deg);
  }
}

.navbar-dropdown-menu {
  position: fixed;
  z-index: 300;
  padding: 6px 0;

  background: $grey-darker;
  border: solid 1px rgba(255, 255, 255, .15);
  border-top: solid 2px $primary;
  box-shadow: 0 10px 24px rgba(0, 0, 0, .6);
}

.navbar-dropdown-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 16px;
  color: $white-alt-2;

  &:hover,
  &:focus {
    color: $white;
    background: rgba(255, 255, 255, .06);
    outline: none;
  }

  &.is-current {
    color: $white;
    box-shadow: inset 3px 0 0 $primary;
  }
}

.navbar-dropdown-item-icon {
  flex: 0 0 auto;
  width: 26px;
  height: 26px;
}

.navbar-dropdown-item-text {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.navbar-dropdown-item-label {
  font-size: 1.4rem;
  font-weight: bold;
  text-transform: uppercase;
}

.navbar-dropdown-item-hint {
  font-size: 1.2rem;
  line-height: 1.4;
  opacity: .65;
}
</style>
