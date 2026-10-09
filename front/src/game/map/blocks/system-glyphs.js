import {
  CanvasTexture,
  Color,
  Group,
  InstancedBufferAttribute,
  InstancedMesh,
  LinearFilter,
  Object3D,
  PlaneGeometry,
  ShaderMaterial,
} from 'three';
import SvgIcon from 'vue-svgicon';

import config from '@/config';
import store from '@/store';
import {
  presence, fleetArcs, agentPips, statRows, statLayout, glyphRadii, glyphScale, STATS,
} from '../system-glyph';

import Block from './block';

// The "overview" map mode: around each system dot, who stands there and
// (for the faction's own systems) how well it holds.
//
//   ring         fleets. One arc per fleet, as long as its upkeep's share
//                of a full ring (FLEET_CAP), in its faction's colour. A
//                dashed arc is a fleet whose army the faction cannot read.
//   pips         the other agents in orbit, under the dot. A ring is an
//                Erased, a disc a Siderian.
//   stat ring    own faction's systems only, and only up close: icons
//                on one ring outside the rest, a third per stat
//                (intelligence top left, stability top right, defense
//                underneath). A large icon is 100, a small one 50, the
//                last part filled; negative stability is the same icons,
//                each split.
//   dashed ring  a system under siege.
//
// What to draw comes from system-glyph.js; the data is the faction's map
// intel (store `mapIntel`, refreshed by Map.vue while this mode is on)
// plus the viewer's own roster, which is live.
//
// Every arc and pip is one instance of one quad: the fragment shader cuts
// the shape out of it. The stat icons are instances of a second quad,
// textured from a small atlas. Two meshes in all, whatever the number of
// systems.

const MODE = 'overview';
// Past this altitude the stat icons are too small to tell apart: not drawn.
const DETAIL_FAR = 110;

// The resource icons the stat rows use, as vue-svgicon registers them
// (the same glyphs as the system view's own figures).
const STAT_ICONS = {
  defense: 'resource/defense',
  stability: 'resource/happiness',
  counter_intelligence: 'resource/counter_intelligence',
};
const ATLAS_CELL = 64;
// the icon is drawn inside its cell with a margin, so that linear
// filtering never bleeds a neighbour in
const ATLAS_MARGIN = 5;

const ARC = 0;
const PIP = 1;

const WHITE = 0xe6e6e6;
// $color-alert
const ALERT = 0xff832e;

const vertexShader = `
  attribute vec4 aShape;
  attribute vec3 aRadii;
  attribute vec4 aColor;

  // glyphScale(): the glyph grows about its system as the camera rises
  uniform float uScale;

  varying vec2 vPoint;
  varying vec4 vShape;
  varying vec2 vRadii;
  varying vec4 vColor;

  void main() {
    // the quad spans the glyph: [-extent, extent] around the system
    vPoint = (uv - 0.5) * 2.0 * aRadii.z;
    vShape = aShape;
    vRadii = aRadii.xy;
    vColor = aColor;

    vec4 local = vec4(position.xy * uScale, position.z, 1.0);
    #ifdef USE_INSTANCING
      local = instanceMatrix * local;
    #endif
    gl_Position = projectionMatrix * modelViewMatrix * local;
  }
`;

// aShape = (kind, angle, sweep | orbit, dashes | hollow), angles clockwise
// from 12 o'clock. Shapes keep a minimum width in pixels, so that a ring
// seen from far is thin rather than gone.
const fragmentShader = `
  varying vec2 vPoint;
  varying vec4 vShape;
  varying vec2 vRadii;
  varying vec4 vColor;

  const float TAU = 6.28318530718;

  void main() {
    float r = length(vPoint);
    float px = fwidth(r);
    float mask = 0.0;

    if (vShape.x < 0.5) {
      float mid = (vRadii.x + vRadii.y) * 0.5;
      float halfWidth = max((vRadii.y - vRadii.x) * 0.5, px * 0.8);
      float radial = 1.0 - smoothstep(halfWidth - px * 0.5, halfWidth + px * 0.5, abs(r - mid));

      float angle = atan(vPoint.x, vPoint.y);
      float d = mod(angle - vShape.y + 2.0 * TAU, TAU);
      float sweep = vShape.z;
      float along = 1.0;

      if (sweep < TAU - 0.001) {
        float edge = d <= sweep ? min(d, sweep - d) : -min(d - sweep, TAU - d);
        along = smoothstep(-px * 0.5, px * 0.5, edge * r);
        if (vShape.w > 0.5) {
          along *= step(fract(d / sweep * vShape.w), 0.6);
        }
      } else if (vShape.w > 0.5) {
        along = step(fract(d / TAU * vShape.w), 0.55);
      }

      mask = radial * along;
    } else {
      vec2 center = vShape.z * vec2(sin(vShape.y), cos(vShape.y));
      float dist = length(vPoint - center);
      float radius = max(vRadii.x, px * 1.3);
      mask = 1.0 - smoothstep(radius - px * 0.5, radius + px * 0.5, dist);
      if (vShape.w > 0.5) {
        float hole = radius * 0.5;
        mask *= smoothstep(hole - px * 0.5, hole + px * 0.5, dist);
      }
    }

    float alpha = vColor.a * mask;
    if (alpha < 0.01) discard;
    gl_FragColor = vec4(vColor.rgb, alpha);
  }
`;

