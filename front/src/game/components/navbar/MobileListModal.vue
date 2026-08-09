<template>
  <div class="mobile-list-modal">
    <div
      class="mlm-backdrop"
      @click="$emit('close')"></div>
    <div class="mlm-sheet">
      <div class="mlm-header">
        <span>{{ title }}</span>
        <button
          class="mlm-close"
          @click="$emit('close')">
          <svgicon name="close" />
        </button>
      </div>
      <div class="mlm-list">
        <div
          v-for="item in items"
          :key="item.id"
          class="mlm-row"
          @click="$emit('select', item)">
          <svgicon
            v-if="item.icon"
            class="mlm-icon"
            :name="item.icon" />
          <div class="mlm-text">
            <div class="mlm-label">{{ item.label }}</div>
            <div
              v-if="item.sub"
              class="mlm-sub">{{ item.sub }}</div>
          </div>
          <div
            v-if="item.right"
            class="mlm-right">{{ item.right }}</div>
        </div>
        <div
          v-if="items.length === 0"
          class="mlm-empty">—</div>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'mobile-list-modal',
  props: {
    title: { type: String, required: true },
    items: { type: Array, required: true },
  },
};
</script>
