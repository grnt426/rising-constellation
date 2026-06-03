import { Group, Sprite, SpriteMaterial } from 'three';

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

      const sprite = new Sprite(material.clone());
      const scale = SCALE_BY_KIND[icon.kind] || ICON_SCALE_DEFAULT;
      sprite.scale.set(scale, scale, 1);
      sprite.position.set(
        system.position.x + ICON_OFFSET_X,
        system.position.y + ICON_OFFSET_Y,
        config.MAP.Z_SYSTEM_NEAR_STAR + 0.02,
      );
      // Stash the placer + system for hover-attribution; the picker
      // already pulls from the store so this is just a future hook
      // (e.g. tooltips on the map itself).
      sprite.userData.systemId = icon.system_id;
      sprite.userData.placerId = icon.placer_id;
      sprite.userData.kind = icon.kind;
      this.iconsGroup.add(sprite);
    });
  }

  // Pull the live faction icon list off the store on every update.
  // The faction_faction channel broadcast (see backend
  // Faction.Agent#on_call({:place_icon, ...})) carries the full
  // icons array, so reading from store is always current.
  factionIcons() {
    const faction = store.state.game.faction;
    return (faction && faction.icons) || [];
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
