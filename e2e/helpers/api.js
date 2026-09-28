// REST/harness helpers for world setup. All calls go straight to Phoenix
// (the SPA's own endpoints) — the browser is reserved for player-visible
// assertions.
const fs = require('fs');
const os = require('os');
const path = require('path');

const HARNESS_SECRET = process.env.RC_BOT_HARNESS_SECRET || 'dev-harness-secret';

const TOKEN_CACHE = path.join(os.tmpdir(), 'rc-e2e-tokens.json');
const TOKEN_CACHE_MS = 3 * 60 * 60 * 1000;

function readTokenCache() {
  try {
    return JSON.parse(fs.readFileSync(TOKEN_CACHE, 'utf8'));
  } catch (_e) {
    return {};
  }
}

function writeTokenCache(key, token) {
  try {
    fs.writeFileSync(TOKEN_CACHE, JSON.stringify({ ...readTokenCache(), [key]: { token, at: Date.now() } }));
  } catch (_e) {
    // best effort: a missing cache only costs a login
  }
}

class Api {
  constructor(request, baseURL) {
    this.request = request;
    this.baseURL = baseURL;
    this.tokens = new Map(); // email -> access_token
  }

  // Logins are rate limited (10 per IP per 15-min fixed window, 2 per
  // spec run), so access tokens (4 h lifetime) are cached on disk across
  // runs and reused for up to 3 h. E2E_NO_TOKEN_CACHE=1 disables it.
  async login(email, password) {
    const cached = readTokenCache()[`${this.baseURL}|${email}`];
    if (cached && Date.now() - cached.at < TOKEN_CACHE_MS && !process.env.E2E_NO_TOKEN_CACHE) {
      this.tokens.set(email, cached.token);
      return cached.token;
    }

    const res = await this.request.post(`${this.baseURL}/api/auth/identity/callback`, {
      data: { account: { email, password } },
    });
    if (!res.ok()) throw new Error(`login ${email} failed: ${res.status()} ${await res.text()}`);
    const body = await res.json();
    const token = body.access_token || body.token;
    this.tokens.set(email, token);
    writeTokenCache(`${this.baseURL}|${email}`, token);
    return token;
  }

  authHeaders(email) {
    const token = this.tokens.get(email);
    if (!token) throw new Error(`no token for ${email}; call login() first`);
    return { Authorization: `Bearer ${token}` };
  }

  // One call = scenario + instance + publish + registrations + start, on
  // the Flash-speed fixture with time_limit/victory_points neutralized.
  // Also pre-places agents in the player's starting system. `grant` tops
  // up starting resources so tests can walk the patent tree / afford
  // fleets without playing out the opening economy.
  // `features` (array of beta-feature keys) makes the account's feature
  // set exactly that list — pass [] to force-disable all betas.
  // `ownAdmirals` (default 1) places extra own navarchs — armada flows
  // need 2-4 co-located. `armadaLayout` ({own: [2,2], friendly: [2],
  // hostile: [3]}) pre-forms armadas: own groups consume the caller's
  // navarchs, friendly/hostile groups mint fresh puppet navarchs in
  // the caller's starting system. `speed` ("fast" | "medium" | "slow")
  // overrides the fixture scenario's tick rate — flows asserting
  // speed-conditional UI (e.g. the Legacy income-per-hour display)
  // need a "slow" world. `empire` (true, or {destabilize: false}) grows
  // the player to 2 systems + 1 dominion through real Lex/claim paths and
  // destabilizes home; the response's `empire` block holds the ids
  // (home, owned2, dominion, autonomous, uninhabited, destabilized).
  async createAgentFixture(email = 'user1@abc', grant = null, features = null, ownAdmirals = null, armadaLayout = null, speed = null, empire = null) {
    const data = { email };
    if (grant) data.grant = grant;
    if (features) data.features = features;
    if (ownAdmirals) data.own_admirals = ownAdmirals;
    if (armadaLayout) data.armada_layout = armadaLayout;
    if (speed) data.speed = speed;
    if (empire) data.empire = empire;
    const res = await this.request.post(`${this.baseURL}/api/harness/dev/agent-fixture`, {
      headers: { 'X-Harness-Secret': HARNESS_SECRET },
      data,
    });
    if (!res.ok()) throw new Error(`agent-fixture failed: ${res.status()} ${await res.text()}`);
    return res.json(); // { instance_id, system: {id, name}, enter_url, agents, armadas, empire }
  }

  // The index omits tokens for everyone; the show endpoint returns the
  // token only for the caller's own registration — probe each row.
  async registrationToken(email, instanceId) {
    const res = await this.request.get(
      `${this.baseURL}/api/instances/${instanceId}/registrations`,
      { headers: this.authHeaders(email) },
    );
    if (!res.ok()) throw new Error(`registrations failed: ${res.status()} ${await res.text()}`);
    const body = await res.json();
    const rows = body.data || body.registrations || body;
    for (const row of (Array.isArray(rows) ? rows : [])) {
      const show = await this.request.get(
        `${this.baseURL}/api/registrations/${row.id}`,
        { headers: this.authHeaders(email) },
      );
      if (!show.ok()) continue;
      const detail = await show.json();
      const reg = detail.data || detail;
      if (reg && reg.token) return reg;
    }
    throw new Error(`no own registration with token found: ${JSON.stringify(body).slice(0, 500)}`);
  }

  // The exact payload the SPA's game/init consumes (and the cookie set
  // the /game route needs).
  async gameStartPayload(email, instanceId, registrationToken) {
    const res = await this.request.get(
      `${this.baseURL}/api/instances/${instanceId}/game/start/${registrationToken}`,
      { headers: this.authHeaders(email) },
    );
    if (!res.ok()) throw new Error(`game/start failed: ${res.status()} ${await res.text()}`);
    return res.json();
  }

  // Dev-only: hold every action start/finish hook of the instance for
  // `ms` (0 lifts it) — keeps a character's queue locked long enough to
  // edit it inside the window.
  async orchestratorDelay(instanceId, ms) {
    const res = await this.request.post(`${this.baseURL}/api/harness/dev/orchestrator-delay`, {
      headers: { 'X-Harness-Secret': HARNESS_SECRET },
      data: { instance_id: instanceId, ms },
    });
    if (!res.ok()) throw new Error(`orchestrator-delay failed: ${res.status()} ${await res.text()}`);
    return res.json();
  }

  // Raw server view of a character — the only one that shows the
  // `locked` pseudo-action (player-facing payloads strip it). Also pokes
  // the agent's tick.
  async charStatus(instanceId, characterId) {
    const res = await this.request.get(
      `${this.baseURL}/api/harness/gov-debug/char-status?iid=${instanceId}&cid=${characterId}`,
      { headers: { 'X-Harness-Secret': HARNESS_SECRET } },
    );
    if (!res.ok()) throw new Error(`char-status failed: ${res.status()} ${await res.text()}`);
    return res.json();
  }

  // Retire the instance so the next server boot doesn't resurrect it.
  async finishInstance(adminEmail, instanceId) {
    const res = await this.request.put(
      `${this.baseURL}/api/instances/${instanceId}/finish`,
      { headers: this.authHeaders(adminEmail), data: {} },
    );
    return res.ok();
  }
}

module.exports = { Api };