const iconVertexShader = `
  attribute vec2 aOffset;
  attribute vec4 aIcon;
  attribute vec4 aColor;

  uniform float uScale;

  varying vec2 vUv;
  varying vec4 vIcon;
  varying vec4 vColor;

  void main() {
    vUv = uv;
    vIcon = aIcon;
    vColor = aColor;

    // the instance sits on its system: the icon's place and size are in
    // glyph units from there, and grow with the glyph
    vec4 local = vec4((aOffset + position.xy * aIcon.w) * uScale, position.z, 1.0);
    #ifdef USE_INSTANCING
      local = instanceMatrix * local;
    #endif
    gl_Position = projectionMatrix * modelViewMatrix * local;
  }
`;

// aIcon = (atlas cell, fill, broken, size). The part of the icon past
// `fill` is drawn dim, so that the icon's shape still reads. A broken
// icon is split down the middle, its halves pulled apart and out of line.
const iconFragmentShader = `
  uniform sampler2D uAtlas;
  uniform float uCells;

  varying vec2 vUv;
  varying vec4 vIcon;
  varying vec4 vColor;

  void main() {
    vec2 uv = vUv;

    if (vIcon.z > 0.5) {
      if (uv.x < 0.5) {
        uv = vec2(uv.x + 0.07, uv.y - 0.06);
        if (uv.x > 0.5) discard;
      } else {
        uv = vec2(uv.x - 0.07, uv.y + 0.06);
        if (uv.x < 0.5) discard;
      }
      if (uv.y < 0.0 || uv.y > 1.0) discard;
    }

    float shape = texture2D(uAtlas, vec2((vIcon.x + uv.x) / uCells, uv.y)).a;
    float lit = uv.x <= vIcon.y ? 1.0 : 0.3;
    float alpha = shape * lit * vColor.a;
    if (alpha < 0.02) discard;
    gl_FragColor = vec4(vColor.rgb, alpha);
  }
`;

// The stat icons side by side on one canvas, white on transparent: the
// shader only reads the alpha. Resolves to null when the icons are not
// registered (the rows are then left out, the rest of the glyph stays).
function bakeStatAtlas() {
  const registry = SvgIcon.icons || {};
  const icons = STATS.map((key) => registry[STAT_ICONS[key]]);
  if (icons.some((icon) => !icon)) return Promise.resolve(null);

  const canvas = document.createElement('canvas');
  canvas.width = ATLAS_CELL * icons.length;
  canvas.height = ATLAS_CELL;
  const ctx = canvas.getContext('2d');

  return Promise.all(icons.map((icon, i) => new Promise((resolve) => {
    const size = ATLAS_CELL - (ATLAS_MARGIN * 2);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${icon.viewBox}" `
      + `width="${size}" height="${size}" fill="#ffffff">${icon.data}</svg>`;
    const img = new Image();
    img.onload = () => {
      ctx.drawImage(img, (i * ATLAS_CELL) + ATLAS_MARGIN, ATLAS_MARGIN, size, size);
      resolve(true);
    };
    img.onerror = () => resolve(false);
    img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  }))).then((drawn) => {
    if (drawn.some((ok) => !ok)) return null;
    const texture = new CanvasTexture(canvas);
    texture.minFilter = LinearFilter;
    texture.magFilter = LinearFilter;
    return texture;
  });
}

const _dummy = new Object3D();
const _color = new Color();

