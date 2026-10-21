// renderMd link/image targets — plain node, no webpack:
//   node --test front/src/utils/__tests__/markdown.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { renderMd, safeTarget } from '../markdown.js';

// href/src values as the browser reads them (renderMd only writes these
// five entities).
const ENTITIES = {
  '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'",
};
const targets = (html) => [...html.matchAll(/\s(?:href|src)="([^"]*)"/g)]
  .map(([, value]) => value.replace(/&(?:amp|lt|gt|quot|#39);/g, (e) => ENTITIES[e]));

// What the URL parser would take for a scheme ('' for a relative target).
const scheme = (url) => {
  const m = /^([a-z][a-z0-9+.-]*):/i.exec(url.replace(/[\t\n\r]/g, '').trim());
  return m ? m[1].toLowerCase() : '';
};

const assertNoScript = (html) => {
  targets(html).forEach((url) => {
    assert.ok(['', 'http', 'https', 'mailto'].includes(scheme(url)), `unsafe target ${url} in ${html}`);
  });
};

test('a javascript: link keeps its text and loses the link', () => {
  const html = renderMd('[x](javascript:alert(1))');
  assert.equal(html, '<p>x</p>\n');
});

test('a player name carrying a script link is inert in a notification', () => {
  const html = renderMd('**[x](javascript:alert(1))** sent you 100 credits');
  assert.equal(html, '<p><strong>x</strong> sent you 100 credits</p>\n');
});

test('other script-ish schemes and spellings are dropped too', () => {
  [
    '[x](JavaScript:alert(1))',
    '[x](vbscript:msgbox(1))',
    '[x](data:text/html,hi)',
    '[x](file:///etc/passwd)',
    '[x](javascript&#58;alert(1))',
    '[x](javascript&colon;alert(1))',
    '[x](&#106;avascript:alert(1))',
    '[x][a]\n\n[a]: javascript:alert(1)',
    '[x](  javascript:alert(1))',
  ].forEach((md) => {
    const html = renderMd(md);
    assertNoScript(html);
    assert.ok(!/javascript:/i.test(targets(html).join(' ')), md);
  });
});

test('the target is checked as the browser parses it', () => {
  assert.equal(safeTarget('java\tscript:alert(1)', 'link'), null);
  assert.equal(safeTarget('java\nscript:alert(1)', 'link'), null);
  assert.equal(safeTarget('\u0001javascript:alert(1)', 'link'), null);
  assert.equal(safeTarget(' javascript:alert(1)', 'link'), null);
  // raw entities only reach here if the pre-escape ever goes away
  assert.equal(safeTarget('javascript&#58;alert(1)', 'link'), null);
  assert.equal(safeTarget('&#x6A;avascript:alert(1)', 'link'), null);
  assert.equal(safeTarget('java\\script:alert(1)', 'link'), null);
  assert.equal(safeTarget(undefined, 'link'), null);
});

test('no entity survives into the output to decode into a scheme later', () => {
  // `&amp;colon;` decodes once, to `&colon;`: written out as `&amp;colon;`
  // so the browser reads `&colon;`, a relative path, not `:`.
  assert.equal(safeTarget('javascript&amp;colon;alert(1)', 'link'), 'javascript&amp;colon;alert(1)');
  assertNoScript(renderMd('[x](javascript&colon;alert(1))'));
});

test('http(s), mailto, relative and anchor links still work', () => {
  assert.equal(
    renderMd('[Steam account page](https://store.steampowered.com/account/)'),
    '<p><a href="https://store.steampowered.com/account/">Steam account page</a></p>\n',
  );
  assert.equal(renderMd('[a](http://example.com)'), '<p><a href="http://example.com">a</a></p>\n');
  assert.equal(renderMd('[mail](mailto:admin@example.com)'), '<p><a href="mailto:admin@example.com">mail</a></p>\n');
  assert.equal(renderMd('[help](/help/systems)'), '<p><a href="/help/systems">help</a></p>\n');
  assert.equal(renderMd('[up](#top)'), '<p><a href="#top">up</a></p>\n');
  assert.equal(renderMd('[q](?tab=market)'), '<p><a href="?tab=market">q</a></p>\n');
  assert.equal(renderMd('[t](/a (Title))'), '<p><a href="/a" title="Title">t</a></p>\n');
});

test('a query string keeps its ampersands', () => {
  const html = renderMd('[s](https://example.com/?a=1&b=2)');
  assert.equal(html, '<p><a href="https://example.com/?a=1&amp;b=2">s</a></p>\n');
  assert.deepEqual(targets(html), ['https://example.com/?a=1&b=2']);
});

test('autolinks still work', () => {
  assert.deepEqual(targets(renderMd('see https://example.com/x now')), ['https://example.com/x']);
  assert.deepEqual(targets(renderMd('see www.example.com now')), ['http://www.example.com']);
  // marked mangles autolinked addresses into entities; the target is decoded
  assert.deepEqual(targets(renderMd('write to admin@example.com')), ['mailto:admin@example.com']);
});

test('images only load from this site', () => {
  assert.equal(
    renderMd('![Steam ID](media/steam-id-help.png)'),
    '<p><img src="media/steam-id-help.png" alt="Steam ID"></p>\n',
  );
  assert.equal(renderMd('![p](/img/help/x.png)'), '<p><img src="/img/help/x.png" alt="p"></p>\n');
  assert.equal(renderMd('![p](https://evil.example/pixel.png)'), '<p>p</p>\n');
  assert.equal(renderMd('![p](//evil.example/pixel.png)'), '<p>p</p>\n');
  assert.equal(safeTarget('/\\evil.example/pixel.png', 'image'), null);
  assert.equal(renderMd('![p](javascript:alert(1))'), '<p>p</p>\n');
  assert.equal(renderMd('![p](data:image/svg+xml,x)'), '<p>p</p>\n');
});

test('markup is still escaped and emphasis still renders', () => {
  assert.equal(renderMd('<img src=x onerror=alert(1)>'), '<p>&lt;img src=x onerror=alert(1)&gt;</p>\n');
  assert.equal(renderMd('**bold** and *it*'), '<p><strong>bold</strong> and <em>it</em></p>\n');
  assert.equal(renderMd('[a "b" & \'c\'](/x)'), '<p><a href="/x">a &quot;b&quot; &amp; &#39;c&#39;</a></p>\n');
});
