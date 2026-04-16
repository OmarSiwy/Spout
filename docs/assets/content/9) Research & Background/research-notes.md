# Research Notes: DRC, PEX, and Analog Layout in Open-Source EDA

These notes document the complete content of `RESEARCH.md` and expand every point with additional technical context relevant to Spout's design decisions. The document covers two major research bodies: the Magic VLSI vs KLayout technical comparison, and the Qrouter architecture analysis.

---

## Part I: DRC and PEX in Magic VLSI vs KLayout

**Central finding:** Magic and KLayout implement fundamentally different DRC engines — tile-based vs polygon-based — and diverge sharply on parasitic extraction maturity. Magic's corner-stitched tile architecture delivers real-time incremental DRC and deeply integrated PEX with decades of refinement, but lacks antenna checks, density analysis, and connectivity-aware spacing. KLayout's polygon-based DRC scripting engine offers far broader rule coverage (antenna, density, connectivity primitives) and superior scalability through hierarchical/tiled processing, but its parasitic extraction capability only recently appeared in v0.30 and remains immature for capacitance. Neither tool matches commercial DFM capabilities for OPC, double patterning, or forbidden pitch verification.

This comparison directly informs Spout's signoff strategy: Spout uses **KLayout for DRC and LVS** (via `tools.py:run_klayout_drc`, `run_klayout_lvs`) and **Magic for PEX** (via `tools.py:run_magic_pex`), combining the strengths of both tools.

---

## How Each Engine Represents and Checks Geometry

### Magic: Corner-Stitched Tiles

Magic stores layout as a stack of **planes** (active, metal1, metal2, well, etc.), each composed entirely of non-overlapping rectangular **tiles** covering the complete plane — including explicitly represented "space" tiles. Each tile carries a type field and four corner-stitched pointers linking to adjacent tiles. This data structure is based on Ousterhout's 1984 algorithm and enables **O(√n) expected search time** for area queries. Edge detection is trivial: every boundary between two different tile types is an implicit geometric edge.

The DRC engine fires rules by **scanning tile edges**. When an edge between two different types is found, all DRC rules keyed to that type pair trigger and check the surrounding "halo" region. The halo distance equals the largest distance in any DRC rule. This enables **real-time incremental DRC** — every paint, erase, or move operation triggers rechecking only the affected region, with errors stored as special tiles on a dedicated `designRuleError` plane.

The most general DRC primitive is `edge4way`, which matches a pattern of types on each side of an edge, checks distance in all four directions, and applies corner-distance exceptions. Higher-level rules (`width`, `spacing`, `surround`, `overhang`, `extend`, `widespacing`) are syntactic sugar compiled into `edge4way` internally. Non-Manhattan geometry is handled through split tiles (v7.1+), where a tile is bisected diagonally to carry two material types.

**Key performance trade-off:** The explicit space representation means memory scales with total layout area, not just drawn geometry. Large halo distances (from wide-spacing or pad rules) cause severe DRC slowdowns. The `stepsize` keyword and manual `drc *halo` override provide mitigation.

### KLayout: Polygon and Edge Collections

KLayout operates on three fundamental object types: **Regions** (polygon collections), **Edges** (edge collections derived from polygon contours), and **EdgePairs** (violation markers pairing two interacting edges). All coordinates are stored as integer database units; operations use scanline-based boolean algorithms.

Three processing modes are available:
- **Flat mode** (default): Flattens all geometry before processing.
- **Deep mode**: Preserves cell hierarchy using subject/intruder decomposition, processing each cell once and reusing results across instances — critical for large designs with repeated blocks.
- **Tiled mode**: Splits the layout into rectangular tiles processed independently with border overlap, enabling multi-threaded execution via `threads(n)`.

DRC scripts are written in a Ruby DSL (Python supported via `klayout.db.Region` for low-level access). Each DRC statement operates on Region or Edge objects and produces EdgePairs marking violations. **Clean mode** (default) merges touching polygons before checks; **raw mode** preserves individual shapes. **Shielding** (enabled by default) ensures intermediate polygons block distance measurements — a feature absent in Magic's tile engine.

---

## Pure Geometric Rules: Width, Spacing, Area, and Booleans

### Width and Spacing

Both tools support minimum width and minimum spacing as core primitives. Magic's syntax:

```
width allm1 3 "Metal1 width < 3"
spacing *poly *ndiff 1 touching_ok "Poly-Ndiff spacing < 1"
```

