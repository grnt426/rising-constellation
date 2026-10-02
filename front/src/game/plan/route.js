// Shortest route between two systems, for re-routing an agent's plan
// outside the map (the plan editor). Same graph and weights as the map's
// pathfinder (map/blocks/character.js createPathFinder), so an edited plan
// routes exactly like a fresh right-click order would. The server still
// validates every hop against its own lane list.
import path from 'ngraph.path';
import createGraph from 'ngraph.graph';

let cached = { edges: null, finder: null };

function finderFor(edges) {
  if (cached.edges === edges && cached.finder) return cached.finder;

  const graph = createGraph();
  edges.forEach((edge) => {
    graph.addLink(edge.s1.id, edge.s2.id, { weight: edge.weight });
  });
  const finder = path.nba(graph, { distance: (from, to, link) => link.data.weight });
  cached = { edges, finder };
  return finder;
}

// --- single-source routes ------------------------------------------------

let cachedAdjacency = { edges: null, adjacency: null };

function adjacencyFor(edges) {
  if (cachedAdjacency.edges === edges && cachedAdjacency.adjacency) return cachedAdjacency.adjacency;

  const adjacency = new Map();
  const link = (from, to, weight) => {
    if (!adjacency.has(from)) adjacency.set(from, []);
    adjacency.get(from).push({ to, weight });
  };
  edges.forEach((edge) => {
    link(edge.s1.id, edge.s2.id, edge.weight);
    link(edge.s2.id, edge.s1.id, edge.weight);
  });
  cachedAdjacency = { edges, adjacency };
  return adjacency;
}

// Min-heap of [weight, hops, id] entries, ordered by weight.
function heapPush(heap, entry) {
  heap.push(entry);
  let i = heap.length - 1;
  while (i > 0) {
    const parent = (i - 1) >> 1;
    if (heap[parent][0] <= heap[i][0]) break;
    [heap[parent], heap[i]] = [heap[i], heap[parent]];
    i = parent;
  }
}

function heapPop(heap) {
  const top = heap[0];
  const last = heap.pop();
  if (heap.length) {
    heap[0] = last;
    let i = 0;
    for (;;) {
      const l = (2 * i) + 1;
      const r = l + 1;
      let min = i;
      if (l < heap.length && heap[l][0] < heap[min][0]) min = l;
      if (r < heap.length && heap[r][0] < heap[min][0]) min = r;
      if (min === i) break;
      [heap[min], heap[i]] = [heap[i], heap[min]];
      i = min;
    }
  }
  return top;
}

// Route length (summed lane weight, the map's travel-time basis) and
// jump count from `source` to every reachable system, in one Dijkstra
// pass over the same lanes and weights as makeRouter. The agent orders
// list ranks the whole galaxy by distance from an agent, which a
// per-pair search can't afford on a 6k-system map.
// Returns Map(systemId -> { weight, hops }).
export function routesFrom(galaxy, source) {
  const adjacency = adjacencyFor(galaxy.edges);
  const routes = new Map([[source, { weight: 0, hops: 0 }]]);
  const done = new Set();
  const heap = [[0, 0, source]];

  while (heap.length) {
    const [weight, hops, id] = heapPop(heap);
    if (!done.has(id)) {
      done.add(id);
      (adjacency.get(id) || []).forEach(({ to, weight: lane }) => {
        const next = weight + lane;
        const known = routes.get(to);
        if (!known || next < known.weight) {
          routes.set(to, { weight: next, hops: hops + 1 });
          heapPush(heap, [next, hops + 1, to]);
        }
      });
    }
  }

  return routes;
}

// route(from, to) -> [from, ..., to], or null when unreachable.
export default function makeRouter(galaxy) {
  const finder = finderFor(galaxy.edges);
  return (from, to) => {
    if (from === to) return [from];
    let found;
    try {
      found = finder.find(from, to);
    } catch (_e) {
      return null; // a system with no lanes at all isn't in the graph
    }
    // ngraph returns the path from `to` back to `from`
    return found.length ? found.map((node) => node.id).reverse() : null;
  };
}
