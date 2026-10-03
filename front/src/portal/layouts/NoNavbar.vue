<template>
  <div class="portal-context">
    <div class="layout no-navbar">
      <main
        id="main"
        class="layout-content"
        tabindex="-1">
        <slot />
      </main>
    </div>
  </div>
</template>

<script>
export default {
  name: 'no-navbar-layout',
};
</script>
