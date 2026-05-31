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
    // dev_proxy), forward API + WebSocket calls back to Phoenix on :4000
    // so cookies stay first-party.
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true },
      '/socket': { target: 'http://localhost:4000', changeOrigin: true, ws: true },
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
