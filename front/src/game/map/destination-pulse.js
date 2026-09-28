import { Mesh, MeshBasicMaterial, RingGeometry } from 'three';

import config from '@/config';

// A ring that grows and fades, over and over, on one system — shown while
// the player hovers an entry of an agent's plan, so "which order is that?"
// is answered on the map. Colored like the destination system's faction.
//
// One mesh for the map's lifetime, added straight to the scene (outside
// the per-mode groups, whose matrices are frozen). Driven from the map's
// animation loop via tick(); invisible and idle when nothing is hovered.
const PERIOD_MS = 1100;
const geometry = new RingGeometry(0.42, 0.55, 48);

export default class DestinationPulse {
  constructor(map) {
    this.map = map;
    this.systemId = null;
    this.startedAt = 0;
    this.material = new MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0, depthWrite: false });
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
    this.material.color.setHex(colors[faction].hex.lighter);
    this.mesh.position.set(system.position.x, system.position.y, config.MAP.Z_CHARACTER_NEAR_LINE + 0.02);
    this.mesh.userData.systemId = systemId;
    this.mesh.userData.faction = faction;
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

  // Grow 1 → 2.6× while fading out, then start over. Sized with the
  // camera distance so it stays readable when zoomed out.
  tick() {
    if (this.systemId === null) return;
    const phase = ((performance.now() - this.startedAt) % PERIOD_MS) / PERIOD_MS;
    const zoom = Math.max(1, Math.min(8, this.map.camera.position.z / 30));
    const scale = zoom * (1 + 1.6 * phase);
    this.mesh.scale.set(scale, scale, 1);
    this.material.opacity = 0.9 * (1 - phase);
    this.mesh.userData.scale = scale;
  }

  dispose() {
    this.map.scene.remove(this.mesh);
    this.material.dispose();
  }
}
