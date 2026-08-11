// REST/harness helpers for world setup. All calls go straight to Phoenix
// (the SPA's own endpoints) — the browser is reserved for player-visible
// assertions.
const HARNESS_SECRET = process.env.RC_BOT_HARNESS_SECRET || 'dev-harness-secret';

class Api {
  constructor(request, baseURL) {
    this.request = request;
    this.baseURL = baseURL;
    this.tokens = new Map(); // email -> access_token
  }

  async login(email, password) {
    const res = await this.request.post(`${this.baseURL}/api/auth/identity/callback`, {
      data: { account: { email, password } },
    });
    if (!res.ok()) throw new Error(`login ${email} failed: ${res.status()} ${await res.text()}`);
    const body = await res.json();
    const token = body.access_token || body.token;
    this.tokens.set(email, token);
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
  async createAgentFixture(email = 'user1@abc', grant = null) {
    const res = await this.request.post(`${this.baseURL}/api/harness/dev/agent-fixture`, {
      headers: { 'X-Harness-Secret': HARNESS_SECRET },
      data: grant ? { email, grant } : { email },
    });
    if (!res.ok()) throw new Error(`agent-fixture failed: ${res.status()} ${await res.text()}`);
    return res.json(); // { instance_id, system: {id, name}, enter_url, agents }
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
