import {
  FrontSide,
  Group,
  Mesh,
  MeshBasicMaterial,
  ShapeBufferGeometry,
  PlaneGeometry,
  Shape,
  Vector2,
  Vector3,
} from 'three';
import { MeshLine, MeshLineMaterial } from 'three.meshline';
import Offset from 'polygon-offset';

import config from '@/config';
import Block from './block';
import { disposeObjectTree } from '../three-utils';

const meshLineGroupSize = 3;

// due to a weird bug on the Offset external lib
// I had to make the padding twice
// the first one to "correct" the data (with a null padding)
// the second one is the real padding operation
export function offsetSector(sector, size = 0.2) {
  const offset = new Offset();
  const points = offset.data(sector.points).padding(0);

  try {
    return offset.data(points).padding(size);
  } catch (err) {
    return [points];
  }
}

export default class Sector extends Block {
  constructor(map) {
    super(map, 'Sector');
  }

  _create() {
    this.createSectors('near');
    this.createSectors('medium');
    this.createSectors('far');
    this.resetRepaint();
  }

  _update() {
    if (this.map.data.hasToRepaintSectors) {
      this.group.children.forEach((child) => disposeObjectTree(child));
      this.group.children = [];

      this.createSectors('near');
      this.createSectors('medium');
      this.createSectors('far');
      this.refresh();

      this.resetRepaint();
    }
  }

  resetRepaint() {
    this.map.data.hasToRepaintSectors = false;
  }

  createSectors(distance) {
    const distances = {
      near: { near: 20, far: 80, offset: 0.15, line: 0.05, opacity: 0.05, borderLabelSize: 0.7 },
      medium: { near: 80, far: 200, offset: 0.15, line: 0.1, opacity: 0.05, borderLabelSize: 1.2 },
      far: { near: 200, far: this.map.maxZ, offset: 0.3, line: 0.2, opacity: 0.12, borderLabelSize: 0 },
    };

    // sector lines and sector labels
    const group = new Group();
    group.name = `sector-${distance}`;
    Object.assign(group.userData, { near: distances[distance].near, far: distances[distance].far });

    this.map.data.sectors.forEach((sector) => {
      const colors = sector.owner ? this.colors[sector.owner] : this.colors.neutral;
      const material = sector.owner ? this.colors[sector.owner].material.darker : this.map.materials.lightGrey;

      offsetSector(sector, distances[distance].offset).forEach((polygon) => {
        const points = polygon.reduce((acc, [x, y]) => acc.concat([x, y, config.MAP.Z_SECTOR_NEAR]), []);
        points.push(points[0], points[1], points[2]);

        for (let i = meshLineGroupSize; i < points.length - meshLineGroupSize; i += meshLineGroupSize) {
          const lMaterial = new MeshLineMaterial({
            color: colors.hex.darker,
            transparent: true,
            lineWidth: distances[distance].line,
          });

          const geom = new MeshLine();
          geom.setPoints(points.slice(i - meshLineGroupSize, i + meshLineGroupSize));
          const line = new Mesh(geom, lMaterial);
          line.material.opacity = 0.5;
          group.add(line);
        }
      });

      offsetSector(sector, distances[distance].offset).forEach((polygon) => {
        const points = polygon.map(([x, y]) => new Vector2(x, y));
        const shape = new Shape(points);
        const geometry = new ShapeBufferGeometry(shape);
        const mesh = new Mesh(geometry, material.clone());
        mesh.position.setZ(config.MAP.Z_SECTOR_FAR);
        mesh.material.opacity = distances[distance].opacity;
        group.add(mesh);
      });

      if (distance === 'far') {
        const position = [sector.centroid[0], sector.centroid[1], config.MAP.Z_SECTOR_FAR_LABEL];
        const label = this.sectorLabel(sector.name, position, colors.hex.lighter, 1.5);
        label.gameObject = { type: 'sector', data: sector.id };

        group.add(label);
      } else if (sector.name && distances[distance].borderLabelSize) {
        offsetSector(sector, distances[distance].offset).forEach((polygon) => {
          this.addBorderLabels(group, sector.name, polygon, colors.hex.lighter, distances[distance].borderLabelSize);
        });
      }
    });

    this.group.add(group);

    // Sectors and their labels don't move in world space; camera panning
    // is handled by the view matrix. Freeze local matrices once so the
    // renderer skips per-frame updateMatrix/compose on every sector
    // border-line and label mesh. _update() repaints by disposing all
    // children and re-running createSectors for each distance, so freshly
    // created subtrees pass through here and get frozen too.
    group.traverse((o) => {
      o.matrixAutoUpdate = false;
      o.updateMatrix();
    });
  }

