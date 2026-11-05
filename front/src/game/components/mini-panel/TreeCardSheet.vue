<template>
  <!-- Phone detail card for a patent / lex tree node. One sheet per
       panel, opened by tapping a node, closed by its ✕ or by a tap
       anywhere around the card. The cards used to hang off each node,
       centred on screen right over the node a second tap would have
       to hit to close them — and the desktop :hover rule kept a tapped
       node's card up too, so they took a flurry of taps to clear. -->
  <div
    class="tree-card-sheet"
    @click.self="$emit('close')">
    <div class="tcs-body">
      <button
        type="button"
        class="tcs-close"
        :aria-label="$t('card.close_hint')"
        @click="$emit('close')">
        <svgicon name="close" />
      </button>
      <slot />
    </div>
  </div>
</template>

<script>
export default {
  name: 'tree-card-sheet',
};
</script>
