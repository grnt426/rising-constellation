// Card illustration srcset — plain node, no webpack:
//   node --test front/src/utils/__tests__/card-art.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { cardArtSrcset, prefersLowData } from '../card-art.js';
import HD from '../card-art-hd.js';

const DATA = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../public/data');

test('art with an original master gets 1x and 2x WebP', () => {
  assert.equal(
    cardArtSrcset('data/agents/admiralM_007.jpg'),
    'data/agents/admiralM_007.webp 400w, data/agents/admiralM_007@2x.webp 800w',
  );
});

test('art without a master gets the 1x WebP only', () => {
  assert.equal(cardArtSrcset('data/ships/capital_1.jpg'), 'data/ships/capital_1.webp 400w');
});

test('low-data mode never offers the 2x file', () => {
  assert.equal(
    cardArtSrcset('data/doctrines/tech_1.jpg', { lowData: true }),
    'data/doctrines/tech_1.webp 400w',
  );
});

test('relative, absolute and Steam prefixes are kept', () => {
  assert.equal(
    cardArtSrcset('../portal/data/avatars/avatarF_001.jpg'),
    '../portal/data/avatars/avatarF_001.webp 400w, ../portal/data/avatars/avatarF_001@2x.webp 800w',
  );
  assert.equal(cardArtSrcset('/dist/main/data/buildings/hab_dome.jpg'), '/dist/main/data/buildings/hab_dome.webp 400w');
});

test('anything that is not card art falls back to the plain img', () => {
  assert.equal(cardArtSrcset(null), null);
  assert.equal(cardArtSrcset(''), null);
  assert.equal(cardArtSrcset('data/sectors/default.jpg'), null);
  assert.equal(cardArtSrcset('data/agents/admiralM_007.png'), null);
});

test('low data = Save-Data or a 2G-class connection', () => {
  assert.equal(prefersLowData(undefined), false);
  assert.equal(prefersLowData({}), false);
  assert.equal(prefersLowData({ connection: { saveData: true } }), true);
  assert.equal(prefersLowData({ connection: { effectiveType: 'slow-2g' } }), true);
  assert.equal(prefersLowData({ connection: { effectiveType: '2g' } }), true);
  assert.equal(prefersLowData({ connection: { effectiveType: '4g' } }), false);
});

test('every file a srcset can name exists', () => {
  for (const dir of Object.keys(HD)) {
    for (const file of readdirSync(path.join(DATA, dir)).filter((f) => f.endsWith('.jpg'))) {
      const srcset = cardArtSrcset(`data/${dir}/${file}`);
      for (const candidate of srcset.split(', ')) {
        const url = candidate.split(' ')[0];
        assert.ok(existsSync(path.join(DATA, '..', url)), `${url} is missing`);
      }
    }
  }
});

test('the 2x list matches the @2x files on disk', () => {
  for (const [dir, names] of Object.entries(HD)) {
    const onDisk = readdirSync(path.join(DATA, dir))
      .filter((f) => f.endsWith('@2x.webp'))
      .map((f) => f.slice(0, -'@2x.webp'.length))
      .sort();
    assert.deepEqual([...names].sort(), onDisk, dir);
  }
});
