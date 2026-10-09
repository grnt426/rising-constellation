import {
  AmbientLight,
  Raycaster,
  Vector2,
  Vector3,
} from 'three';

import { MapControls } from 'three/examples/jsm/controls/OrbitControls';

import Stats from 'stats-js';
import TWEEN from '@tweenjs/tween.js';
import store from '@/store';
import { serverNow } from '@/game/clock';
import viewport from '@/utils/viewport';
import config from '@/config';
import eventBus from '@/plugins/event-bus';
import { mapProbe } from '@/game/debug/collector';
import { reportFleet } from '@/game/components/chat/reportSighting';
import { loadFonts, materialsFactory, colorsFactory } from './three-utils';
import DestinationPulse from './destination-pulse';
import { Radar, Sector, System, SystemIcons, Blackhole, Skydome, Character, DetectedObject, Ruler, Gateway, SystemGlyphs } from './blocks';

// Player-icon picker gesture thresholds. 500ms is the common
// long-press convention (Material/iOS); 8px lets a small finger /
// mouse wobble during the hold not cancel the trigger.
const ICON_PICKER_LONG_PRESS_MS = 500;
const ICON_PICKER_JITTER_PX = 8;

// Pan-vs-click slop: max down→up drift for a release to still count as
// a click. A finger tap (and even a fast mouse click) drifts a few
// pixels between down and up; exact-equality rejected every touch tap.
const TAP_SLOP_PX = 8;

// Phones, multi-move mode: a second tap this soon and this close to the
// first is a double-tap (it ends the mode). The first tap has already
// acted by then — same trade as the agent bubble's double-tap.
const DOUBLE_TAP_MS = 320;
const DOUBLE_TAP_SLOP_PX = 40;
// How long a system tapped in multi-move mode keeps pulsing.
const MULTI_MOVE_FLASH_MS = 1400;
// Taps further apart than this have all reached the store: see
// multiMoveOrigin.
const MULTI_MOVE_CHAIN_MS = 10000;

let currentlyHoveredObject;

export default class Map {
  constructor({ scene, camera, renderer, $root, vm, data, fov, $socket, $toasted }) {
    this.isDev = config.MODE === 'development';
    this.log = this.isDev ? console.log : () => {};
    this.scene = scene;
    // three r126's WebGLRenderer.render() calls scene.updateMatrixWorld()
    // every frame, and the scene root's default matrixAutoUpdate=true
    // marks the root dirty each time — which force-cascades
    // multiplyMatrices through EVERY descendant, including the frozen
    // system subtrees (their matrixAutoUpdate=false only skips the local
    // compose, not a forced parent-driven multiply). At 6k+ systems that
    // was ~25ms/frame of pure matrix churn. Freezing the root kills the
    // cascade; it stays safe because updateMatrixWorld still visits every
    // child, so a dirty flag set anywhere deeper (label flips, moving
    // characters) is still honored.
    this.scene.matrixAutoUpdate = false;
    this.camera = camera;
    this.camera.updateProjectionMatrix();

    this.$root = $root;
    this.$socket = $socket;
    this.$toasted = $toasted;
    this.vm = vm;
    this.data = data;
    this.renderer = renderer;
    this.requestAnimationFrame = null;
    // Debug report: how far init() got, and frames actually rendered.
    this.initStage = 'created';
    this.frameCount = 0;
    this.inSystem = null;
    this.moving = false;
    this.hovercaster = new Raycaster();
    this.assetFailureShown = false;
    this.destroyed = false;
    this.windowHeight = 100;
    this.windowWidth = 100;

    this.onWindowResize();
    // MapControls (three r126) handles touch pan/pinch itself but never
    // sets touch-action, so the browser's own scroll/zoom gestures
    // compete with the map's on mobile.
    renderer.domElement.style.touchAction = 'none';
    this.controls = new MapControls(this.camera, renderer.domElement);
    this.controls.enableKeys = true;
    this.controls.keyPanSpeed = 30;
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.2;

    // compute map dimensions
    this.size = store.state.game.galaxy.size;
    const halfSize = this.size / 2;

    const boundaries = [{ x: Infinity, y: Infinity }, { x: -Infinity, y: -Infinity }];
    this.data.systems.forEach(({ position: { x, y } }) => {
      if (x < boundaries[0].x) boundaries[0].x = x;
      if (x > boundaries[1].x) boundaries[1].x = x;
      if (y < boundaries[0].y) boundaries[0].y = y;
      if (y > boundaries[1].y) boundaries[1].y = y;
    });

    /*
    Trigonometry: tan(⍺) = opposite/adjacent
      fov/2 = ⍺
             /|
            / | adjacent = z
           /  |
          /___|
      opposite = halfSize
    */
    this.maxZ = halfSize / Math.tan((fov / 2) * (Math.PI / 180));
    this.maxZ = Math.max(this.maxZ, 330);
    this.minZ = 30;
    this.initialZ = config.MAP.Z_DEFAULT;
    // last Z, to be able to get back to it after a context switch or a move
    this.lastZ = config.MAP.Z_DEFAULT;
    // in a system, Z at which the user is 'locked'
    this.systemZ = 4;

    // constrain pan to boundaries
    const minPan = new Vector3(boundaries[0].x, boundaries[0].y, 0);
    const maxPan = new Vector3(boundaries[1].x, boundaries[1].y, 20);
    const v = new Vector3();
    this.constrainPan = () => {
      v.copy(this.controls.target);
      this.controls.target.clamp(minPan, maxPan);
      v.sub(this.controls.target);
      this.camera.position.sub(v);
    };
    this.controls.addEventListener('change', this.constrainPan.bind(this));

    // listen to map position update
    this.controls.addEventListener('end', () => {
      store.commit('game/updateMapPosition', {
        x: Math.round(this.camera.position.x),
        y: Math.round(this.camera.position.y),
        z: Math.round(this.camera.position.z),
      });
    });

    // only enable for tests
    this.controls.screenSpacePanning = true;
    this.controls.enableRotate = this.isDev;
    this.controls.addEventListener('change', this.onControlChange.bind(this));

    this.mouse = new Vector2(1, 1);
    this.mouseLastPosition = {};
    // Touch bookkeeping: a pinch (two pointers down at any point in the
    // gesture) must never resolve as a tap on release, and the
    // contextmenu Android fires mid-long-press must not re-run the
    // click path on top of the pointerup that follows.
    this.activePointers = new Set();
    this.sawMultiTouch = false;
    this.lastPointerType = 'mouse';
    // Phones: a held press that opened the action wheel (see onLongPress),
    // and the tap that closed it (see onActionRadialClosed).
    this.longPressTimer = null;
    this.longPressFired = false;
    this.actionRadialOpen = false;
    this.swallowedPointerId = null;
    this.multiMoveChain = null;
    this.lastMultiMoveTap = null;
    // Hover feedback of radar blips (see syncBlipFeedback).
    this.pickingHover = false;
    this.blipPulseTarget = null;
    this.onMouseMoveBound = this.onMouseMove.bind(this);
    this.onMouseDownBound = this.onMouseDown.bind(this);
    this.onMouseUpBound = this.onMouseUp.bind(this);
    this.onDoubleClickBound = this.onDoubleClick.bind(this);
    this.onPointerMoveBound = this.onPointerMove.bind(this);
    this.onPointerCancelBound = this.onPointerCancel.bind(this);
    document.addEventListener('mousemove', this.onMouseMoveBound, false);
    this.renderer.domElement.addEventListener('pointerdown', this.onMouseDownBound, true);
    this.renderer.domElement.addEventListener('pointerup', this.onMouseUpBound, true);
    this.renderer.domElement.addEventListener('pointermove', this.onPointerMoveBound, true);
    this.renderer.domElement.addEventListener('pointercancel', this.onPointerCancelBound, true);
    this.renderer.domElement.addEventListener('contextmenu', this.onMouseUpBound, true);
    this.renderer.domElement.addEventListener('dblclick', this.onDoubleClickBound, true);

    const ambientLight = new AmbientLight(0xffffff);
    this.scene.add(ambientLight);

    // initial camera position
    const { x, y } = this.playerSystems.length ? this.playerSystems[0].position : { x: halfSize, y: halfSize };
    this.setCameraPosition(x, y, this.initialZ);
    this.camera.zoom = 1;
    this.blocks = [];
    this.materials = materialsFactory(this);

    // $root outlives every Map instance, so each $on registered here
    // must be $off'd in destroy() or it accumulates across mount cycles
    // (Game.vue remounts → fresh Map → another anonymous listener on the
    // same event). Stale listeners then re-fire every emit, e.g. one
    // infiltrate click → N+1 add_character_actions pushes → N+1 queued
    // infiltrates. We bind each handler once here so the same reference
    // is available to both $on and $off.
    this.onCenterToSystem = this.onCenterToSystem.bind(this);
    this.onCenterToCharacter = this.onCenterToCharacter.bind(this);
    this.onCenterToPosition = this.onCenterToPosition.bind(this);
    this.onHidePath = this.onHidePath.bind(this);
    this.onAddAction = this.onAddAction.bind(this);
    this.onPulseSystem = this.onPulseSystem.bind(this);
    this.onUnpulseSystem = this.onUnpulseSystem.bind(this);
    this.onEnterSystem = this.onEnterSystem.bind(this);
    this.onExitSystem = this.onExitSystem.bind(this);
    this.onActionRadialOpened = this.onActionRadialOpened.bind(this);
    this.onActionRadialClosed = this.onActionRadialClosed.bind(this);

    eventBus.$on('map:action-radial:opened', this.onActionRadialOpened);
    eventBus.$on('map:action-radial:closed', this.onActionRadialClosed);
    this.$root.$on('map:centerToSystem', this.onCenterToSystem);
    this.$root.$on('map:centerToCharacter', this.onCenterToCharacter);
    this.$root.$on('map:centerToPosition', this.onCenterToPosition);
    this.$root.$on('map:hidePath', this.onHidePath);
    this.$root.$on('map:addAction', this.onAddAction);
    this.$root.$on('map:pulseSystem', this.onPulseSystem);
    this.$root.$on('map:unpulseSystem', this.onUnpulseSystem);
  }

