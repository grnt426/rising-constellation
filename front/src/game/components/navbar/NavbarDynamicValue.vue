<template>
  <div class="navbar-dynamic-value">
    <div class="label">
      <svgicon :name="icon" />
    </div>

    <div class="values">
      <div class="value">
        <dynamic-value :initial="initial" />
      </div>
      <div class="change">
        {{ initial.change | income(0, true) }}
      </div>
    </div>
  </div>
</template>

<script>
import DynamicValue from '@/game/components/generic/DynamicValue.vue';

export default {
  name: 'navbar-dynamic-value',
  props: {
    icon: String,
    initial: Object,
  },
  components: {
    DynamicValue,
  },
};
</script>
