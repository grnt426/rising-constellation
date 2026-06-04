// Token-refresh helpers shared between axios (HTTP) and websockets (WS).
//
// The server issues a short-lived access token (4h) and a long-lived
// refresh token (30d). Access tokens go in the `Authorization: Bearer`
// header on every API call and as the `token` param on socket connect.
// Refresh tokens are accepted only at POST /api/auth/refresh and live
// either in the http-only Phoenix session (web build) or in localStorage
// (Steam build, no cookies).
//
// This module owns: reading the current access token, swapping a refresh
// for a fresh access, and bailing to /login when the refresh itself fails.
//
// Single-flight is enforced here so that N parallel 401s and a concurrent
// pre-reconnect freshness check all share ONE refresh POST.

import axiosLib from 'axios';
import Cookies from 'js-cookie';
import store from '@/store';
import config from '@/config';

// Refresh proactively this many seconds before the access token's exp.
// Lets the socket grab a fresh token before reconnect rather than waiting
// for the rejection round-trip.
const REFRESH_BUFFER_SECONDS = 60;

let refreshInFlight = null;

export function currentAccessToken() {
  return config.IS_STEAM
    ? store.state.portal.apiToken
    : Cookies.get('user_token');
}

export function decodeJwtExp(jwt) {
  if (!jwt) return null;
  try {
    const payload = jwt.split('.')[1];
    if (!payload) return null;
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(json).exp || null;
  } catch (_e) {
    return null;
  }
}

export function isExpiringSoon(jwt, bufferSec = REFRESH_BUFFER_SECONDS) {
  const exp = decodeJwtExp(jwt);
  if (!exp) return false;
  return exp - Math.floor(Date.now() / 1000) < bufferSec;
}

function persistNewAccessToken(token) {
  if (config.IS_STEAM) {
    store.dispatch('portal/setApiToken', token);
    localStorage.setItem('apiToken', token);
  } else {
    Cookies.set('user_token', token);
  }
}

// Refresh-token rejections from the server (see Portal.AuthErrorHandler +
// AuthenticationController.refresh): if any of these come back from
// /api/auth/refresh, the refresh credential itself is dead and the user
// must re-authenticate.
const FATAL_REFRESH_ERRORS = new Set([
  'token_expired',
  'invalid_token',
  'token_revoked',
  'no_resource_found',
  'no_refresh_token',
  'account_inactive',
]);

async function performRefresh() {
  const body = config.IS_STEAM
    ? { refresh_token: localStorage.getItem('refreshToken') || '' }
    : {};

  // Bare axios call — must not run through the interceptor that wraps the
  // default instance, or a 401 here would recurse into refresh-on-401.
  // withCredentials sends the Phoenix session cookie that carries the
  // web build's refresh token.
  const resp = await axiosLib.post(
    `${config.BASE_URL}/api/auth/refresh`,
    body,
    { withCredentials: true },
  );

  const token = resp.data && resp.data.access_token;
  if (!token) {
    throw new Error('refresh response missing access_token');
  }

  persistNewAccessToken(token);
  return token;
}

export function refreshAccessToken() {
  if (!refreshInFlight) {
    refreshInFlight = performRefresh().finally(() => {
      refreshInFlight = null;
    });
  }
  return refreshInFlight;
}

// Returns a guaranteed-fresh-enough access token, refreshing if the
// current one is within REFRESH_BUFFER_SECONDS of exp (or already gone).
export async function ensureFreshAccessToken() {
  const current = currentAccessToken();
  if (current && !isExpiringSoon(current)) {
    return current;
  }
  return refreshAccessToken();
}

export function isFatalRefreshError(serverMessage) {
  return FATAL_REFRESH_ERRORS.has(serverMessage);
}

// Called when refresh itself has failed (refresh token expired, revoked,
// missing). Clear local credentials and hand off to the existing logout
// flow, routing to /login so the user lands on the re-auth form rather
// than the public landing's sign-up CTA.
export function handleAuthFailure() {
  if (config.IS_STEAM) {
    localStorage.removeItem('apiToken');
    localStorage.removeItem('refreshToken');
  } else {
    Cookies.remove('user_token');
  }
  // store.dispatch returns a promise but we don't await — fire-and-forget
  // is fine here because the caller is already on the failure path.
  store.dispatch('portal/logout', { destination: `${config.BASE_URL}/login` });
}