The `spacing` rule accepts adjacency qualifiers: `touching_ok`, `touching_illegal`, `surround_ok`, `corner_ok`, and `manhattan_dist`. KLayout equivalent with richer metric options:

```ruby
metal1.width(0.7, euclidean).output("m1_width")
metal1.space(0.4, projection).output("m1_space")
```

KLayout additionally distinguishes `notch` (intra-polygon spacing), `isolated` (inter-polygon spacing), and `space` (both). This distinction is absent in Magic, where all spacing rules apply uniformly to tile edges regardless of polygon topology.

**Maximum width** is supported natively in both: Magic via `maxwidth layers distance [exempt_layers] why`, KLayout via `with_bbox_width` or universal DRC. Magic's `maxwidth` algorithm was substantially rewritten in v7.3 for better accuracy.

### Minimum and Maximum Area

Magic lacks a native minimum area DRC rule in the `drc` section. Area checks require CIF-based rules: `cifarea ciflayer area why`, which operate on layers generated through the `cifoutput` section's boolean pipeline. KLayout handles area natively with `with_area(min..max)` and `without_area(min..max)`:

```ruby
metal1.with_area(0, 0.083).output("m1_min_area", "Area < 0.083 sq.um")
```

### Boolean Operations

Magic's boolean operations exist only in the **CIF output pipeline** (`cifoutput` section), using operators `and`, `or`, `and-not`, `bloat`, `shrink`, `grow`. These are used to derive mask layers from internal tile types but are not available as general-purpose operations during editing or DRC.

KLayout provides **full Region algebra** as first-class operations:

```ruby
gate = active & poly          # AND (intersection)
field = active - poly         # NOT (subtraction)
diff = layer1 ^ layer2        # XOR
all_metal = metal1 | metal2   # OR (union)
```

The `andnot()` method computes AND and NOT simultaneously for efficiency. Sizing operations (`sized(d)`) implement Minkowski sum/difference with configurable corner modes (Manhattan square, octagonal, or round approximation). This makes KLayout dramatically more expressive for complex derived-layer rules.

### Slotting Rules

Magic handles slotting through the `cifoutput` section's `slots` operator, generating rectangular openings inside tiles, combined with `rect_only` and `exact_overlap` DRC rules to enforce proper cut generation. KLayout has no dedicated slot check but can implement slotting verification through boolean operations on polygon holes:

```ruby
metal1_holes = metal1.holes
metal1_holes.width(max_slot_width).output("slot_width_violation")
```

---

## Edge-Aware, Via, and Device-Level Rules

### End-of-Line and Parallel Run Length

**End-of-line (EOL) spacing** is not natively supported in Magic. It must be approximated using `edge4way` with careful type-pair matching, which is fragile for complex geometries. KLayout also lacks a dedicated `eol` function but provides composable edge primitives:

```ruby
short_edges = metal1.edges.with_length(0, 0.5.um)  # line-ends
short_edges.space(0.2).output("eol_spacing")
```

**Parallel run length (PRL) spacing** has no native support in Magic. The `widespacing` rule provides width-dependent spacing but not length-dependent spacing. KLayout supports PRL through the `projecting` option:

```ruby
layer.space(projection, projecting >= 2.um, 1.6).output("PRL >= 2um spacing")
```

### Corner and Angle Rules

Magic's `angles layers limit why` rule restricts allowed angles. Corner checking in Magic is embedded in `edge4way` via `cornerOKtypes` and `cornerdist` parameters.

KLayout provides the dedicated `corners()` function:

```ruby
metal1.corners(-90.0).output("convex_corners")  # negative = convex
metal1.corners(90.0).output("concave_corners")   # positive = concave
```

### Via and Contact Rules

Both tools handle via enclosure, spacing, and rectangularity. Magic uses `surround` for enclosure, `spacing` for via-to-via distance, and `rect_only` to enforce rectangular contacts:

```
surround via *m1 1 absence_ok "M1 enclosure of via < 1"
spacing via via 3 touching_illegal "Via spacing < 3"
rect_only pc/a "Contact not rectangular"
```

Magic's `no_overlap` and `exact_overlap` rules handle subcell overlap for correct contact cut generation. KLayout uses `enclosing`/`enclosed` and standard `space`/`separation`:

```ruby
metal1.enclosing(via, 0.05).output("m1_via_enc")
via.space(0.1).output("via_space")
```

**Via array rules** are not natively supported in either tool.

### Device-Level and Well/Implant Rules

