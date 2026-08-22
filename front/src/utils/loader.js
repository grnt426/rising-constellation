import config from '@/config';

export async function maintenanceCheck() {
  try {
    const maintenance = await fetch(config.BASE_URL + '/api/maintenance').then((response) => response.json());
    return maintenance === true;
  } catch (_err) {
    //
  }
  return false;
}

export async function versionCheck() {
  try {
    const { data: { version } } = await fetch(config.BASE_URL + '/api/version').then((response) => response.json());
    if (version === 'dev') {
      return true;
    }
    let [major, minor, patch] = version.split('.');
    const backendVersion = { major, minor, patch };
    // eslint-disable-next-line no-undef
    [major, minor, patch] = __localVersion.split('.');
    const clientVersion = { major, minor, patch };
    const needsUpgrade = backendVersion.major > clientVersion.major
      || (backendVersion.major === clientVersion.major && backendVersion.minor > clientVersion.minor);
    return !needsUpgrade;
  } catch (_err) {
    //
  }
  return true;
}

export async function connectivityCheck() {
  try {
    // Probe our own origin, not a third party (this used to query
    // dns.google, leaking a request from every visitor to Google). Any
    // HTTP response counts — reachability is the question, not status.
    // This is the loading screen's only "can I reach anything" signal:
    // maintenanceCheck/versionCheck default to passing when the fetch
    // throws, so they don't detect a dead network.
    await fetch(config.BASE_URL + '/robots.txt', { cache: 'no-store' });
    return true;
  } catch (err) {
    //
  }
  return false;
}
