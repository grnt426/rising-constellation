import {
  AmbientLight,
  Raycaster,
  Vector2,
  Vector3,
  TextureLoader,
} from 'three';

import { MapControls } from 'three/examples/jsm/controls/OrbitControls';

import Stats from 'stats-js';
import TWEEN from '@tweenjs/tween.js';
import store from '@/store';
import config from '@/config';
import eventBus from '@/plugins/event-bus';
import { loadFonts, materialsFactory } from './three-utils';
import { Radar, Sector, System, SystemIcons, Blackhole, Skydome, Character, DetectedObject, Ruler } from './blocks';

// Player-icon picker gesture thresholds. 500ms is the common
// long-press convention (Material/iOS); 8px lets a small finger /
// mouse wobble during the hold not cancel the trigger.
const ICON_PICKER_LONG_PRESS_MS = 500;
const ICON_PICKER_JITTER_PX = 8;

// Pan-vs-click slop: max down→up drift for a release to still count as
// a click. A finger tap (and even a fast mouse click) drifts a few
// pixels between down and up; exact-equality rejected every touch tap.
const TAP_SLOP_PX = 8;

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
    this.inSystem = null;
    this.moving = false;
    this.hovercaster = new Raycaster();
    this.textureLoader = new TextureLoader();
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
    this.onMouseMoveBound = this.onMouseMove.bind(this);
    this.onMouseDownBound = this.onMouseDown.bind(this);
    this.onMouseUpBound = this.onMouseUp.bind(this);
    this.onDoubleClickBound = this.onDoubleClick.bind(this);
    document.addEventListener('mousemove', this.onMouseMoveBound, false);
    this.renderer.domElement.addEventListener('pointerdown', this.onMouseDownBound, true);
    this.renderer.domElement.addEventListener('pointerup', this.onMouseUpBound, true);
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

    // monotonic time offset
    this.timeOffset = store.state.game.time.now_monotonic - Date.now();

    // $root outlives every Map instance, so each $on registered here
    // must be $off'd in destroy() or it accumulates across mount cycles
    // (Game.vue remounts → fresh Map → another anonymous listener on the
    // same event). Stale listeners then re-fire every emit, e.g. one
    // infiltrate click → N+1 add_character_actions pushes → N+1 queued
    // infiltrates. We bind each handler once here so the same reference
    // is available to both $on and $off.
    this.onCenterToSystem = this.onCenterToSystem.bind(this);
    this.onCenterToCharacter = this.onCenterToCharacter.bind(this);
    this.onHidePath = this.onHidePath.bind(this);
    this.onAddAction = this.onAddAction.bind(this);
    this.onEnterSystem = this.onEnterSystem.bind(this);
    this.onExitSystem = this.onExitSystem.bind(this);

    this.$root.$on('map:centerToSystem', this.onCenterToSystem);
    this.$root.$on('map:centerToCharacter', this.onCenterToCharacter);
    this.$root.$on('map:hidePath', this.onHidePath);
    this.$root.$on('map:addAction', this.onAddAction);
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

    this.fonts = await loadFonts();

    this.sceneInit();

    this.mapUpdate = true;
    const animate = () => {
      // always call this, otherwise tweens don't finish
      TWEEN.update();

      // don't update the map while we're in a system because it's hidden behind
      if (!this.mapUpdate) {
        this.requestAnimationFrame = requestAnimationFrame(animate);
        return;
      }

      stats.begin();
      this.controls.update();
      const { z } = this.camera.position;
      this.blocks.forEach((block) => {
        // block.update() is async but we don't want to wait for it to be done!
        block.update();
        block.animationCallbacks.forEach(({ far, near, cb }) => {
          if (z < far && z >= near) {
            cb();
          }
        });
      });

      this.renderer.render(this.scene, this.camera);
      stats.end();

      this.requestAnimationFrame = requestAnimationFrame(animate);
    };

    animate();
  }

  destroy() {
    if (this.isDev) {
      const stats = document.getElementById('threejs-stats');
      stats.parentNode.removeChild(stats);
    }

    this.unbindEvents();

    // Pair with the $on calls in the constructor. See the comment there
    // for why omitting these duplicates queued actions on remount.
    this.$root.$off('map:centerToSystem', this.onCenterToSystem);
    this.$root.$off('map:centerToCharacter', this.onCenterToCharacter);
    this.$root.$off('map:hidePath', this.onHidePath);
    this.$root.$off('map:addAction', this.onAddAction);
  }

  bindEvents() {
    setTimeout(() => { this.onWindowResize(); }, 0);
    this.$root.$on('enterSystem', this.onEnterSystem);
    this.$root.$on('exitSystem', this.onExitSystem);
    window.addEventListener('resize', this.onWindowResize.bind(this), false);
  }

  unbindEvents() {
    cancelAnimationFrame(this.requestAnimationFrame);
    window.removeEventListener('resize', this.onWindowResize);
    document.removeEventListener('change', this.onControlChange);
    document.removeEventListener('mousemove', this.onMouseMoveBound);
    this.renderer.domElement.removeEventListener('pointerdown', this.onMouseDownBound);
    this.renderer.domElement.removeEventListener('pointerup', this.onMouseUpBound);
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
      const elapsed = this.timeOffset + Date.now() - action.started_at;
      const progress = (speedFactor * elapsed) / (180000 * action.total_time);

      const pX = p1.x + progress * (p2.x - p1.x);
      const pY = p1.y + progress * (p2.y - p1.y);

      this.move(pX, pY, config.MAP.Z_DEFAULT, 600, 'centerToCharacter');
    }
  }

  onHidePath() {
    const character = this.getBlockByName('Character');
    character.hideHoverPath();
  }

  onAddAction(action, payload) {
    this.addCharacterAction(action, payload);
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
      if (this.activePointers.size > 1) this.sawMultiTouch = true;
    }
    if (event.pointerType) this.lastPointerType = event.pointerType;
    this.onClick(event, 'down');
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
      const isTrueClick = this.mouseLastPosition.x !== undefined
        && Math.abs(event.clientX - this.mouseLastPosition.x) <= TAP_SLOP_PX
        && Math.abs(event.clientY - this.mouseLastPosition.y) <= TAP_SLOP_PX;

      // Touch has no hover phase: at tap time currentlyHoveredObject is
      // unset (or stale from a previous gesture) because the mousemove
      // raycast never ran. Raycast the release point now so the tap
      // sees what's actually under the finger.
      if (isTrueClick && (event.pointerType === 'touch' || event.pointerType === 'pen')) {
        this.updateHoverAt(event.clientX, event.clientY);
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
        if (clickedObject && clickedObject.type === 'system_icon') {
          const system = this.data.systems.find((s) => s.id === clickedObject.data.systemId);
          if (system) {
            clickedObject = { type: 'system', data: system };
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

          // Picker wins over every other gesture on a system — the
          // user explicitly held / alt-clicked, so don't also fire
          // openSystem or jump.
          if (wantsIconPicker) {
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
        }
      } else if (button === 'left' && isTrueClick) {
        store.dispatch('game/unselectCharacter');
      }

      this.mouseLastPosition = {};
      this.mouseDownAt = 0;
    }
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
      this.updateHoverAt(event.clientX, event.clientY);
    }
  }

  // Raycast pick at a client-space point and refresh hover state.
  // Shared by the mousemove hover path and the touch-tap path in
  // onClick, which has no hover phase to rely on.
  updateHoverAt(clientX, clientY) {
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
      { block: 'Sector', group: 'sector-far' },
    ];

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
        const groups = block.getGroupByName(type.group).children;
        const intersection = this.hovercaster
          .intersectObjects(groups, true)
          .filter(({ object }) => object.userData?.hoverable);

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
      new System(this),
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

    const { character, system } = metadata;
    const characterBlock = this.getBlockByName('Character');

    const actions = [];
    let virtualPosition = store.state.game.selectedCharacter.actions.virtual_position;
    const characterId = store.state.game.selectedCharacter.id;
    const itinerary = characterBlock.computePath(virtualPosition, system.id);

    if (itinerary.length) {
      actions.push(...itinerary.map((a) => ({
        type: 'jump',
        data: { source: a.source, target: a.target },
      })));

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

    this.$socket.player.push('add_character_actions', {
      character_id: characterId,
      actions,
    }).receive('error', (err) => {
      this.$toastError(err.reason);
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

    // Flippable labels: the always-shown player-owned system name label sits
    // permanently to the right of its dot and can hide a neighbouring system
    // underneath. When the cursor enters its area, mirror it to the other
    // side. Only fires on hover *transitions* (not while still hovering the
    // same object), so a held cursor doesn't oscillate; a fresh entry into
    // the label's area on either side toggles it back across.
    if (hoveredGroup.userData?.canFlip) {
      hoveredGroup.position.x = hoveredGroup.position.x === 0
        ? hoveredGroup.userData.flipDelta
        : 0;
      // System block freezes label matrices (matrixAutoUpdate = false) to
      // skip per-frame updateMatrix on thousands of static meshes. That
      // makes this position mutation invisible unless we bake the local
      // matrix and mark the world matrix stale; the next render's
      // updateMatrixWorld will then recompute this label and its text/
      // background children.
      hoveredGroup.updateMatrix();
      hoveredGroup.matrixWorldNeedsUpdate = true;
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
