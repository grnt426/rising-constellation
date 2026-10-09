import {
  FrontSide,
  Group,
  InstancedMesh,
  Mesh,
  MeshBasicMaterial,
  Object3D,
  PlaneGeometry,
} from 'three';
import { MeshLine, MeshLineMaterial } from 'three.meshline';

import config from '@/config';
import store from '@/store';
import { disposeObjectTree } from '../three-utils';

import Block from './block';

// Far zoom only: the faction's gateway links, each drawn as a faint lane
// between its two systems with a few ships shuttling along it both ways.
// Only games with the faction government have links, and a faction only
// knows its own (`faction.government.gateway_links`).

// The lane. Thin enough to read as a hint under the system dots.
const LANE_WIDTH = 0.22;
const LANE_OPACITY = 0.22;
// A link still forming or coming down: the lane alone, dimmer.
const LANE_OPACITY_PENDING = 0.1;
// Lanes stop short of the systems they join (the dot and its halo).
const LANE_MARGIN = 2.2;

// The ships: small rectangles, one size whatever the lane.
const SHIP_LENGTH = 1.5;
const SHIP_WIDTH = 0.42;
const SHIP_OPACITY = 0.55;
// How far each direction rides from the lane's axis.
const SHIP_SIDE = 0.34;
// World units per second, and the gap between two ships going the same
// way. A ship crossing while another transits (`busy`) goes faster.
const SHIP_SPEED = 9;
const SHIP_SPEED_BUSY = 22;
const SHIP_SPACING = 46;

const shipGeometry = new PlaneGeometry(SHIP_LENGTH, SHIP_WIDTH);
const _dummy = new Object3D();

export default class Gateway extends Block {
  constructor(map) {
    super(map, 'Gateway');
    this.lastKey = null;
    // One entry per ship: the lane it rides and where along it.
    this.ships = [];
    this.shipMesh = null;
    this.lastFrameAt = null;

    // Ships move whether or not the game clock runs (a paused game still
    // shows where the lanes are), so they ride the animation callbacks,
    // which the map calls every frame the camera is in range.
    this.animationCallbacks.push({ near: 200, far: Infinity, cb: () => this.animate() });
  }

  // Links change while the game is paused too (a restore, a founding):
  // like SystemIcons, repaint on a key rather than on the game clock.
  async update(data) {
    if (!this.children.length) {
      this._create(data);
    } else {
      this._update(data);
    }
  }

  _create() {
    this.lanes = new Group();
    this.lanes.name = 'gateway-lanes';
    Object.assign(this.lanes.userData, { near: 200, far: this.map.maxZ });
    this.group.add(this.lanes);
    this._update();
  }

  _update() {
    const links = this.links();
    const key = links
      .map((l) => `${l.id}:${l.status}:${l.transit ? 1 : 0}:${l.endpoints.map((e) => e.system_id).join('-')}`)
      .join('|');
    if (key === this.lastKey) return;
    this.lastKey = key;

    this.rebuild(links);
  }

  links() {
    const { faction } = store.state.game;
    const government = faction && faction.government;
    return (government && government.gateway_links) || [];
  }

