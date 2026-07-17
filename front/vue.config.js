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
    //
    // WEBSOCKETS ARE DELIBERATELY NOT PROXIED HERE (`ws: false` on every
    // entry — it must be explicit because vue-cli defaults it to true).
    // http-proxy-middleware 0.19 (pinned by webpack-dev-server 3) wraps each
    // entry's upgrade handler in lodash `debounce`, which coalesces
    // same-tick calls and keeps only the LAST one. Every ws-enabled entry
    // hears every upgrade event, so when a page opens two sockets in the
    // same tick — the login page opens /live and /phoenix/live_reload
    // together — a middleware processes only the second event and the first
    // socket is silently never forwarded: it hangs until phoenix.js retries.
    // Instead, `after` below attaches ONE deterministic upgrade listener.
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/socket': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/uploads': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/login': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/signup': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/forgotten-password': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/reset-password': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/bind': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/live': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/phoenix': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/js': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/css/app.css': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
      '/img': { target: 'http://localhost:4000', changeOrigin: true, ws: false },
    },
    // Single upgrade listener replacing the per-entry debounced handlers
    // (see the proxy comment above). Forwards the game socket (/socket),
    // LiveView (/live) and live-reload (/phoenix/live_reload) websockets
    // to Phoenix. webpack-dev-server's own HMR socket lives at
    // /sockjs-node and is untouched.
    after(app, server) {
      const httpProxy = require('http-proxy');
      const wsProxy = httpProxy.createProxyServer({
        target: 'http://localhost:4000',
        changeOrigin: true,
      });
      wsProxy.on('error', (err, req, socket) => {
        if (socket && socket.destroy) socket.destroy();
      });
      // listeningApp is created later in the Server constructor than the
      // `after` hook runs; by the next tick it exists.
      process.nextTick(() => {
        server.listeningApp.on('upgrade', (req, socket, head) => {
          if (/^\/(socket|live|phoenix)\//.test(req.url)) {
            wsProxy.ws(req, socket, head);
          }
        });
      });
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
