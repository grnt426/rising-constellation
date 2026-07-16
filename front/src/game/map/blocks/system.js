import {
  Color,
  FrontSide,
  Group,
  InstancedMesh,
  Mesh,
  MeshBasicMaterial,
  Object3D,
  RingGeometry,
  ShapeBufferGeometry,
  PlaneGeometry,
  Vector3,
} from 'three';

import config from '@/config';
import store from '@/store';
import { disposeObjectTree } from '../three-utils';

import Block from './block';

const nearHoverDisk = new RingGeometry(0.0001, 0.5, 32);
const farHoverDisk = new RingGeometry(0.0001, 2, 32);

// Unit-radius ring geometry shared by every per-mode rings InstancedMesh.
// Each instance is scaled to its actual radius via setMatrixAt — one
// geometry instead of one-per-system collapses N draw calls + N
// vertex buffers into 1.
const ringUnitGeometry = new RingGeometry(0.0001, 1, 128);

// 1x1 quad shared by every per-variant base-sprite InstancedMesh. Each
// instance is scaled to the variant's display size via setMatrixAt. The
// original code used three.js Sprites (auto-billboarded quads); for the
// galaxy's top-down view with camera rotation disabled in prod
// (Map.controls.enableRotate = this.isDev), a flat XY plane facing +Z
// is visually identical.
const planeUnitGeometry = new PlaneGeometry(1, 1);

// Unit disc for the far-view system circles. Scaled per instance to
// 0.2 * display_size_factor, matching the old per-system
// RingGeometry(0.0002, 0.2 * dsf, 32) — inner radius 0.001 * 0.2 keeps
// the same (invisible) pinhole at the center.
const farUnitDisk = new RingGeometry(0.001, 1, 32);

// Reusable scratch objects for building instance matrices/colors so the
// per-system loop doesn't allocate in a hot rebuild path.
const _scratchDummy = new Object3D();
const _scratchColor = new Color();

const modes = ['population', 'visibility', 'radar'];

export default class System extends Block {
  constructor(map) {
    super(map, 'System');
  }

  _create() {
    this.mode = store.state.game.mapOptions.mode;

    this.groups = modes.reduce((groups, modeName) => {
      groups[modeName] = this.group.clone();
      return groups;
    }, {});

    this.group = this.groups[this.mode];
    // Inactive mode groups stay OFF the scene graph entirely. Scene
    // visibility (visible = false) only skips rendering — r126's
    // scene.updateMatrixWorld() still recurses through invisible
    // subtrees every frame, which at 6k+ systems means two full extra
    // copies of the galaxy walked for nothing. _update swaps groups
    // in and out of the scene on mode switch instead.

    // Lazily-built hover label subtrees, keyed `${mode}|${systemId}`.
    // See attachHoverLabels — most systems' labels are hover-only, so
    // they don't exist in the scene graph (or at all) until first
    // hovered. Entries are disposed + dropped on repaint.
    this.hoverLabelCache = new Map();

    // Single shared hover indicator. Replaces N per-system hover Meshes
    // that were invisible 99% of the time but still bloated the scene
    // graph (~N tree-walk hits per frame, ~N raycast AABB tests per
    // pointer move, ~N cloned MeshBasicMaterial allocations). On hover,
    // Map#showHover repositions and shows this one mesh; Map#hideHover
    // sets it invisible. Lives directly on map.scene so it's
    // independent of mode-switch and isn't affected by the per-mode
    // group's matrix freeze (matrixAutoUpdate stays true here because
    // this mesh DOES move every time hover transitions).
    this.hoverIndicator = new Mesh(nearHoverDisk, this.map.materials.white.clone());
    this.hoverIndicator.material.opacity = 0.12;
    this.hoverIndicator.position.z = config.MAP.Z_SYSTEM_NEAR_STAR - 0.01;
    this.hoverIndicator.visible = false;
    this.hoverIndicator.name = 'system-hover-indicator';
    // Force the hover indicator to render BEFORE the per-mode base-sprite
    // InstancedMesh. Three.js sorts InstancedMesh by its own world
    // position (origin) for the transparent pass, not per-instance — so
    // the sprite-instance covering the hovered system would otherwise
    // sort as "far back", render first, write depth across its entire
    // quad (including transparent corners), and then occlude the hover
    // halo's pixels inside the quad. renderOrder = -1 puts the hover
    // first in the transparent pass; the sprite then blends on top
    // correctly and its transparent corners reveal the halo behind.
    this.hoverIndicator.renderOrder = -1;
    this.map.scene.add(this.hoverIndicator);

    this.createSystems(true);
    this.resetRepaint();
  }