Magic's transistor rules leverage its unique type system: poly over diffusion creates a transistor tile type on the active plane. Rules `overhang` (poly endcap extension), `extend` (minimum channel length), and `width` (channel width) operate directly on derived types:

```
overhang *poly nfet 3 "Poly overhang of NFET < 3 (gate extension)"
extend nfet ndiff 2 "NFET channel length < 2"
```

KLayout handles device-level rules through boolean layer derivation (`gate = active & poly`) followed by standard geometric checks, plus 12 built-in device extractors (mos3, mos4, dmos3, dmos4, bjt3, bjt4, diode, resistor, resistor_with_bulk, capacitor, capacitor_with_bulk) that recognize device structures and extract parameters (W, L, AS, AD, PS, PD).

---

## Antenna, Density, and Connectivity-Aware Checking

### Antenna Rules: KLayout's Clearest Advantage

Magic does not check antenna rules in its DRC engine. Antenna checking was added as a separate batch operation (`antennacheck run`, v7.5+) invoked explicitly — not part of continuous background DRC.

KLayout provides a **dedicated `antenna_check()` function** integrated with its Netter connectivity framework:

```ruby
connect(gate, poly); connect(poly, contact); connect(contact, metal1)
antenna_check(gate, metal1, 50.0).output("Antenna M1/gate > 50")
```

Key capabilities include incremental layer-by-layer connectivity, **diode recognition** (exclude or weight diode area), and perimeter-based area contributions via `area_and_perimeter()` and `evaluate_nets()` for custom antenna formulas. Results integrate with KLayout's net browser.

### Density and CMP Analysis

Magic has **no density checking capability**. KLayout offers two approaches. The built-in `with_density` function (v0.27+) supports **sliding window analysis**:

```ruby
metal.with_density(0.2..0.8, tile_size(200.um), tile_step(100.um)).output("density_ok")
```

The `TilingProcessor` class provides lower-level multi-threaded density computation.

### Connectivity-Aware DRC

Magic's DRC engine operates purely on tile types without connectivity knowledge. **Same-net vs different-net spacing is not supported.** KLayout (v0.28+) introduced **property-constrained operations** through the `nets` method:

```ruby
metal1_nets = metal1.nets  # attach net identity
metal1_nets.space(0.5, props_ne).output("diff_net_space")
metal1_nets.space(0.2, props_eq).output("same_net_space")
```

This capability is newer and less mature than commercial tools' CONNECTED/UNCONNECTED modes.

---

## Parasitic Extraction

### Magic's Integrated Extraction Pipeline

Magic's PEX is deeply coupled with its tile database and represents **decades of refinement**. The extractor traverses tile planes, accumulating area and perimeter per node, identifying device structures, and constructing RC networks. The `.ext` file format stores hierarchical extraction results with per-cell adjustment records.

**Capacitance extraction** covers five distinct parasitic types:

- **Area (parallel plate) to substrate**: `areacap types capacitance` or `defaultareacap`
- **Perimeter (fringe) to substrate**: `perimc type1 type2 capacitance` or `defaultperimeter`
- **Overlap (parallel plate between layers)**: `overlap layers1 layers2 capacitance [shielding]` — replaces substrate capacitance of upper layer with internodal capacitance to lower layer
- **Sidewall (lateral coupling)**: `sidewall types1 types2 distance capacitance` — parallel-plate model between vertical edges
- **Sidewall-overlap (fringe between layers)**: `sideoverlap layers1 layers2 distance capacitance` — orthogonal-plate coupling

The `planeorder` system automates shielding calculations. The `sidehalo` parameter controls maximum coupling distance, trading accuracy for speed (disabling coupling yields **30–50% faster extraction**).

**Gate capacitance** is specified per device. **Junction capacitance** is extracted as source/drain area and perimeter (AS, PS, AD, PD) per node.

**Resistance extraction** operates at two levels: basic lumped worst-case resistance per node from area/perimeter ratios, and full distributed RC extraction via `extresist`. Since v8.3.597, `extract do resistance` integrates distributed extraction. **Inductance** is limited to FastHenry format export — Magic does not compute inductance values natively.

**Spout relevance:** `tools.py:run_magic_pex()` calls Magic in batch mode (`magic -dnull -noconsole`) with a TCL script that runs `extract do resistance`, `extract do capacitance`, `extract do coupling`, `extract all`, `ext2spice hierarchy on`, `ext2spice format ngspice`, and finally `ext2spice`. The result is parsed by counting lines starting with `C` (capacitors) and `R` (resistors) in the output SPICE file.