  rebuild(links) {
    // dispose child by child: handing the group itself to
    // disposeObjectTree would also detach it from the block a tick later
    this.lanes.children.slice().forEach((child) => {
      this.lanes.remove(child);
      // the ships' geometry is shared across rebuilds
      disposeObjectTree(child, {
        removeFromParent: false,
        destroyGeometry: child !== this.shipMesh,
        destroyMaterial: true,
      });
    });
    this.ships = [];
    this.shipMesh = null;

    const playerFaction = store.state.game.player.faction;
    const colors = this.colors[playerFaction] || this.colors.neutral;

    const lanes = links
      .map((link) => this.lane(link))
      .filter((lane) => lane !== null);

    lanes.forEach((lane) => {
      const geometry = new MeshLine();
      geometry.setPoints([
        lane.from.x, lane.from.y, config.MAP.Z_GATEWAY_LANE,
        lane.to.x, lane.to.y, config.MAP.Z_GATEWAY_LANE,
      ]);
      const material = new MeshLineMaterial({
        color: colors.hex.lighter,
        transparent: true,
        opacity: lane.linked ? LANE_OPACITY : LANE_OPACITY_PENDING,
        lineWidth: LANE_WIDTH,
        depthWrite: false,
      });
      const line = new Mesh(geometry, material);
      // Default render order on purpose: the sky backdrop is itself a
      // transparent mesh, and anything ordered before it is painted over.
      // The lane sits under the system dots by depth (Z_GATEWAY_LANE).
      line.matrixAutoUpdate = false;
      line.updateMatrix();
      this.lanes.add(line);

      if (!lane.linked) return;

      // ships in both directions, evenly spread, the two directions half
      // a gap apart so they do not cross in step
      const perDirection = Math.max(1, Math.round(lane.length / SHIP_SPACING));
      for (let i = 0; i < perDirection; i += 1) {
        this.ships.push({ lane, direction: 1, offset: i / perDirection });
        this.ships.push({ lane, direction: -1, offset: (i + 0.5) / perDirection });
      }
    });

    if (this.ships.length > 0) {
      const material = new MeshBasicMaterial({
        color: colors.hex.lighter,
        transparent: true,
        opacity: SHIP_OPACITY,
        side: FrontSide,
        depthWrite: false,
      });
      this.shipMesh = new InstancedMesh(shipGeometry, material, this.ships.length);
      // instances span the galaxy: the unit geometry's bounds mean nothing
      this.shipMesh.frustumCulled = false;
      this.shipMesh.matrixAutoUpdate = false;
      this.shipMesh.updateMatrix();
      this.lanes.add(this.shipMesh);
      this.placeShips(0);
    }

    this.lanes.matrixAutoUpdate = false;
    this.lanes.updateMatrix();
    this.refresh();
  }

  // A link as a segment between its two systems, or null when the map
  // does not know one of them.
  lane(link) {
    const [a, b] = link.endpoints.map((e) => this.map.data.systemsById.get(e.system_id));
    if (!a || !b) return null;

    const dx = b.position.x - a.position.x;
    const dy = b.position.y - a.position.y;
    const span = Math.sqrt((dx * dx) + (dy * dy));
    if (span <= LANE_MARGIN * 2) return null;

    const ux = dx / span;
    const uy = dy / span;

    return {
      from: { x: a.position.x + (ux * LANE_MARGIN), y: a.position.y + (uy * LANE_MARGIN) },
      to: { x: b.position.x - (ux * LANE_MARGIN), y: b.position.y - (uy * LANE_MARGIN) },
      ux,
      uy,
      length: span - (LANE_MARGIN * 2),
      angle: Math.atan2(dy, dx),
      linked: link.status === 'linked',
      busy: !!link.transit,
      // each ship's progress along the lane, shared by its two directions
      progress: 0,
    };
  }

  animate() {
    if (!this.shipMesh || !this.lanes.visible) {
      this.lastFrameAt = null;
      return;
    }

    const now = performance.now();
    // a tab left in the background comes back with one huge frame: cap it
    const elapsed = this.lastFrameAt === null ? 0 : Math.min((now - this.lastFrameAt) / 1000, 0.1);
    this.lastFrameAt = now;
    this.placeShips(elapsed);
  }

  placeShips(elapsed) {
    const moved = new Set();

    this.ships.forEach((ship, i) => {
      const { lane } = ship;
      if (!moved.has(lane)) {
        moved.add(lane);
        const speed = lane.busy ? SHIP_SPEED_BUSY : SHIP_SPEED;
        lane.progress = (lane.progress + ((speed * elapsed) / lane.length)) % 1;
      }

      const t = (lane.progress + ship.offset) % 1;
      const along = (ship.direction === 1 ? t : 1 - t) * lane.length;
      // each direction keeps to its right of the axis
      const side = SHIP_SIDE * ship.direction;

      _dummy.position.set(
        lane.from.x + (lane.ux * along) + (lane.uy * side),
        lane.from.y + (lane.uy * along) - (lane.ux * side),
        config.MAP.Z_GATEWAY_LANE,
      );
      _dummy.rotation.set(0, 0, lane.angle);
      _dummy.updateMatrix();
      this.shipMesh.setMatrixAt(i, _dummy.matrix);
    });

    this.shipMesh.instanceMatrix.needsUpdate = true;
  }
}
