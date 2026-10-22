// A mouse-and-keyboard browser for synthetic usability sessions (see
// docs/scenario-scripting.md, "Synthetic usability study"): one persistent
// Chromium page on the Scenario Workshop, signed in as the seeded user1,
// driven over HTTP by a participant (a person or an agent) who sees only
// screenshots, never the code.
//
//   node usability-harness.js <port> <outdir>
//   curl -s localhost:<port> -d '{"cmd":"shot"}'
//
// Commands (JSON body):
//   shot                          screenshot only
//   click {x, y, button?, shift?, ctrl?, alt?, double?}
//   drag {x1, y1, x2, y2}         press, move in steps, release (works for
//                                 wires, node moves, and dragging from the
//                                 node list onto the canvas)
//   type {text}                   type into whatever has focus
//   press {key}                   e.g. "Enter", "Delete", "Control+z"
//   scroll {x, y, dy}             wheel at a point (zooms the canvas)
//   choose {x, y, option}         pick an option in the dropdown at x,y
//   answer {text}                 the text to give the next popup question
//   text                          the page's visible text (trimmed)
//   goto {path}                   e.g. "/portal/scenario-workshop"
// Every reply: {ok, url, shot, note?}. Screenshots are 1440x900 PNGs.
const http = require('http');
const path = require('path');
const fs = require('fs');

const port = Number(process.argv[2]);
const out = path.resolve(process.argv[3]);
const { chromium } = require('@playwright/test');
const { Api } = require('./helpers/api');

const ports = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '.dev-ports.json'), 'utf8')).ports;
const BASE = `http://localhost:${ports.phoenix}`;

let n = 0;
let answer = '';
const log = [];

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const api = new Api(null, BASE);
  const token = await api.login('user1@abc', 'user1dev');
  const browser = await chromium.launch({ channel: 'chromium' });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.addCookies([{ name: 'user_token', value: token, domain: 'localhost', path: '/' }]);
  const page = await context.newPage();
  page.on('dialog', async (d) => {
    log.push(`popup: "${d.message()}" answered "${answer}"`);
    await d.accept(answer);
  });
  page.on('pageerror', (e) => log.push(`page error: ${e.message}`));
  await page.goto(`${BASE}/portal/scenario-workshop`);
  await page.waitForTimeout(4000);

  const shot = async () => {
    n += 1;
    const file = path.join(out, `${String(n).padStart(3, '0')}.png`);
    await page.screenshot({ path: file });
    return file;
  };

  http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', async () => {
      let reply;
      try {
        const c = JSON.parse(body || '{}');
        let note;
        switch (c.cmd) {
          case 'click': {
            const mods = [c.shift && 'Shift', c.ctrl && 'Control', c.alt && 'Alt'].filter(Boolean);
            for (const m of mods) await page.keyboard.down(m);
            if (c.double) await page.mouse.dblclick(c.x, c.y, { button: c.button || 'left' });
            else await page.mouse.click(c.x, c.y, { button: c.button || 'left' });
            for (const m of mods) await page.keyboard.up(m);
            break;
          }
          case 'drag':
            await page.mouse.move(c.x1, c.y1);
            await page.mouse.down();
            for (let i = 1; i <= 12; i += 1) {
              await page.mouse.move(c.x1 + ((c.x2 - c.x1) * i) / 12, c.y1 + ((c.y2 - c.y1) * i) / 12);
              await page.waitForTimeout(16);
            }
            await page.mouse.up();
            break;
          case 'type': await page.keyboard.type(String(c.text), { delay: 10 }); break;
          case 'press': await page.keyboard.press(String(c.key)); break;
          case 'scroll':
            await page.mouse.move(c.x, c.y);
            await page.mouse.wheel(0, c.dy);
            break;
          case 'choose': {
            note = await page.evaluate(({ x, y, option }) => {
              const el = document.elementFromPoint(x, y);
              const sel = el && el.closest('select');
              if (!sel) return 'no dropdown at that point';
              const opt = [...sel.options].find((o) => o.text.trim() === option || o.value === option);
              if (!opt) return `no option "${option}"; options are: ${[...sel.options].map((o) => o.text.trim()).join(' | ')}`;
              sel.value = opt.value;
              sel.dispatchEvent(new Event('change', { bubbles: true }));
              return `chose "${opt.text.trim()}"`;
            }, c);
            break;
          }
          case 'answer': answer = String(c.text); note = 'the next popup gets this answer'; break;
          case 'text': note = (await page.evaluate(() => document.body.innerText)).replace(/\n{2,}/g, '\n').slice(0, 6000); break;
          case 'goto': await page.goto(`${BASE}${c.path}`); await page.waitForTimeout(2500); break;
          case 'shot': break;
          default: throw new Error(`unknown cmd ${c.cmd}`);
        }
        await page.waitForTimeout(c.cmd === 'shot' ? 100 : 600);
        log.push(JSON.stringify(c));
        fs.writeFileSync(path.join(out, 'log.txt'), log.join('\n'));
        reply = {
          ok: true, url: page.url(), shot: await shot(), note,
        };
      } catch (e) {
        reply = { ok: false, error: e.message, shot: await shot().catch(() => null) };
      }
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(reply));
    });
  }).listen(port, () => console.log(`harness on ${port}`));
})().catch((e) => { console.error(e); process.exit(1); });
