// Runnable test cases for the editor's polygon-merge logic.
//
// These exercise mergeBySharedEdges (the edge-deletion merge) and the
// full assembleTriangles pipeline, including the polygon.union fallback
// path. The intent is regression coverage: when we tweak any of the
// merge tiers, we can run this and see which scenarios still work.
//
// How to run:
//   1. From the create-map page, click the "Run editor tests" button
//      in the right panel — results go to the browser console.
//   2. Or import + call from any code: `editorTests.runAllTests()`.
//
// Each test case has:
//   - inputs: array of polygon rings, exactly as a sector's shape.points
//     would be stored.
//   - expect: assertions to make about the result.
//   - expectIncludes: vertex coords that must be present in the merged
//     boundary (with eps tolerance) — catches the "v3 went missing"
//     class of bugs.
//   - expectExcludes: vertex coords that must NOT be in the result
//     (catches "introduced a spurious vertex" bugs).

import editor from './editor';

const EPS = 0.5;

function eqCoord(a, b, eps = EPS) {
  return Math.abs(a[0] - b[0]) < eps && Math.abs(a[1] - b[1]) < eps;
}

function ringContains(ring, target, eps = EPS) {
  if (!ring) return false;
  return ring.some((p) => eqCoord(p, target, eps));
}

function countDistinctVertices(ring, eps = EPS) {
  if (!ring || ring.length < 2) return 0;
  const seen = [];
  for (let i = 0; i < ring.length - 1; i += 1) {
    if (!seen.some((s) => eqCoord(s, ring[i], eps))) seen.push(ring[i]);
  }
  return seen.length;
}

// ---- Test cases --------------------------------------------------------

const TEST_CASES = [
  {
    name: 'two shapes sharing one edge (user degenerate case)',
    inputs: [
      [
        [12.802426554714579, 24.436741767764296],
        [24.24090142473191, 32.5476603119584],
        [37.44714059284283, 33.067590987868286],
        [33.91161199665565, 41.28249566724437],
        [12.594454284350627, 40.762564991334486],
        [12.802426554714579, 24.436741767764296],
      ],
      [
        [33.91161199665565, 41.28249566724437],
        [37.44714059284283, 33.067590987868286],
        [60, 15.909878682842287],
        [60, 42.218370883882145],
        [33.91161199665565, 41.28249566724437],
      ],
    ],
    expect: { cycleCount: 1, distinctVertices: 7 },
    expectIncludes: [
      [37.45, 33.07], // v3 — the vertex polygon.union drops
      [60, 15.91], // v6
      [12.80, 24.44], // v1
    ],
    expectExcludes: [],
  },
  {
    name: 'two squares sharing one edge',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[10, 0], [20, 0], [20, 10], [10, 10], [10, 0]],
    ],
    expect: { cycleCount: 1, distinctVertices: 6 },
    expectIncludes: [
      [10, 0], // shared vertex top
      [10, 10], // shared vertex bottom
      [0, 0], [20, 0], [20, 10], [0, 10],
    ],
    expectExcludes: [],
  },
  {
    name: 'three rectangles sharing two consecutive edges',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[10, 0], [20, 0], [20, 10], [10, 10], [10, 0]],
      [[20, 0], [30, 0], [30, 10], [20, 10], [20, 0]],
    ],
    expect: { cycleCount: 1, distinctVertices: 8 },
    expectIncludes: [
      [0, 0], [30, 0], [30, 10], [0, 10],
      [10, 0], [20, 0], [10, 10], [20, 10],
    ],
    expectExcludes: [],
  },
  {
    name: 'L-shape: two squares sharing one edge (concave outer boundary)',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[10, 0], [20, 0], [20, 5], [10, 5], [10, 0]],
    ],
    expect: { cycleCount: 1, distinctVertices: 7 },
    expectIncludes: [
      [10, 5], // inner corner of the L
      [20, 0], [20, 5], [10, 10],
    ],
    expectExcludes: [],
  },
  {
    name: 'disjoint shapes — no shared edges',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[100, 100], [110, 100], [110, 110], [100, 110], [100, 100]],
    ],
    expect: { mergeReturnsNull: true },
  },
  {
    name: 'shapes touching only at a single vertex',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[10, 10], [20, 10], [20, 20], [10, 20], [10, 10]],
    ],
    expect: { mergeReturnsNull: true },
  },
  {
    name: 'single shape (no merge candidates)',
    inputs: [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
    ],
    expect: { mergeReturnsNull: true },
  },
];

// ---- Runner ------------------------------------------------------------

function describeRing(ring) {
  if (!ring) return 'null';
  return ring.map((p) => `[${p[0].toFixed(2)},${p[1].toFixed(2)}]`).join(' → ');
}