  _update() {
    const mode = store.state.game.mapOptions.mode;

    if (this.mode !== mode) {
      // Swap the active mode group in and out of the scene — detached
      // groups cost nothing per frame, unlike visible=false ones (see
      // _create). The outgoing group keeps its baked matrices, so
      // re-attaching later recomputes nothing.
      this.map.scene.remove(this.group);
      this.mode = mode;
      this.group = this.groups[mode];
      this.group.visible = true;
      this.map.scene.add(this.group);

      this.refresh();
    }

    if (this.map.data.systemsToRepaint.size > 0) {
      this.createSystems();
      this.refresh();
      this.resetRepaint();
    }
  }

  resetRepaint() {
    this.map.data.systemsToRepaint.clear();
  }

  createSystems(initial = false) {
    modes.forEach((mode) => {
      let sng = this.groups[mode].children.find((group) => group.name === 'systems-near');
      let sfg = this.groups[mode].children.find((group) => group.name === 'systems-far');

      if (!sng) {
        sng = new Group();
        sng.name = 'systems-near';
        Object.assign(sng.userData, { near: 20, far: 200 });
      }

      if (!sfg) {
        sfg = new Group();
        sfg.name = 'systems-far';
        Object.assign(sfg.userData, { near: 200, far: this.map.maxZ });
      }

      // loop through all systems
      this.map.data.systems.forEach((system) => {
        const name = `system-${system.id}`;

        // only if tutorial mode, change neutral dominion in sector 2 with
        // fake myrmezir dominion
        if (store.state.game.galaxy.tutorial_id
          && system.status === 'inhabited_neutral' && system.sector_id === 2) {
          system.faction = 'myrmezir';
          system.owner = 'Myrmezir';
          system.status = 'inhabited_dominion';
        }

        // check need to create or recreate the object
        if (initial || this.map.data.systemsToRepaint.has(system.id)) {
          if (!initial) {
            const previous = sng.children.find((g) => g.userData.name === name);
            if (previous) disposeObjectTree(previous);

            // drop this mode's cached hover labels — ownership/visibility
            // repaints change label text and colors
            const cached = this.hoverLabelCache.get(`${mode}|${system.id}`);
            if (cached) {
              cached.forEach((label) => disposeObjectTree(label));
              this.hoverLabelCache.delete(`${mode}|${system.id}`);
            }
          }

          // create near system
          const sn = this.nearSystem(system, name, mode);
          sng.add(sn);

          // (far systems are batched wholesale into InstancedMeshes by
          // buildFarInstancedMeshes below — no per-system object)
        }
      });

      this.groups[mode].add(sng);
      this.groups[mode].add(sfg);

      // Build the per-mode rings InstancedMesh (visibility / population
      // modes only). One InstancedMesh covers every eligible system in
      // the galaxy — collapses ~N RingGeometry meshes into a single
      // draw call. Repaints flow back through createSystems so this
      // helper finds and disposes the previous InstancedMesh.
      this.buildRingsInstancedMesh(sng, mode);

      // Build the per-variant base-sprite InstancedMeshes. One
      // InstancedMesh per (system type × habitability × visibility)
      // combination — typically a couple dozen variants instead of
      // ~N individual Sprite Objects. Hover detection in map.js
      // resolves an instanceId back to the per-system sn Group via
      // the userData map populated here.
      this.buildBaseSpritesInstancedMeshes(sng);

      // Batch the faction/owner overlay sprites (dominion + player-run
      // systems) the same way — grouped by (type × faction × owner ×
      // visibility). Late-game galaxies can have thousands of owned
      // systems, each of which used to be its own cloned Sprite.
      this.buildOwnedSpritesInstancedMeshes(sng);

      // Batch the far-view circles + own-system halos into a handful of
      // InstancedMeshes — replaces ~N Groups each holding 1-2 Meshes
      // (and ~N draw calls when zoomed out).
      this.buildFarInstancedMeshes(sfg);

      // Systems are static in world space — panning is camera-driven (the
      // view matrix), not object-driven. Disabling matrixAutoUpdate skips
      // the per-frame updateMatrix/compose work on every system mesh,
      // which dominated render time in production profiles. Bake each
      // local matrix once from its position/scale set above. Repaints
      // (ownership color change) flow through this same path, so the
      // fresh subtrees get frozen too. Mutating these positions later
      // requires obj.updateMatrix() + obj.matrixWorldNeedsUpdate = true —
      // see Map#showHover for the only such case (canFlip labels).
      this.groups[mode].traverse((o) => {
        o.matrixAutoUpdate = false;
        o.updateMatrix();
      });
    });
  }

