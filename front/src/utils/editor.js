import { Delaunay } from 'd3-delaunay';
import { polygon } from 'polygon-tools';
import Offset from 'polygon-offset';
import lodash from 'lodash';

const InsidePolygon = require('point-in-polygon');

export default {
  genVoronoi(rng, size, grid) {
    const points = [];

    for (let i = 0; i < size; i += grid) {
      for (let j = 0; j < size; j += grid) {
        points.push([
          Math.round(rng.next() * grid) + i,
          Math.round(rng.next() * grid) + j,
        ]);
      }
    }

    return Array
      .from(Delaunay.from(points).trianglePolygons())
      .map((triangle, id) => ({
        key: id,
        points: triangle,
        color: undefined,
      }));
  },
  createSector(id, name) {
    const color = ((id - 1) % 9) + 1;

    return {
      key: id,
      color: `editor-color-${color}`,
      name,
      triangles: [],
      // List of primitive components ({kind, points, params}). Empty
      // array = use triangle grouping; non-empty = shapes path. Sectors
      // can hold any number of shapes that get unioned into a single
      // polygon at assembly time (same union pipeline as triangles).
      shapes: [],
      // null = use the global density flow; a positive integer switches
      // this sector to "place exactly N systems, weighted by the same
      // hot-point falloff." See placeByExactCount.
      systemCount: null,
    };
  },
  // Shape primitives. All return a closed polygon ring ([first === last])
  // in the same screen-y-down convention as d3-delaunay's trianglePolygons,
  // so downstream consumers (polygon.union, polygon.area, polygon.centroid,
  // polygon-offset, point-in-polygon) behave identically to the legacy
  // Voronoi-triangle output.
  genRect(p1, p2) {
    const x1 = Math.min(p1[0], p2[0]);
    const x2 = Math.max(p1[0], p2[0]);
    const y1 = Math.min(p1[1], p2[1]);
    const y2 = Math.max(p1[1], p2[1]);
    return [[x1, y1], [x2, y1], [x2, y2], [x1, y2], [x1, y1]];
  },
  genEllipse(center, radiusPoint, segments = 32) {
    const rx = Math.abs(radiusPoint[0] - center[0]);
    const ry = Math.abs(radiusPoint[1] - center[1]);
    const points = [];
    for (let i = 0; i < segments; i += 1) {
      const t = (i / segments) * 2 * Math.PI;
      points.push([
        center[0] + rx * Math.cos(t),
        center[1] + ry * Math.sin(t),
      ]);
    }
    points.push(points[0].slice());
    return points;
  },
  genNgon(center, vertexPoint, sides) {
    const dx = vertexPoint[0] - center[0];
    const dy = vertexPoint[1] - center[1];
    const r = Math.sqrt((dx * dx) + (dy * dy));
    const rotation = Math.atan2(dy, dx);
    const n = Math.max(3, Math.min(12, Math.floor(sides)));
    const points = [];
    for (let i = 0; i < n; i += 1) {
      const t = rotation + ((i / n) * 2 * Math.PI);
      points.push([
        center[0] + r * Math.cos(t),
        center[1] + r * Math.sin(t),
      ]);
    }
    points.push(points[0].slice());
    return points;
  },
  createBlackhole(id, name, position, radius) {
    return {
      key: id,
      name,
      position,
      radius,
    };
  },
  toggleTriangleToSector(key, toggle, sector, triangles, sectors) {
    const triangle = triangles.find((p) => p.key === key);

    if (toggle) {
      if (triangle.color) {
        if (lodash.includes(sector.triangles, triangle)) {
          triangle.color = undefined;
          lodash.remove(sector.triangles, (p) => p.key === triangle.key);
        } else {
          sectors.forEach((s) => {
            lodash.remove(s.triangles, (p) => p.key === triangle.key);
          });

          triangle.color = sector.color;
          sector.triangles.push(triangle);
        }
      } else {
        triangle.color = sector.color;
        sector.triangles.push(triangle);
      }
    } else {
      if (triangle.color) {
        sectors.forEach((s) => {
          lodash.remove(s.triangles, (p) => p.key === triangle.key);
        });
      }

      triangle.color = sector.color;
      sector.triangles.push(triangle);
    }

    return { triangles, sectors };
  },
  assembleTriangles(sectors) {
    const errors = [];
    const hasPinch = this.hasPinch.bind(this);
    const splitAtPinch = this.splitAtPinch.bind(this);
    const polygonArea = this.polygonArea.bind(this);
    const offsetPolygon = this.offsetPolygon.bind(this);

    sectors = sectors
      .filter((sector) => (sector.shapes && sector.shapes.length > 0)
        || sector.triangles.length > 0)
      .map((sector, key) => {
        let points;

        if (sector.shapes && sector.shapes.length > 0) {
          // Shape primitives. Three-tier merge strategy:
          //
          //   Tier 1: edge-deletion merge (mergeBySharedEdges). When the
          //     user's primitives share boundary edges via snap, this
          //     walks the existing edges only — no new vertices, no
          //     intersection-introduced spikes. Clean by construction.
          //
          //   Tier 2: polygon.union fallback when no shared edges exist
          //     (shapes overlap area-wise or share only a vertex). May
          //     produce pinched results we then try to fix.
          //
          //   Tier 3: dilate-retry when the union produces a pinch or
          //     multi-piece result. Inflates inputs by 0.1 so vertex
          //     touches become real area overlaps.
          //
          //   Final defensive split + keep-largest catches anything that
          //   still has self-touches.
          const polys = sector.shapes.map((s) => s.points);
          let unionResult = null;

          if (polys.length === 1) {
            unionResult = [polys[0]];
          } else {
            const merged = this.mergeBySharedEdges(polys, 0.5);
            if (merged && merged.length > 0) {
              unionResult = merged;
            } else {
              unionResult = polygon.union(...polys);
              const pinched = unionResult.length === 1 && hasPinch(unionResult[0]);
              if (pinched || unionResult.length > 1) {
                const dilated = polys.map((p) => offsetPolygon(p, 0.1));
                const retry = polygon.union(...dilated);
                if (retry.length === 1 && !hasPinch(retry[0])) {
                  unionResult = retry;
                }
              }
            }
          }

          // Final defensive split: any remaining pinches get split into
          // separate rings, and any multi-piece result drops the smaller
          // pieces with a user-facing warning.
          const pieces = [];
          unionResult.forEach((ring) => {
            splitAtPinch(ring).forEach((p) => pieces.push(p));
          });

          if (pieces.length > 1) {
            errors.push({
              key: 'page.create.map_editor.toast_sector_pieces_dropped',
              params: { name: sector.name },
            });
            pieces.sort((a, b) => Math.abs(polygonArea(b)) - Math.abs(polygonArea(a)));
          }

          points = pieces[0];
        } else {
          // Legacy Voronoi flow: union the triangle ring into one polygon.
          const pointPolygons = sector.triangles.map((shape) => shape.points);
          const unionResult = polygon.union(...pointPolygons);

          if (unionResult.length > 1) {
            errors.push({
              key: 'page.create.map_editor.toast_sector_pieces_dropped',
              params: { name: sector.name },
            });
          }

          points = unionResult[0];
        }

        return {
          key,
          name: sector.name,
          color: sector.color,
          // Preserve the source primitives so re-opening a saved map in
          // the editor can show "Ellipse + Rectangle", and so step-2
          // re-edits don't lose individual-shape metadata.
          shapes: sector.shapes || [],
          points,
          points03: this.offsetPolygon(points, 0.3),
          points05: this.offsetPolygon(points, 0.5),
          points25: this.offsetPolygon(points, 2.5),
          area: polygon.area(points),
          centroid: polygon.centroid(points),
          systems: [],
        };
      });

    return { sectors, errors };
  },
  // For each polygon's edge, find any vertex of any OTHER polygon that
  // lies strictly inside the edge (a T-junction). Insert those points
  // into the edge so the resulting ring has them as proper vertices.
  // This is a preprocessing step for mergeBySharedEdges — without it,
  // a small square meeting one edge of a larger square at its midpoint
  // wouldn't produce a reverse-direction edge pair, and the algorithm
  // would fail to detect the shared boundary.
  splitAtTJunctions(polys, eps = 0.5) {
    if (!polys || polys.length === 0) return polys;
    // Collect all vertices grouped by polygon (excluding closing dups).
    const allVerts = polys.map((ring) => {
      if (!ring || ring.length < 2) return [];
      const closed = ring.length >= 2
        && ring[0][0] === ring[ring.length - 1][0]
        && ring[0][1] === ring[ring.length - 1][1];
      return ring.slice(0, closed ? -1 : ring.length).map((p) => p.slice());
    });
    const onSegment = (p, a, b) => {
      const dx = b[0] - a[0];
      const dy = b[1] - a[1];
      const lenSq = (dx * dx) + (dy * dy);
      if (lenSq < eps * eps) return false;
      const t = (((p[0] - a[0]) * dx) + ((p[1] - a[1]) * dy)) / lenSq;
      const len = Math.sqrt(lenSq);
      const tMargin = eps / len;
      if (t < tMargin || t > 1 - tMargin) return false;
      const px = a[0] + (t * dx);
      const py = a[1] + (t * dy);
      const ddx = p[0] - px;
      const ddy = p[1] - py;
      return ((ddx * ddx) + (ddy * ddy)) < eps * eps;
    };
    const result = [];
    for (let i = 0; i < polys.length; i += 1) {
      const ring = polys[i];
      if (!ring || ring.length < 3) { result.push(ring); continue; }
      const newRing = [];
      for (let e = 0; e < ring.length - 1; e += 1) {
        const a = ring[e];
        const b = ring[e + 1];
        newRing.push(a.slice());
        const inserts = [];
        for (let j = 0; j < allVerts.length; j += 1) {
          if (i === j) continue;
          const others = allVerts[j];
          for (let v = 0; v < others.length; v += 1) {
            if (onSegment(others[v], a, b)) inserts.push(others[v].slice());
          }
        }
        if (inserts.length > 0) {
          const dx = b[0] - a[0];
          const dy = b[1] - a[1];
          const lenSq = (dx * dx) + (dy * dy);
          inserts.sort((u, w) => {
            const tu = (((u[0] - a[0]) * dx) + ((u[1] - a[1]) * dy)) / lenSq;
            const tw = (((w[0] - a[0]) * dx) + ((w[1] - a[1]) * dy)) / lenSq;
            return tu - tw;
          });
          const dedup = [];
          inserts.forEach((p) => {
            if (!dedup.some((q) => (((p[0] - q[0]) ** 2) + ((p[1] - q[1]) ** 2)) < eps * eps)) {
              dedup.push(p);
            }
          });
          dedup.forEach((p) => newRing.push(p));
        }
      }
      newRing.push(ring[ring.length - 1].slice());
      result.push(newRing);
    }
    return result;
  },
  // Remove consecutive near-duplicate vertices from a closed ring.
  // polygon-offset prints "edges of the same polygon overlap" warnings
  // when two consecutive points coincide within float precision. The
  // merge walker and mirror generator both occasionally emit those —
  // canonicalization clustering rolls two adjacent vertices onto the
  // same canonical position, leaving a near-zero-length edge in the
  // output. This pass drops the dups while keeping ring closure.
  dedupConsecutive(ring, eps = 1e-4) {
    if (!ring || ring.length < 2) return ring;
    const out = [ring[0].slice()];
    for (let i = 1; i < ring.length; i += 1) {
      const last = out[out.length - 1];
      const dx = ring[i][0] - last[0];
      const dy = ring[i][1] - last[1];
      if ((dx * dx) + (dy * dy) > eps * eps) out.push(ring[i].slice());
    }
    // Ensure ring closure (last == first) if it was closed originally.
    if (out.length >= 3) {
      const first = out[0];
      const last = out[out.length - 1];
      if (Math.abs(first[0] - last[0]) > eps || Math.abs(first[1] - last[1]) > eps) {
        out.push(first.slice());
      }
    }
    return out;
  },
  // Merge multiple closed polygons that share boundary edges by deleting
  // those edges, then walking the remaining edge set to form one or more
  // cycles. Algorithm:
  //
  //   1. Canonicalize vertices into a pool (eps-tolerant clustering) so
  //      "the same vertex in two polygons" maps to a single integer id.
  //   2. Collect directed edges from every input ring, tagged with their
  //      source polygon index.
  //   3. Find pairs of edges (A→B in poly i, B→A in poly j with i≠j) —
  //      these are the shared boundaries between adjacent polygons drawn
  //      with consistent winding. Mark both for deletion.
  //   4. Walk the remaining edges. Each closed traversal is a cycle in
  //      the merged result. Two shapes sharing one edge collapse to one
  //      cycle; three shapes meeting along a chain produce one cycle;
  //      disjoint shapes produce two cycles.
  //
  // Returns null when no shared edges exist (caller should fall back to
  // a boolean union for overlapping-but-not-edge-sharing cases). Returns
  // an array of closed rings when at least one shared edge was found.
  //
  // The advantage over polygon.union for our use case: this only walks
  // edges that were ALREADY in the input polygons. No new vertices are
  // introduced at intersection points, so we can't get the "spike" or
  // "thin sliver" artifacts that polygon-tools produces when shapes
  // touch at a single vertex or overlap along a near-zero-width sliver.
  mergeBySharedEdges(polys, eps = 0.5) {
    if (!polys || polys.length < 2) return null;

    // Step 0: split edges at T-junctions so a vertex from one polygon
    // that lies in the middle of another polygon's edge becomes a
    // proper shared vertex. Without this, L-shape cases (small square
    // meeting one edge of a larger square at a midpoint) don't produce
    // exact reverse-direction edge pairs and the algorithm bails to the
    // polygon.union fallback.
    const split = this.splitAtTJunctions(polys, eps);

    // Step 1: canonicalize vertices
    const vertexPool = [];
    const epsSq = eps * eps;
    const findOrCreate = (pos) => {
      for (let i = 0; i < vertexPool.length; i += 1) {
        const dx = vertexPool[i][0] - pos[0];
        const dy = vertexPool[i][1] - pos[1];
        if ((dx * dx) + (dy * dy) < epsSq) return i;
      }
      vertexPool.push(pos.slice());
      return vertexPool.length - 1;
    };

    // Step 2: collect directed edges
    const directed = []; // { from, to, polyIdx }
    split.forEach((ring, pi) => {
      if (!ring || ring.length < 3) return;
      const closed = ring.length >= 4
        && ring[0][0] === ring[ring.length - 1][0]
        && ring[0][1] === ring[ring.length - 1][1];
      const n = closed ? ring.length - 1 : ring.length;
      for (let e = 0; e < n; e += 1) {
        const from = findOrCreate(ring[e]);
        const to = findOrCreate(ring[(e + 1) % n]);
        if (from === to) continue; // skip degenerate zero-length edges
        directed.push({ from, to, polyIdx: pi });
      }
    });

    // Step 3: find reverse-direction pairs across different polygons.
    // These represent edges shared by two adjacent polygons drawn with
    // consistent winding (CCW). Mark both for deletion. Only the first
    // matching reverse is removed per source edge — if three polygons
    // somehow have the same edge (a degenerate case we don't expect),
    // the third stays in the graph and gets walked as part of a cycle.
    const removed = new Set();
    let sharedFound = false;
    for (let i = 0; i < directed.length; i += 1) {
      if (removed.has(i)) continue;
      for (let j = i + 1; j < directed.length; j += 1) {
        if (removed.has(j)) continue;
        if (directed[i].polyIdx === directed[j].polyIdx) continue;
        if (directed[i].from === directed[j].to
          && directed[i].to === directed[j].from) {
          removed.add(i);
          removed.add(j);
          sharedFound = true;
          break;
        }
      }
    }

    if (!sharedFound) return null;

    // Step 4: walk cycles on the remaining edges.
    const remaining = [];
    directed.forEach((e, i) => { if (!removed.has(i)) remaining.push(e); });
    const adj = new Map(); // fromVertex → [{ to, remainingIdx }]
    remaining.forEach((e, i) => {
      if (!adj.has(e.from)) adj.set(e.from, []);
      adj.get(e.from).push({ to: e.to, remainingIdx: i });
    });

    const used = new Set();
    const cycles = [];
    for (let startIdx = 0; startIdx < remaining.length; startIdx += 1) {
      if (used.has(startIdx)) continue;

      const startVertex = remaining[startIdx].from;
      const cycle = [vertexPool[startVertex].slice()];
      let currentIdx = startIdx;
      let safety = remaining.length + 1;
      let success = false;

      while (safety > 0) {
        safety -= 1;
        used.add(currentIdx);
        const edge = remaining[currentIdx];
        cycle.push(vertexPool[edge.to].slice());

        if (edge.to === startVertex) {
          success = true;
          break;
        }

        const options = (adj.get(edge.to) || [])
          .filter((opt) => !used.has(opt.remainingIdx));
        if (options.length === 0) break;
        // Prefer an edge from the same polygon to keep traversal stable
        // at junctions; fall back to any available outgoing edge.
        const samePoly = options.find((opt) => remaining[opt.remainingIdx].polyIdx === edge.polyIdx);
        currentIdx = (samePoly || options[0]).remainingIdx;
      }

      if (success && cycle.length >= 4) cycles.push(this.dedupConsecutive(cycle));
    }

    return cycles.length > 0 ? cycles : null;
  },
  // Detect a self-touch / "pinch" in a closed ring: any interior vertex
  // that appears at the same coords as another interior vertex. The
  // closing vertex (always equal to ring[0]) is excluded. Used by
  // assembleTriangles to recognize polygon-tools union outputs that
  // collapsed two vertex-touching inputs into a single polygon with a
  // self-touch — those need to be split or dilate-retried.
  hasPinch(ring) {
    if (!ring || ring.length < 4) return false;
    const inner = ring.slice(0, -1);
    const seen = new Set();
    for (let i = 0; i < inner.length; i += 1) {
      const key = `${inner[i][0].toFixed(3)},${inner[i][1].toFixed(3)}`;
      if (seen.has(key)) return true;
      seen.add(key);
    }
    return false;
  },
  // Split a closed ring at its first detected self-touch, then recurse
  // on each piece (pinches can have multiple). Returns an array of
  // closed pinch-free rings. Used as a defensive fallback when the
  // dilate-retry in assembleTriangles doesn't produce a clean union.
  splitAtPinch(ring) {
    if (!ring || ring.length < 4) return [ring];
    const inner = ring.slice(0, -1);
    const seen = new Map();
    for (let i = 0; i < inner.length; i += 1) {
      const key = `${inner[i][0].toFixed(3)},${inner[i][1].toFixed(3)}`;
      if (seen.has(key)) {
        const j = seen.get(key);
        const piece1 = inner.slice(j, i);
        piece1.push(piece1[0].slice());
        const piece2 = [...inner.slice(0, j), ...inner.slice(i)];
        piece2.push(piece2[0].slice());
        const out = [];
        this.splitAtPinch(piece1).forEach((p) => out.push(p));
        this.splitAtPinch(piece2).forEach((p) => out.push(p));
        return out;
      }
      seen.set(key, i);
    }
    return [ring];
  },
  // Geometry transforms used by step-2 select-mode (drag-to-move + rotate
  // handle). All emit new point arrays — callers can speculatively transform
  // for preview and discard, then commit the final value back to the shape.
  translatePolygon(points, dx, dy) {
    return points.map(([x, y]) => [x + dx, y + dy]);
  },
  rotatePolygon(points, center, angle) {
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    const [cx, cy] = center;
    return points.map(([x, y]) => {
      const px = x - cx;
      const py = y - cy;
      return [
        (px * cos) - (py * sin) + cx,
        (px * sin) + (py * cos) + cy,
      ];
    });
  },
  shapesIntersect(a, b) {
    // Cheap AABB rejection first — most shape pairs in a normal map are
    // nowhere near each other and a 4-number bounds check skips the
    // expensive Sutherland-Hodgman path inside polygon.intersection.
    const aBounds = this.polygonBounds(a);
    const bBounds = this.polygonBounds(b);
    if (aBounds.maxx < bBounds.minx || bBounds.maxx < aBounds.minx) return false;
    if (aBounds.maxy < bBounds.miny || bBounds.maxy < aBounds.miny) return false;
    try {
      const result = polygon.intersection(a, b);
      if (!result || result.length === 0) return false;
      // polygon-tools occasionally returns near-zero-area slivers from
      // shared edges; treat anything below 1 sq source-unit as touching,
      // not overlapping.
      const area = Math.abs(polygon.area(result[0]));
      return area > 1;
    } catch (_) {
      return false;
    }
  },
  polygonBounds(points) {
    let minx = Infinity;
    let miny = Infinity;
    let maxx = -Infinity;
    let maxy = -Infinity;
    for (let i = 0; i < points.length; i += 1) {
      const [x, y] = points[i];
      if (x < minx) minx = x;
      if (y < miny) miny = y;
      if (x > maxx) maxx = x;
      if (y > maxy) maxy = y;
    }
    return { minx, miny, maxx, maxy };
  },
  polygonCentroid(points) {
    return polygon.centroid(points);
  },
  polygonArea(points) {
    return polygon.area(points);
  },
  // Vertex-presence test: does any vertex of `points` sit on the left
  // of `axisCoord` along the named axis (with `eps` tolerance), and any
  // other vertex on the right? If both → the polygon straddles the
  // axis and mirroring would mostly overlap itself. Skip the mirror in
  // that case rather than generate a useless half-shadow.
  polygonStraddles(points, axisCoord, axis, eps = 0.5) {
    let hasLow = false;
    let hasHigh = false;
    const i = axis === 'x' ? 0 : 1;
    for (let k = 0; k < points.length; k += 1) {
      const v = points[k][i];
      if (v < axisCoord - eps) hasLow = true;
      else if (v > axisCoord + eps) hasHigh = true;
      if (hasLow && hasHigh) return true;
    }
    return false;
  },
  // Reflect a polygon across an axis. Reverses the vertex order to
  // preserve winding (reflection flips orientation; reversing flips it
  // back) so polygon-tools area, centroid, and polygon-offset behave
  // consistently with the originals.
  reflectAcross(points, axisCoord, axis) {
    const flipped = points.map(([x, y]) => (
      axis === 'x' ? [(2 * axisCoord) - x, y] : [x, (2 * axisCoord) - y]
    ));
    return flipped.reverse();
  },
  // Two-pass vertex cleanup that runs before mirroring. (1) Any vertex
  // within `eps` of the active axis is snapped exactly onto it, so the
  // reflection of an "on-axis" vertex maps to itself (no float gap).
  // (2) Any vertex within `eps` of another sector's vertex collapses
  // onto the same canonical coordinates, so adjacent sectors really
  // share their border verbatim instead of being parallel-but-offset.
  // After cleanup we recompute the offset rings and centroid so the
  // step-3 system placement and the mirror generator both see the
  // canonical geometry. Returns the same sectors array, mutated.
  canonicalizeSharedVertices(sectors, symmetry, center, eps) {
    if (!sectors || sectors.length === 0) return sectors;
    const kind = symmetry && symmetry.kind;
    const wantsV = kind === 'vertical' || kind === 'both';
    const wantsH = kind === 'horizontal' || kind === 'both';

    const epsSq = eps * eps;
    const canonical = [];
    const findOrCreate = (pos) => {
      for (let i = 0; i < canonical.length; i += 1) {
        const dx = canonical[i][0] - pos[0];
        const dy = canonical[i][1] - pos[1];
        if ((dx * dx) + (dy * dy) < epsSq) return canonical[i];
      }
      canonical.push(pos.slice());
      return canonical[canonical.length - 1];
    };
    const snapToAxisIfClose = ([x, y]) => {
      let nx = x;
      let ny = y;
      if (wantsV && Math.abs(x - center) < eps) nx = center;
      if (wantsH && Math.abs(y - center) < eps) ny = center;
      return [nx, ny];
    };

    sectors.forEach((sector) => {
      const pts = sector.points.map(snapToAxisIfClose);
      sector.points = pts.map((p) => findOrCreate(p).slice());
      // Ensure ring closure: last vertex must equal first (the .map
      // could have routed them to different canonical entries if their
      // pre-canonical coords drifted apart more than eps).
      sector.points[sector.points.length - 1] = sector.points[0].slice();
      sector.points03 = this.offsetPolygon(sector.points, 0.3);
      sector.points05 = this.offsetPolygon(sector.points, 0.5);
      sector.points25 = this.offsetPolygon(sector.points, 2.5);
      sector.area = this.polygonArea(sector.points);
      sector.centroid = this.polygonCentroid(sector.points);
    });

    return sectors;
  },
  // Mirror an assembled sector's polygon according to the symmetry kind.
  // Returns an array of {kind, points} entries — empty when the source
  // straddles all relevant axes (nothing to mirror). The caller wraps
  // each entry into a full sector object with name/color/key.
  generateMirrorSectors(sector, symmetry, center, eps = 0.5) {
    const kind = symmetry && symmetry.kind;
    if (!kind || kind === 'none') return [];

    const points = sector.points;
    const straddlesV = this.polygonStraddles(points, center, 'x', eps);
    const straddlesH = this.polygonStraddles(points, center, 'y', eps);
    const out = [];

    if ((kind === 'vertical' || kind === 'both') && !straddlesV) {
      out.push({ kind: 'v', points: this.reflectAcross(points, center, 'x') });
    }
    if ((kind === 'horizontal' || kind === 'both') && !straddlesH) {
      out.push({ kind: 'h', points: this.reflectAcross(points, center, 'y') });
    }
    if (kind === 'both' && !straddlesV && !straddlesH) {
      // Both axes: a quadrant sector generates three mirrors. The diagonal
      // (vh) mirror is the composition; if the sector straddles either
      // axis the diagonal collapses onto the other mirror and is dropped.
      const vh = this.reflectAcross(
        this.reflectAcross(points, center, 'x'), center, 'y',
      );
      out.push({ kind: 'vh', points: vh });
    }
    return out;
  },
  // Reflect a list of system positions to match a mirrored sector.
  // Returns new system objects with the same `type`; caller assigns
  // fresh keys.
  mirrorSystems(systems, mirrorKind, center) {
    return systems.map((sys) => {
      let { x, y } = sys.position;
      if (mirrorKind === 'v' || mirrorKind === 'vh') x = (2 * center) - x;
      if (mirrorKind === 'h' || mirrorKind === 'vh') y = (2 * center) - y;
      return { position: { x, y }, type: sys.type };
    });
  },
  // Closest point on segment [a, b] to point p. Linear projection clamped
  // to the segment endpoints. Used by snapPolygon for edge snapping —
  // both vertex-to-vertex and vertex-to-edge cases collapse into this.
  closestPointOnSegment(p, a, b) {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const lenSq = (dx * dx) + (dy * dy);
    if (lenSq === 0) return [a[0], a[1]];
    let t = (((p[0] - a[0]) * dx) + ((p[1] - a[1]) * dy)) / lenSq;
    t = Math.max(0, Math.min(1, t));
    return [a[0] + (t * dx), a[1] + (t * dy)];
  },
  // Find the closest snap target for a single point across a list of rings
  // and return rich anchor metadata: which ring (polygonIndex), whether the
  // snap landed on a vertex or partway along an edge, the resolved snapped
  // point, and edge fraction t when relevant. Null when nothing is within
  // `radius`. The polygon-build flow records one of these per placed
  // vertex; close-time perimeter walking reads them back.
  // vertexEps biases the snap toward existing vertices when the cursor's
  // projection onto an edge lands within `vertexEps` source units of
  // either edge endpoint — the snap target shifts from the edge point
  // to the vertex. Default 1.0 (a full grid unit) is intentionally
  // generous: "almost on a vertex" snaps yield near-zero-length edges
  // when used as anchors, which cause skinny path-traces and weird
  // surface-graph routes downstream. Callers can pass a tighter value
  // for contexts where exact-edge-fraction snaps are desired.
  snapPoint(point, otherPolygons, radius, vertexEps = 1.0) {
    let best = null;
    for (let oi = 0; oi < otherPolygons.length; oi += 1) {
      const ring = otherPolygons[oi];
      if (!ring || ring.length < 2) continue;
      const bounds = this.polygonBounds(ring);
      if (point[0] + radius < bounds.minx || bounds.maxx + radius < point[0]) continue;
      if (point[1] + radius < bounds.miny || bounds.maxy + radius < point[1]) continue;

      const n = ring[ring.length - 1][0] === ring[0][0]
        && ring[ring.length - 1][1] === ring[0][1]
        ? ring.length - 1
        : ring.length;
      for (let j = 0; j < n; j += 1) {
        const a = ring[j];
        const b = ring[(j + 1) % n];
        const closest = this.closestPointOnSegment(point, a, b);
        const dx = closest[0] - point[0];
        const dy = closest[1] - point[1];
        const dist = Math.sqrt((dx * dx) + (dy * dy));
        if (dist > radius) continue;
        if (best && dist >= best.dist) continue;

        const dToA = Math.sqrt(((closest[0] - a[0]) ** 2) + ((closest[1] - a[1]) ** 2));
        const dToB = Math.sqrt(((closest[0] - b[0]) ** 2) + ((closest[1] - b[1]) ** 2));

        if (dToA < vertexEps) {
          best = {
            point: a.slice(), dist, polygonIndex: oi,
            kind: 'vertex', vertexIndex: j,
          };
        } else if (dToB < vertexEps) {
          best = {
            point: b.slice(), dist, polygonIndex: oi,
            kind: 'vertex', vertexIndex: (j + 1) % n,
          };
        } else {
          const segDx = b[0] - a[0];
          const segDy = b[1] - a[1];
          const segLenSq = (segDx * segDx) + (segDy * segDy);
          const t = segLenSq === 0 ? 0
            : (((closest[0] - a[0]) * segDx) + ((closest[1] - a[1]) * segDy)) / segLenSq;
          best = {
            point: closest, dist, polygonIndex: oi,
            kind: 'edge', edgeIndex: j, t,
          };
        }
      }
    }
    return best;
  },
  // Walk the perimeter of `ring` from `fromAnchor` to `toAnchor`, picking
  // the shorter of the two directions, and return the list of intermediate
  // vertex points (excluding the anchors themselves). Used at polygon-close
  // time to stitch a shared border when both endpoints sit on the same
  // existing polygon. The new polygon's ring becomes
  //   [start, v_1, …, v_last, …perimeter intermediates…, start]
  // and the result is one closed ring that exactly shares the border.
  perimeterWalk(ring, fromAnchor, toAnchor) {
    const n = ring[ring.length - 1][0] === ring[0][0]
      && ring[ring.length - 1][1] === ring[0][1]
      ? ring.length - 1
      : ring.length;
    const segLengths = [];
    let total = 0;
    for (let i = 0; i < n; i += 1) {
      const a = ring[i];
      const b = ring[(i + 1) % n];
      const len = Math.sqrt(((b[0] - a[0]) ** 2) + ((b[1] - a[1]) ** 2));
      segLengths.push(len);
      total += len;
    }
    const anchorPos = (anchor) => {
      let pos = 0;
      const limit = anchor.kind === 'vertex' ? anchor.vertexIndex : anchor.edgeIndex;
      for (let i = 0; i < limit; i += 1) pos += segLengths[i];
      if (anchor.kind === 'edge') pos += anchor.t * segLengths[anchor.edgeIndex];
      return pos;
    };
    const fromPos = anchorPos(fromAnchor);
    const toPos = anchorPos(toAnchor);

    // Build per-vertex perimeter positions so we can filter+sort by arc.
    const vertexPositions = [];
    let cum = 0;
    for (let i = 0; i < n; i += 1) {
      vertexPositions.push({ idx: i, pos: cum });
      cum += segLengths[i];
    }

    const forwardArc = ((toPos - fromPos) % total + total) % total;
    const direction = forwardArc <= total / 2 ? +1 : -1;

    // Forward (direction +1): emit vertices with pos in (fromPos, toPos) on the ring.
    // Backward (-1): emit vertices with pos in (toPos, fromPos).
    const between = [];
    for (let i = 0; i < n; i += 1) {
      const p = vertexPositions[i].pos;
      let inArc;
      if (direction === +1) {
        inArc = fromPos < toPos
          ? (p > fromPos && p < toPos)
          : (p > fromPos || p < toPos);
      } else {
        inArc = toPos < fromPos
          ? (p > toPos && p < fromPos)
          : (p > toPos || p < fromPos);
      }
      if (inArc) between.push({ idx: i, pos: p });
    }

    if (direction === +1) {
      if (fromPos < toPos) {
        between.sort((a, b) => a.pos - b.pos);
      } else {
        between.sort((a, b) => {
          const aLate = a.pos > fromPos ? 0 : 1;
          const bLate = b.pos > fromPos ? 0 : 1;
          if (aLate !== bLate) return aLate - bLate;
          return a.pos - b.pos;
        });
      }
    } else if (fromPos > toPos) {
      between.sort((a, b) => b.pos - a.pos);
    } else {
      between.sort((a, b) => {
        const aEarly = a.pos < fromPos ? 0 : 1;
        const bEarly = b.pos < fromPos ? 0 : 1;
        if (aEarly !== bEarly) return aEarly - bEarly;
        return b.pos - a.pos;
      });
    }

    return between.map((e) => ring[e.idx].slice());
  },
  // Build a connectivity graph over the surface of every polygon. Each
  // polygon's perimeter contributes nodes (its vertices) and weighted
  // edges (consecutive vertex pairs, length = Euclidean distance). Nodes
  // at distinct polygons but identical coordinates (within `eps`) get
  // deduplicated, which is what stitches polygons that share vertices —
  // snap already lands shared vertices at exact positions, so distinct
  // polygons that "touch" naturally fuse into a connected graph here.
  //
  // The two anchors are also injected as nodes. For an edge-kind anchor,
  // its position subdivides the edge it sits on so the anchor becomes a
  // real graph node connected to both endpoint vertices with correct arc
  // lengths.
  //
  // Returns { nodes, adjacency, fromNodeId, toNodeId }. Caller runs
  // shortestPathOnSurface to recover the intermediate node positions.
  buildSurfaceGraph(polygons, fromAnchor, toAnchor, eps = 0.5) {
    const nodes = [];
    const adjacency = [];
    const epsSq = eps * eps;
    const ensure = (id) => { while (adjacency.length <= id) adjacency.push([]); };
    const findOrCreate = (pos) => {
      for (let i = 0; i < nodes.length; i += 1) {
        const dx = nodes[i][0] - pos[0];
        const dy = nodes[i][1] - pos[1];
        if ((dx * dx) + (dy * dy) < epsSq) return i;
      }
      nodes.push([pos[0], pos[1]]);
      ensure(nodes.length - 1);
      return nodes.length - 1;
    };
    const addEdge = (u, v) => {
      if (u === v) return;
      const dx = nodes[v][0] - nodes[u][0];
      const dy = nodes[v][1] - nodes[u][1];
      const w = Math.sqrt((dx * dx) + (dy * dy));
      adjacency[u].push({ to: v, weight: w });
      adjacency[v].push({ to: u, weight: w });
    };

    for (let pi = 0; pi < polygons.length; pi += 1) {
      const ring = polygons[pi];
      if (!ring || ring.length < 2) continue;
      const n = ring[ring.length - 1][0] === ring[0][0]
        && ring[ring.length - 1][1] === ring[0][1]
        ? ring.length - 1
        : ring.length;
      for (let e = 0; e < n; e += 1) {
        const a = ring[e];
        const b = ring[(e + 1) % n];
        // Collect any anchor that lies on this edge (kind === 'edge'),
        // sorted by t, so we can subdivide consistently.
        const inserts = [];
        for (let k = 0; k < 2; k += 1) {
          const anchor = k === 0 ? fromAnchor : toAnchor;
          if (!anchor) continue;
          if (anchor.polygonIndex !== pi) continue;
          if (anchor.kind === 'edge' && anchor.edgeIndex === e) {
            inserts.push({ t: anchor.t, pos: anchor.point });
          }
        }
        inserts.sort((x, y) => x.t - y.t);
        let prev = findOrCreate(a);
        for (let s = 0; s < inserts.length; s += 1) {
          const mid = findOrCreate(inserts[s].pos);
          addEdge(prev, mid);
          prev = mid;
        }
        addEdge(prev, findOrCreate(b));
      }
    }

    const resolveAnchor = (anchor) => {
      if (!anchor) return -1;
      // Vertex anchors collapse onto an existing graph node directly;
      // edge anchors were inserted during the perimeter pass above.
      return findOrCreate(anchor.point);
    };

    return {
      nodes,
      adjacency,
      fromNodeId: resolveAnchor(fromAnchor),
      toNodeId: resolveAnchor(toAnchor),
    };
  },
  // Dijkstra over the surface graph. V is small (typically < 200 verts
  // across all polygons in a normal map), so the unsorted O(V²) inner
  // loop beats a binary heap on overhead and is fewer lines.
  //
  // Returns the list of intermediate node positions from the node after
  // `fromId` up to but excluding `toId`, i.e. the perimeter walk that
  // sits BETWEEN the two anchors — the caller stitches them into the
  // new polygon as [start, v_1, …, v_last, …intermediates…, start].
  // Returns null when no connecting path exists (polygons aren't
  // adjacent through the surface graph).
  shortestPathOnSurface(graph, fromId, toId) {
    if (fromId < 0 || toId < 0 || fromId === toId) return null;
    const { nodes, adjacency } = graph;
    const dist = new Array(nodes.length).fill(Infinity);
    const prev = new Array(nodes.length).fill(-1);
    const visited = new Array(nodes.length).fill(false);
    dist[fromId] = 0;

    for (;;) {
      let u = -1;
      let minDist = Infinity;
      for (let i = 0; i < nodes.length; i += 1) {
        if (!visited[i] && dist[i] < minDist) {
          u = i;
          minDist = dist[i];
        }
      }
      if (u === -1 || u === toId) break;
      visited[u] = true;
      const neigh = adjacency[u] || [];
      for (let k = 0; k < neigh.length; k += 1) {
        const { to, weight } = neigh[k];
        const alt = dist[u] + weight;
        if (alt < dist[to]) {
          dist[to] = alt;
          prev[to] = u;
        }
      }
    }

    if (dist[toId] === Infinity) return null;
    const intermediates = [];
    let cur = prev[toId];
    while (cur !== -1 && cur !== fromId) {
      intermediates.unshift(nodes[cur].slice());
      cur = prev[cur];
    }
    return intermediates;
  },
  // Find the closest "vertex of `points` → point on edge of any otherPolygons[i]"
  // pair across all combinations. If the closest pair is within `radius`,
  // return a copy of `points` translated so that pair aligns exactly.
  // Returns null when nothing is within range — callers leave the shape
  // un-snapped. otherPolygons are expected to be closed rings; the last
  // (closing) vertex is skipped so we don't double-count.
  snapPolygon(points, otherPolygons, radius) {
    if (!points || !otherPolygons || otherPolygons.length === 0) return null;
    const myBounds = this.polygonBounds(points);
    let best = null;
    for (let oi = 0; oi < otherPolygons.length; oi += 1) {
      const other = otherPolygons[oi];
      if (!other || other.length < 2) continue;
      const oBounds = this.polygonBounds(other);
      // Skip pairs whose AABBs are further apart than the snap radius —
      // cheap rejection saves the per-vertex×per-edge inner loop.
      if (myBounds.maxx + radius < oBounds.minx) continue;
      if (oBounds.maxx + radius < myBounds.minx) continue;
      if (myBounds.maxy + radius < oBounds.miny) continue;
      if (oBounds.maxy + radius < myBounds.miny) continue;

      const lastIdx = points[points.length - 1][0] === points[0][0]
        && points[points.length - 1][1] === points[0][1]
        ? points.length - 1 : points.length;
      for (let i = 0; i < lastIdx; i += 1) {
        const v = points[i];
        for (let j = 0; j < other.length - 1; j += 1) {
          const a = other[j];
          const b = other[j + 1];
          const closest = this.closestPointOnSegment(v, a, b);
          const dx = closest[0] - v[0];
          const dy = closest[1] - v[1];
          const dist = Math.sqrt((dx * dx) + (dy * dy));
          if (dist <= radius && (!best || dist < best.dist)) {
            best = { dist, dx, dy };
          }
        }
      }
    }
    if (!best) return null;
    return points.map(([x, y]) => [x + best.dx, y + best.dy]);
  },
  genSystem(rng, sectors, systemData, options) {
    let i = 0;

    return sectors.reduce((acc, sector) => {
      sector.systems = [];

      const useExactCount = Number.isInteger(sector.systemCount) && sector.systemCount > 0;
      const placements = useExactCount
        ? this.placeByExactCount(rng, sector, options, sector.systemCount)
        : this.placeByDensity(rng, sector, options);

      placements.forEach(({ px, py }) => {
        i += 1;
        const type = this.getRandomSystemType(systemData, rng);
        const system = { key: i, position: { x: px, y: py }, type };
        acc.push(system);
        sector.systems.push(system);
      });

      return acc;
    }, []);
  },
  sectorBounds(rng, sector, options) {
    const minx = Math.ceil(Math.min(...sector.points05.map(([x, _y]) => x)));
    const miny = Math.ceil(Math.min(...sector.points05.map(([_x, y]) => y)));
    const maxx = Math.floor(Math.max(...sector.points05.map(([x, _y]) => x)));
    const maxy = Math.floor(Math.max(...sector.points05.map(([_x, y]) => y)));

    const hpsCount = options.points;
    const hotPoints = [];
    // Cap the rejection-sampling loop. A degenerate sector polygon (zero/
    // near-zero area, or a wisp left over from a near-touching shape union)
    // can let the inside-polygon test fail for every random sample —
    // without a cap the wizard hangs forever. 200 attempts per requested
    // hot point is plenty for any normal sector; if we fail to hit any
    // valid point, fall back to the bounds centroid so genSystem still
    // produces something instead of NaN-ing through the placement code.
    const maxAttempts = Math.max(1000, hpsCount * 200);
    let attempts = 0;
    while (hotPoints.length < hpsCount && attempts < maxAttempts) {
      attempts += 1;
      const point = { x: rng.next(minx, maxx), y: rng.next(miny, maxy) };
      if (InsidePolygon([point.x, point.y], sector.points25)) {
        hotPoints.push(point);
      }
    }
    if (hotPoints.length < hpsCount) {
      const fallback = sector.centroid
        ? { x: sector.centroid[0], y: sector.centroid[1] }
        : { x: (minx + maxx) / 2, y: (miny + maxy) / 2 };
      while (hotPoints.length < hpsCount) hotPoints.push({ ...fallback });
    }

    const longestSide = Math.max(Math.abs(minx - maxx), Math.abs(miny - maxy));
    const hpsRadius = (longestSide / hpsCount) * options.spread;

    return { minx, miny, maxx, maxy, hotPoints, hpsRadius };
  },
  placeByDensity(rng, sector, options) {
    const { minx, miny, maxx, maxy, hotPoints, hpsRadius } = this.sectorBounds(rng, sector, options);
    const placements = [];

    for (let px = minx; px <= maxx; px += 1) {
      for (let py = miny; py <= maxy; py += 1) {
        if (InsidePolygon([px, py], sector.points05)) {
          let threshold = hotPoints
            .map(({ x, y }) => Math.sqrt(Math.abs(x - px) ** 2 + Math.abs(y - py) ** 2))
            .map((d) => (Math.max(hpsRadius - d, 0) / hpsRadius) ** options.attenuation)
            .reduce((acc2, d) => acc2 + d);

          threshold *= options.density / 100;
          threshold = Math.min(threshold, options.maxDensity / 100);

          if (rng.next() < threshold) {
            placements.push({ px, py });
          }
        }
      }
    }

    return placements;
  },
  placeByExactCount(rng, sector, options, count) {
    const { minx, miny, maxx, maxy, hotPoints, hpsRadius } = this.sectorBounds(rng, sector, options);

    // Epsilon keeps points outside every hot-point's influence radius
    // eligible at low probability — without it, a small "points" /
    // "spread" combo would force all N picks into a single cluster.
    const epsilon = 1e-6;
    const candidates = [];
    for (let px = minx; px <= maxx; px += 1) {
      for (let py = miny; py <= maxy; py += 1) {
        if (InsidePolygon([px, py], sector.points05)) {
          const weight = hotPoints
            .map(({ x, y }) => Math.sqrt(Math.abs(x - px) ** 2 + Math.abs(y - py) ** 2))
            .map((d) => (Math.max(hpsRadius - d, 0) / hpsRadius) ** options.attenuation)
            .reduce((acc, w) => acc + w, 0);
          candidates.push({ px, py, weight: weight + epsilon });
        }
      }
    }

    if (candidates.length === 0) return [];

    // Efraimidis-Spirakis: assign each candidate key u^(1/w) where u is
    // uniform [0,1); the top-N by key is a weighted sample without
    // replacement with selection prob ∝ w.
    const keyed = candidates.map(({ px, py, weight }) => {
      const u = rng.next();
      const key = u === 0 ? 0 : u ** (1 / weight);
      return { px, py, key };
    });
    keyed.sort((a, b) => b.key - a.key);
    return keyed.slice(0, Math.min(count, keyed.length)).map(({ px, py }) => ({ px, py }));
  },
  offsetPolygon(points, size = 0.2) {
    // polygon-offset can collapse a degenerate input (skinny triangle,
    // near-collinear vertices) to an empty multi-polygon. Fall back to
    // the un-offset points so step 2 → 3 doesn't crash the editor.
    // Dedup consecutive vertices first — polygon-offset prints noisy
    // "edges of the same polygon overlap" warnings on near-zero-length
    // edges, and float drift from the merge walker / canonicalize
    // routinely produces them.
    if (!points || points.length < 3) return points;
    const cleaned = this.dedupConsecutive(points);
    if (cleaned.length < 4) return points;
    try {
      const result = new Offset().data(cleaned).padding(size);
      return (result && result[0]) || cleaned;
    } catch (_) {
      return cleaned;
    }
  },
  getRandomSystemType(systemData, rng) {
    const systemProbSum = systemData.reduce((acc, s) => acc + parseInt(s.gen_prob_factor, 10), 0);
    const systemProbSteps = systemData.reduce(({ acc, i }, s, idx) => {
      const newVal = i + (parseInt(s.gen_prob_factor, 10) / systemProbSum);
      acc.push(newVal);

      if (idx < systemData.length - 1) {
        return { acc, i: newVal };
      }

      return acc;
    }, { acc: [], i: 0 });

    const index = systemProbSteps.findIndex((prob) => rng.next() < prob);
    const { key } = systemData[index];
    return key;
  },
};
