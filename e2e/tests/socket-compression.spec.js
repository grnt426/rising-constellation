// permessage-deflate on the game socket (Portal.Endpoint `compress: true`).
//
// The join replies are the largest payloads the game sends (the whole
// galaxy plus the static content catalogue), so this checks, with a real
// browser on the compressed side:
//   - the SPA's socket actually negotiates the extension;
//   - join replies decode to exactly what an UNCOMPRESSED connection gets
//     (helpers/raw-socket.js never offers the extension), and that client
//     is still served plain frames;
//   - client -> server frames inflate correctly (unicode chat round trip,
//     a 60 KB push);
//   - the 64 KB max_frame_size replay-spam cap still bounds the INFLATED
//     size: a 70 KB push that deflates to a few hundred bytes on the wire
//     must still be refused (close 1009).
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected } = require('../helpers/game');
const { connectRaw } = require('../helpers/raw-socket');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

let api;
let instanceId;

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);
  const fixture = await api.createAgentFixture(PLAYER.email);
  instanceId = fixture.instance_id;
});

test.afterAll(async () => {
  if (api && instanceId) {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});

// A second, bare browser WebSocket kept on window.__cmp so the steps below
// can speak the Phoenix v2 wire protocol ([join_ref, ref, topic, event,
// payload]) over the browser's own deflate implementation.
async function openBrowserSocket(page, wsUrl) {
  return page.evaluate(async (url) => {
    const ws = new WebSocket(url);
    const s = { ws, msgs: [], closeCode: null, ref: 0, joins: {} };
    ws.onmessage = (e) => s.msgs.push(e.data);
    ws.onclose = (e) => { s.closeCode = e.code; };
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error('browser websocket failed to open'));
    });
    window.__cmp = s;
    return ws.extensions;
  }, wsUrl);
}

// Send one message and wait for its phx_reply (or the socket closing).
async function browserSend(page, topic, event, payload) {
  return page.evaluate(async ({ topic, event, payload }) => {
    const s = window.__cmp;
    s.ref += 1;
    const ref = String(s.ref);
    const joinRef = event === 'phx_join' ? ref : s.joins[topic];
    if (event === 'phx_join') s.joins[topic] = ref;
    s.ws.send(JSON.stringify([joinRef, ref, topic, event, payload]));
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const i = s.msgs.findIndex((m) => { const a = JSON.parse(m); return a[1] === ref && a[3] === 'phx_reply'; });
      if (i >= 0) return { reply: s.msgs.splice(i, 1)[0], closeCode: null };
      if (s.closeCode !== null) return { reply: null, closeCode: s.closeCode };
      await new Promise((r) => setTimeout(r, 50));
    }
    return { reply: null, closeCode: s.closeCode, timedOut: true };
  }, { topic, event, payload });
}

async function rawJoin(wsUrl, topic, params) {
  const sock = await connectRaw(wsUrl);
  sock.send(JSON.stringify(['1', '1', topic, 'phx_join', params]));
  const reply = await sock.next((m) => { const a = JSON.parse(m); return a[1] === '1' && a[3] === 'phx_reply'; });
  return { sock, reply };
}

test('game socket: permessage-deflate negotiated, payloads intact both ways', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);

  const token = api.tokens.get(PLAYER.email);
  const wsUrl = `${baseURL.replace(/^http/, 'ws')}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(token)}`;
  const globalTopic = `instance:global:${instanceId}`;
  const factionTopic = `instance:faction:${instanceId}:${start.faction}`;
  const joinParams = { registration: reg.token };

  await test.step('the SPA game socket negotiated permessage-deflate', async () => {
    const ext = await page.evaluate(() => document.querySelector('#app').__vue__.$socket.ws.conn.extensions);
    expect(ext).toContain('permessage-deflate');
  });

  await test.step('join replies: compressed browser == uncompressed reference', async () => {
    const ext = await openBrowserSocket(page, wsUrl);
    expect(ext).toContain('permessage-deflate');

    // The galaxy can legitimately change on a tick between the two joins;
    // the content catalogue (global_data) is static and must match exactly
    // on the first attempt.
    let galaxyMatched = false;
    for (let attempt = 0; attempt < 3 && !galaxyMatched; attempt += 1) {
      const [browser, raw] = await Promise.all([
        browserSend(page, globalTopic, 'phx_join', joinParams),
        rawJoin(wsUrl, globalTopic, joinParams),
      ]);
      raw.sock.close();
      expect(raw.sock.headers['sec-websocket-extensions']).toBeUndefined();
      expect(raw.sock.reservedBitsSeen).toBe(false);

      const b = JSON.parse(browser.reply)[4];
      const r = JSON.parse(raw.reply)[4];
      expect(b.status).toBe('ok');
      expect(r.status).toBe('ok');
      expect(b.response.global_data).toEqual(r.response.global_data);
      expect(JSON.stringify(b.response.global_data).length).toBeGreaterThan(50000);
      galaxyMatched = JSON.stringify(b.response.global_galaxy) === JSON.stringify(r.response.global_galaxy);
      // Leave the channel so the next attempt can join it again.
      await browserSend(page, globalTopic, 'phx_leave', {});
    }
    expect(galaxyMatched, 'global_galaxy differed between compressed and uncompressed joins').toBe(true);
  });

  await test.step('client -> server: unicode chat round-trips exactly', async () => {
    const join = await browserSend(page, factionTopic, 'phx_join', joinParams);
    expect(JSON.parse(join.reply)[4].status).toBe('ok');

    const marker = `deflate-e2e ${Date.now()} Tétrarchie ⚔ 星々 — ${'ωψ'.repeat(40)}`;
    const push = await browserSend(page, factionTopic, 'push_chat_message', { message: marker });
    expect(JSON.parse(push.reply)[4].status).toBe('ok');

    // The faction broadcast carries the chat back; find the exact string.
    const echoed = await page.waitForFunction((needle) => {
      const hit = (v) => (typeof v === 'string' ? v === needle
        : v && typeof v === 'object' ? Object.values(v).some(hit) : false);
      return window.__cmp.msgs.some((m) => hit(JSON.parse(m)));
    }, marker, { timeout: 30000 });
    expect(await echoed.jsonValue()).toBe(true);
  });

  await test.step('client -> server: a 60 KB push inflates and is accepted', async () => {
    const push = await browserSend(page, factionTopic, 'push_chat_message', { message: 'A'.repeat(60000) });
    expect(push.closeCode).toBeNull();
    expect(JSON.parse(push.reply)[4].status).toBe('ok');
  });

  await test.step('the 64 KB cap applies to the inflated size', async () => {
    // ~70 KB of JSON that deflates to a few hundred bytes on the wire.
    const push = await browserSend(page, factionTopic, 'push_chat_message', { message: 'B'.repeat(70000) });
    expect(push.reply).toBeNull();
    expect(push.closeCode).toBe(1009);
  });

  await test.step('the SPA socket was unaffected', async () => {
    const connected = await page.evaluate(() => document.querySelector('#app').__vue__.$store.state.game.connected);
    expect(connected).toBe(true);
  });
});
