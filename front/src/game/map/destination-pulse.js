import { MathUtils, Mesh, MeshBasicMaterial, RingGeometry } from 'three';

import config from '@/config';

// A ring that grows and fades, over and over, around one system — shown
// while the player hovers an entry of an agent's plan, so "which order is
// that?" is answered on the map. It starts right at the edge of the system's
// icon, so it reads as that system rather than a spot near it. Colored like
// the destination system's faction; unowned systems get a soft gray.
//
// One mesh for the map's lifetime, added straight to the scene (outside
// the per-mode groups, whose matrices are frozen). Driven from the map's
// animation loop via tick(); invisible and idle when nothing is hovered.
const PERIOD_MS = 1100;
// The ring grows from the icon's edge to this many times its radius.
const MAX_GROWTH = 1.6;
// Where a system icon's visible edge is: sprites are 0.4 × the type's
// display_size_factor wide (three-utils.js) and their textures
// (public/map/systems) draw out to 87 of 128 px from the center.
const ICON_EDGE_RADIUS = 0.2 * (87 / 128);
// Zoomed far out the icons are dots of a pixel or two: keep the ring
// readable there.
const MIN_START_PX = 4;
const NEUTRAL_GRAY = 0x8c8c8c;
// Inner radius 1: scaled to the icon's edge.
const geometry = new RingGeometry(1, 1.3, 48);

export default class DestinationPulse {
  constructor(map) {
    this.map = map;
    this.systemId = null;
    this.startedAt = 0;
    this.iconRadius = ICON_EDGE_RADIUS;
    this.sizeFactors = new Map(map.gameData.stellar_system.map((s) => [s.key, s.display_size_factor]));
    this.material = new MeshBasicMaterial({ color: NEUTRAL_GRAY, transparent: true, opacity: 0, depthWrite: false });
    this.mesh = new Mesh(geometry, this.material);
    this.mesh.name = 'queue-destination-pulse';
    this.mesh.visible = false;
    this.mesh.renderOrder = 10;
    map.scene.add(this.mesh);
  }

  show(systemId, colors) {
    const system = this.map.data.systemsById.get(systemId);
    if (!system) {
      this.hide();
      return;
    }

    const faction = colors[system.faction] ? system.faction : 'neutral';
    this.material.color.setHex(faction === 'neutral' ? NEUTRAL_GRAY : colors[faction].hex.lighter);
    this.iconRadius = ICON_EDGE_RADIUS * (this.sizeFactors.get(system.type) || 1);
    // just above the star sprites (a sprite's quad reaches past its icon
    // and would hide the ring behind it), under labels and agents
    this.mesh.position.set(system.position.x, system.position.y, config.MAP.Z_SYSTEM_NEAR_STAR + 0.05);
    this.mesh.userData.systemId = systemId;
    this.mesh.userData.faction = faction;
    this.mesh.userData.iconRadius = this.iconRadius;
    this.systemId = systemId;
    this.startedAt = performance.now();
    this.mesh.visible = true;
    this.tick();
  }

  hide() {
    this.systemId = null;
    this.mesh.visible = false;
    this.mesh.userData.systemId = null;
  }

  // Grow from the icon's edge to MAX_GROWTH × while fading out, then start
  // over.
  tick() {
    if (this.systemId === null) return;
    const phase = ((performance.now() - this.startedAt) % PERIOD_MS) / PERIOD_MS;
    const start = Math.max(this.iconRadius, MIN_START_PX * this.worldPerPixel());
    const scale = start * (1 + (MAX_GROWTH - 1) * phase);
    this.mesh.scale.set(scale, scale, 1);
    this.material.opacity = 0.8 * (1 - phase);
    this.mesh.userData.scale = scale;
  }

  // World units per screen pixel on the galaxy plane.
  worldPerPixel() {
    const { camera, renderer } = this.map;
    const height = renderer.domElement.clientHeight;
    if (!height) return 0;
    return (2 * camera.position.z * Math.tan(MathUtils.degToRad(camera.fov / 2))) / height;
  }

  dispose() {
    this.map.scene.remove(this.mesh);
    this.material.dispose();
  }
}
