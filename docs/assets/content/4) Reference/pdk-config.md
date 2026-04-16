# PDK Configuration

PDK definitions live in `pdks/*.json`. Each file fully describes a process node.

## Top-level structure

```json
{
  "name": "sky130",
  "version": "1.0",
  "layers": [ ... ],
  "design_rules": { ... },
  "devices": { ... },
  "liberty": { ... }
}
```

## `layers`

```json
{
  "name": "met1",
  "gds_layer": 68,
  "gds_datatype": 20,
  "type": "metal",
  "direction": "horizontal",
  "min_width": 0.14,
  "min_space": 0.14,
  "sheet_resistance": 0.125
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Layer identifier used throughout Spout |
| `gds_layer` / `gds_datatype` | int | GDS II layer/datatype numbers |
| `type` | string | `metal` \| `poly` \| `diff` \| `well` \| `via` \| `implant` |
| `direction` | string | Preferred routing direction: `horizontal` \| `vertical` |
| `min_width` | µm | Minimum drawn width |
| `min_space` | µm | Minimum space to same-layer objects |
| `sheet_resistance` | Ω/□ | Used by PEX |

## `design_rules`

```json
{
  "met1": {
    "min_width":     0.14,
    "min_space":     0.14,
    "min_area":      0.083,
    "end_of_line":   { "space": 0.28, "width": 0.14 }
  },
  "via1": {
    "size":          0.15,
    "enclosure_met1": 0.055,
    "enclosure_met2": 0.055,
    "min_space":     0.17
  }
}
```

## `devices`

```json
{
  "nmos": {
    "layer_map": {
      "gate":   "poly",
      "source": "ndiff",
      "drain":  "ndiff",
      "body":   "pwell"
    },
    "params": {
      "min_w": 0.36,
      "min_l": 0.15
    }
  }
}
```

## Adding a new PDK

1. Copy `pdks/sky130.json` as a starting point
2. Update all layer names, GDS numbers, and design-rule values
3. Test with `python scripts/benchmark.py --pdk pdks/yourpdk.json`

> [!WARNING]
> DRC rules are enforced at route time. An incomplete rule deck will silently produce layouts with violations. Validate against a known-good reference layout before using a new PDK in production.