### KLayout's Extraction: Strong LVS, Nascent PEX

KLayout's core extraction strength is **LVS and device recognition** (since v0.26). Its 12 built-in device extractors handle MOSFET, BJT, diode, resistor, and capacitor recognition with parameter extraction. The hierarchical extraction engine is stable, well-documented, and scriptable in Ruby and Python.

**KLayout v0.30 introduced a new `pex` module** with native resistance extraction classes: `RExtractor`, `RNetExtractor`, `RExtractorTech`, `RExtractorTechConductor`, `RExtractorTechVia`, `RNetwork`, `RNode`, and `RElement`.

**KLayout has no built-in parasitic capacitance extraction.** The gap is addressed by **KLayout-PEX (KPEX)** (GitHub: iic-jku/klayout-pex, GPL-3.0), providing three engines:

- **KPEX/FasterCap**: 3D field solver integration (most accurate, slowest)
- **KPEX/MAGIC**: Wrapper calling Magic's extraction engine externally
- **KPEX/2.5D**: Analytical engine reimplementing Magic's parasitic formulas

KPEX remains **pre-alpha** (v0.3.9 as of February 2026) with supported PDKs limited to SKY130A and IHP SG13G2.

---

## DFM and Manufacturability Limits

Both Magic and KLayout offer minimal DFM capability. **Neither tool supports:** OPC/litho-aware rules, forbidden pitch verification, double-patterning coloring constraints, self-aligned double patterning verification, or line-end shortening prediction. Both tool developers explicitly acknowledge this gap and recommend commercial sign-off DRC for tapeout.

---

## Comprehensive Rule Support Matrix

| Rule Category             | Magic                     | KLayout                                   |
| ------------------------- | ------------------------- | ----------------------------------------- |
| Minimum width             | `width`                   | `width()`                                 |
| Maximum width             | `maxwidth`                | `with_bbox_width` / universal DRC         |
| Minimum spacing           | `spacing`                 | `space()` / `separation()`                |
| Width-dependent spacing   | `widespacing`             | via `projecting` option                   |
| Notch (internal spacing)  | via `spacing`             | `notch()` (dedicated)                     |
| Minimum area              | `cifarea` only            | `with_area()`                             |
| Maximum area              | via CIF                   | `without_area()`                          |
| Boolean operations        | CIF pipeline only         | Full Region algebra                       |
| Slotting                  | CIF `slots` operator      | via boolean on holes                      |
| End-of-line               | not supported             | composable from edge filters              |
| Parallel run length       | not supported             | `projecting` parameter                    |
| Corner detection          | `edge4way` cornerOK       | `corners()` function                      |
| Angle restriction         | `angles`                  | `with_angle()`                            |
| Via enclosure             | `surround`                | `enclosing()` / `enclosed()`             |
| Via spacing               | `spacing`                 | `space()`                                 |
| Via arrays                | not supported             | via `covering`/count                      |
| Transistor rules          | `overhang` / `extend`     | boolean + device extractors               |
| Antenna rules             | separate batch command    | `antenna_check()` integrated              |
| Density/CMP               | not supported             | `with_density()` + TilingProcessor        |
| Same-net/different-net    | not supported             | `props_eq`/`props_ne` (newer versions)    |
| Incremental real-time DRC | core feature              | batch only                                |

| PEX Category              | Magic                    | KLayout (Core)          | KLayout-PEX    |
| ------------------------- | ------------------------ | ----------------------- | -------------- |
| Area cap to substrate     | `areacap`                | not supported           | 2.5D engine    |
| Fringe cap to substrate   | `perimc`                 | not supported           | 2.5D engine    |
| Overlap cap (inter-layer) | `overlap`                | not supported           | 2.5D engine    |
| Sidewall coupling cap     | `sidewall`               | not supported           | 2.5D engine    |
| Sidewall-overlap fringe   | `sideoverlap`            | not supported           | 2.5D engine    |
| Gate capacitance          | device perim/area cap    | not supported           | partial        |
| Junction capacitance      | AS/PS/AD/PD              | device extraction       | partial        |
| Sheet resistance          | `resist`                 | `pex` module (v0.30)    | supported      |
| Contact/via resistance    | `contact`                | `pex` module (v0.30)    | supported      |
| Distributed R extraction  | `extresist`              | new `pex` module        | partial        |
| Corner R correction       | v7.5+                    | not supported           | not supported  |
| Inductance                | FastHenry export         | not supported           | not supported  |
| 3D field solver           | not supported            | not supported           | FasterCap      |
| SPICE output              | ext2spice                | write_spice             | supported      |
| SPEF output               | not supported            | not supported           | planned        |

