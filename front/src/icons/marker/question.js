/* eslint-disable */
// Generic "investigate" / "unknown" marker — stylized question mark
// rendered as a filled hook plus a dot. Avoids needing a font glyph
// (the other map icons are all fill-only SVG paths).
var icon = require('vue-svgicon')
icon.register({
  'marker/question': {
    width: 20,
    height: 20,
    viewBox: '0 0 20 20',
    data: '<path pid="0" d="M6 7 C6 4 8 2 10 2 C12 2 14 4 14 7 C14 9 12.5 10 11.5 11 C11 11.5 11 12 11 13 L9 13 C9 11.5 9.5 10.5 10.5 9.5 C11.5 8.5 12 8 12 7 C12 5.5 11 4 10 4 C9 4 8 5.5 8 7 Z"/><circle pid="1" cx="10" cy="16" r="1.4"/>'
  }
})
