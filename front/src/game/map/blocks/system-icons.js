import {
  Group, Mesh, ShapeBufferGeometry, Sprite, SpriteMaterial,
} from 'three';

import config from '@/config';
import store from '@/store';
import { disposeObjectTree } from '../three-utils';
import { loadIconTextures } from '../icon-textures';

import Block from './block';

// Player-placed marker icons live on their own block (not folded into
// the System block) so they can update independently of system
// repaints — placing an icon shouldn't force every system mesh in the
// faction to rebuild, and a faction whose chat message landed
// shouldn't repaint every icon either.
//
// The single "icons-near" group has near/far set to the SAME range as
// the System block's "systems-near" group. block.js#onZ uses those to
// hide the group at far zoom, which gives us the design's
// "no icons at Far zoom" behavior automatically — no extra logic.

// Sprite scale — hand-tuned per kind so glyphs of different visual
// weights (line-art vs. solid-filled) read as roughly the same size
// at a glance. `target` (priority) gets the biggest bump on purpose
// — strategic emphasis. `danger` stays at the default so the burst
// shape has room to breathe.
const ICON_SCALE_DEFAULT = 0.35;
const SCALE_BY_KIND = {
  attack: 0.3,
  flag: 0.3,
  path: 0.3,
  question: 0.33,
  shield: 0.3,
  target: 0.38,
};

// Pulled slightly to the left of the system dot so the marker doesn't
// crowd the right-anchored system label. Y nudges up just enough to
// clear the faction sprite below.
const ICON_OFFSET_X = -0.3;
const ICON_OFFSET_Y = 0.25;

export default class SystemIcons extends Block {
  constructor(map) {
    super(map, 'SystemIcons');
    this.materials = null;
    this.lastRenderedKey = '';
    this.iconsGroup = null;

    // Async-load the textures. _create / _update will no-op until
    // they're ready so the first faction-state arrival doesn't try to
    // build sprites before we have material to attach.
    loadIconTextures().then((textures) => {
      this.materials = Object.entries(textures).reduce((acc, [kind, texture]) => {
        acc[kind] = new SpriteMaterial({
          map: texture,
          transparent: true,
          depthTest: false,
          // Keep the marker on top of the system dot regardless of
          // angle. The map is effectively top-down so this is safe.
        });
        return acc;
      }, {});
      // Force a paint once textures land.
      this.lastRenderedKey = '';
      this.update({});
    });
  }

  // Override Block#update — the base gates `_update` on
  // `time.is_running`, but a placement made during a pause (or
  // tutorial walkthrough) still needs to render. Icons also have no
  // animated state, so the key-based short-circuit in `_update` means
  // there's no cost to running every frame when nothing changed.
  async update(data) {
    if (!this.children.length) {
      this._create(data);
    } else {
      this._update(data);
    }
  }

  _create() {
    this.iconsGroup = new Group();
    this.iconsGroup.name = 'icons-near';
    // Match the system-near zoom window so the existing onZ machinery
    // hides icons at Far automatically.
    Object.assign(this.iconsGroup.userData, { near: 20, far: 200 });
    this.group.add(this.iconsGroup);
    this._update();
  }

  _update() {
    if (!this.materials || !this.iconsGroup) return;

    const icons = this.factionIcons();
    const key = this.makeKey(icons);
    if (key === this.lastRenderedKey) return;
    this.lastRenderedKey = key;

    // Simple diff-by-rebuild. Placement is rare (player click) so the
    // amortized cost of disposing and rebuilding every faction icon
    // on each change is fine, and the code stays trivially
    // correct — no orphan-sprite bugs.
    //
    // IMPORTANT: dispose each child individually with
    // removeFromParent:false. Passing iconsGroup to disposeObjectTree
    // would queue a microtask that ALSO detaches iconsGroup from
    // this.group itself — visible for one frame then gone. Found the
    // hard way: icons appeared and vanished after a few frames.
    this.iconsGroup.children.forEach((child) => {
      disposeObjectTree(child, {
        removeFromParent: false,
        destroyGeometry: true,
        destroyMaterial: true,
      });
    });
    while (this.iconsGroup.children.length > 0) {
      this.iconsGroup.remove(this.iconsGroup.children[0]);
    }

    icons.forEach((icon) => {
      const system = this.systemById(icon.system_id);
      if (!system) return; // unknown system_id — ignore quietly
      const material = this.materials[icon.kind];
      if (!material) return; // unknown kind — ignore quietly

      // Each placed icon is wrapped in a Group so the existing hover
      // machinery (see Map#showHover / hideHover) can find the
      // sibling "by X" label via the standard `userData.showOnHover`
      // flag. The wrapper carries `gameObject` so the hover walker
      // can identify the type without poking at sprites.
      //
      // The `.name` is required: `hideHover` falls back to walking
      // the PARENT's children when the hovered group is unnamed
      // (the "this is a system label" heuristic), which would hide
      // every sibling icon's children — none of which match the
      // showOnHover filter — leaving our just-shown label stuck
      // until the cursor lands on something else. Naming the
      // wrapper sends hideHover down the own-children branch, where
      // the label actually lives.
      const iconWrapper = new Group();
      iconWrapper.name = 'system-icon';
      iconWrapper.gameObject = {
        type: 'system_icon',
        data: {
          systemId: icon.system_id,
          placerId: icon.placer_id,
          kind: icon.kind,
        },
      };

      const iconX = system.position.x + ICON_OFFSET_X;
      const iconY = system.position.y + ICON_OFFSET_Y;

      const sprite = new Sprite(material.clone());
      const scale = SCALE_BY_KIND[icon.kind] || ICON_SCALE_DEFAULT;
      sprite.scale.set(scale, scale, 1);
      sprite.position.set(iconX, iconY, config.MAP.Z_SYSTEM_NEAR_STAR + 0.02);
      sprite.userData.hoverable = true;
      iconWrapper.add(sprite);

      const label = this.createHoverLabel(icon.placer_id, iconX, iconY);
      if (label) iconWrapper.add(label);

      this.iconsGroup.add(iconWrapper);
    });

    // Icons are static in world space; hover toggles `visible` only,
    // never touches position/scale. Freeze local matrices so the
    // renderer skips per-frame updateMatrix on every icon and label.
    // Rebuilds (placement/mute change) pass through this _update path,
    // so fresh sprites get frozen on the next paint.
    this.iconsGroup.traverse((o) => {
      o.matrixAutoUpdate = false;
      o.updateMatrix();
    });
  }