---

## Conclusion: Optimal Workflow

**Magic delivers unmatched integration between layout editing, real-time DRC, and parasitic extraction** through its tile-based architecture. Its PEX engine, handling five capacitance types plus distributed resistance, remains the most mature open-source extraction capability available.

**KLayout provides the more powerful verification framework** through its polygon-based engine and Ruby scripting DSL. Antenna checking, density analysis, and emerging net-aware spacing fill critical gaps that Magic cannot address.

The optimal workflow — and the one Spout implements — combines both: **KLayout for DRC and LVS**, **Magic for parasitic extraction**, and Netgen for schematic comparison.

---

## Part II: Qrouter Architecture

**Source:** Tim Edwards, Open Circuit Design. Repository: https://github.com/RTimothyEdwards/qrouter

Qrouter is a multi-layer detail netlist router for digital ASIC designs. Its architecture is studied as a reference for Spout's own maze router implementation in `src/router/maze.zig` and `src/router/detailed.zig`.

### File Structure

```
qrouter/
├── core routing engine
│   ├── maze.c / maze.h          # Lee algorithm maze router core
│   ├── node.c / node.h          # Node/net generation and obstruction handling
│   ├── qrouter.c / qrouter.h    # Main routing orchestration, stage entry points
│   └── mask.c / mask.h          # Route mask generation for search space limiting
│
├── I/O formats
│   ├── lef.c / lef.h            # LEF parser (layers, vias, cells)
│   ├── def.c / def.h            # DEF parser/writer (design, nets, routes)
│   └── output.c / output.h      # DEF output generation
│
├── cost & timing
│   ├── qconfig.h                # Design rules (widths, pitches, via arrays, costs)
│   └── delays.c                 # RLC extraction and delay calculation
│
├── verification
│   └── antenna.c                # Antenna effect detection and fixing
│
└── interface
    ├── tclqrouter.c             # Tcl command interface
    └── main.c                   # Non-Tcl entry point
```

### Key Data Structures

```c
// Grid point with cost
typedef struct gridp_ {
    short x, y;
    u_char layer;
    int cost;
} GRIDP;

// Partial route for maze expansion
typedef struct proute_ {
    u_char flags;
    union {
        int net;   // net number (for blocking)
        int cost;  // accumulated cost
    } prdata;
} PROUTE;

// Complete route
typedef struct route_ {
    DSEG segments;   // linked list of wire/via segments
    union {
        NODE node;   // start node
        ROUTE route; // or connected route
    } start, end;
    u_char flags;
    int netnum;
} ROUTE;

// Wire segment
typedef struct seg_ {
    int x1, y1, x2, y2;
    u_char layer;
    u_char segtype;    // WIRE, VIA, flags
    struct seg_ *next;
} SEG;
```

### Multi-Level Routing Architecture

Qrouter uses a **three-stage approach**:

**Stage 1: `dofirststage()` — Initial Masked Routing**
Routes nets in order defined by `create_netorder()`. Uses route masks (`RMask` array) to limit search space. For 2-node nets: creates L-shaped mask between tap points. For multi-node nets: generates trunk-and-branch patterns. Mask gradient: 0 = ideal area, increasing outward to "halo" distance.

**Stage 2: `dosecondstage()` — Rip-up/Reroute**
Iteratively rips up failing nets and re-routes with expanded search. Called multiple times with increasing cost limits (up to 100 iterations). Handles conflicts between nets via `ripup_net()`.

**Stage 3: `dothirdstage()` — Final Cleanup**
Final optimization pass. Handles power/ground bus routing. Route cleanup via `cleanup_net()` removes redundant adjacent vias.

### Design Rules Encoding

Layer configuration in `qconfig.h`:
```c
extern int Num_layers;
extern int PathWidth[];    // route width per layer
extern int GDSLayer[];     // GDS layer number mapping
extern int PitchX[], PitchY[];
extern u_char Vert[];      // vertical(1) or horizontal(0) per layer
```

Cost parameters:
```c
extern int SegCost;      // segment cost multiplier
extern int ViaCost;      // via cost multiplier
extern int JogCost;      // jog cost multiplier
extern int XverCost;     // cross-under cost
extern int BlockCost;    // blockage cost
extern int OffsetCost;   // offset tap cost
extern int ConflictCost; // routing conflict cost
```