  // Build the rings InstancedMesh for one mode's systems-near group.
  // Only 'visibility' and 'population' modes show rings; 'radar' is a
  // no-op (we still clear any leftover instance from a prior mode).
  // Faction-tinted per-instance color is applied via setColorAt
  // (multiplied with the material's white base color in the shader).
  buildRingsInstancedMesh(sng, mode) {
    const existing = sng.children.find((c) => c.name === 'system-rings');
    if (existing) {
      sng.remove(existing);
      // ringUnitGeometry is shared across all rebuilds — don't dispose it.
      existing.material.dispose();
      existing.dispose();
    }

    if (mode !== 'visibility' && mode !== 'population') return;

    let eligible;
    if (mode === 'visibility') {
      eligible = this.map.data.systems.filter((s) => s.visibility > 0);
    } else {
      eligible = this.map.data.systems
        .filter((s) => s.visibility > 2
          && store.state.game.data.population_class.some((pc) => pc.key === s.class));
    }
    if (eligible.length === 0) return;

    const material = new MeshBasicMaterial({
      color: 0xffffff,
      transparent: true,
      opacity: 0.25,
      side: FrontSide,
    });
    const rings = new InstancedMesh(ringUnitGeometry, material, eligible.length);
    rings.name = 'system-rings';
    // Default frustum culling tests the unit geometry's bounding sphere
    // (radius 1 at the InstancedMesh's local origin) — wrong for a mesh
    // whose instances span the whole galaxy. Disable so the culler doesn't
    // hide instances that are actually in view.
    rings.frustumCulled = false;

    eligible.forEach((system, i) => {
      let radius;
      if (mode === 'visibility') {
        radius = 0.25 * system.visibility;
      } else {
        const pc = store.state.game.data.population_class.find((p) => p.key === system.class);
        radius = 0.15 * pc.points;
      }
      _scratchDummy.position.set(
        system.position.x,
        system.position.y,
        config.MAP.Z_SYSTEM_NEAR_RING,
      );
      _scratchDummy.scale.set(radius, radius, 1);
      _scratchDummy.quaternion.set(0, 0, 0, 1);
      _scratchDummy.updateMatrix();
      rings.setMatrixAt(i, _scratchDummy.matrix);

      const faction = system.faction || 'neutral';
      _scratchColor.set(this.colors[faction].hex.normal);
      rings.setColorAt(i, _scratchColor);
    });

    rings.instanceMatrix.needsUpdate = true;
    if (rings.instanceColor) rings.instanceColor.needsUpdate = true;

    sng.add(rings);
  }