  addBorderLabels(group, name, polygon, colorHex, fontSize) {
    const text = name.toUpperCase();

    // Measure once per sector — same text reused across qualifying segments.
    const sharedGeom = new ShapeBufferGeometry(this.map.fonts.nunito800.generateShapes(text, fontSize));
    sharedGeom.computeBoundingBox();
    const size = new Vector3();
    const center = new Vector3();
    sharedGeom.boundingBox.getSize(size);
    sharedGeom.boundingBox.getCenter(center);
    const textWidth = size.x;
    const textHeight = size.y;
    sharedGeom.translate(-center.x, -center.y, 0);

    // Inset from each endpoint so acute corners don't get crowded.
    const cornerMargin = textHeight * 1.6;
    const minSegmentLength = textWidth + 2 * cornerMargin;
    const repeatThreshold = textWidth * 2.6 + 2 * cornerMargin;
    // Push the text's center inward from the edge so its bounding box doesn't
    // cross into the neighboring sector (text spans ±textHeight/2 perpendicular).
    const inwardInset = (textHeight / 2) + (textHeight * 0.25);

    const material = new MeshBasicMaterial({
      color: colorHex,
      transparent: true,
      side: FrontSide,
      opacity: 0.22,
    });

    // Polygon winding via signed area. For a simple polygon (convex or not),
    // CCW winding (positive area) places the interior on the LEFT of every
    // directed edge a→b, so the inward normal is (-dy, dx)/L. CW flips that.
    // A centroid-based test fails on concave shapes because the centroid can
    // sit on the wrong side of some edges.
    const nlen = polygon.length;
    let signedArea = 0;
    for (let i = 0; i < nlen; i += 1) {
      const [x1, y1] = polygon[i];
      const [x2, y2] = polygon[(i + 1) % nlen];
      signedArea += (x1 * y2) - (x2 * y1);
    }
    const ccw = signedArea > 0;

    let used = false;
    for (let i = 0; i < nlen; i += 1) {
      const a = polygon[i];
      const b = polygon[(i + 1) % nlen];
      const dx = b[0] - a[0];
      const dy = b[1] - a[1];
      const length = Math.sqrt((dx * dx) + (dy * dy));

      if (length < minSegmentLength) continue;

      let copies = 1;
      if (length >= repeatThreshold * 2) copies = 2;
      if (length >= repeatThreshold * 3) copies = 3;

      // Flip text by π when the segment direction would otherwise read upside-down.
      let angle = Math.atan2(dy, dx);
      if (angle > Math.PI / 2 || angle < -Math.PI / 2) {
        angle += Math.PI;
      }

      const nx = (ccw ? -dy : dy) / length;
      const ny = (ccw ? dx : -dx) / length;

      for (let c = 0; c < copies; c += 1) {
        const t = (c + 1) / (copies + 1);
        const x = a[0] + (dx * t) + (nx * inwardInset);
        const y = a[1] + (dy * t) + (ny * inwardInset);

        const mesh = new Mesh(sharedGeom, material);
        mesh.position.set(x, y, config.MAP.Z_SECTOR_BORDER_LABEL);
        mesh.rotation.z = angle;
        group.add(mesh);
        used = true;
      }
    }

    if (!used) {
      sharedGeom.dispose();
      material.dispose();
    }
  }

  sectorLabel(message, position, color, size = 10) {
    const label = new Group();

    const material = new MeshBasicMaterial({ color, side: FrontSide });
    const shapes = this.map.fonts.nunito800.generateShapes(message.toUpperCase(), size);
    const textGeometry = new ShapeBufferGeometry(shapes);
    const textSize = new Vector3();
    textGeometry.computeBoundingBox();
    textGeometry.boundingBox.getSize(textSize);

    // center text to position
    const x = position[0] - (textGeometry.boundingBox.max.x / 2);
    const y = position[1] - (textGeometry.boundingBox.max.y / 2);
    const z = position[2];

    const textMesh = new Mesh(textGeometry, material);
    textMesh.position.set(x, y, z);
    textMesh.userData.hoverable = true;
    label.add(textMesh);

    const padding = 5;
    const rect = new PlaneGeometry(textSize.x + (2 * padding), textSize.y + (2 * padding), 32);
    const backgroundMesh = new Mesh(rect, this.map.materials.white.clone());
    backgroundMesh.position.set(x + (textSize.x / 2), y + (textSize.y / 2), z - 0.01);
    backgroundMesh.material.opacity = 0;
    backgroundMesh.userData.hoverable = true;
    label.add(backgroundMesh);

    return label;
  }
}
