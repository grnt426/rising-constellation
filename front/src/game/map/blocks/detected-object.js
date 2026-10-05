import config from '@/config';
import store from '@/store';
import { Group } from 'three';
import Block from './block';

import { disposeObjectTree } from '../three-utils';

export default class DetectedObject extends Block {
  constructor(map) {
    super(map, 'DetectedObject');
    // The "Shift+click: report" label shown beside a hovered blip (a DOM
    // element, see showHint).
    this.hint = null;
  }

  _create() {
    this.createDetectedObjects();
    this.resetRepaint();
    this.refresh();
  }

  _update() {
    if (this.map.data.hasToRepaintDetectedObjects) {
      disposeObjectTree(this.getGroupByName('detected-objects'));
      this.group.children = this.group.children.filter((group) => group.name !== 'detected-objects');

      this.createDetectedObjects();
      this.resetRepaint();
      this.refresh();
    }
  }

  resetRepaint() {
    this.map.data.hasToRepaintDetectedObjects = false;
  }

  createDetectedObjects() {
    const detectedObjectsGroup = new Group();
    detectedObjectsGroup.name = 'detected-objects';

    Object.assign(detectedObjectsGroup.userData, { near: 20, far: 200 });

    const ownFaction = store.state.game.playerFaction;

    this.map.data.detectedObjects.forEach((detected) => {
      const { angle, position: { x, y }, faction } = detected;
      const sprite = this.map.materials.sprites.characters[faction].character.clone();
      sprite.position.set(x, y, config.MAP.Z_CHARACTER_NEAR_SPRITE);
      sprite.material = sprite.material.clone();
      sprite.material.rotation = angle;

      // Each blip sits in a named wrapper carrying `gameObject`, the
      // shape the map's hover/click machinery looks for (see
      // system-icons.js for why the wrapper needs a name). Hovering any
      // blip pulses the system it is flying to; another faction's fleet
      // is also `reportable` to the faction (Shift+click, Map#onClick).
      // A blip has no identity on the wire, so `data` is just what is
      // drawn or said of it: whose it is, where, and its next stop.
      const reportable = faction !== ownFaction;
      const blip = new Group();
      blip.name = 'detected-object';
      blip.gameObject = {
        type: 'detected_object',
        data: {
          faction,
          position: { x, y },
          targetSystemId: detected.target_system_id != null ? detected.target_system_id : null,
          reportable,
        },
      };
      sprite.userData.hoverable = true;
      sprite.userData.reportable = reportable;

      blip.add(sprite);
      detectedObjectsGroup.add(blip);
    });

    this.group.add(detectedObjectsGroup);
  }

  // Hover feedback, driven by Map#syncBlipFeedback: a small label by
  // the pointer saying what Shift+click does. Plain DOM rather
  // than text in the scene — at the zoom fleets are spotted from, scene
  // text is a few pixels tall.
  showHint({ x, y }) {
    if (!this.hint) this.hint = this.createHint();
    if (!this.hint) return;

    this.hint.style.left = `${x}px`;
    this.hint.style.top = `${y}px`;
    this.hint.style.display = 'block';
  }

  hideHint() {
    if (this.hint) this.hint.style.display = 'none';
  }

  // Lives beside the canvas, so it leaves the page with the map.
  createHint() {
    const canvas = this.map.renderer && this.map.renderer.domElement;
    if (!canvas || !canvas.parentElement) return null;

    const vm = this.map.vm;
    const hint = document.createElement('div');
    hint.className = 'map-blip-hint';
    hint.style.display = 'none';
    hint.textContent = vm ? vm.$t('galaxy.map.blip.report_hint') : 'shift-click to report';
    canvas.parentElement.appendChild(hint);

    return hint;
  }
}
