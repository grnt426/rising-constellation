import greenworks from 'greenworks';

const isDevelopment = process.env.NODE_ENV !== 'production';
const apiOrigin = isDevelopment
  ? 'http://localhost:4000'
  : process.env.VUE_APP_BASE_URL;

if (!apiOrigin) {
  throw new Error('VUE_APP_BASE_URL must be set at build time for the Steam client');
}

const baseUrl = `${apiOrigin}/api`;
const backendTicketAuthEndpoint = `${baseUrl}/steam/ticket`;
const backendUserAuthEndpoint = `${baseUrl}/auth/identity/callback`;

async function getAuthSessionTicket() {
  return new Promise((resolve, reject) => greenworks.getAuthSessionTicket(resolve, reject));
}

export async function steamTicket() {
  console.log('starting auth');
  try {
    const { ticket: ticketBin, handle: _handle } = await getAuthSessionTicket();
    const ticketHex = ticketBin.toString('hex');
    console.log('auth success cb, now going to', backendTicketAuthEndpoint);

    const { steamid, result } = await (fetch(backendTicketAuthEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticket: ticketHex }),
    }).then((res) => res.json()));

    console.log('signup result:', result);
    return { ticketHex, steamid };
  } catch (err) {
    console.log('error', 'steam auth failed');
    console.log(err.message);
    console.log(err.trace);
    throw err;
  }
}

export async function steamAuth({ ticketHex, steamid }) {
  console.log('auth');

  try {
    // Server returns { token, access_token, refresh_token, account }.
    // `token` is kept for backwards compat (== access_token); we prefer
    // the explicit key. refresh_token is the long-lived (30d) credential
    // the Steam client persists in localStorage to swap for fresh access
    // tokens without re-doing the Steam ticket dance.
    const resp = await (fetch(backendUserAuthEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticket: ticketHex, steam_id: steamid }),
    }).then((res) => res.json()));

    const { account } = resp;
    const apiToken = resp.access_token || resp.token;
    const refreshToken = resp.refresh_token;

    console.log('auth() done');
    return { account, apiToken, refreshToken };
  } catch (err) {
    console.log(`${backendUserAuthEndpoint} failed`);
    console.log(err.message);
    console.log(err.trace);
  }
}
