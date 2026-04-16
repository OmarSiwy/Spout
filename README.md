<div align="left">
  <img src="docs/spout.svg" alt="Spout logo" width="72" height="72"/>
</div>

# Spout

> High-performance IC layout automation — routing, placement, DRC/LVS/PEX — written in Zig.

---

## Overview

Spout is a fast, programmable layout automation engine targeting analog and mixed-signal IC design. It provides:

- **Router** — grid-aware A\*, maze, and detailed routing with DRC rule enforcement
- **Placer** — constraint-driven standard-cell and analog placement
- **DRC/LVS/PEX** — on-the-fly design-rule checking, layout-vs-schematic, and parasitic extraction
- **PDK Support** — SkyWater 130nm (sky130) and extensible JSON-based PDK definitions
- **Python bindings** — scriptable automation via FFI

## Docs

Browse the [documentation site](docs/index.html) locally, or open `docs/index.html` in a browser.

## Quick Start

```bash
# Build
zig build

# Run benchmarks
python scripts/benchmark.py

# Run tests
zig build test
```

## PDK

PDK definitions live in `pdks/`. Currently supported:

| PDK       | File              |
|-----------|-------------------|
| SkyWater 130nm | `pdks/sky130.json` |

## License

See `LICENSE`.
