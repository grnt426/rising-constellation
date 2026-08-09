<template>
  <!-- Production readout + queue toggle. Extracted from Properties.vue
       so the mobile layout can place it independently (above the
       celestial list) while desktop keeps it pinned in the square. -->
  <div class="production-box">
    <div class="production-value">
      <template v-if="!system.production">
        <div class="yield-box">
          ░░░
          <svgicon name="resource/production" />
        </div>
      </template>
      <v-popover v-else trigger="hover">
        <div class="yield-box">
          {{ system.production.value | integer }}
          <svgicon name="resource/production" />
        </div>
        <resource-detail
          slot="popover"
          :title="$t('data.bonus_pipeline_in.sys_production.name')"
          :description="$t(`resource-description.production`)"
          :value="system.production.value"
          :details="system.production.details" />
      </v-popover>
    </div>
    <div
      v-if="isOwnProperty && system.queue && system.queue.queue.length > 0"
      class="production-counter">
      <counter
        :current="system.queue.queue[0].remaining_prod / system.production.value"
        :receivedAt="system.receivedAt" />
    </div>
    <div
      v-if="system.queue"
      class="round-icon"
      :class="{
        'is-disabled': system.queue.queue.length === 0,
        'has-hover': system.queue.queue.length > 0,
        'is-pulsing': system.queue.queue.length > 0,
      }"
      @click="$emit('toggleQueue')">
      <template v-if="system.queue.queue.length > 0">
        <circle-progress-value
          :current="system.queue.queue[0].total_prod - system.queue.queue[0].remaining_prod"
          :total="system.queue.queue[0].total_prod"
          :increase="system.production.value"
          :size="46"
          :width="4"
          :theme="color" />
        <svgicon
          v-if="system.queue.queue[0].type === 'ship'"
          :name="`ship/${system.queue.queue[0].prod_key}`" />
        <svgicon
          v-else
          :name="`building/${system.queue.queue[0].prod_key}`" />
        <span
          v-if="system.queue.queue.length - 1 > 0"
          class="number">
          {{ system.queue.queue.length - 1 }}
        </span>
      </template>
    </div>
    <div
      v-else
      class="round-icon is-disabled">
    </div>
  </div>
</template>

<script>
import ResourceDetail from '@/game/components/generic/ResourceDetail.vue';
import CircleProgressValue from '@/game/components/generic/CircleProgressValue.vue';
import Counter from '@/game/components/generic/Counter.vue';

export default {
  name: 'production-box',
  props: {
    system: Object,
    isOwnProperty: Boolean,
    color: String,
  },
  components: {
    ResourceDetail,
    CircleProgressValue,
    Counter,
  },
};
</script>
