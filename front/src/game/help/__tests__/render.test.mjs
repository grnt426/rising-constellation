// Plain node, no webpack:
//   node --test front/src/game/help/__tests__/
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  renderHelpHtml, makeIconLookup, searchPages, publicHelpUrl,
} from '../render.js';

const registry = {
  'resource/mobility': {
    width: 20, height: 20, viewBox: '0 0 20 20', data: '<path pid="0" _fill="#111" d="M0 0h20v20z"/>',
  },
};
const lookup = makeIconLookup(registry);

test('icon markers become inline svg from the registry, original colours dropped', () => {
  const html = renderHelpHtml('a <i class="help-icon" data-icon="resource/mobility" title="Mobility"></i> b', lookup);
  assert.equal(
    html,
    'a <svg class="svg-icon help-icon" viewBox="0 0 20 20" role="img" aria-label="Mobility"><title>Mobility</title><path pid="0" d="M0 0h20v20z"/></svg> b',
  );
});

test('unknown icons leave a titled placeholder, other markup is untouched', () => {
  const html = renderHelpHtml('<i class="help-icon" data-icon="nope/x" title="X"></i><a href="/help/taxes" class="help-ref" data-help="taxes">taxes</a>', lookup);
  assert.equal(html, '<span class="help-icon help-icon-missing" title="X"></span><a href="/help/taxes" class="help-ref" data-help="taxes">taxes</a>');
  assert.equal(renderHelpHtml(null, lookup), '');
});

test('search ranks title, then terms, then text', () => {
  const pages = [
    { slug: 'credit', title: 'Credit', terms: ['credits'], text: 'taxes mobility' },
    { slug: 'taxes', title: 'Taxes', terms: ['tax'], text: 'population' },
    { slug: 'mobility', title: 'Mobility', terms: ['mobility bonus'], text: 'taxes' },
  ];
  assert.deepEqual(searchPages(pages, 'tax').map((p) => p.slug), ['taxes', 'credit', 'mobility']);
  assert.deepEqual(searchPages(pages, '  '), []);
  assert.deepEqual(searchPages(pages, 'zzz'), []);
});

test('public url carries a non-default speed', () => {
  assert.equal(publicHelpUrl('https://tetrarchyfalls.com', 'mobility', 'slow'), 'https://tetrarchyfalls.com/help/mobility');
  assert.equal(publicHelpUrl('', 'mobility', 'fast'), '/help/mobility?speed=fast');
});