export function runMergeBySharedEdgesTests() {
  const results = [];
  TEST_CASES.forEach((tc) => {
    const result = { name: tc.name, status: 'pass', failures: [] };
    let cycles;
    try {
      cycles = editor.mergeBySharedEdges(tc.inputs, 0.5);
    } catch (e) {
      result.status = 'error';
      result.failures.push(`threw: ${e.message}`);
      results.push(result);
      return;
    }

    if (tc.expect.mergeReturnsNull) {
      if (cycles !== null) {
        result.status = 'fail';
        result.failures.push(`expected null result, got ${cycles.length} cycles`);
      }
      result.output = cycles;
      results.push(result);
      return;
    }

    if (!cycles) {
      result.status = 'fail';
      result.failures.push('expected merged result, got null');
      results.push(result);
      return;
    }

    if (typeof tc.expect.cycleCount === 'number' && cycles.length !== tc.expect.cycleCount) {
      result.status = 'fail';
      result.failures.push(`expected ${tc.expect.cycleCount} cycle(s), got ${cycles.length}`);
    }

    const mainRing = cycles[0];
    if (typeof tc.expect.distinctVertices === 'number') {
      const got = countDistinctVertices(mainRing);
      if (got !== tc.expect.distinctVertices) {
        result.status = 'fail';
        result.failures.push(`expected ${tc.expect.distinctVertices} distinct vertices, got ${got}`);
      }
    }
    (tc.expectIncludes || []).forEach((v) => {
      if (!ringContains(mainRing, v)) {
        result.status = 'fail';
        result.failures.push(`expected vertex [${v[0]},${v[1]}] in result`);
      }
    });
    (tc.expectExcludes || []).forEach((v) => {
      if (ringContains(mainRing, v)) {
        result.status = 'fail';
        result.failures.push(`vertex [${v[0]},${v[1]}] should NOT be in result`);
      }
    });

    result.output = mainRing;
    results.push(result);
  });

  return results;
}

// Run the full assembleTriangles pipeline on the test inputs and compare
// the resulting sector.points to expectations. This catches regressions
// that the bare merge test wouldn't — e.g. a bug introduced in the
// polygon.union fallback or the dilate-retry path.
export function runAssembleTrianglesTests() {
  const results = [];
  TEST_CASES.forEach((tc) => {
    if (tc.expect.mergeReturnsNull) return; // not meaningful for assemble pipeline
    const result = { name: `assemble: ${tc.name}`, status: 'pass', failures: [] };
    const sector = {
      key: 1,
      name: 'test',
      color: 'editor-color-1',
      triangles: [],
      shapes: tc.inputs.map((points) => ({ kind: 'polygon', points, params: {} })),
    };
    let assembled;
    try {
      assembled = editor.assembleTriangles([sector]);
    } catch (e) {
      result.status = 'error';
      result.failures.push(`threw: ${e.message}`);
      results.push(result);
      return;
    }

    const points = assembled.sectors[0] && assembled.sectors[0].points;
    if (!points) {
      result.status = 'fail';
      result.failures.push('no points produced');
      results.push(result);
      return;
    }

    if (typeof tc.expect.distinctVertices === 'number') {
      const got = countDistinctVertices(points);
      if (got !== tc.expect.distinctVertices) {
        result.status = 'fail';
        result.failures.push(`expected ${tc.expect.distinctVertices} distinct vertices, got ${got}`);
      }
    }
    (tc.expectIncludes || []).forEach((v) => {
      if (!ringContains(points, v)) {
        result.status = 'fail';
        result.failures.push(`expected vertex [${v[0]},${v[1]}] in result`);
      }
    });
    (tc.expectExcludes || []).forEach((v) => {
      if (ringContains(points, v)) {
        result.status = 'fail';
        result.failures.push(`vertex [${v[0]},${v[1]}] should NOT be in result`);
      }
    });

    result.output = points;
    results.push(result);
  });

  return results;
}

export function runAllTests() {
  // eslint-disable-next-line no-console
  console.group('[editor-tests] mergeBySharedEdges');
  const mergeResults = runMergeBySharedEdgesTests();
  mergeResults.forEach((r) => {
    const tag = r.status === 'pass' ? '✓' : r.status === 'fail' ? '✗' : '!';
    // eslint-disable-next-line no-console
    console.log(`${tag} ${r.name}`);
    r.failures.forEach((f) => console.log(`    - ${f}`));
    if (r.status !== 'pass') console.log(`    output: ${describeRing(r.output)}`);
  });
  // eslint-disable-next-line no-console
  console.groupEnd();

  // eslint-disable-next-line no-console
  console.group('[editor-tests] assembleTriangles');
  const assembleResults = runAssembleTrianglesTests();
  assembleResults.forEach((r) => {
    const tag = r.status === 'pass' ? '✓' : r.status === 'fail' ? '✗' : '!';
    // eslint-disable-next-line no-console
    console.log(`${tag} ${r.name}`);
    r.failures.forEach((f) => console.log(`    - ${f}`));
    if (r.status !== 'pass') console.log(`    output: ${describeRing(r.output)}`);
  });
  // eslint-disable-next-line no-console
  console.groupEnd();

  const total = mergeResults.length + assembleResults.length;
  const passed = mergeResults.filter((r) => r.status === 'pass').length
    + assembleResults.filter((r) => r.status === 'pass').length;
  // eslint-disable-next-line no-console
  console.log(`[editor-tests] ${passed}/${total} passed`);

  return { mergeResults, assembleResults, total, passed };
}

export default { runAllTests, runMergeBySharedEdgesTests, runAssembleTrianglesTests, TEST_CASES };