  // Build per-variant base-sprite InstancedMeshes inside a mode's sng.
  // The original code created one cloned Sprite per system; this groups
  // systems by (type, habitability, visibility) and builds one
  // InstancedMesh per group. Each InstancedMesh stores an
  // instanceId → sn map in userData so the hover code in map.js can
  // resolve a raycast intersection to the per-system Group that carries
  // the gameObject and showOnHover children.
  buildBaseSpritesInstancedMeshes(sng) {
    const existing = sng.children.filter((c) => c.name && c.name.startsWith('system-base|'));
    existing.forEach((c) => {
      sng.remove(c);
      c.material.dispose();
      c.dispose();
    });

    // Group systems by sprite variant.
    const variants = new Map();
    this.map.data.systems.forEach((system) => {
      const habitability = ['uninhabitable', 'uninhabited'].includes(system.status) ? 'uninhabited' : 'inhabited';
      const visibility = system.visibility === 0 ? 'unknown' : 'known';
      const key = `system-base|${system.type}|${habitability}|${visibility}`;
      let entry = variants.get(key);
      if (!entry) {
        entry = { type: system.type, habitability, visibility, systems: [] };
        variants.set(key, entry);
      }
      entry.systems.push(system);
    });

    variants.forEach((variant, key) => {
      if (variant.systems.length === 0) return;

      const sourceSprite = this.map.materials.sprites.systems[variant.type][variant.habitability][variant.visibility];
      const sourceMaterial = sourceSprite.material;
      const size = sourceSprite.scale.x;

      // Mirror the source SpriteMaterial as a MeshBasicMaterial. Set
      // transparent explicitly — the original SpriteMaterial relied on
      // an implicit Sprite-side transparency flag that doesn't survive
      // the swap to a plain Mesh.
      const material = new MeshBasicMaterial({
        map: sourceMaterial.map,
        transparent: true,
        opacity: sourceMaterial.opacity,
        side: FrontSide,
      });

      const instanced = new InstancedMesh(planeUnitGeometry, material, variant.systems.length);
      instanced.name = key;
      instanced.frustumCulled = false;
      instanced.userData.hoverable = true;
      instanced.userData.systemGroupByInstanceId = {};

      variant.systems.forEach((system, i) => {
        _scratchDummy.position.set(
          system.position.x,
          system.position.y,
          config.MAP.Z_SYSTEM_NEAR_STAR,
        );
        _scratchDummy.scale.set(size, size, 1);
        _scratchDummy.quaternion.set(0, 0, 0, 1);
        _scratchDummy.updateMatrix();
        instanced.setMatrixAt(i, _scratchDummy.matrix);

        // Look up the per-system Group already created by nearSystem
        // and stash it on the InstancedMesh keyed by instanceId. The
        // hover code special-cases isInstancedMesh intersections to
        // read this map and treat the looked-up sn as if the cursor
        // had hit it directly.
        const sn = sng.children.find((c) => c.userData && c.userData.name === `system-${system.id}`);
        if (sn) instanced.userData.systemGroupByInstanceId[i] = sn;
      });

      instanced.instanceMatrix.needsUpdate = true;
      sng.add(instanced);
    });
  }

  nearSystem(system, name, mode) {
    const sn = new Group();
    sn.name = 'system-near';
    sn.userData.name = name;

    // affect game object here in order to allow click
    sn.gameObject = { type: 'system', data: system };

    // (per-system hover disk removed — replaced by the single shared
    // this.hoverIndicator built in _create and managed by
    // Map#showHover/hideHover.)

    // (base sprite moved to a per-variant InstancedMesh built by
    // buildBaseSpritesInstancedMeshes; the InstancedMesh is what
    // carries userData.hoverable now, and the hover walk in map.js
    // resolves an InstancedMesh hit's instanceId back to this sn.)

    // (faction/owner overlay sprite for dominion/player systems moved
    // to per-variant InstancedMeshes — buildOwnedSpritesInstancedMeshes.)

    // Only permanently-visible labels are built here (own systems' name
    // labels and the mode numerals). Hover-only labels — the vast
    // majority at galaxy scale — are built lazily by attachHoverLabels
    // when the cursor first reaches the system, so they never weigh on
    // the per-frame scene walk (or on startup text-geometry generation).
    this.labelSpecs(system, mode)
      .filter((spec) => spec.isVisible)
      .forEach((spec) => {
        sn.add(this.createSystemLabel(system, spec.shift, spec.text, true, spec.options));
      });

    return sn;
  }

