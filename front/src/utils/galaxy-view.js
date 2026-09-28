import Offset from 'polygon-offset';

// Galaxy coordinates -> 2D screen, oriented the way the game shows them.
//
// The in-game map (front/src/game/map) puts game_data coordinates straight
// into a y-up three.js scene: x grows to the right and y grows UP the
// screen. SVG and canvas y grows DOWN, so every 2D galaxy view maps
// through here: the lobby and create-game map (InstanceMap), the archive
// map, the Forge map and scenario editors, and the Forge preview. The
// server-side renders follow the same rule through RC.GalaxyView
// (lib/rc/galaxy_view.ex). Stored game_data is never flipped; only the
// drawing is, so running games are unaffected.
//
//   const view = galaxyView(gameData.size, 480);
//   view.x(p.x), view.y(p.y)    // screen position of a galaxy point
//   view.len(radius)            // lengths carry no orientation
//   view.polygon(sector.points) // "x,y x,y ..." for <polygon :points>
//   view.toDataX(px), view.toDataY(py) // mouse position back to galaxy

const round2 = (v) => Math.round(v * 100) / 100;

export function galaxyView(dataSize, pixelSize) {
  const k = pixelSize / dataSize;
  const sx = (x) => round2(x * k);
  const sy = (y) => round2((dataSize - y) * k);

  return {
    x: sx,
    y: sy,
    len: (d) => round2(d * k),
    point: ([x, y]) => [sx(x), sy(y)],
    polygon: (points) => (points || []).map(([x, y]) => `${sx(x)},${sy(y)}`).join(' '),
    // A sector outline inset by `padding` galaxy units, the lobby's look
    // for sectors that would otherwise touch their neighbours.
    insetPolygon(points, padding) {
      const flipped = (points || []).map(([x, y]) => [x, dataSize - y]);
      if (flipped.length < 3) return '';
      const offset = new Offset();
      const closed = offset.data(flipped).padding(0);
      const inset = offset.data(closed).padding(padding)[0] || [];
      return inset.map(([x, y]) => `${round2(x * k)},${round2(y * k)}`).join(' ');
    },
    toDataX: (px) => px / k,
    toDataY: (py) => dataSize - py / k,
    // For an SVG <g> whose children are drawn at scaled but unflipped
    // galaxy coordinates (the Forge map editor, which positions ~60
    // overlay elements that way): the group applies the same y flip.
    // Text must stay outside such a group or it renders mirrored.
    flipTransform: `translate(0 ${pixelSize}) scale(1 -1)`,
  };
}

export default galaxyView;
