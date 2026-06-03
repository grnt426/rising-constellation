/* eslint-disable */
// Pennant flag — pole on the left, triangular bunting to the right.
// Used generically for "I want this" / "this is desirable" markers.
var icon = require('vue-svgicon')
icon.register({
  'marker/flag': {
    width: 20,
    height: 20,
    viewBox: '0 0 20 20',
    data: '<path pid="0" d="M5 2 L7 2 L7 18 L5 18 Z"/><path pid="1" d="M7 4 L16 7 L7 10 Z"/>'
  }
})
