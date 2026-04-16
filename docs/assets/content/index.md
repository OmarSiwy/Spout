# Spout

**Spout** is a high-performance IC layout automation engine for analog and mixed-signal design. Written in Zig for deterministic, low-latency operation.

> [!TIP]
> New here? Start with [Introduction](/1) Getting Started/introduction) to understand the architecture, then follow the [Quick Start](/1) Getting Started/quick-start) guide.

## What Spout does

| Subsystem | Description |
|-----------|-------------|
| **Router** | Grid-aware A\*, maze, and detailed routing with DRC enforcement |
| **Placer** | Constraint-driven placement for standard-cell and analog blocks |
| **DRC** | On-the-fly design-rule checking against PDK rule decks |
| **LVS** | Layout-vs-schematic netlist comparison |
| **PEX** | Parasitic extraction — capacitance and resistance |
| **Python API** | Scriptable automation via FFI bindings |

## PDKs

Currently supported:

- **SkyWater 130nm** (`pdks/sky130.json`)

## Quick links

- [Installation](/1) Getting Started/installation)
- [Quick Start](/1) Getting Started/quick-start)
- [Router Architecture](/2) Router/overview)
- [Python API Reference](/4) Reference/python-api)
