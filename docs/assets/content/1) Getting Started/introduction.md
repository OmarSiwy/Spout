# Introduction

Spout is a layout automation engine that takes a schematic netlist and physical constraints as input, and produces a complete GDS layout as output.

## Design philosophy

- **Correctness first** — DRC violations are caught at the routing layer, not after the fact
- **Analog-aware** — matched routing, guard rings, shielding, and thermal awareness built in
- **Deterministic** — same inputs always produce the same outputs; no random seeds in critical paths
- **Composable** — subsystems (router, placer, DRC, PEX) can be used independently via the Python API

## Architecture overview

```
Netlist + Constraints
        │
        ▼
    ┌────────┐
    │ Placer │  ← device placement, constraint satisfaction
    └───┬────┘
        │ placed cells + nets
        ▼
    ┌────────┐
    │ Router │  ← global route → detailed route → DRC fixup
    └───┬────┘
        │ routed layout
        ▼
    ┌────────┐
    │  DRC   │  ← rule deck from PDK JSON
    └───┬────┘
        │ clean layout
        ▼
    ┌────────┐
    │  PEX   │  ← parasitic extraction
    └───┬────┘
        │
        ▼
   GDS + SPICE netlist
```

## Key concepts

### PDK JSON

All process-specific rules (layer stack, design rules, device parameters) are stored in a single JSON file under `pdks/`. This makes Spout portable across processes without recompiling.

### Constraint language

Placement and routing constraints are expressed as structured data (Zig structs / Python dicts), not a custom DSL. This keeps the system simple and testable.

### Net classes

Nets are grouped into classes that drive routing strategy:

| Class | Strategy |
|-------|----------|
| `signal` | Standard shortest-path routing |
| `power` | Wide traces, via arrays |
| `matched` | Length-matched, symmetric |
| `analog` | Shielded, guard-ring enclosed |
| `clock` | Balanced H-tree or star |