  // One spec per label the system can show: permanent ones
  // (isVisible: true) are attached at build time by nearSystem, the
  // rest exist only while hovered (attachHoverLabels). Kept as data so
  // both paths derive from the same branching.
  labelSpecs(system, mode) {
    const faction = system.faction ? system.faction : 'neutral';
    const colors = this.colors[faction];
    const populationClass = store.state.game.data.population_class.find((pc) => pc.key === system.class);
    const ownSystem = this.map.playerSystems.find((sys) => sys.id === system.id);
    const ownDominion = this.map.playerDominions.find((sys) => sys.id === system.id);
    const systemName = ['inhabited_neutral', 'inhabited_dominion'].includes(system.status)
      ? `${system.name}*` : system.name;

    const specs = [];

    if ((ownDominion || ownSystem) || (!system.owner && system.visibility === 0)) {
      const labelVisibility = !!system.owner;

      specs.push({
        shift: { x: 0.46, y: -0.12 },
        text: systemName,
        isVisible: labelVisibility,
        options: {
          fontSize: 0.25,
          textColor: this.map.materials.black,
          bckColor: colors.material.darker,
          zIndex: config.MAP.Z_SYSTEM_NEAR_LABEL,
          // Always-shown player-owned-system labels sit ~0.46 to the right of
          // the dot and can permanently obscure a neighbour. Marking the label
          // canFlip lets map.js' showHover translate it to the mirror side on
          // cursor entry, so the player can uncover whatever it's covering.
          canFlip: labelVisibility,
        },
      });
    } else {
      specs.push({
        shift: { x: 0.46, y: 0.08 },
        text: systemName,
        isVisible: false,
        options: {
          fontSize: 0.25,
          textColor: this.map.materials.black,
          bckColor: colors.material.darker,
          zIndex: config.MAP.Z_SYSTEM_NEAR_LABEL,
        },
      });

      const secondLine = system.owner
        ? system.owner
        : (system.score === 0
          ? this.map.vm.$t('galaxy.map.uninhabitable')
          : `${system.score} ${this.map.vm.$tc('galaxy.map.orbit', system.score)}`);

      specs.push({
        shift: { x: 0.46, y: -0.30 },
        text: secondLine,
        isVisible: false,
        options: {
          fontSize: 0.18,
          textColor: this.map.materials.black,
          bckColor: colors.material.lighter,
          zIndex: config.MAP.Z_SYSTEM_NEAR_LABEL,
        },
      });
    }

    // Mode-specific numeric label ('1'..'5' for visibility, population
    // points for population). The corresponding ring around each system
    // is built in bulk by buildRingsInstancedMesh, not here.
    if (mode === 'visibility' && system.visibility > 0) {
      specs.push({
        shift: { x: 0.26, y: 0.26 },
        text: `${system.visibility}`,
        isVisible: true,
        options: {
          fontSize: 0.15,
          textColor: this.map.materials.white,
          zIndex: config.MAP.Z_SYSTEM_NEAR_LABEL,
        },
      });
    } else if (mode === 'population' && populationClass && system.visibility > 2) {
      specs.push({
        shift: { x: 0.26, y: 0.26 },
        text: `${populationClass.points}`,
        isVisible: true,
        options: {
          fontSize: 0.15,
          textColor: this.map.materials.white,
          zIndex: config.MAP.Z_SYSTEM_NEAR_LABEL,
        },
      });
    }

    return specs;
  }

  // Map a hover-walk hit (the sn Group itself, or one of its label
  // Groups — labels carry gameObject too) back to the sn Group that
  // lazy hover labels attach to.
  resolveSystemGroup(hovered) {
    if (!hovered) return null;
    if (hovered.name === 'system-near') return hovered;
    if (hovered.parent && hovered.parent.name === 'system-near') return hovered.parent;
    return null;
  }

  attachHoverLabels(hovered) {
    const sn = this.resolveSystemGroup(hovered);
    if (!sn || !sn.gameObject) return;

    const system = sn.gameObject.data;
    const key = `${this.mode}|${system.id}`;
    let labels = this.hoverLabelCache.get(key);

    if (!labels) {
      labels = this.labelSpecs(system, this.mode)
        .filter((spec) => !spec.isVisible)
        .map((spec) => {
          const label = this.createSystemLabel(system, spec.shift, spec.text, false, spec.options);
          // Tagged so detachHoverLabels can find them on the sn without
          // relying on cache-key state (mode may have switched while
          // hovered).
          label.userData.lazyHoverLabel = true;
          return label;
        });
      this.hoverLabelCache.set(key, labels);
    }

    labels.forEach((label) => {
      label.visible = true;
      sn.add(label);
    });
  }

  detachHoverLabels(hovered) {
    const sn = this.resolveSystemGroup(hovered);
    if (!sn) return;

    sn.children
      .filter((child) => child.userData.lazyHoverLabel)
      .forEach((label) => {
        label.visible = false;
        sn.remove(label);
      });
  }

