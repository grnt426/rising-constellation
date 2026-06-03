/* eslint-disable */
// "Attack here" — four inward-pointing chevrons (each a filled wedge)
// arranged at 90° rotations. Distinct from the ship attack icons
// (energy_strikes / explosive_strikes) so a player marking a system
// for assault doesn't read as "this system has explosive weapons".
var icon = require('vue-svgicon')
icon.register({
  'marker/attack': {
    width: 20,
    height: 20,
    viewBox: '0 0 20 20',
    data: '<path pid="0" d="M5 2 L15 2 L10 7 Z"/><path pid="1" d="M18 5 L18 15 L13 10 Z"/><path pid="2" d="M5 18 L15 18 L10 13 Z"/><path pid="3" d="M2 5 L2 15 L7 10 Z"/>'
  }
})
