# Router Overview

The Spout router operates in three phases: global routing, detailed routing, and DRC-driven fixup.

## Phases

### 1. Global routing

Divides the layout into a coarse grid (GCells). Assigns each net a GCell path using A\* with congestion cost. This phase is fast and produces an approximate topology.

### 2. Detailed routing

Within each GCell, expands the global route to actual metal tracks using maze routing. Enforces:

- Minimum width and spacing (from PDK rule deck)
- Via enclosure rules
- Layer assignment (preferred direction per layer)

### 3. DRC fixup

After detailed routing, runs the DRC engine against the full layout. Violations trigger local rip-up and reroute of affected nets.

## Analog-aware strategies

| Strategy | Trigger | What it does |
|----------|---------|--------------|
| `matched` | `rc.match_length()` | Enforces equal-length routes with mirrored topology |
| `shielded` | Net class `analog` | Surrounds route with grounded shield on same layer |
| `guard_ring` | `pc.add_guard_ring()` | Adds well-tap ring around device cluster |
| `symmetric_steiner` | Matched differential pairs | Builds a symmetric Steiner tree |

## Key files

| File | Description |
|------|-------------|
| `src/router/astar.zig` | A\* global router |
| `src/router/maze.zig` | Maze detailed router |
| `src/router/detailed.zig` | Detailed routing coordinator |
| `src/router/analog_router.zig` | Analog-aware routing strategies |
| `src/router/matched_router.zig` | Length-matched routing |
| `src/router/guard_ring.zig` | Guard ring generation |
| `src/router/lde.zig` | Local density effects |
| `src/router/pex_feedback.zig` | PEX-aware rerouting |
