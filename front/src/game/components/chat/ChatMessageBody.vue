<template>
  <span class="chat-message-body">
    <template v-for="(node, i) in nodes">
      <span
        v-if="node.type === 'text'"
        :key="`t-${i}`"
        class="chat-text">{{ node.value }}</span>
      <component
        v-else
        :key="`r-${i}`"
        :is="componentForKind(node.kind)"
        :kind="node.kind"
        :id="node.id"
        :label="node.label" />
    </template>
  </span>
</template>

<script>
import { parseChatMessage } from './parseChatMessage';
import ChatRefSystem from './refs/ChatRefSystem.vue';
import ChatRefUnknown from './refs/ChatRefUnknown.vue';

/**
 * Map of ref kind → component name. Adding a new ref type (char,
 * coord, patent, policy, …) means dropping a component into refs/
 * and registering it here. Unknown kinds render as ChatRefUnknown.
 *
 * The `id` prop is intentionally passed to every ref kind, even though
 * Vue's prop validation warns when a component doesn't declare it.
 * The dynamic <component :is> resolves at render time so unrecognized
 * extra props on ChatRefSystem etc. are stripped via Vue's filtering.
 */
const REF_COMPONENTS = {
  sys: 'chat-ref-system',
  // Phase 2: 'char', 'coord' added here.
};

export default {
  name: 'chat-message-body',
  components: {
    ChatRefSystem,
    ChatRefUnknown,
  },
  props: {
    raw: { type: String, default: '' },
  },
  computed: {
    nodes() {
      return parseChatMessage(this.raw);
    },
  },
  methods: {
    componentForKind(kind) {
      return REF_COMPONENTS[kind] || 'chat-ref-unknown';
    },
  },
};
</script>
