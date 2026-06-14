import store from '@/store';

import { Group } from 'three';
import { colorsFactory } from '../three-utils';

// not to be confused with `THREE.Group`
export default class Block {
  constructor(map, name) {
    this.map = map;
    this.log = map.log;
    // `THREE.Group` has `.visible`, `Block` has `.shown`
    this.shown = false;
    this.group = new Group();
    this.name = name;
    this.group.name = this.name;

    this.colors = colorsFactory(this.map);

    /*
    [{far: Number, near: Number, cb: [(): void]}]
    */
    this.animationCallbacks = [];

    // `progress` used to derive in-flight position from
    // `(Date.now() + timeOffset) - startedAt`, anchored on the server's
    // monotonic clock. That broke across BEAM restart: actions queued
    // before a deploy carry the OLD BEAM's monotonic `started_at`, and
    // the post-restart `timeOffset` references the NEW BEAM's clock, so
    // elapsed went sharply negative until those actions completed.
    // Authoritative progress lives in `remainingTime` (decremented per
    // tick by the engine's delta), which survives restarts cleanly.
    // Smoothness drops from frame rate to server-broadcast cadence —
    // acceptable trade for not rendering ships at extrapolated-backward
    // positions until their pre-restart action finishes.
    this.progress = (startedAt, remainingTime, totalTime) => {
      if (!startedAt) return 0;
      if (remainingTime <= 0) return 1;
      if (totalTime <= 0) return 1;
      return (totalTime - remainingTime) / totalTime;
    };
  }

  get children() {
    return this.group.children;
  }

  getGroupByName(name) {
    return this.find((group) => group.name === name);
  }

  find(predicate) {
    return this.group.children.find(predicate);
  }

  async _create() {
    throw new Error('not implemented');
  }

  async _update() {
    throw new Error('not implemented');
  }

  /**
   * Creates or updates this.group
   */
  async update(data) {
    if (!this.children.length) {
      this.log('creating');
      this._create(data);
    } else if (this.shown && store.state.game.time.is_running) {
      this._update(data);
    }
  }

  refresh() {
    this.onZ(this.map.camera.position.z);
  }

  /**
   * Called whenever `z` changes
   * @param {number} z Altitude on the Z axis
   */
  onZ(z) {
    const maxZoomedOut = Math.abs(z - this.map.maxZ) < 0.2;
    // will be true if any object inside this group is visible
    let visible = false;

    this.group.children.forEach((group) => {
      if (typeof group.userData.near !== 'number' || typeof group.userData.far !== 'number') {
        return;
      }
      if (z >= group.userData.near && z <= group.userData.far) {
        group.visible = true;
        visible = group.name;
      } else if (group.visible === true && !maxZoomedOut) {
        group.visible = false;
      }
    });

    this.shown = visible;
    // we iterate on direct children of this.group and show/hide
    // each depending on comparing z with their .near/.far
  }
}
