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

const shot = '<figure class="help-shot" data-shot="system-population"><div class="help-shot-frame" style="aspect-ratio: 640 / 220">'
  + '<img src="/img/help/shots/system-population.png" alt="Population" width="640" height="220" loading="lazy">'
  + '<span class="help-shot-mark" data-n="1" style="left:10.5%;top:60%;width:30%;height:20%"></span></div></figure>';

test('help image srcs are left root-relative without an origin', () => {
  assert.equal(renderHelpHtml(shot, lookup), shot);
  assert.equal(renderHelpHtml(shot, lookup, {}), shot);
  assert.equal(renderHelpHtml(shot, lookup, { origin: '' }), shot);
});

test('options.origin makes help image srcs absolute, trailing slash tolerated', () => {
  const expected = shot.replace('src="/img/help/', 'src="https://tetrarchyfalls.com/img/help/');
  assert.equal(renderHelpHtml(shot, lookup, { origin: 'https://tetrarchyfalls.com' }), expected);
  assert.equal(renderHelpHtml(shot, lookup, { origin: 'https://tetrarchyfalls.com/' }), expected);
  const two = `${shot}${shot}`;
  assert.equal(
    renderHelpHtml(two, lookup, { origin: 'http://localhost:4840' }).split('src="http://localhost:4840/img/help/shots/').length,
    3,
  );
});

test('origin only touches /img/help/ srcs, not links, other images or icons', () => {
  const html = '<a href="/img/help/x.png">x</a><img src="/img/other.png"><img src="https://cdn.example/img/help/y.png">'
    + '<i class="help-icon" data-icon="resource/mobility" title="Mobility"></i>';
  const out = renderHelpHtml(html, lookup, { origin: 'http://localhost:4840' });
  assert.ok(out.startsWith('<a href="/img/help/x.png">x</a><img src="/img/other.png"><img src="https://cdn.example/img/help/y.png">'));
  assert.ok(out.includes('<svg class="svg-icon help-icon"'));
});

test('unit and chart markup passes through untouched', () => {
  const html = '<span class="help-rate"><span class="help-unit-tick">2 credits per tick</span><span class="help-unit-hour">40 credits per hour</span></span>'
    + '<figure class="help-chart"><div class="help-unit-tick"><svg class="help-chart-svg" viewBox="0 0 640 320"></svg></div></figure>';
  assert.equal(renderHelpHtml(html, lookup, { origin: 'http://localhost:4840' }), html);
});

test('building card radio groups get fresh names on every render', () => {
  const card = '<figure class="help-bcard" data-building="hab_open"><div class="help-bcard-pips">'
    + '<label class="help-bcard-pip"><input type="radio" name="help-bcard-hab_open" value="1" checked><span>1</span></label>'
    + '<label class="help-bcard-pip"><input type="radio" name="help-bcard-hab_open" value="2"><span>2</span></label></div></figure>';
  const names = (html) => [...html.matchAll(/name="([^"]+)"/g)].map((m) => m[1]);
  const first = names(renderHelpHtml(card, lookup));
  const second = names(renderHelpHtml(card, lookup));
  assert.equal(first.length, 2);
  assert.equal(new Set(first).size, 1);
  assert.equal(new Set(second).size, 1);
  assert.notEqual(first[0], second[0]);
  assert.ok(first[0].startsWith('help-bcard-hab_open-'));
  assert.equal(renderHelpHtml(shot, lookup), shot);
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