  get playerSystems() {
    return store.state.game.player.stellar_systems;
  }

  get playerDominions() {
    return store.state.game.player.dominions;
  }

  get gameData() {
    return store.state.game.data;
  }

  async init() {
    // FPS meter (stats-js): opt-in even in dev — run
    // `localStorage.setItem('rc:fps', '1')` in the console and reload
    // to get it back. Always-on it just sat over the top-left of the
    // UI (especially bad on phones).
    let stats = { begin() { }, end() { } };
    if (this.isDev && window.localStorage && localStorage.getItem('rc:fps') === '1') {
      stats = new Stats();
      stats.setMode(0);
      stats.domElement.setAttribute('id', 'threejs-stats');
      document.body.appendChild(stats.domElement);
    }

    // Debug report timings (mapProbe) ride on this loop's own work: two
    // performance.now() reads per block and per frame, no extra work.
    const initStart = performance.now();
    this.initStage = 'fonts';
    this.fonts = await loadFonts((url, error) => this.reportAssetFailure(url, error));
    mapProbe.stage('fontsMs', performance.now() - initStart);

    this.initStage = 'scene';
    const sceneStart = performance.now();
    this.sceneInit();
    // synchronous part: builds every system's meshes up front
    mapProbe.stage('sceneMs', performance.now() - sceneStart);
    this.destinationPulse = new DestinationPulse(this);

    this.mapUpdate = true;
    this.initStage = 'running';
    const animate = (ts) => {
      // always call this, otherwise tweens don't finish
      TWEEN.update();

      // don't update the map while we're in a system because it's hidden behind
      if (!this.mapUpdate) {
        mapProbe.idle(ts);
        this.requestAnimationFrame = requestAnimationFrame(animate);
        return;
      }

      stats.begin();
      const frameStart = performance.now();
      this.controls.update();
      const { z } = this.camera.position;
      this.blocks.forEach((block) => {
        const blockStart = performance.now();
        // block.update() is async but we don't want to wait for it to be done!
        block.update();
        block.animationCallbacks.forEach(({ far, near, cb }) => {
          if (z < far && z >= near) {
            cb();
          }
        });
        mapProbe.block(block.name, performance.now() - blockStart);
      });

      if (this.destinationPulse) this.destinationPulse.tick();
      const renderStart = performance.now();
      this.renderer.render(this.scene, this.camera);
      const frameEnd = performance.now();
      this.frameCount += 1;
      if (this.frameCount === 1) mapProbe.stage('toFirstFrameMs', frameEnd - initStart);
      mapProbe.frame(ts, frameEnd - frameStart, frameEnd - renderStart, z, this.renderer.info.render);
      stats.end();

      this.requestAnimationFrame = requestAnimationFrame(animate);
    };

    animate();
  }

  // A map file (sprite, font, skydome) still failed after asset-loader.js's
  // retries. A map missing its graphics looks like a rendering bug, so say
  // so, once per map, with a way out: a reload re-requests everything.
  reportAssetFailure(url, error) {
    console.warn(`[map] ${url} failed to load after retries`, error);
    if (this.assetFailureShown || this.destroyed) return;
    this.assetFailureShown = true;

    const { vm } = this;
    this.$toasted.error(vm.$t('galaxy.map.assets_failed.message'), {
      duration: null,
      action: [
        {
          text: vm.$t('galaxy.map.assets_failed.reload'),
          onClick: () => window.location.reload(),
        },
        {
          text: vm.$t('galaxy.map.assets_failed.dismiss'),
          onClick: (e, toast) => toast.goAway(0),
        },
      ],
    });
  }