### Maze Routing Algorithm: Modified Lee Algorithm

Qrouter implements a **modified Lee algorithm** with all targets presented simultaneously.

**`eval_pt()`** — the cost evaluation heart:
```c
cost = base_cost + direction_penalty + via_penalty + mask_penalty + conflict_penalty
// Direction changes add JogCost
// Moving to a new layer adds ViaCost
// Mask regions have gradient cost (0 to halo distance)
// Already-routed areas add ConflictCost
```

**`commit_proute()`** converts the partial route (PROUTE stack) into actual SEG chains, handling via insertion on layer changes.

### Net Ordering

Two methods in `create_netorder()`:
1. **Node count** (`compNets()`) — route nets with fewest nodes first
2. **Bounding box** (`altCompNets()`) — route nets with smallest bounding box first

Critical nets are always routed first.

### Route Mask System

`createMask()` generates masks that limit search space:
- **2-node nets**: L-shaped mask between closest tap points
- **Multi-node nets**: Trunk-and-branch patterns; trunk horizontal or vertical based on aspect ratio

The mask gradient provides ~**30x speedup** for masked routes. Used in stage 1, disabled for rip-up/reroute in stage 2.

### Congestion Modeling

`analyzeCongestion()` scores potential trunk positions based on obstacle density and offset from ideal center location. `find_bounding_box()` computes min/max coordinates of all tap points for a net — used for both net ordering and mask generation.

### Rip-up/Reroute Mechanism

**`ripup_net()`** algorithm:
1. Walk all route segments for the net
2. Clear ROUTED_NET flags from OBS2[]
3. Clear net number from OBSVAL[]
4. Free route segment structures
5. Reset net->routes to NULL

Stage 2 iterates up to `ripdirs` times (default 100). On each iteration: find unrouted nodes, attempt route with expanded cost limits, rip up conflicting nets if necessary, retry with higher maxcost.

### Important: Qrouter Does NOT Use A\*

Qrouter does NOT use classical A* with heuristic history. Cost is purely additive path cost from source. The `PR_ON_STACK` flag prevents a point from being re-added to the expansion queue even if found via a cheaper path later — this prevents cycles but is not true A* with heuristic. This is a Lee-type (BFS-like) algorithm, not A*.

**Spout relevance:** Spout's `src/router/maze.zig` implements a similar Lee-based approach, while `src/router/astar.zig` provides a true A* implementation with heuristic cost. The Qrouter architecture informs Spout's three-layer routing strategy and cost function design.

### Delay Estimation

`delays.c` provides RLC extraction and delay calculation per route. Relevant to Spout's timing-aware placement cost in `SpoutConfig.SaConfig`:
- `delay_driver_r`: driver output resistance (default 500 Ω)
- `delay_wire_r_per_um`: wire resistance per micron (default 0.125 Ω/µm)
- `delay_wire_c_per_um`: wire capacitance per micron (default 0.2 fF/µm)
- `delay_pin_c`: pin input capacitance (default 1.0 fF)

---

## Open Problems and Future Directions

From the research documents, the following problems remain open and are directly relevant to Spout's development:

1. **Connectivity-aware DRC in open-source tools**: KLayout's `props_eq`/`props_ne` is newer and less mature than commercial same-net/different-net spacing. Spout's inline DRC in `router/inline_drc.zig` could eventually incorporate net-aware rules.

2. **Open-source parasitic capacitance extraction**: KPEX is pre-alpha. Magic's extraction engine, while mature, is difficult to integrate programmatically. Spout currently shells out to Magic via subprocess; a native Zig PEX engine would eliminate this dependency.

3. **Density-aware routing**: Neither Magic nor KLayout integrates density analysis into the routing loop. Spout's RUDY (Routing Utilization Distribution Yield) cost function in the SA placer addresses this but only at placement time.

4. **Multi-patterning and EUV verification**: Not addressed by either open-source tool. Not currently in Spout's scope but relevant for future advanced-node support.

5. **LDE-aware placement**: At advanced nodes, STI stress (LOD), WPE, and other LDE mechanisms create systematic shifts exceeding random mismatch. Spout's constraint extractor recognizes differential pairs, current mirrors, and cascodes, and the SA placer has a `w_symmetry` cost weight, but full LDE-aware placement (computing SA/SB for all device placements) is a future direction.
