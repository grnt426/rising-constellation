const path = require('path');
const batchedPoll = require('./dev/batched-poll');

// The dev server polls for file changes (see watchOptions below). batched-poll
// backs that polling off while nothing is changing; polling every path once a
// second kept an idle stack at ~18% of a core.
if (process.argv.includes('serve')) batchedPoll.install();

// The client version for Help -> Debug reports (src/game/debug/environment.js).
process.env.VUE_APP_VERSION = require('./package.json').version;

module.exports = {
  productionSourceMap: true,
  publicPath: '/portal/',
  configureWebpack: {
    resolve: {
      alias: {
        public: path.resolve(__dirname, './public/'),
        // The Edict language engine the editor kits ship (completion, docs
        // under the cursor), shared with the Scenario Workshop's code view.
        'edict-editors': path.resolve(__dirname, '../priv/edict/editors/'),
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
    // Reached through Phoenix's dev_proxy and the worktree's mapped port,
    // never on its own hostname.
    allowedHosts: 'all',
    // webpack-dev-server 4 compresses every response, brotli for browsers,
    // on each request: ~34s for the 4.8 MB dev app.js, ~1 min for vendors.
    // Served over localhost, compression buys nothing.
    compress: false,
    // Vue CLI 5 has webpack-dev-server watch public/ (773 files) with its own
    // chokidar poller, outside batched-poll. webpack-dev-server 3 never
    // watched it (watchContentBase was off), so keep it that way: public/
    // changes need a page reload, as they always did. (Vue CLI merges this
    // into its own `static` block.)
    static: { watch: false },
    client: {
      progress: false,
      // webpack-dev-server 4 also overlays uncaught runtime errors, a
      // full-page iframe that swallows clicks (and fails e2e runs) over
      // errors the game already reports in its own debug log.
      overlay: { errors: true, warnings: false, runtimeErrors: false },
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
    // http-proxy-middleware 0.19 (pinned by webpack-dev-server 3) wrapped each
    // entry's upgrade handler in lodash `debounce`, which coalesces
    // same-tick calls and keeps only the LAST one. Every ws-enabled entry
    // hears every upgrade event, so when a page opens two sockets in the
    // same tick — the login page opens /live and /phoenix/live_reload
    // together — a middleware processes only the second event and the first
    // socket is silently never forwarded: it hangs until phoenix.js retries.
    // Instead, `onListening` below attaches ONE deterministic upgrade
    // listener. (webpack-dev-server 4 ships http-proxy-middleware 2, but one
    // listener for every socket is still the simplest thing that works.)
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
    // to Phoenix. webpack-dev-server's own HMR socket lives at /ws and is
    // untouched.
    onListening(devServer) {
      const httpProxy = require('http-proxy');
      const wsProxy = httpProxy.createProxyServer({
        target: 'http://localhost:4000',
        changeOrigin: true,
      });
      wsProxy.on('error', (err, req, socket) => {
        if (socket && socket.destroy) socket.destroy();
      });
      devServer.server.on('upgrade', (req, socket, head) => {
        if (/^\/(socket|live|phoenix)\//.test(req.url)) {
          wsProxy.ws(req, socket, head);
        }
      });
    },
  },
  chainWebpack: (config) => {
    // plain CommonJS for every browser the game supports (and for Node in the
    // editor kits): Babel would mix module systems in it
    config.module.rule('js').exclude.add(path.resolve(__dirname, '../priv'));
    config.watchOptions({
      poll: 1000,
      ignored: /node_modules/,
    });
  },
  lintOnSave: false,
  // No thread-loader pool for Babel (Vue CLI 5 turns it on for production
  // builds): each worker loads its own Babel, and the release build runs
  // on a 4-vCPU / 8 GB builder next to the Elixir and Rust compiles.
  parallel: false,
};
