import {
  BufferGeometry,
  Group,
  Line,
  LineBasicMaterial,
  Mesh,
  MeshBasicMaterial,
  RingGeometry,
  Vector3,
} from 'three';

import config from '@/config';
import store from '@/store';
import Block from './block';

// Shared geometry/material for waypoint rings — cheap to reuse across
// the whole ruler lifetime, and avoids leaking GPU buffers if the
// player toggles the tool repeatedly.
const ringGeometry = new RingGeometry(0.35, 0.45, 32);
const ringMaterial = new MeshBasicMaterial({
  color: 0xffffff,
  transparent: true,
  opacity: 0.9,
});

function arrayToPoints(xs, z) {
  return xs.map(([x, y]) => new Vector3(x, y, z));
}

// Ruler overlay block. Reads the committed ruler.waypoints +
// ruler.hoveredSystemId from the store, runs the same pathfinder the
// Character block builds, and draws a single line segment per edge.
// Travel time is the sum of edge weights × character_movement_factor;
// the result is written back to the store so the Vue overlay can show
// it in wall-clock units.
export default class Ruler extends Block {
  constructor(map) {
    super(map, 'Ruler');
    this.lastSignature = '';
    this.waypointRings = [];
  }

  // The pathfinder lives on the Character block — sharing it means the
  // ruler reflects the exact same routing the agent would take.
  pathfinder() {
    const character = this.map.getBlockByName('Character');
    return character?.pathfinder;
  }

  // Override Block#update: the base class gates `_update` on
  // `time.is_running`, but the ruler is purely a measurement overlay
  // and must respond to clicks/hover even when the game is paused.
  // The signature-based short-circuit in `_update` keeps the
  // every-frame cost trivial when nothing changed.
  async update(data) {
    if (!this.children.length) {
      this._create(data);
    } else {
      this._update(data);
    }
  }

  _create() {
    // Cover the entire zoom range. The ruler is a manual measurement
    // tool — at any zoom the player can see, they should also see the
    // path they're measuring.
    const displayRange = { near: 0, far: Infinity };

    const pathGroup = new Group();
    pathGroup.name = 'ruler-path';
    Object.assign(pathGroup.userData, displayRange);

    const material = new LineBasicMaterial({
      color: 0xffffff,
      opacity: 0.8,
      transparent: true,
      // High z so the line draws over systems/sectors. The line itself
      // sits at config.MAP.Z_CHARACTER_NEAR_LINE.
    });
    const geometry = new BufferGeometry().setFromPoints([]);
    this.line = new Line(geometry, material);
    pathGroup.add(this.line);

    const ringsGroup = new Group();
    ringsGroup.name = 'ruler-rings';
    pathGroup.add(ringsGroup);
    this.ringsGroup = ringsGroup;

    this.group.add(pathGroup);
  }

  _update() {
    const ruler = store.state.game.ruler;
    // The cursor's hovered system lives on MapData, not in the store —
    // it's written by showHover every mouse move and reading it here
    // saves a per-mousemove vuex commit just to feed the ruler.
    const hoveredSystemId = ruler.active ? this.map.data.hoveredSystemId : null;
    const signature = `${ruler.active ? 1 : 0}|${ruler.waypoints.join(',')}|${hoveredSystemId ?? ''}`;
    if (signature === this.lastSignature) return;
    this.lastSignature = signature;

    if (!ruler.active || ruler.waypoints.length === 0) {
      this.line.geometry.setFromPoints([]);
      this.line.geometry.computeBoundingSphere();
      this.clearRings();
      store.commit('game/setRulerTravelTime', null);
      return;
    }

    const sequence = [...ruler.waypoints];
    if (hoveredSystemId
        && hoveredSystemId !== sequence[sequence.length - 1]
        && !sequence.includes(hoveredSystemId)) {
      sequence.push(hoveredSystemId);
    }

    const pathfinder = this.pathfinder();
    if (!pathfinder) {
      store.commit('game/setRulerTravelTime', null);
      return;
    }

    const points = [];
    let totalWeight = 0;
    for (let i = 0; i < sequence.length - 1; i += 1) {
      const from = sequence[i];
      const to = sequence[i + 1];
      if (from === to) continue;

      const found = pathfinder.find(from, to);
      // ngraph.path returns the path reversed (target → source). Walk
      // backwards so we draw source → target. Edge weight in the
      // backend is Euclidean distance between system positions (see
      // SpatialGraph.generate_edges), so we recompute it locally from
      // positions instead of fishing it out of the graph's link data.
      for (let j = found.length - 1; j > 0; j -= 1) {
        const s1 = this.map.data.systemsById.get(found[j].id);
        const s2 = this.map.data.systemsById.get(found[j - 1].id);
        if (!s1 || !s2) continue;
        points.push([s1.position.x, s1.position.y]);
        points.push([s2.position.x, s2.position.y]);

        const dx = s2.position.x - s1.position.x;
        const dy = s2.position.y - s1.position.y;
        totalWeight += Math.sqrt(dx * dx + dy * dy);
      }
    }

    this.line.geometry.setFromPoints(arrayToPoints(points, config.MAP.Z_CHARACTER_NEAR_LINE));
    this.line.geometry.computeBoundingSphere();

    this.refreshRings(ruler.waypoints);

    const constant = store.state.game.data.constant?.[0];
    const movementFactor = constant?.character_movement_factor ?? 1;
    const travelTimeTicks = totalWeight * movementFactor;
    store.commit('game/setRulerTravelTime', travelTimeTicks > 0 ? travelTimeTicks : null);
  }

  refreshRings(waypoints) {
    this.clearRings();
    waypoints.forEach((id) => {
      const system = this.map.data.systemsById.get(id);
      if (!system) return;
      const mesh = new Mesh(ringGeometry, ringMaterial);
      mesh.position.set(
        system.position.x,
        system.position.y,
        config.MAP.Z_CHARACTER_NEAR_LINE,
      );
      this.ringsGroup.add(mesh);
      this.waypointRings.push(mesh);
    });
  }

  clearRings() {
    while (this.waypointRings.length) {
      const mesh = this.waypointRings.pop();
      this.ringsGroup.remove(mesh);
      // Geometry/material are module-level shared singletons — don't
      // dispose them.
    }
  }

  clear() {
    this.lastSignature = '';
    if (this.line) {
      this.line.geometry.setFromPoints([]);
      this.line.geometry.computeBoundingSphere();
    }
    this.clearRings();
    store.commit('game/setRulerTravelTime', null);
  }
}