  destroy() {
    this.destroyed = true;

    // The stats panel is opt-in now (see init) — it may not exist.
    const stats = document.getElementById('threejs-stats');
    if (stats && stats.parentNode) {
      stats.parentNode.removeChild(stats);
    }

    this.unbindEvents();

    // Pair with the $on calls in the constructor. See the comment there
    // for why omitting these duplicates queued actions on remount.
    this.$root.$off('map:centerToSystem', this.onCenterToSystem);
    this.$root.$off('map:centerToCharacter', this.onCenterToCharacter);
    this.$root.$off('map:centerToPosition', this.onCenterToPosition);
    this.$root.$off('map:hidePath', this.onHidePath);
    this.$root.$off('map:addAction', this.onAddAction);
    this.$root.$off('map:pulseSystem', this.onPulseSystem);
    this.$root.$off('map:unpulseSystem', this.onUnpulseSystem);
    eventBus.$off('map:action-radial:opened', this.onActionRadialOpened);
    eventBus.$off('map:action-radial:closed', this.onActionRadialClosed);
    this.cancelLongPress();
    clearTimeout(this.flashTimer);
    if (this.destinationPulse) this.destinationPulse.dispose();

    // Release the GL context. Browsers cap live WebGL contexts (~16);
    // without this, each game re-entry allocated a fresh renderer while
    // the old context lingered until GC felt like it.
    if (this.renderer) {
      this.renderer.dispose();
      this.renderer.forceContextLoss();
    }
  }

  bindEvents() {
    setTimeout(() => { this.onWindowResize(); }, 0);
    this.$root.$on('enterSystem', this.onEnterSystem);
    this.$root.$on('exitSystem', this.onExitSystem);
    // Bound once to a stable ref: `removeEventListener` with a fresh
    // `.bind()` result never matches, which pinned every previous Map
    // instance (scene, renderer, all geometry) in memory via the leaked
    // resize listener — one whole THREE graph per game re-entry.
    this.onWindowResizeBound = this.onWindowResize.bind(this);
    window.addEventListener('resize', this.onWindowResizeBound, false);
  }

  unbindEvents() {
    cancelAnimationFrame(this.requestAnimationFrame);
    window.removeEventListener('resize', this.onWindowResizeBound);
    document.removeEventListener('change', this.onControlChange);
    document.removeEventListener('mousemove', this.onMouseMoveBound);
    this.renderer.domElement.removeEventListener('pointerdown', this.onMouseDownBound);
    this.renderer.domElement.removeEventListener('pointerup', this.onMouseUpBound);
    this.renderer.domElement.removeEventListener('pointermove', this.onPointerMoveBound);
    this.renderer.domElement.removeEventListener('pointercancel', this.onPointerCancelBound);
    this.renderer.domElement.removeEventListener('contextmenu', this.onMouseUpBound);
    this.renderer.domElement.removeEventListener('dblclick', this.onDoubleClickBound);
    this.controls.removeEventListener('change', this.constrainPan);

    this.$root.$off('enterSystem', this.onEnterSystem);
    this.$root.$off('exitSystem', this.onExitSystem);
  }

  // $root event-bus handlers. Defined as instance methods (not arrow
  // functions in the constructor) so the constructor can bind each once
  // to a stable reference that destroy() can pass to $root.$off().
  onCenterToSystem(systemId) {
    this.centerToSystem(systemId, config.MAP.Z_DEFAULT, 600);
  }

  onCenterToCharacter(character) {
    if (character.system) {
      this.centerToSystem(character.system, config.MAP.Z_DEFAULT, 600);
    } else {
      const speedFactor = store.getters['game/effectiveSpeedFactor'];

      const action = character.actions.queue[0];
      const p1 = action.data.source_position;
      const p2 = action.data.target_position;

      // Clock-based, matching block.js's progress formula. Server-side
      // `Character.Agent.on_call({:start, _})` rebases every in-flight
      // action's `started_at` to the live monotonic frame at instance
      // start, so this stays correct across BEAM restarts. See block.js.
      const elapsed = (serverNow(store.state.game.time) ?? action.started_at) - action.started_at;
      const progress = (speedFactor * elapsed) / (180000 * action.total_time);

      const pX = p1.x + progress * (p2.x - p1.x);
      const pY = p1.y + progress * (p2.y - p1.y);

      this.move(pX, pY, config.MAP.Z_DEFAULT, 600, 'centerToCharacter');
    }
  }

  // A bare point of the map (a sighting's last known position).
  onCenterToPosition(position) {
    if (!position || !Number.isFinite(position.x) || !Number.isFinite(position.y)) return;
    this.move(position.x, position.y, config.MAP.Z_DEFAULT, 600, 'centerToPosition');
  }

  onHidePath() {
    const character = this.getBlockByName('Character');
    character.hideHoverPath();
  }

  onAddAction(action, payload) {
    this.addCharacterAction(action, payload);
  }

  // Plan editor hover (AgentPlan.vue): pulse the destination system.
  onPulseSystem(systemId) {
    if (!this.destinationPulse) return;
    if (!this.pulseColors) this.pulseColors = colorsFactory();
    this.destinationPulse.show(systemId, this.pulseColors);
  }

  onUnpulseSystem() {
    if (this.destinationPulse) this.destinationPulse.hide();
  }

  // Pulse a system for a moment (a tap that queued a move there).
  flashSystem(systemId) {
    this.onPulseSystem(systemId);
    clearTimeout(this.flashTimer);
    this.flashTimer = setTimeout(() => {
      if (this.destinationPulse && this.destinationPulse.systemId === systemId) this.destinationPulse.hide();
    }, MULTI_MOVE_FLASH_MS);
  }

  onActionRadialOpened() {
    this.actionRadialOpen = true;
  }

  // `dismissedBy`: the pointerdown that closed the wheel, when one did.
  // On the map, that tap means "never mind" and nothing else — it must
  // not also open the system or drop the selection under it.
  onActionRadialClosed({ dismissedBy } = {}) {
    this.actionRadialOpen = false;
    if (dismissedBy && dismissedBy.target === this.renderer.domElement) {
      this.swallowedPointerId = dismissedBy.pointerId;
    }
  }

  onEnterSystem(system) {
    this.enterSystem(system);
  }

  onExitSystem() {
    this.exitSystem();
  }

  // EVENT LISTENERS
  onMouseDown(event) {
    if (event.pointerId !== undefined) {
      this.activePointers.add(event.pointerId);
      if (this.activePointers.size > 1) {
        this.sawMultiTouch = true;
        this.cancelLongPress();
      }
    }
    if (event.pointerType) this.lastPointerType = event.pointerType;

    // With no press recorded, this pointer's release is not a click.
    const swallowed = this.swallowedPointerId !== null && event.pointerId === this.swallowedPointerId;
    this.swallowedPointerId = null;
    if (swallowed) {
      this.mouseLastPosition = {};
      this.mouseDownAt = 0;
      return;
    }

    this.onClick(event, 'down');
    if (this.activePointers.size <= 1) this.armLongPress(event);
  }

