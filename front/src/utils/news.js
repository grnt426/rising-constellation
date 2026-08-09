// Shared renderer for news-ticker bulletins.
//
// A bulletin is `{id, key, data, inserted_at}` where `key` is e.g.
// "news.battle" and `data` is the payload emitted by the backend
// (Game.News.Server). Template selection:
//
//   1. If the viewer's faction is a participant in the event and an
//      `.involved` variant exists, use it (more detail for factions
//      with visibility).
//   2. Otherwise the `.public` variant (fog-of-war-safe wording).
//   3. Unknown keys fall back to `news.unknown_event` so the backend
//      can ship new event types before the frontend learns them.
//
// `vm` is any Vue instance (needs $t/$te). `viewerFaction` is the
// viewer's faction key string (e.g. "synelle") or null for outsiders.

import { escape } from '@/plugins/filters';

const PARTICIPANT_FIELDS = ['faction', 'attacker_faction', 'defender_faction', 'victim_faction', 'prev_faction'];

function factionName(vm, key) {
  const i18nKey = `data.faction.${key}.name`;
  return vm.$te(i18nKey) ? vm.$t(i18nKey) : key;
}

export function buildParams(vm, data) {
  const params = { ...data };

  // Faction atoms become localized display names.
  PARTICIPANT_FIELDS.forEach((f) => {
    if (params[f]) params[f] = factionName(vm, params[f]);
  });

  // Building key becomes its localized name (news.building.first).
  if (params.building) {
    const k = `data.building.${params.building}.name`;
    if (vm.$te(k)) params.building = vm.$t(k);
  }

  // Resource key (income firsts) becomes a localized label.
  if (params.resource) {
    const k = `news.resource.${params.resource}`;
    if (vm.$te(k)) params.resource = vm.$t(k);
  }

  // Ship key (capital-ship fielded) becomes its localized name.
  if (params.ship) {
    const k = `data.ship.${params.ship}.name`;
    if (vm.$te(k)) params.ship = vm.$t(k);
  }

  // Every consumer renders through v-html, and some params originate
  // from community-authored content (system names come from published
  // maps, character names from the generator) — escape all of them.
  Object.keys(params).forEach((k) => {
    if (typeof params[k] === 'string') params[k] = escape(params[k]);
  });

  return params;
}

export function renderNews(vm, item, viewerFaction = null) {
  const data = item.data || {};
  const baseKey = item.key.startsWith('news.') ? item.key.slice('news.'.length) : item.key;

  const involved = viewerFaction
    && PARTICIPANT_FIELDS.some((f) => data[f] === viewerFaction);

  const candidates = [];
  if (involved) candidates.push(`news.${baseKey}.involved`);
  candidates.push(`news.${baseKey}.public`);

  const templateKey = candidates.find((k) => vm.$te(k));
  if (!templateKey) return vm.$t('news.unknown_event');

  return vm.$t(templateKey, buildParams(vm, data));
}

export default renderNews;
