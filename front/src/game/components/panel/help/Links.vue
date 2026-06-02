<template>
  <div class="panel-content is-small">
    <v-scrollbar class="has-padding">
      <h1 class="panel-default-title">
        {{ $t('panel.help.links_title') }}
      </h1>

      <div class="help-link">
        <h2>{{ $t('panel.help.wiki_title') }}</h2>
        <p>{{ $t('panel.help.wiki_description') }}</p>
        <a
          :href="wikiUrl"
          target="_blank"
          rel="noopener"
          class="help-link-button">
          {{ $t('panel.help.wiki_open') }}
        </a>
      </div>
    </v-scrollbar>
  </div>
</template>

<script>
export default {
  name: 'help-links-panel',
  data() {
    return {
      wikiUrl: 'https://rising-constellation.fandom.com/fr/wiki/Wiki_Rising_Constellation',
    };
  },
};
</script>
