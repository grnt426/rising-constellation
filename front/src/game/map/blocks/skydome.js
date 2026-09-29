import {
 Group,
 LoadingManager,
} from 'three';

import { MTLLoader } from 'three/examples/jsm/loaders/MTLLoader';
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader';

import { loadAsset, loadTexture } from '../asset-loader';
import Block from './block';

export default class Skydome extends Block {
  constructor(map) {
    super(map, 'Skydome');
  }

  _create() {
    // position is centered on the map
    const skyDomePosition = {
      x: this.map.size / 2,
      y: this.map.size / 2,
      z: -250,
    };
    const scale = 330;

    const skydomeGroup = new Group();
    Object.assign(skydomeGroup.userData, { near: -Infinity, far: Infinity });

    const onFailure = (url, error) => this.map.reportAssetFailure(url, error);
    const manager = new LoadingManager();
    // The MTL's textures (map_Kd) load through the same retrying loader as
    // the system sprites instead of a bare TextureLoader.
    manager.addHandler(/\.(png|jpe?g|webp)$/i, { load: (url) => loadTexture(url, onFailure) });

    const mtlLoader = new MTLLoader(manager)
      .setMaterialOptions({ ignoreZeroRGBs: true })
      .setPath('./map/skydome/');
    const objLoader = new OBJLoader(manager)
      .setPath('./map/skydome/');

    loadAsset(mtlLoader, 'skybowl_001_LL.mtl', onFailure)
      .then((materials) => {
        materials.preload();
        Object.entries(materials.materials).forEach(([, material]) => {
          material.alphaTest = 0;
          material.transparent = true;
          material.fog = false;
        });

        return loadAsset(objLoader.setMaterials(materials), 'skybowl_001_LL.obj', onFailure);
      })
      .then((sky) => {
        sky.rotateX(Math.PI / 2);
        sky.position.x = skyDomePosition.x;
        sky.position.y = skyDomePosition.y;
        sky.position.z = skyDomePosition.z;
        sky.scale.set(scale, scale, scale);
        sky.name = 'skydome';
        skydomeGroup.add(sky);
      })
      .catch(() => {}); // already reported; the map works without its backdrop

    this.group.add(skydomeGroup);
  }

  _update() {
    this.log(`updating ${this.group.name}`);
  }
}