  // Build the far-view InstancedMeshes inside a mode's systems-far
  // group: one mesh per opacity bucket (visibility 0 systems render at
  // 0.5, the rest at 1.0 — opacity is a material property, so buckets),
  // plus one for the player's own-system halos. Replaces one Group +
  // 1-2 Meshes per system. Instance color carries the faction tint;
  // instance scale carries the per-type display size.
  buildFarInstancedMeshes(sfg) {
    const existing = sfg.children.filter((c) => c.name && c.name.startsWith('system-far|'));
    existing.forEach((c) => {
      sfg.remove(c);
      // farUnitDisk / farHoverDisk are shared across rebuilds — don't
      // dispose the geometry.
      c.material.dispose();
      c.dispose();
    });

    const sizeFactorByType = this.map.gameData.stellar_system.reduce((acc, s) => {
      acc[s.key] = s.display_size_factor;
      return acc;
    }, {});

    const buckets = { known: [], unknown: [] };
    this.map.data.systems.forEach((system) => {
      buckets[system.visibility === 0 ? 'unknown' : 'known'].push(system);
    });

    Object.entries(buckets).forEach(([bucket, systems]) => {
      if (systems.length === 0) return;

      const material = new MeshBasicMaterial({
        color: 0xffffff,
        transparent: true,
        opacity: bucket === 'unknown' ? 0.5 : 1.0,
        side: FrontSide,
      });
      const circles = new InstancedMesh(farUnitDisk, material, systems.length);
      circles.name = `system-far|${bucket}`;
      // Same reasoning as the rings mesh: the unit geometry's bounding
      // sphere is meaningless for galaxy-spanning instances.
      circles.frustumCulled = false;

      systems.forEach((system, i) => {
        const radius = 0.2 * (sizeFactorByType[system.type] || 1);
        _scratchDummy.position.set(system.position.x, system.position.y, config.MAP.Z_SYSTEM_FAR_STAR);
        _scratchDummy.scale.set(radius, radius, 1);
        _scratchDummy.quaternion.set(0, 0, 0, 1);
        _scratchDummy.updateMatrix();
        circles.setMatrixAt(i, _scratchDummy.matrix);

        _scratchColor.set(system.faction ? this.colors[system.faction].hex.lighter : 0xffffff);
        circles.setColorAt(i, _scratchColor);
      });

      circles.instanceMatrix.needsUpdate = true;
      if (circles.instanceColor) circles.instanceColor.needsUpdate = true;

      sfg.add(circles);
    });

    const ownIds = new Set(
      [...this.map.playerSystems, ...this.map.playerDominions].map((s) => s.id),
    );
    const own = this.map.data.systems.filter((s) => ownIds.has(s.id));
    if (own.length > 0) {
      const playerFaction = store.state.game.player.faction;
      const material = new MeshBasicMaterial({
        color: this.colors[playerFaction].hex.normal,
        transparent: true,
        opacity: 0.20,
        side: FrontSide,
      });
      const halos = new InstancedMesh(farHoverDisk, material, own.length);
      halos.name = 'system-far|own';
      halos.frustumCulled = false;

      own.forEach((system, i) => {
        _scratchDummy.position.set(system.position.x, system.position.y, config.MAP.Z_SYSTEM_FAR_OWN);
        _scratchDummy.scale.set(1, 1, 1);
        _scratchDummy.quaternion.set(0, 0, 0, 1);
        _scratchDummy.updateMatrix();
        halos.setMatrixAt(i, _scratchDummy.matrix);
      });

      halos.instanceMatrix.needsUpdate = true;
      sfg.add(halos);
    }
  }

