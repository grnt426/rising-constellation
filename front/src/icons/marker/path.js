/* eslint-disable */
// Directional chevron — generic "route through" / "scout this way" marker.
// Single rightward wedge, neutral enough that a faction can decide whether
// it means "explore" or "incoming" via their own convention.
var icon = require('vue-svgicon')
icon.register({
  'marker/path': {
    width: 20,
    height: 20,
    viewBox: '0 0 20 20',
    data: '<path pid="0" d="M4 3 L14 10 L4 17 L7 17 L17 10 L7 3 Z"/>'
  }
})
