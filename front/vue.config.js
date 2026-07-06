const path = require('path');

module.exports = {
  productionSourceMap: true,
  publicPath: '/portal/',
  configureWebpack: {
    resolve: {
      alias: {
        public: path.resolve(__dirname, './public/'),
      },
    },
  },
  pluginOptions: {
    'style-resources-loader': {
      preProcessor: 'scss',
      patterns: [path.resolve(__dirname, 'src/styles/**/*.scss')],
    },
  },
  devServer: {
    progress: false,
    disableHostCheck: true,
    // Windows bind-mounted volumes don't propagate inotify events into the
    // container, so the dev watcher misses file changes. Fall back to
    // polling.
    watchOptions: {
      poll: 1000,
      ignored: /node_modules/,
    },
    // When hitting the SPA directly on :8080 (bypassing Phoenix's slow
    // dev_proxy), forward API + WebSocket + uploaded-file calls back to
    // Phoenix on :4000 so cookies stay first-party. /uploads serves
    // Waffle's local-storage directory via a Plug.Static on the Phoenix
    // endpoint — without this proxy the Vue dev server intercepts the
    // request and returns its SPA-shell HTML for the unknown path.
    //
    // The auth pages (/login, /signup, ...) are Phoenix LiveViews, not SPA
    // routes. They must be proxied too, or the dev server's history
    // fallback serves the SPA shell at /login — which, signed out,
    // redirects to /login again: an infinite auth loop on this origin.
    // With the proxy the whole sign-in round trip stays on one origin and
    // the user_token cookie is visible to the SPA (cookies ignore ports).
    //
    // /live is the LiveView websocket; /js, /css/app.css and /img are the
    // Phoenix-side static assets those pages load (kept narrow — the SPA's
    // own public/ dir also serves /css/* and /fonts/* on this origin).
    // /phoenix is the live-reload iframe, proxied only to keep the login
    // page's console clean.
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true },
      '/socket': { target: 'http://localhost:4000', changeOrigin: true, ws: true },
      '/uploads': { target: 'http://localhost:4000', changeOrigin: true },
      '/login': { target: 'http://localhost:4000', changeOrigin: true },
      '/signup': { target: 'http://localhost:4000', changeOrigin: true },
      '/forgotten-password': { target: 'http://localhost:4000', changeOrigin: true },
      '/reset-password': { target: 'http://localhost:4000', changeOrigin: true },
      '/bind': { target: 'http://localhost:4000', changeOrigin: true },
      '/live': { target: 'http://localhost:4000', changeOrigin: true, ws: true },
      '/phoenix': { target: 'http://localhost:4000', changeOrigin: true, ws: true },
      '/js': { target: 'http://localhost:4000', changeOrigin: true },
      '/css/app.css': { target: 'http://localhost:4000', changeOrigin: true },
      '/img': { target: 'http://localhost:4000', changeOrigin: true },
    },
  },
  chainWebpack: (config) => {
    config.watchOptions({
      poll: 1000,
      ignored: /node_modules/,
    });
  },
  lintOnSave: false,
};