  // Build per-variant InstancedMeshes for the faction/owner overlay
  // sprites shown on inhabited_dominion / inhabited_player systems,
  // grouped by (type × faction × owner × visibility). The overlay sits
  // 0.01 above the base sprite; renderOrder pushes it after the base
  // meshes in the transparent pass so blending stays correct (the
  // painter's sort can't order InstancedMeshes that all sit at the
  // scene origin).
  buildOwnedSpritesInstancedMeshes(sng) {
    const existing = sng.children.filter((c) => c.name && c.name.startsWith('system-owned|'));
    existing.forEach((c) => {
      sng.remove(c);
      c.material.dispose();
      c.dispose();
    });

    const variants = new Map();
    this.map.data.systems.forEach((system) => {
      if (!['inhabited_dominion', 'inhabited_player'].includes(system.status)) return;

      const faction = system.faction ? system.faction : 'neutral';
      const owner = system.status === 'inhabited_dominion' ? 'dominion' : 'player';
      const visibility = system.visibility === 0 ? 'unknown' : 'known';
      const key = `system-owned|${system.type}|${faction}|${owner}|${visibility}`;
      let entry = variants.get(key);
      if (!entry) {
        entry = { type: system.type, faction, owner, visibility, systems: [] };
        variants.set(key, entry);
      }
      entry.systems.push(system);
    });

    variants.forEach((variant, key) => {
      const sourceSprite = this.map.materials.sprites
        .systems[variant.type].factions[variant.faction][variant.owner][variant.visibility];
      const sourceMaterial = sourceSprite.material;
      const size = sourceSprite.scale.x;

      const material = new MeshBasicMaterial({
        map: sourceMaterial.map,
        color: sourceMaterial.color,
        transparent: true,
        opacity: sourceMaterial.opacity,
        side: FrontSide,
      });

      const instanced = new InstancedMesh(planeUnitGeometry, material, variant.systems.length);
      instanced.name = key;
      instanced.frustumCulled = false;
      // Hover hits resolve through the base-sprite InstancedMesh (which
      // covers every system, including these); the overlay stays out of
      // the hover walk.
      instanced.renderOrder = 1;

      variant.systems.forEach((system, i) => {
        _scratchDummy.position.set(
          system.position.x,
          system.position.y,
          config.MAP.Z_SYSTEM_NEAR_STAR + 0.01,
        );
        _scratchDummy.scale.set(size, size, 1);
        _scratchDummy.quaternion.set(0, 0, 0, 1);
        _scratchDummy.updateMatrix();
        instanced.setMatrixAt(i, _scratchDummy.matrix);
      });

      instanced.instanceMatrix.needsUpdate = true;
      sng.add(instanced);
    });
  }

  createSystemLabel(system, shift, text, isVisible, options) {
    const gameObject = { type: 'system', data: system };
    const position = {
      x: system.position.x + shift.x,
      y: system.position.y + shift.y,
    };

    // Pass the raw x-shift through so createLabel can compute the mirror
    // translation for labels that flip on hover. The y-shift doesn't change
    // on flip (we only mirror horizontally), so it doesn't need to travel.
    return this.createLabel(position, text, isVisible, gameObject, { ...options, _shiftX: shift.x });
  }

  createLabel(position, text, isVisible, gameObject, options) {
    const label = new Group();
    label.gameObject = gameObject;
    label.userData.hoverable = true;

    if (!isVisible) {
      label.visible = false;
      label.userData.showOnHover = true;
    }

    const shape = this.map.fonts.nunito800.generateShapes(text.toUpperCase(), options.fontSize);
    const textGeometry = new ShapeBufferGeometry(shape);
    const textSize = new Vector3();
    textGeometry.computeBoundingBox();
    textGeometry.boundingBox.getSize(textSize);

    const x = position.x;
    const y = position.y;
    const z = options.zIndex;

    const textMesh = new Mesh(textGeometry, options.textColor);
    textMesh.position.set(x, y, z);
    label.add(textMesh);

    if (options.bckColor) {
      const padding = 0.1;
      const rect = new PlaneGeometry(textSize.x + (2 * padding), textSize.y + (2 * padding), 32);
      const backgroundMesh = new Mesh(rect, options.bckColor);
      backgroundMesh.position.set(x + (textSize.x / 2), y + (textSize.y / 2), z - 0.01);
      label.add(backgroundMesh);
    }

    if (options.canFlip && typeof options._shiftX === 'number') {
      // Precompute the translation that mirrors this label to the opposite
      // side of the system dot. Original anchor: system.x + shift.x. Mirror
      // anchor (right edge of label sitting just left of the dot):
      //   system.x - shift.x - textSize.x
      // → delta from original = -(2 * shift.x + textSize.x).
      // map.js' showHover toggles label.position.x between 0 and this delta.
      label.userData.canFlip = true;
      label.userData.flipDelta = -((2 * options._shiftX) + textSize.x);
    }

    return label;
  }
}
