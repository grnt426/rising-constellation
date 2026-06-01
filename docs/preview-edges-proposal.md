# Map editor `preview_edges`: client-validate proposal

## Context

`POST /api/maps/preview-edges` accepts JSON arrays `systems` + `blackholes`,
then runs `Instance.Galaxy.SpatialGraph.generate_edges/2` — a doubly-nested
`Enum.reduce` / `Enum.filter` that does an `O(N² · B)` distance comparison
across every system pair, gated by every blackhole.

Stage 5's security audit flagged this as a medium-severity authenticated
DoS: an attacker submits a 50 000-entry `systems` list (~4 MB body, well
under the upload limit) and pins a Cowboy acceptor on `2.5 × 10⁹`
comparisons for tens of seconds. Concurrent requests degrade gameplay
latency for every player.

A naive fix would be a hard cap (`length(systems) <= N`), but that risks
breaking legitimate large maps — and we don't actually know the
legitimate ceiling. This document proposes an alternative.

## Proposal: client computes, server validates

The map editor (`front/src/portal/pages/create/Map.vue`) already has all
the data it needs to compute the edge set in the browser. Doing so:

1. Moves the expensive computation to the user's own CPU, where it can't
   degrade other users.
2. Lets us validate the result in linear time on the server.
3. Removes the hard cap entirely — large maps just take longer in the
   user's browser, with their own visible feedback.

### New endpoint contract

```
POST /api/maps/preview-edges
{
  "systems": [{key, position: {x, y}, ...}, ...],
  "blackholes": [{key, position: {x, y}, radius}, ...],
  "proposed_edges": [{from: <system_key>, to: <system_key>}, ...]
}

→ 200 { "valid": true, "edges": [...] }
→ 422 { "errors": { "proposed_edges": ["<reason>"] } }
```

The server validates that:

- Each `from` / `to` references a real system in `systems` (O(E) with a key→system map).
- The Euclidean distance between the endpoints is below the game's
  maximum edge length (O(E)).
- The straight-line edge doesn't pass through any blackhole disk (O(E·B);
  B is typically <10, so this is effectively O(E)).
- No duplicate edges (O(E) via MapSet).
- Optionally: the edges form a connected graph (single BFS, O(E + N)).

Total cost: `O(E + E·B + N + N)` — linear in input size with a small
multiplier. For a 1000-system map with 3000 edges and 5 blackholes:
~15 000 operations vs the prior 5 × 10⁶ comparisons.

### Server validator outline

```elixir
def validate_edges(systems, blackholes, proposed_edges) do
  systems_by_key = Map.new(systems, &{&1.key, &1})
  blackhole_disks = Enum.map(blackholes, &to_disk/1)

  with :ok <- check_edges_reference_real_systems(proposed_edges, systems_by_key),
       :ok <- check_no_duplicate_edges(proposed_edges),
       :ok <- check_edge_lengths(proposed_edges, systems_by_key, @max_edge_length),
       :ok <- check_no_blackhole_crossings(proposed_edges, systems_by_key, blackhole_disks) do
    {:ok, proposed_edges}
  end
end
```

Each check returns `{:error, %{field: :proposed_edges, reason: ..., index: i}}`
on failure so the UI can highlight the offending edge.

### Frontend changes

`Map.vue`'s edge-preview step currently round-trips through this
endpoint. Move the actual graph build into a worker (or inline JS) and
keep this endpoint only for validation. Pseudocode:

```javascript
// front/src/portal/pages/create/Map.vue
async previewEdges() {
  const { systems, blackholes } = this.steps[5].map;
  // Was: POST /api/maps/preview-edges with just systems+blackholes
  // and let the server compute. New:
  const proposed_edges = computeEdgesClientSide(systems, blackholes);
  // Send for validation only:
  await this.$axios.post('/maps/preview-edges', {
    systems, blackholes, proposed_edges
  });
}
```

`computeEdgesClientSide` is the same Elixir algorithm in JS. For very
large maps, run it in a Web Worker so the UI stays responsive.

### Migration path

1. **Add server-side validator**, accepting both old (`systems +
   blackholes` only) and new (`+ proposed_edges`) payload shapes. Both
   paths return the same edge list.
2. **Cap the old path** at a generous N (e.g. 2000 systems) and return
   a clear changeset-style error if exceeded — so legacy clients hit
   the cap but don't crash.
3. **Ship the frontend change** that sends `proposed_edges`.
4. **Remove the legacy path** after one release.

### Alternative if frontend can't easily compute edges

If `computeEdgesClientSide` is non-trivial to port (e.g. the graph
algorithm uses Elixir-specific data structures), the next-best option
is:

- Keep the server-side computation.
- Apply Hammer rate limiting on the endpoint (e.g. 10/min/account — map
  editing is interactive but discrete).
- Add a generous `length(systems) <= 2000` cap with a clear
  changeset-style error.

Rate limiting catches abuse; the cap protects against a single huge
request; legitimate map editing within a 2000-system budget keeps
working unchanged.

## Decision needed

- **Path A**: client computes, server validates (most secure, cheapest
  runtime cost, biggest frontend change).
- **Path B**: rate limit + generous cap (smaller change, leaves the
  O(N²) in place but bounds its blast radius).

If the map editor's data flow makes Path A straightforward, do that.
Otherwise Path B is fine for a small-community game.

Either way, the current unbounded O(N²) server endpoint should not ship.
