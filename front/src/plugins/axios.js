import axiosLib from 'axios';
import Cookies from 'js-cookie';
import store from '@/store';
import config from '@/config';

export function createAxiosInstance() {
  // http/cors configs
  const axios = axiosLib.create({ baseURL: `${config.BASE_URL}/api` });
  // The API pipeline (Portal.Plug.AuthApiPipeline) verifies Bearer headers
  // only — cookie-based session auth is intentionally NOT accepted (CSRF
  // defense). So both Steam and web builds need to attach the JWT here.
  // Steam keeps the token in the store (set by the steam-auth flow); web
  // stores it in the `user_token` cookie (set by Hooks.login in app.js
  // after a successful sign-in via /api/auth/identity/callback).
  axios.interceptors.request.use((opt) => {
    const token = config.IS_STEAM
      ? store.state.portal.apiToken
      : Cookies.get('user_token');
    if (token) {
      opt.headers.Authorization = `Bearer ${token}`;
    }
    return opt;
  }, (error) => Promise.reject(error));
  return axios;
}

const axios = createAxiosInstance();

export default {
  axios,
  install(Vue) {
    Vue.prototype.$axios = axios;
  },
};
