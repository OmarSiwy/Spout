# Placer Overview

The placer positions devices on the layout canvas subject to electrical and physical constraints.

## Constraint types

| Constraint | API | Description |
|-----------|-----|-------------|
| Match pair | `pc.match_pair(m1, m2)` | Common-centroid placement, same orientation |
| Proximity | `pc.near(m1, m2)` | Place devices within N microns |
| Guard ring | `pc.add_guard_ring(devs)` | Enclosed region with well-tap ring |
| Fixed | `pc.fix(dev, x, y)` | Pin device to absolute coordinates |
| Row align | `pc.align_row([m1, m2, m3])` | Force devices onto same horizontal row |
| Symmetry | `pc.symmetry_axis(devs, axis="x")` | Mirror placement about axis |

## Algorithm

The placer uses a constraint-satisfaction search with force-directed refinement:

1. **Cluster** — group devices by connectivity and constraints
2. **Floorplan** — assign clusters to regions
3. **Place** — force-directed within each cluster
4. **Legalize** — snap to grid, resolve overlaps
5. **Refine** — simulated annealing to reduce wire length

## Key files

| File | Description |
|------|-------------|
| `src/placer/` | Placer source (see `ARCH.md` for details) |
