// Player portraits and the AI-generated opt-in — plain node, no webpack:
//   node --test front/src/utils/__tests__/portraits.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  AIGC_PORTRAITS, AIGC_STAND_INS, CLASSIC_PORTRAITS,
  isAigcPortrait, isKnownPortrait, pickablePortraits, portraitSrcFor,
} from '../portraits.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../../..');
const AVATARS = path.join(REPO, 'front/public/data/avatars');

test('hidden: an AI portrait loads its classic stand-in, at any URL prefix', () => {
  assert.equal(portraitSrcFor('data/avatars/portraitF_001.jpg', false), 'data/avatars/avatarF_006.jpg');
  assert.equal(portraitSrcFor('../portal/data/avatars/portraitR_002.jpg', false), '../portal/data/avatars/avatarM_002.jpg');
  assert.equal(portraitSrcFor('/dist/main/data/avatars/portraitM_008.jpg', false), '/dist/main/data/avatars/avatarM_004.jpg');
});

test('shown: an AI portrait loads as itself', () => {
  assert.equal(portraitSrcFor('data/avatars/portraitF_001.jpg', true), 'data/avatars/portraitF_001.jpg');
});

test('classic portraits and other card art are never rewritten', () => {
  assert.equal(portraitSrcFor('data/avatars/avatarM_003.jpg', false), 'data/avatars/avatarM_003.jpg');
  assert.equal(portraitSrcFor('data/agents/spyF_003.jpg', false), 'data/agents/spyF_003.jpg');
  assert.equal(portraitSrcFor(null, false), null);
});

test('the picker offers AI portraits only when shown; profiles may hold either', () => {
  assert.deepEqual(pickablePortraits(false), CLASSIC_PORTRAITS);
  assert.equal(pickablePortraits(true).length, CLASSIC_PORTRAITS.length + AIGC_PORTRAITS.length);
  assert.ok(isKnownPortrait('portraitF_003.jpg'));
  assert.ok(isKnownPortrait('avatarF_003.jpg'));
  assert.ok(!isKnownPortrait('todo'));
  assert.ok(isAigcPortrait('portraitF_003.jpg'));
  assert.ok(!isAigcPortrait('avatarF_003.jpg'));
});

test('every stand-in is classic, and every portrait has its files', () => {
  for (const [aigc, standIn] of Object.entries(AIGC_STAND_INS)) {
    assert.ok(CLASSIC_PORTRAITS.includes(standIn), `${aigc} -> ${standIn}`);
  }
  for (const file of [...CLASSIC_PORTRAITS, ...AIGC_PORTRAITS]) {
    const stem = file.slice(0, -'.jpg'.length);
    for (const f of [file, `${stem}.webp`, `${stem}@2x.webp`]) {
      assert.ok(existsSync(path.join(AVATARS, f)), `${f} missing`);
    }
  }
});

test('the table matches RC.Portraits (lib/rc/portraits.ex)', () => {
  const ex = readFileSync(path.join(REPO, 'lib/rc/portraits.ex'), 'utf8');
  const pairs = Object.fromEntries([...ex.matchAll(/"(portrait\w+\.jpg)" => "(avatar\w+\.jpg)"/g)].map((m) => [m[1], m[2]]));
  assert.deepEqual(pairs, AIGC_STAND_INS);
});
