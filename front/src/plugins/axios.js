import axiosLib from 'axios';
import config from '@/config';
import {
  currentAccessToken,
  refreshAccessToken,
  isFatalRefreshError,
  handleAuthFailure,
} from '@/plugins/auth';

export function createAxiosInstance() {
  // http/cors configs
  const axios = axiosLib.create({ baseURL: `${config.BASE_URL}/api` });

  // Request interceptor: attach the current Bearer on every call.
  // The API pipeline (Portal.Plug.AuthApiPipeline) verifies Bearer headers
  // only — cookie-based session auth is intentionally NOT accepted (CSRF
  // defense). So both Steam and web builds need to attach the JWT here.
  // Steam keeps the token in the store (set by the steam-auth flow); web
  // stores it in the `user_token` cookie (set by Hooks.login in app.js
  // after a successful sign-in via /api/auth/identity/callback).
  axios.interceptors.request.use((opt) => {
    const token = currentAccessToken();
    if (token) {
      opt.headers.Authorization = `Bearer ${token}`;
    }
    return opt;
  }, (error) => Promise.reject(error));

  // Response interceptor: on a 401 caused by a stale access token, refresh
  // and retry the original request transparently. The user shouldn't see
  // a re-login prompt until the 30-day refresh token itself expires.
  axios.interceptors.response.use(
    (response) => response,
    async (error) => {
      const original = error.config;
      const status = error.response && error.response.status;
      const data = (error.response && error.response.data) || {};
      const message = data.message;

      // Recoverable only if: server returned 401, message is one of the
      // stale-credential atoms, we haven't already retried this request,
      // and the failing request wasn't itself /auth/refresh.
      const isRefreshCall = original && original.url && original.url.includes('/auth/refresh');
      const recoverable = ['token_expired', 'invalid_token', 'token_revoked'];

      if (
        status !== 401
        || !recoverable.includes(message)
        || (original && original._retry)
        || isRefreshCall
      ) {
        return Promise.reject(error);
      }

      original._retry = true;

      try {
        const newToken = await refreshAccessToken();
        original.headers.Authorization = `Bearer ${newToken}`;
        return axios(original);
      } catch (refreshErr) {
        // If refresh itself returned a token-rejection, the long-lived
        // credential is dead — kick to login. Other failures (network,
        // 5xx) leave the user in place; next request will try again.
        const refreshMessage = refreshErr
          && refreshErr.response
          && refreshErr.response.data
          && refreshErr.response.data.message;

        if (isFatalRefreshError(refreshMessage)) {
          handleAuthFailure();
        }

        return Promise.reject(error);
      }
    },
  );

  return axios;
}

const axios = createAxiosInstance();

export default {
  axios,
  install(Vue) {
    Vue.prototype.$axios = axios;
  },
};
