// Public landing page media: modern image formats, lazy loading, and the
// click-to-play video facades (Hooks.videoFacade in assets/js/app.js).
//
// The page must load, and scroll end to end, without contacting any third
// party; YouTube is only reached after a visitor clicks a poster, and the
// player that click inserts has to survive LiveView re-renders
// (phx-update="ignore"). YouTube requests are aborted here so the spec
// never depends on the outside network.
const { test, expect } = require('@playwright/test');

async function openLanding(page) {
  const thirdParty = [];
  page.on('request', (req) => {
    const host = new URL(req.url()).hostname;
    if (host !== 'localhost' && host !== '127.0.0.1') thirdParty.push(req.url());
  });
  await page.route(/youtube(-nocookie)?\.com|ytimg\.com|googlevideo\.com/, (route) => route.abort());
  await page.goto('/', { waitUntil: 'load' });
  await page.waitForSelector('[data-phx-main].phx-connected', { state: 'attached' });
  return thirdParty;
}

async function scrollToBottom(page) {
  for (let y = 0; y <= 6000; y += 600) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    await page.waitForTimeout(100);
  }
}

test('landing: no third-party requests, modern formats, all variants resolve', async ({ page }) => {
  const thirdParty = await openLanding(page);
  await scrollToBottom(page);
  await page.waitForFunction(() => [...document.querySelectorAll('.landing img')]
    .every((img) => img.complete), null, { timeout: 30000 });

  expect(thirdParty, 'the landing page contacted a third party before any click').toEqual([]);

  const images = await page.$$eval('.landing img', (els) => els.map((img) => ({
    src: img.currentSrc.split('/').pop().split('?')[0],
    ok: img.naturalWidth > 0,
    card: !!img.closest('.card-illustration'),
    hero: img.classList.contains('landing-image'),
    poster: !!img.closest('.video-facade'),
  })));
  expect(images.filter((i) => !i.ok), 'images that failed to load').toEqual([]);

  // Cards are WebP; the hero art and posters prefer AVIF (Chromium supports both).
  const cards = images.filter((i) => i.card);
  expect(cards.length).toBe(27);
  expect(cards.filter((i) => !i.src.endsWith('.webp'))).toEqual([]);
  expect(images.filter((i) => i.poster).map((i) => i.src.split('.').pop())).toEqual(['avif', 'avif']);
  expect(images.filter((i) => i.hero && !i.src.endsWith('.gif')).map((i) => i.src.split('.').pop())).toEqual(['avif', 'avif']);

  // Every candidate a browser could pick (other DPRs, WebP-only or
  // fallback browsers) exists and has an image content type.
  const urls = await page.$$eval('.landing picture source, .landing picture img', (els) => {
    const out = new Set();
    els.forEach((el) => {
      (el.getAttribute('srcset') || '').split(',').map((c) => c.trim().split(/\s+/)[0]).filter(Boolean).forEach((u) => out.add(u));
      if (el.getAttribute('src')) out.add(el.getAttribute('src'));
    });
    return [...out];
  });
  expect(urls.length).toBeGreaterThan(60);
  for (const url of urls) {
    const res = await page.request.get(url);
    expect(res.status(), url).toBe(200);
    expect(res.headers()['content-type'], url).toMatch(/^image\//);
  }
});

test('landing: video facade swaps in the player on click and keeps it across re-renders', async ({ page }) => {
  await openLanding(page);
  const facade = page.locator('#video-gameplay');
  const link = facade.locator('a.video-facade-link');

  // Without JS the poster is a plain link to the video.
  await expect(link).toHaveAttribute('href', 'https://www.youtube.com/watch?v=5jCLs4pBJcw');
  await expect(link).toHaveAttribute('target', '_blank');
  await expect(page.locator('.landing iframe')).toHaveCount(0);

  const playerRequest = page.waitForRequest(/youtube-nocookie\.com\/embed\/5jCLs4pBJcw/);
  await link.scrollIntoViewIfNeeded();
  await link.click();
  await playerRequest;

  const iframe = facade.locator('iframe');
  await expect(iframe).toHaveCount(1);
  expect(await iframe.getAttribute('src')).toBe('https://www.youtube-nocookie.com/embed/5jCLs4pBJcw?autoplay=1&color=white&rel=0');
  expect(await iframe.getAttribute('allow')).toContain('autoplay');
  await expect(link).toHaveCount(0);
  // Only the clicked video changed.
  await expect(page.locator('#video-trailer iframe')).toHaveCount(0);
  await expect(page.locator('#video-trailer a.video-facade-link')).toHaveCount(1);

  // A LiveView round trip re-renders the page (sign-up/login toggle, then a
  // full reconnect); phx-update="ignore" must keep the player in place.
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.locator('a[phx-click="show_signup"]').first().click();
  await page.waitForTimeout(500);
  await expect(iframe).toHaveCount(1);
  await page.evaluate(() => { window.liveSocket.disconnect(); window.liveSocket.connect(); });
  await page.waitForSelector('[data-phx-main].phx-connected', { state: 'attached' });
  await page.waitForTimeout(500);
  await expect(facade.locator('iframe')).toHaveCount(1);
});