  // Phones: holding a system with an agent selected opens the action
  // wheel WHILE the finger is still down. Deciding at the release (as
  // the icon picker does) gave no sign of when the hold was long enough:
  // lifting a moment early opened the system instead.
  armLongPress(event) {
    this.cancelLongPress();
    if (event.pointerType !== 'touch' && event.pointerType !== 'pen') return;
    if (!viewport.isMobile || this.inSystem || !store.state.game.selectedCharacter) return;
    const { clientX, clientY } = event;
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = null;
      this.onLongPress(clientX, clientY);
    }, ICON_PICKER_LONG_PRESS_MS);
  }

  cancelLongPress() {
    clearTimeout(this.longPressTimer);
    this.longPressTimer = null;
  }

  onLongPress(clientX, clientY) {
    if (this.sawMultiTouch || this.inSystem || store.state.game.ruler.active) return;
    this.updateHoverAt(clientX, clientY);
    const system = this.hoveredSystem();
    this.hideHover();
    if (!system) return;

    eventBus.$emit('map:action-radial:show', {
      systemId: system.id,
      screen: { x: clientX, y: clientY },
      held: true,
    });
    // nothing to order there: the wheel stayed closed, the press goes on
    if (!this.actionRadialOpen) return;

    // The finger is the wheel's now (slide to an action, or lift and
    // tap one): the map must not pan under it, nor read its release.
    this.longPressFired = true;
    this.controls.enabled = false;
    if (navigator.vibrate) navigator.vibrate(12);
  }

  // A press that wanders is a pan, not a hold.
  onPointerMove(event) {
    if (this.longPressTimer === null || this.mouseLastPosition.x === undefined) return;
    if (Math.abs(event.clientX - this.mouseLastPosition.x) > ICON_PICKER_JITTER_PX
      || Math.abs(event.clientY - this.mouseLastPosition.y) > ICON_PICKER_JITTER_PX) {
      this.cancelLongPress();
    }
  }

  onPointerCancel(event) {
    this.activePointers.delete(event.pointerId);
    if (this.activePointers.size === 0) this.sawMultiTouch = false;
    this.cancelLongPress();
    this.endHeldPress();
    this.mouseLastPosition = {};
    this.mouseDownAt = 0;
  }

  // Returns whether this press had opened the action wheel.
  endHeldPress() {
    if (!this.longPressFired) return false;
    this.longPressFired = false;
    this.controls.enabled = true;
    return true;
  }

  // The system under the last hover raycast (an icon stands for its system).
  hoveredSystem() {
    const object = currentlyHoveredObject && currentlyHoveredObject.gameObject;
    if (!object) return null;
    if (object.type === 'system') return object.data;
    if (object.type === 'system_icon') {
      return this.data.systems.find((s) => s.id === object.data.systemId) || null;
    }
    return null;
  }

  onMouseUp(event) {
    // contextmenu re-enters here after pointerup. On touch it fires
    // mid-long-press (Android); the pointerup path already owns
    // long-press semantics, so swallow the duplicate.
    if (event.type === 'contextmenu' && this.lastPointerType === 'touch') {
      event.preventDefault();
      return;
    }

    if (event.pointerId !== undefined) {
      this.activePointers.delete(event.pointerId);
    }

    this.cancelLongPress();
    // The action wheel opened under this finger and reads the release
    // itself (MapActionRadial): it is not a click on the map.
    if (this.endHeldPress()) {
      this.mouseLastPosition = {};
      this.mouseDownAt = 0;
      return;
    }

    // A pinch is not a tap: once two pointers were down, every release
    // in that gesture belongs to the zoom, not to a click.
    if (this.sawMultiTouch) {
      if (this.activePointers.size === 0) this.sawMultiTouch = false;
      this.mouseLastPosition = {};
      this.mouseDownAt = 0;
      return;
    }

    this.onClick(event, 'up');
  }

  onClick(event, type) {
    let button;
    switch (event.button) {
      case 1: button = 'middle'; break;
      case 2: button = 'right'; break;
      default: button = 'left'; break;
    }

    if (event.ctrlKey && button === 'left') {
      button = 'right';
    }

    if (type === 'down') {
      this.mouseLastPosition = { x: event.clientX, y: event.clientY };
      this.mouseDownAt = Date.now();
    }

    if (type === 'up' && !this.inSystem) {
      // Ruler mode short-circuits every other click semantic on
      // systems: a left click adds a waypoint instead of opening the
      // system view, jumping, or firing the icon picker. Other
      // hovered object types (characters, icons-with-no-system) fall
      // through to the normal handlers — measurement should not
      // hijack agent selection. Mirror the existing pan-vs-click
      // heuristic (compare mouseup position to mousedown) so a drag
      // that happens to release over a system doesn't get treated as
      // a waypoint commit.
      const rulerActive = store.state.game.ruler.active;
      const isTouch = event.pointerType === 'touch' || event.pointerType === 'pen';
      // the next stop of a fleet this tap landed on (see the blip branch)
      let tappedBlipTarget = null;
      const isTrueClick = this.mouseLastPosition.x !== undefined
        && Math.abs(event.clientX - this.mouseLastPosition.x) <= TAP_SLOP_PX
        && Math.abs(event.clientY - this.mouseLastPosition.y) <= TAP_SLOP_PX;

      // Touch has no hover phase: at tap time currentlyHoveredObject is
      // unset (or stale from a previous gesture) because the mousemove
      // raycast never ran. Raycast the release point now so the tap
      // sees what's actually under the finger.
      if (isTrueClick && isTouch) {
        this.updateHoverAt(event.clientX, event.clientY);
      }

      // Shift may have gone down after the pointer last moved: pick again
      // with it, so a fleet under the cursor wins over the system behind it.
      if (isTrueClick && event.button === 0 && event.shiftKey) {
        this.updateHoverAt(event.clientX, event.clientY, true);
      }

      if (rulerActive && button === 'left' && isTrueClick && currentlyHoveredObject) {
        let clickedObject = currentlyHoveredObject.gameObject;
        if (clickedObject && clickedObject.type === 'system_icon') {
          const system = this.data.systems.find((s) => s.id === clickedObject.data.systemId);
          if (system) clickedObject = { type: 'system', data: system };
        }
        if (clickedObject && clickedObject.type === 'system') {
          store.commit('game/addRulerWaypoint', clickedObject.data.id);
          this.mouseLastPosition = {};
          this.mouseDownAt = 0;
          return;
        }
      }

      // Phones, multi-move (MobileSelectedAgent): a tap on a system
      // queues a move there, and nothing else a tap usually does (open
      // the system, select or drop an agent) happens.
      if (store.state.game.multiMove && button === 'left') {
        if (isTrueClick) this.onMultiMoveTap(event);
        this.mouseLastPosition = {};
        this.mouseDownAt = 0;
        this.hideHover();
        return;
      }

      // Gate on isTrueClick so a pan that started (or, via the touch
      // re-raycast above, ended) over a system doesn't open it, and so
      // the contextmenu that trails a handled right-click pointerup
      // (mouseLastPosition already cleared) can't fire the action a
      // second time. A contextmenu that arrives *without* a preceding
      // pointerup (macOS ctrl+click suppression) still carries the
      // press coordinates and passes.
      if (isTrueClick && currentlyHoveredObject) {
        let clickedObject = currentlyHoveredObject.gameObject;

        // Icon clicks delegate to the system underneath them. The
        // icon takes hover priority (so its "by X" label can surface
        // without the system label swallowing the cursor), but a
        // click on an icon should behave exactly as if the system
        // dot were clicked — opening, jumping, or firing the picker.
        // Without this delegation, the existing system/character
        // branches below silently no-op on icon clicks, which reads
        // as a broken click.
        //
        // One exception: Shift+click on a CLAIM flag opens the chat on
        // the post that announced the claim (to read or add follow-ups),
        // instead of linking the system as Shift+click on any other
        // marker does.
        const isShiftClick = event.button === 0 && event.shiftKey;
        if (clickedObject && clickedObject.type === 'system_icon') {
          if (isShiftClick && clickedObject.data.kind === 'flag') {
            this.$root.$emit('chat:showClaim', clickedObject.data.systemId);
            clickedObject = { type: 'handled' };
          } else {
            const system = this.data.systems.find((s) => s.id === clickedObject.data.systemId);
            if (system) {
              clickedObject = { type: 'system', data: system };
            }
          }
        }

        // Player-icon picker triggers: Alt+right-click (desktop power
        // user) or a 500ms long-press of the left button (touch +
        // calmer desktop alt). Right-click without Alt still falls
        // through to the existing jump action below; only Alt
        // diverts. Long-press is left-button-only because
        // contextmenu fires after pointerup with mouseLastPosition
        // already cleared, making jitter checks unreliable.
        //
        // Tutorial mode suppresses the picker entirely. Icons are a
        // faction-coordination tool and the tutorial is solo, so the
        // backend gates the ops out (returns :forbidden_tutorial)
        // anyway — surfacing the picker just to show an error toast
        // is worse than silently ignoring the gesture. Same pattern
        // as the chat and faction panels, both hidden in tutorial.
        const isTutorial = !!store.state.game.galaxy.tutorial_id;
        const dx = this.mouseLastPosition.x !== undefined
          ? Math.abs(event.clientX - this.mouseLastPosition.x) : Infinity;
        const dy = this.mouseLastPosition.y !== undefined
          ? Math.abs(event.clientY - this.mouseLastPosition.y) : Infinity;
        const heldMs = this.mouseDownAt ? Date.now() - this.mouseDownAt : 0;
        const isLongPress = button === 'left'
          && heldMs >= ICON_PICKER_LONG_PRESS_MS
          && dx <= ICON_PICKER_JITTER_PX
          && dy <= ICON_PICKER_JITTER_PX;
        const isAltRightClick = event.altKey && button === 'right';
        const wantsIconPicker = !isTutorial && (isAltRightClick || isLongPress);

        if (clickedObject.type === 'system') {
          const system = clickedObject.data;

          // Phone with an agent selected: a long-press on a system is
          // an ORDER gesture — fan out the agent's possible actions
          // (move/conquer/infiltrate/...) instead of the icon picker.
          // With nothing selected the long-press keeps its icon-picker
          // meaning on mobile too.
          const wantsActionRadial = viewport.isMobile
            && isLongPress
            && !!store.state.game.selectedCharacter;

          // Picker wins over every other gesture on a system — the
          // user explicitly held / alt-clicked, so don't also fire
          // openSystem or jump.
          if (wantsActionRadial) {
            eventBus.$emit('map:action-radial:show', {
              systemId: system.id,
              screen: { x: event.clientX, y: event.clientY },
            });
          } else if (wantsIconPicker) {
            eventBus.$emit('system-icon-picker:show', {
              systemId: system.id,
              screen: { x: event.clientX, y: event.clientY },
            });
          // Shift+left-click on a system inserts it as a chat link
          // (system chip in the composer) instead of opening the
          // system view. Checked against the raw event so the
          // ctrl→right remap above doesn't shadow Shift+Ctrl+click.
          } else if (event.button === 0 && event.shiftKey) {
            this.$root.$emit('chat:insertRef', {
              kind: 'sys',
              id: system.id,
              label: system.name,
            });
          } else if (button === 'left') {
            store.dispatch('game/openSystem', { vm: this.vm, id: system.id });
          } else {
            this.addCharacterAction('jump', { system });
          }
        } else if (clickedObject.type === 'character') {
          const characterId = clickedObject.data;

          if (button === 'left') {
            store.dispatch('game/selectCharacter', { vm: this.vm, id: characterId });
          }
        } else if (clickedObject.type === 'detected_object') {
          // Shift+click on another faction's fleet reports it in the
          // faction's Spotted channel. Nothing else to do with a blip:
          // any other click on one is a click on empty space.
          const blip = clickedObject.data;
          if (isShiftClick && blip.reportable && !isTutorial) {
            reportFleet(this.vm, blip);
          } else if (button === 'left') {
            store.dispatch('game/unselectCharacter');
          }
          // Touch has no hover to show where a fleet is going: a tap does.
          if (isTouch) tappedBlipTarget = blip.targetSystemId;
        } else if (clickedObject.type === 'sector') {
          // Far zoom: a click on a sector's name turns its card to the
          // next faction there (the card sits away from the pointer and
          // cannot be clicked itself).
          if (button === 'left') this.$root.$emit('map:sectorClick', clickedObject.data);
        }
      } else if (button === 'left' && isTrueClick) {
        store.dispatch('game/unselectCharacter');
      }

      this.mouseLastPosition = {};
      this.mouseDownAt = 0;

      // Touch has no hover-off: whatever the tap raycast lit up (the
      // shared hover ring — reads as a stuck crosshair on phones —
      // plus path previews and labels) would linger forever. The click
      // logic above has consumed it; clear it.
      if (isTouch) {
        this.hideHover();
        if (tappedBlipTarget != null) this.flashSystem(tappedBlipTarget);
      }
    }
  }

  // One tap in multi-move mode: a second tap right after the first ends
  // the mode; otherwise a system under it gets a move queued.
  onMultiMoveTap(event) {
    const now = Date.now();
    const last = this.lastMultiMoveTap;
    this.lastMultiMoveTap = { at: now, x: event.clientX, y: event.clientY };
    if (last && now - last.at < DOUBLE_TAP_MS
      && Math.abs(event.clientX - last.x) <= DOUBLE_TAP_SLOP_PX
      && Math.abs(event.clientY - last.y) <= DOUBLE_TAP_SLOP_PX) {
      this.lastMultiMoveTap = null;
      store.commit('game/setMultiMove', false);
      return;
    }

    const system = this.hoveredSystem();
    const character = store.state.game.selectedCharacter;
    if (!system || !character || !character.actions) return;

    if (last && now - last.at > MULTI_MOVE_CHAIN_MS) this.multiMoveChain = null;
    const from = this.multiMoveOrigin(character);
    if (from === system.id) return;

    this.multiMoveChain.targets.push(system.id);
    this.flashSystem(system.id);
    this.addCharacterAction('jump', {
      system,
      from,
      // a refused leg leaves the agent where the store says it is
      onError: () => { this.multiMoveChain = null; },
    });
  }

  // Where the next multi-move leg starts. The store's virtual position
  // trails a queued move by two round trips (the push, then the refetch
  // of the agent), taps come faster than that, and a leg routed from a
  // stale position is refused. So the taps the store has not caught up
  // with are remembered, and the route goes on from the last of them.
  multiMoveOrigin(character) {
    const { virtual_position: queued } = character.actions;
    const stored = queued != null ? queued : character.system;
    let chain = this.multiMoveChain;
    if (!chain || chain.characterId !== character.id) {
      chain = { characterId: character.id, base: stored, targets: [] };
    } else if (chain.targets.includes(stored)) {
      // caught up to that tap: only the ones after it are still ahead
      chain = { ...chain, base: stored, targets: chain.targets.slice(chain.targets.lastIndexOf(stored) + 1) };
    } else if (stored !== chain.base) {
      // the queue changed some other way: start over from the store
      chain = { characterId: character.id, base: stored, targets: [] };
    }
    this.multiMoveChain = chain;
    return chain.targets.length ? chain.targets[chain.targets.length - 1] : stored;
  }

  // Double-click in empty space while the ruler tool is active clears
  // any committed waypoints and exits the tool. Double-clicking on a
  // system is a normal action (it would just register two
  // addRulerWaypoint commits for the same system, which the mutation
  // already de-dupes), so we only consume the gesture when nothing is
  // hovered.
  onDoubleClick() {
    if (!store.state.game.ruler.active) return;
    if (currentlyHoveredObject) return;
    store.commit('game/setRulerActive', false);
  }

  onWindowResize() {
    this.windowHeight = window.innerHeight;
    this.windowWidth = window.innerWidth;
    this.camera.aspect = this.windowWidth / this.windowHeight;
    this.camera.updateProjectionMatrix();

    // Phones are DPR 2-3: without an explicit pixel ratio the canvas
    // renders at CSS resolution and looks soft. Capped at 2 to bound
    // fill-rate cost on 4K desktops.
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setSize(this.windowWidth, this.windowHeight);
  }

  onControlChange() {
    if (this.moving) return;
    if (this.camera.zoom !== 1) {
      // to be on the safe side
      this.camera.zoom = 1;
    }

    const { position } = this.camera;
    if (position.z > this.maxZ) {
      this.setCameraPosition(position.x, position.y, this.maxZ);
    } else if (position.z < this.minZ) {
      this.setCameraPosition(position.x, position.y, this.minZ);
    }

    // in system: lock camera
    if (this.inSystem) {
      const { x, y } = this.inSystem.position;
      this.setCameraPosition(x, y, this.systemZ);
    }

    this.onZ(this.camera.position.z);
  }

  onZ(z) {
    this.blocks.forEach((block) => block.onZ(z));
  }

  onMouseMove(event) {
    // Native form controls (e.g. the government panel's tax and pledge
    // sliders) rely on default mousemove behavior to drag their thumb;
    // this document-level preventDefault froze them mid-drag (click-to-
    // set worked, dragging didn't). Panels render above the map, so
    // skipping these events costs no map interaction.
    if (
      event.target instanceof HTMLInputElement
      || event.target instanceof HTMLSelectElement
      || event.target instanceof HTMLTextAreaElement
    ) {
      return;
    }

    event.preventDefault();

    // While a button is held, MapControls owns the gesture (panning) —
    // raycasting the whole galaxy for hover on every mid-drag mousemove
    // is wasted work, and a "click" that ends a drag is already rejected
    // by the mousedown/mouseup position comparison in onClick. Hover
    // state refreshes on the first move after release.
    if (event.buttons !== 0) {
      return;
    }

    // hover system
    if (!this.inSystem) {
      this.updateHoverAt(event.clientX, event.clientY, event.shiftKey);
    }
  }

  // Raycast pick at a client-space point and refresh hover state.
  // Shared by the mousemove hover path and the touch-tap path in
  // onClick, which has no hover phase to rely on.
  //
  // `preferBlips` (Shift held): the fleets of other factions are picked
  // BEFORE systems. A fleet leaving a system flies over its dot and its
  // label, which would otherwise take the pointer; Shift is the "report
  // this" key, so while it is down the fleet under the cursor is what the
  // player means.
  updateHoverAt(clientX, clientY, preferBlips = false) {
    this.lastHoverPoint = { x: clientX, y: clientY };

    this.pickingHover = true;
    try {
      this.pickHoverAt(clientX, clientY, preferBlips);
    } finally {
      this.pickingHover = false;
    }

    this.syncBlipFeedback();
  }

  // What hovering a radar blip shows: its next stop pulsing on the map
  // (as hovering an order in an agent's plan does) and, for another
  // faction's fleet, what Shift+click would do. Reconciled once the pick
  // has settled rather than in showHover/hideHover: a pick clears and
  // re-sets the hover on every mouse move, and the pulse would start
  // over each time.
  syncBlipFeedback() {
    const hovered = currentlyHoveredObject && currentlyHoveredObject.gameObject;
    const blip = hovered && hovered.type === 'detected_object' ? hovered.data : null;

    const blips = this.getBlockByName('DetectedObject');
    if (blips) {
      if (blip && blip.reportable && this.lastHoverPoint) {
        blips.showHint(this.lastHoverPoint);
      } else {
        blips.hideHint();
      }
    }

    const target = blip && blip.targetSystemId != null ? blip.targetSystemId : null;
    if (target === this.blipPulseTarget) return;

    // only take down a pulse that is ours (the plan editor shares it)
    if (this.blipPulseTarget !== null && this.destinationPulse
      && this.destinationPulse.systemId === this.blipPulseTarget) {
      this.onUnpulseSystem();
    }
    if (target !== null) this.onPulseSystem(target);
    this.blipPulseTarget = target;
  }

  pickHoverAt(clientX, clientY, preferBlips) {
    this.mouse.x = (clientX / this.windowWidth) * 2 - 1;
    this.mouse.y = -(clientY / this.windowHeight) * 2 + 1;
    this.hovercaster.setFromCamera(this.mouse, this.camera);

    // we can "generically" use hover
    //
    // SystemIcons goes FIRST so an icon-hover takes priority over
    // the system underneath it — otherwise the system label can
    // "swallow" the icon for the cursor and the "by X" attribution
    // never surfaces. Falling back to System (and on to Character /
    // Sector) when the cursor isn't over an icon works because the
    // standard intersection path clears currentlyHoveredObject on
    // miss, so the next type's check starts clean.
    const types = [
      { block: 'SystemIcons', group: 'icons-near' },
      { block: 'System', group: 'systems-near' },
      { block: 'Character', group: 'characters-on-map' },
      { block: 'Character', group: 'character-names-on-map' },
      // Radar blips (other factions' fleets): hoverable so one can be
      // reported to the faction with Shift+click. After systems and own
      // agents — a blip never steals a plain click meant for those.
      { block: 'DetectedObject', group: 'detected-objects' },
      { block: 'Sector', group: 'sector-far' },
    ];

    if (preferBlips) {
      types.unshift({ block: 'DetectedObject', group: 'detected-objects', reportableOnly: true });
    }

    for (let i = 0; i < types.length; i += 1) {
      const type = types[i];
      const block = this.getBlockByName(type.block);
      if (!block) {
        continue;
      }

      if (type.block === 'Sector' && block.shown !== type.group) {
        break;
      }

      if (type.block === 'System' && currentlyHoveredObject) {
        // something is already hovered
        const intersection = this.hovercaster
          .intersectObjects([currentlyHoveredObject, ...currentlyHoveredObject.children], true);

        // see if it's still hovered or if one of its children is hovered
        if (intersection.length) {
          if (intersection[0].object.parent.id === currentlyHoveredObject.id) {
            break;
          }

          if (intersection[0]?.object?.parent?.gameObject) {
            currentlyHoveredObject = intersection[0].object.parent;
            break;
          }
        }
      }

      if (block) {
        const typeGroup = block.getGroupByName(type.group);
        // Blips are hidden at far zoom, and the raycaster doesn't care
        // about visibility: don't let an invisible one take the hover.
        if (type.block === 'DetectedObject' && !(typeGroup && typeGroup.visible)) {
          continue;
        }

        const groups = typeGroup.children;
        const intersection = this.hovercaster
          .intersectObjects(groups, true)
          .filter(({ object }) => object.userData?.hoverable
            && (!type.reportableOnly || object.userData.reportable));

        if (intersection.length > 0) {
          const intersecting = 0;
          const { object: intersectedObject } = intersection[intersecting];
          // We intersected a single object, we want the hover to effect the whole system,
          // not just the hovered ring or child-object.
          // Search in intersected object's parents the closer 'hoverable object'.
          let hoveredGroup;

          // System base sprites are batched into InstancedMesh objects
          // by System#buildBaseSpritesInstancedMeshes — those carry a
          // userData.systemGroupByInstanceId map back to the per-system
          // sn Group that holds gameObject and showOnHover children.
          // Resolve InstancedMesh hits through that map instead of
          // walking parents (the InstancedMesh has no gameObject and
          // its parent is sng, also without one).
          if (intersectedObject.isInstancedMesh
              && intersection[intersecting].instanceId !== undefined
              && intersectedObject.userData.systemGroupByInstanceId) {
            hoveredGroup = intersectedObject.userData
              .systemGroupByInstanceId[intersection[intersecting].instanceId];
          } else {
            hoveredGroup = intersectedObject;
            while (hoveredGroup && !('gameObject' in hoveredGroup)) {
              hoveredGroup = hoveredGroup.parent;
            }
          }

          const stillHovering = currentlyHoveredObject && (hoveredGroup.id === currentlyHoveredObject.id);

          if (!hoveredGroup) {
            this.hideHover();
          } else if (!stillHovering) {
            if (hoveredGroup.gameObject.type === 'sector') {
              store.commit('game/addMapOverlay', hoveredGroup.gameObject);
            }

            this.hideHover();
            this.showHover(hoveredGroup, type.block);
            break;
          } else {
            break;
          }
        } else {
          this.hideHover();
        }
      }
    }
  }

  sceneInit() {
    const initialBlocks = [
      // new Crosshair(this),
      new Skydome(this),
      new Blackhole(this),
      new Radar(this),
      new DetectedObject(this),
      new Sector(this),
      // The faction's gateway links (far zoom): over the sector fill,
      // under the system dots.
      new Gateway(this),
      new System(this),
      // Overview mode's rings around the system dots.
      new SystemGlyphs(this),
      // Render SystemIcons AFTER System so the marker sprites layer
      // on top of the system dots/labels in scene-add order; the
      // explicit Z offset in system-icons.js is the primary defense,
      // this is just defense-in-depth.
      new SystemIcons(this),
      new Character(this),
      // Ruler reads the Character block's pathfinder, so it must be
      // constructed after Character. Initial Promise.all() awaits all
      // blocks' first update() — by the time Ruler._update() runs,
      // Character will exist in this.blocks.
      new Ruler(this),
    ];

    Promise.all(initialBlocks.map((block) => {
      const p = block.update({}).then((_) => {
        block.group.children.forEach((group) => { group.visible = false; });
        this.blocks.push(block);
        this.scene.add(block.group);
        // No block ever moves its root group (children are positioned in
        // world coordinates), but an unfrozen root re-composes each frame
        // and force-cascades world-matrix multiplies over its whole
        // subtree — see the scene freeze in the constructor. Objects a
        // block animates (in-flight characters, radar pulses) keep their
        // own matrixAutoUpdate and still update themselves.
        block.group.matrixAutoUpdate = false;
        block.group.updateMatrix();
      });
      return p;
    }));
  }

  addCharacterAction(action, metadata = {}) {
    if (!store.state.game.selectedCharacter) {
      return;
    }

    const { character, system, from, onError } = metadata;
    const characterBlock = this.getBlockByName('Character');

    const actions = [];
    // `from`: where the caller knows the queue will end, ahead of the store
    let virtualPosition = from != null ? from : store.state.game.selectedCharacter.actions.virtual_position;
    const characterId = store.state.game.selectedCharacter.id;
    const itinerary = characterBlock.computePath(virtualPosition, system.id);

    if (itinerary.length) {
      actions.push(...itinerary.map((a) => ({
        type: 'jump',
        data: { source: a.source, target: a.target },
      })));

      // The destination the player picked is a STOP; the jumps before it
      // are only route (see game/plan/stops.js). A gateway charge makes
      // its own stop on the far side, so its approach leg isn't marked.
      if (action !== 'gateway_charge') actions[actions.length - 1].data.stop = true;

      virtualPosition = actions[actions.length - 1].data.target;
    }

    if (['fight', 'sabotage', 'assassination', 'conversion'].includes(action)) {
      actions.push({
        type: action,
        data: {
          target: virtualPosition,
          target_character: character,
        },
      });
    }

    if (['colonization', 'conquest', 'raid', 'loot', 'infiltrate', 'make_dominion',
         'encourage_hate'].includes(action)) {
      actions.push({ type: action, data: { target: virtualPosition } });
    }

    // faction gateway: the pair's other endpoint comes from the
    // government's link records; the server re-validates at start
    if (action === 'gateway_charge') {
      const government = store.state.game.faction && store.state.game.faction.government;
      const links = (government && government.gateway_links) || [];
      const link = links.find((l) => l.endpoints.some((e) => e.system_id === system.id));
      const other = link && link.endpoints.find((e) => e.system_id !== system.id);

      if (other) {
        actions.push({ type: 'gateway_charge', data: { source: system.id, target: other.system_id } });
      }
    }

    this.$socket.player.push('add_character_actions', {
      character_id: characterId,
      actions,
    }).receive('error', (err) => {
      if (onError) onError(err);
      this.vm.$toastError(err.reason);
    });
  }

  showHover(hoveredGroup, type) {
    currentlyHoveredObject = hoveredGroup;
    hoveredGroup.children
      .filter((obj) => obj.userData.showOnHover === true)
      .forEach((obj) => {
        obj.visible = true;
      });

    if (type === 'System') {
      // Attach this system's lazily-built hover labels (name / owner /
      // orbit lines). They live in a detached cache, not the scene graph,
      // so the per-frame matrix walk never sees the ~2 labels × N systems
      // that aren't being hovered right now.
      const systemBlock = this.getBlockByName('System');
      if (systemBlock) {
        systemBlock.attachHoverLabels(hoveredGroup);
      }

      // Reposition and reveal the single shared hover indicator built in
      // System#_create. Replaces the per-system hover Mesh that used to
      // live inside every sn Group with `showOnHover: true` userData.
      const indicator = systemBlock && systemBlock.hoverIndicator;
      const systemPos = hoveredGroup.gameObject && hoveredGroup.gameObject.data
        && hoveredGroup.gameObject.data.position;
      if (indicator && systemPos) {
        indicator.position.x = systemPos.x;
        indicator.position.y = systemPos.y;
        indicator.visible = true;
      }

      if (Character.canHoverPath()) {
        const character = this.getBlockByName('Character');
        character.hoverPathTo(hoveredGroup.gameObject.data);
      }
    }

    // Track hovered system id on the shared MapData so keyboard handlers
    // (C-key copy) can read it without going through Three.js internals.
    if (type === 'System' && hoveredGroup.gameObject?.data?.id) {
      this.data.hoveredSystemId = hoveredGroup.gameObject.data.id;
    }
  }

  hideHover() {
    if (currentlyHoveredObject) {
      if (currentlyHoveredObject.gameObject.type === 'sector') {
        store.commit('game/clearMapOverlay');
      }

      let objectsToHide = currentlyHoveredObject.children;
      if (!currentlyHoveredObject.name && currentlyHoveredObject.parent) {
        // the hovered object is a system label, parent is system, we want to hide the system hover
        objectsToHide = currentlyHoveredObject.parent.children;
      }
      objectsToHide
        .filter((obj) => obj.userData.showOnHover === true)
        .forEach((obj) => {
          obj.visible = false;
        });

      if (currentlyHoveredObject.gameObject?.type === 'system') {
        this.data.hoveredSystemId = null;
        // Hide the single shared system hover indicator (see System#_create
        // and Map#showHover for the show side).
        const systemBlock = this.getBlockByName('System');
        if (systemBlock && systemBlock.hoverIndicator) {
          systemBlock.hoverIndicator.visible = false;
        }
        // Detach the lazily-attached hover labels so they leave the
        // per-frame scene walk (they stay cached for the next hover).
        if (systemBlock) {
          systemBlock.detachHoverLabels(currentlyHoveredObject);
        }
      }

      currentlyHoveredObject = undefined;

      const character = this.getBlockByName('Character');
      character.hideHoverPath();

      // A hover dropped outside a pick (a tap's clean-up, a mode change):
      // take the blip label and pulse down with it.
      if (!this.pickingHover) this.syncBlipFeedback();
    }
  }

  centerToSystem(systemId, z, time) {
    const system = this.data.systems.find((s) => s.id === systemId);

    if (system) {
      this.move(system.position.x, system.position.y, z, time, 'centerToSystem');
    }
  }

  setCameraPosition(x, y, z = this.camera.position.z) {
    this.camera.position.set(x, y, z);
    this.camera.lookAt(new Vector3(x, y, 0));
    this.controls.target = new Vector3(x, y, 0);
  }

  async move(x, y, z = this.camera.position.z, time, reason) {
    if (this.moving) {
      return Promise.resolve();
    }

    this.moving = reason;

    if (!time) {
      this.setCameraPosition(x, y, z);
      this.moving = false;
      return Promise.resolve();
    }

    return new Promise((resolve) => {
      new TWEEN.Tween(this.camera.position)
        .to({ x, y, z }, time)
        .easing(TWEEN.Easing.Cubic.InOut)
        .onComplete(() => {
          this.moving = false;
          resolve();
        })
        .onUpdate((position) => {
          // eslint-disable-next-line no-shadow
          const { x, y, z } = position;

          this.camera.lookAt(new Vector3(x, y, 0));
          this.controls.target = new Vector3(x, y, 0);
          this.onZ(z);
        })
        .start();
    });
  }

  moveRel(xDelta, yDelta) {
    const pos = this.camera.position;
    this.setCameraPosition(pos.x + xDelta, pos.y + yDelta);
  }

  enterSystem(system) {
    this.inSystem = system;
    // Hover detection is paused while in a system; clear any stale hover so
    // the C-key copy handler falls through to the open system view rather
    // than acting on whatever the cursor was last over on the galaxy map.
    this.data.hoveredSystemId = null;

    if (this.camera.position.z !== this.systemZ) {
      this.lastZ = this.camera.position.z;
    }

    const systemPosition = system.position;
    const moveDuration = 500;

    this.vm.$ambiance.sound('system-open');
    this.move(systemPosition.x, systemPosition.y, this.systemZ, moveDuration, 'enterSystem');

    setTimeout(() => {
      store.commit('game/finishSystemTransition');

      if (this.mapUpdate) {
        this.mapUpdate = false;
      }
    }, moveDuration);
  }

  exitSystem() {
    const backToZ = this.lastZ || this.initialZ;

    this.mapUpdate = true;
    this.inSystem = null;
    this.lastZ = null;

    this.vm.$ambiance.sound('system-close');
    this.move(this.camera.position.x, this.camera.position.y, backToZ, 500, 'exitSystem');
  }

  getBlockByName(name) {
    return this.blocks.find((block) => block.group.name === name);
  }
}
