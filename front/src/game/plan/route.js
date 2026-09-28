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
