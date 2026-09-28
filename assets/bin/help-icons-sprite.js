/* eslint-disable */
// Builds the SVG sprite the public help pages use for in-game icons.
//
//   npm run help-icons --prefix ./assets
//
// Source: the generated vue-svgicon modules under front/src/icons (the
// original SVG files are not in the repo). Each module calls
// `icon.register({ 'group/name': { viewBox, data } })`; we evaluate it with
// a fake `vue-svgicon` that records the call, and emit one <symbol> per
// icon, id = name with "/" replaced by "--" (e.g. #resource--mobility).
//
// Output: assets/static/img/help-icons.svg, copied to priv/static by the
// webpack build and served at /img/help-icons.svg. Committed so a dev
// checkout works without running this; build-front.sh regenerates it.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ICONS_DIR = path.resolve(__dirname, '../../front/src/icons');
const OUT = path.resolve(__dirname, '../static/img/help-icons.svg');

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(full);
    if (!entry.name.endsWith('.js') || entry.name === 'index.js') return [];
    return [full];
  });
}

const icons = {};
for (const file of walk(ICONS_DIR).sort()) {
  const code = fs.readFileSync(file, 'utf8');
  const fakeRequire = (name) => {
    if (name !== 'vue-svgicon') throw new Error(`${file}: unexpected require(${name})`);
    return { register: (defs) => Object.assign(icons, defs) };
  };
  vm.runInNewContext(code, { require: fakeRequire, module: { exports: {} }, exports: {} }, { filename: file });
}

const escapeAttr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;');

const symbols = Object.keys(icons)
  .sort()
  .map((name) => {
    const { viewBox, data } = icons[name];
    const id = name.replace(/\//g, '--');
    const body = data.replace(/ pid="\d+"/g, '');
    return `  <symbol id="${escapeAttr(id)}" viewBox="${escapeAttr(viewBox)}">${body}</symbol>`;
  });

const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n${symbols.join('\n')}\n</svg>\n`;

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, svg);
console.log(`help-icons: ${symbols.length} symbols → ${path.relative(process.cwd(), OUT)} (${(svg.length / 1024).toFixed(0)} KB)`);
