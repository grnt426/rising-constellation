import { MathUtils, Mesh, MeshBasicMaterial, RingGeometry } from 'three';

import config from '@/config';

// Rings that grow and fade, over and over, around one system — shown
// while the player hovers an entry of an agent's plan, so "which order is
// that?" is answered on the map. Colored like the destination system's
// faction; unowned systems get a soft gray.
//
// A system on the map is more than its dot: its texture draws a halo
// around the dot (and owned systems a second, faction-colored one), out to
// the edge of the sprite. A ring inside that looks like one more halo, so
// the rings start where the sprite ends and travel well clear of it — two
// of them, half a period apart, so one is always on its way out.
//
// Meshes for the map's lifetime, added straight to the scene (outside the
// per-mode groups, whose matrices are frozen). Driven from the map's
// animation loop via tick(); invisible and idle when nothing is hovered.
const PERIOD_MS = 1400;
const RING_COUNT = 2;
// The rings grow from the sprite's edge to this many times its radius…
const MAX_GROWTH = 2.6;
// …and by at least this much on screen: zoomed out, a multiple of a
// few-pixel icon is still only a few pixels.
const MIN_GROWTH_PX = 14;
// Where everything drawn for a system ends: sprites are 0.4 × the type's
// display_size_factor wide (three-utils.js) and the textures
// (public/map/systems) fade out at their very edge.
const SPRITE_RADIUS = 0.2;
// Zoomed far out the icons are dots of a pixel or two: keep the rings
// readable there.
const MIN_START_PX = 6;
const PEAK_OPACITY = 0.95;
const NEUTRAL_GRAY = 0x8c8c8c;
// Inner radius 1: scaled to the sprite's edge.
const geometry = new RingGeometry(1, 1.18, 64);

export default class DestinationPulse {
  constructor(map) {
    this.map = map;
    this.systemId = null;
    this.startedAt = 0;
    this.spriteRadius = SPRITE_RADIUS;
    this.sizeFactors = new Map(map.gameData.stellar_system.map((s) => [s.key, s.display_size_factor]));
    // the first ring carries the state (userData); the others echo it
    this.rings = Array.from({ length: RING_COUNT }, (_, i) => {
      const material = new MeshBasicMaterial({ color: NEUTRAL_GRAY, transparent: true, opacity: 0, depthWrite: false });
      const mesh = new Mesh(geometry, material);
      mesh.name = i === 0 ? 'queue-destination-pulse' : `queue-destination-pulse-echo-${i}`;
      mesh.visible = false;
      mesh.renderOrder = 10;
      map.scene.add(mesh);
      return mesh;
    });
    [this.mesh] = this.rings;
  }

  show(systemId, colors) {
    const system = this.map.data.systemsById.get(systemId);
    if (!system) {
      this.hide();
      return;
    }

    const faction = colors[system.faction] ? system.faction : 'neutral';
    const color = faction === 'neutral' ? NEUTRAL_GRAY : colors[faction].hex.lighter;
    this.spriteRadius = SPRITE_RADIUS * (this.sizeFactors.get(system.type) || 1);
    this.rings.forEach((ring) => {
      ring.material.color.setHex(color);
      // just above the star sprites (a sprite's quad would hide a ring
      // behind it), under labels and agents
      ring.position.set(system.position.x, system.position.y, config.MAP.Z_SYSTEM_NEAR_STAR + 0.05);
      ring.visible = true;
    });
    this.mesh.userData.systemId = systemId;
    this.mesh.userData.faction = faction;
    this.mesh.userData.spriteRadius = this.spriteRadius;
    this.systemId = systemId;
    this.startedAt = performance.now();
    this.tick();
  }

  hide() {
    this.systemId = null;
    this.rings.forEach((ring) => { ring.visible = false; });
    this.mesh.userData.systemId = null;
  }

  // Each ring grows from the sprite's edge while fading out, then starts
  // over; ring i runs i/RING_COUNT of a period behind the first.
  tick() {
    if (this.systemId === null) return;
    const elapsed = performance.now() - this.startedAt;
    const perPixel = this.worldPerPixel();
    const start = Math.max(this.spriteRadius, MIN_START_PX * perPixel);
    const growth = Math.max(start * (MAX_GROWTH - 1), MIN_GROWTH_PX * perPixel);

    this.rings.forEach((ring, i) => {
      const t = (elapsed / PERIOD_MS) - (i / RING_COUNT);
      // an echo waits for its turn on the first pass
      const phase = t < 0 ? null : t % 1;
      const scale = start + growth * (phase || 0);
      ring.scale.set(scale, scale, 1);
      ring.material.opacity = phase === null ? 0 : PEAK_OPACITY * (1 - phase) ** 1.2;
    });
    this.mesh.userData.start = start;
    this.mesh.userData.end = start + growth;
  }

  // World units per screen pixel on the galaxy plane.
  worldPerPixel() {
    const { camera, renderer } = this.map;
    const height = renderer.domElement.clientHeight;
    if (!height) return 0;
    return (2 * camera.position.z * Math.tan(MathUtils.degToRad(camera.fov / 2))) / height;
  }

  dispose() {
    this.rings.forEach((ring) => {
      this.map.scene.remove(ring);
      ring.material.dispose();
    });
  }
}