export default class SystemGlyphs extends Block {
  constructor(map) {
    super(map, 'SystemGlyphs');
    this.lastKey = null;
    this.material = new ShaderMaterial({
      uniforms: { uScale: { value: 1 } },
      vertexShader,
      fragmentShader,
      transparent: true,
      depthWrite: false,
      // fwidth: core in WebGL2, an extension in WebGL1
      extensions: { derivatives: true },
    });

    // The stat rows wait for their atlas (three SVGs rasterized once);
    // without it they are left out.
    this.iconMaterial = null;
    bakeStatAtlas().then((atlas) => {
      if (!atlas) return;
      this.iconMaterial = new ShaderMaterial({
        uniforms: { uScale: { value: 1 }, uAtlas: { value: atlas }, uCells: { value: STATS.length } },
        vertexShader: iconVertexShader,
        fragmentShader: iconFragmentShader,
        transparent: true,
        depthWrite: false,
      });
      // repaint with the rows
      this.lastKey = null;
    });

    this.sizeFactors = this.map.gameData.stellar_system.reduce((acc, s) => {
      acc[s.key] = s.display_size_factor;
      return acc;
    }, {});

    // every frame the camera is in range, paused game or not
    this.animationCallbacks.push({
      near: 20,
      far: Infinity,
      cb: () => {
        const scale = glyphScale(this.map.camera.position.z);
        this.material.uniforms.uScale.value = scale;
        if (this.iconMaterial) this.iconMaterial.uniforms.uScale.value = scale;
      },
    });
  }

  // Intel lands and agents move while the game is paused too: repaint on
  // a key, not on the game clock (as SystemIcons does).
  async update(data) {
    if (!this.children.length) {
      this._create(data);
    } else {
      this._update(data);
    }
  }

  _create() {
    this.near = new Group();
    this.near.name = 'glyphs-near';
    Object.assign(this.near.userData, { near: 20, far: 200 });
    this.group.add(this.near);

    this.detail = new Group();
    this.detail.name = 'glyphs-detail';
    Object.assign(this.detail.userData, { near: 20, far: DETAIL_FAR });
    this.group.add(this.detail);

    this._update();
  }

  _update() {
    const key = this.makeKey();
    if (key === this.lastKey) return;
    this.lastKey = key;
    this.rebuild();
  }

  active() {
    return store.state.game.mapOptions.mode === MODE;
  }

  // What the glyphs depend on: the intel on hand and where the viewer's
  // own agents stand. Cheap enough to work out every frame.
  makeKey() {
    if (!this.active()) return 'off';

    const { mapIntel, player } = store.state.game;
    const own = (player.characters || [])
      .filter((c) => c.status === 'on_board' && c.system != null)
      .map((c) => `${c.id}@${c.system}:${c.army_maintenance || 0}`)
      .join(',');

    return `${mapIntel ? mapIntel.at : 0}|${own}`;
  }

  rebuild() {
    [this.near, this.detail].forEach((group) => {
      group.children.slice().forEach((mesh) => {
        group.remove(mesh);
        // each mesh owns its geometry (the instanced attributes live on
        // it); the material is the block's and stays
        mesh.geometry.dispose();
        mesh.dispose();
      });
    });

    if (!this.active()) return;

    const { mapIntel, player } = store.state.game;
    const ownFaction = player.faction;
    const intelSystems = (mapIntel && mapIntel.systems) || {};

    // the viewer's agents by system, straight from the roster
    const playerAgentIds = new Set();
    const live = {};
    (player.characters || []).forEach((c) => {
      playerAgentIds.add(c.id);
      if (c.status !== 'on_board' || c.system == null) return;
      (live[c.system] = live[c.system] || []).push({
        id: c.id,
        type: c.type,
        faction: ownFaction,
        upkeep: c.type === 'admiral' ? (c.army_maintenance || 0) : null,
      });
    });

    const near = [];
    const icons = [];
    const ids = new Set([...Object.keys(intelSystems), ...Object.keys(live)].map(Number));

    ids.forEach((id) => {
      const system = this.map.data.systemsById.get(id);
      if (!system) return;

      const intel = intelSystems[id];
      const radii = glyphRadii(this.sizeFactors[system.type] || 1);
      const at = { x: system.position.x, y: system.position.y, extent: radii.extent };
      const { fleets, agents } = presence({
        intelAgents: intel ? intel.agents : [],
        liveAgents: live[id],
        playerAgentIds,
        ownFaction,
      });

      if (fleets.length > 0) {
        // the ring the arcs fill
        near.push({ ...at, kind: ARC, angle: 0, span: Math.PI * 2, flag: 0, radii: radii.fleet, color: WHITE, alpha: 0.1 });
        fleetArcs(fleets).forEach((arc) => {
          near.push({
            ...at,
            kind: ARC,
            angle: arc.start,
            span: arc.sweep,
            flag: arc.known ? 0 : 3,
            radii: radii.fleet,
            color: this.factionColor(arc.faction),
            alpha: 0.95,
          });
        });
      }

      agentPips(agents).forEach((pip) => {
        near.push({
          ...at,
          kind: PIP,
          angle: pip.angle,
          span: radii.pipOrbit,
          flag: pip.type === 'spy' ? 1 : 0,
          radii: [radii.pipRadius, 0],
          color: this.factionColor(pip.faction),
          alpha: 0.95,
        });
      });

      if (intel && intel.siege) {
        near.push({ ...at, kind: ARC, angle: 0, span: Math.PI * 2, flag: 14, radii: radii.siege, color: ALERT, alpha: 0.95 });
      }

      statLayout(statRows(intel), radii.statRadius).forEach((icon) => {
        icons.push({
          x: at.x,
          y: at.y,
          offset: [icon.x, icon.y],
          cell: STATS.indexOf(icon.key),
          fill: icon.fill,
          broken: icon.broken,
          size: icon.size,
          // a negative stat is a warning: the game's alert colour
          color: icon.broken ? ALERT : WHITE,
        });
      });
    });

    this.addMesh(this.near, near);
    this.addIconMesh(this.detail, icons);
    this.refresh();
  }

