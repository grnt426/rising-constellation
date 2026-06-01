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
    const { account, token } = await (fetch(backendUserAuthEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticket: ticketHex, steam_id: steamid }),
    }).then((res) => res.json()));

    console.log('auth() done');
    console.log(JSON.stringify({ account, token }, null, 2));
    return { account, apiToken: token };
  } catch (err) {
    console.log(`${backendUserAuthEndpoint} failed`);
    console.log(err.message);
    console.log(err.trace);
  }
}