  // Build a small "by {name}" label parented to the icon wrapper.
  // Hidden by default; the hover machinery flips `visible` via the
  // `showOnHover` userData flag. Returns null if the fonts haven't
  // loaded yet (the first animate frame can race ahead of
  // loadFonts()); next rebuild will populate it.
  createHoverLabel(placerId, iconX, iconY) {
    const fonts = this.map.fonts;
    if (!fonts || !fonts.nunito800) return null;

    const placerName = this.placerNameFor(placerId);
    const vm = this.map.vm;
    const text = vm
      ? vm.$t('galaxy.map.icons.placed_by_short', { name: placerName })
      : `by ${placerName}`;

    const label = new Group();
    label.visible = false;
    label.userData.showOnHover = true;

    const shape = fonts.nunito800.generateShapes(text.toUpperCase(), 0.15);
    const textGeometry = new ShapeBufferGeometry(shape);
    const textMesh = new Mesh(textGeometry, this.map.materials.white);
    // Position the label up-and-left of the icon so it doesn't
    // overlap the system label that sits to the right of the dot.
    textMesh.position.set(iconX - 0.1, iconY + 0.15, config.MAP.Z_SYSTEM_NEAR_LABEL);
    label.add(textMesh);

    return label;
  }

  // Look up the placer's display name from the in-memory faction
  // roster. Falls back to the i18n "former member" string when the
  // placer profile has been deleted (FK SET NULL on system_icons
  // means `placer_id` is null in that case, but we also defend
  // against a stale id that no longer matches any roster entry).
  placerNameFor(placerId) {
    const vm = this.map.vm;
    const former = vm
      ? vm.$t('galaxy.map.icons.placed_by_former_short')
      : 'former member';
    if (!placerId) return former;
    const players = (store.state.game.faction && store.state.game.faction.players) || [];
    const match = players.find((p) => p.id === placerId);
    return (match && match.name) || former;
  }

  // Pull the live faction icon list off the store on every update,
  // then drop icons placed by anyone the current account has muted.
  // Mute is applied here (renderer-side) rather than upstream of the
  // broadcast so other faction members' real-time state stays
  // unaffected and toggling a mute takes effect immediately on the
  // next animate frame — no round-trip required. Icons with no
  // `placer_id` (FK SET NULL after profile deletion) are never
  // muted: a "former member" can't be a mute target.
  //
  // The master `showSystemIcons` toggle (set from Map.vue's options
  // bar) short-circuits the list to []; the diff-by-key check in
  // _update then sees an empty key, rebuilds with no sprites, and
  // we're hidden until the toggle flips back.
  factionIcons() {
    if (!store.state.game.mapOptions.showSystemIcons) return [];
    const faction = store.state.game.faction;
    const all = (faction && faction.icons) || [];
    const isMuted = store.getters['portal/isIconMuted'];
    return all.filter((icon) => !(icon.placer_id && isMuted(icon.placer_id)));
  }

  systemById(id) {
    return this.map.data.systems.get
      ? this.map.data.systems.get(id)
      : this.map.data.systems.find((s) => s.id === id);
  }

  // Cheap stable key so _update can skip work when nothing changed.
  // Order-insensitive isn't required here — the backend orders by
  // insertion and reorders only on actual mutation.
  makeKey(icons) {
    if (!icons.length) return '';
    return icons.map((i) => `${i.system_id}:${i.kind}:${i.placer_id || 0}`).join('|');
  }
}