  addIconMesh(group, icons) {
    if (icons.length === 0 || !this.iconMaterial) return;

    const geometry = new PlaneGeometry(1, 1);
    const offset = new Float32Array(icons.length * 2);
    const icon = new Float32Array(icons.length * 4);
    const color = new Float32Array(icons.length * 4);

    const mesh = new InstancedMesh(geometry, this.iconMaterial, icons.length);
    mesh.frustumCulled = false;
    mesh.renderOrder = 2;

    icons.forEach((s, i) => {
      offset.set(s.offset, i * 2);
      icon.set([s.cell, s.fill, s.broken ? 1 : 0, s.size], i * 4);
      _color.setHex(s.color);
      color.set([_color.r, _color.g, _color.b, 0.9], i * 4);

      _dummy.position.set(s.x, s.y, config.MAP.Z_SYSTEM_NEAR_STAR + 0.03);
      _dummy.scale.set(1, 1, 1);
      _dummy.updateMatrix();
      mesh.setMatrixAt(i, _dummy.matrix);
    });

    geometry.setAttribute('aOffset', new InstancedBufferAttribute(offset, 2));
    geometry.setAttribute('aIcon', new InstancedBufferAttribute(icon, 4));
    geometry.setAttribute('aColor', new InstancedBufferAttribute(color, 4));
    mesh.instanceMatrix.needsUpdate = true;

    mesh.matrixAutoUpdate = false;
    mesh.updateMatrix();
    group.add(mesh);
  }

  factionColor(faction) {
    return (this.colors[faction] || this.colors.neutral).hex.lighter;
  }

  addMesh(group, shapes) {
    if (shapes.length === 0) return;

    const geometry = new PlaneGeometry(1, 1);
    const shape = new Float32Array(shapes.length * 4);
    const radii = new Float32Array(shapes.length * 3);
    const color = new Float32Array(shapes.length * 4);

    const mesh = new InstancedMesh(geometry, this.material, shapes.length);
    // instances span the galaxy: the unit quad's bounds mean nothing
    mesh.frustumCulled = false;
    // over the star sprites and their faction overlays (renderOrder 1)
    mesh.renderOrder = 2;

    shapes.forEach((s, i) => {
      shape.set([s.kind, s.angle, s.span, s.flag], i * 4);
      radii.set([s.radii[0], s.radii[1], s.extent], i * 3);
      _color.setHex(s.color);
      color.set([_color.r, _color.g, _color.b, s.alpha], i * 4);

      _dummy.position.set(s.x, s.y, config.MAP.Z_SYSTEM_NEAR_STAR + 0.03);
      _dummy.scale.set(s.extent * 2, s.extent * 2, 1);
      _dummy.updateMatrix();
      mesh.setMatrixAt(i, _dummy.matrix);
    });

    geometry.setAttribute('aShape', new InstancedBufferAttribute(shape, 4));
    geometry.setAttribute('aRadii', new InstancedBufferAttribute(radii, 3));
    geometry.setAttribute('aColor', new InstancedBufferAttribute(color, 4));
    mesh.instanceMatrix.needsUpdate = true;

    mesh.matrixAutoUpdate = false;
    mesh.updateMatrix();
    group.add(mesh);
  }
}
