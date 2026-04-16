# Threading Model

Spout's analog router uses a hand-written lock-free thread pool to parallelize group routing across CPU cores. The model is designed around three invariants that eliminate all data races without mutexes: the shared spatial grid is read-only during routing; each worker thread writes only to its own private segment buffer; and the global segment database is written only by the main thread during single-threaded merge windows between wavefronts.

```svg
<svg viewBox="0 0 900 640" xmlns="http://www.w3.org/2000/svg" style="background:#060C18;border-radius:8px;display:block;max-width:100%">
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#00C4E8"/>
    </marker>
    <marker id="arr-g" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#43A047"/>
    </marker>
    <marker id="arr-a" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#FB8C00"/>
    </marker>
  </defs>

  <!-- Title -->
  <text x="450" y="30" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="15" font-weight="bold">Thread Pool — Wavefront Parallel Routing</text>

  <!-- ── Main Thread Box ── -->
  <rect x="30" y="55" width="840" height="80" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="450" y="78" text-anchor="middle" fill="#00C4E8" font-family="monospace" font-size="12" font-weight="bold">MAIN THREAD</text>
  <rect x="70"  y="88" width="130" height="32" rx="4" fill="#0D1B2E" stroke="#14263E"/>
  <text x="135" y="109" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="10">colorGroups()</text>
  <rect x="230" y="88" width="130" height="32" rx="4" fill="#0D1B2E" stroke="#14263E"/>
  <text x="295" y="109" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="10">WorkQueue.push()</text>
  <rect x="390" y="88" width="130" height="32" rx="4" fill="#0D1B2E" stroke="#14263E"/>
  <text x="455" y="109" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="10">Thread.spawn() × N</text>
  <rect x="550" y="88" width="130" height="32" rx="4" fill="#0D1B2E" stroke="#14263E"/>
  <text x="615" y="109" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="10">thread.join() × N</text>
  <rect x="710" y="88" width="130" height="32" rx="4" fill="#0D1B2E" stroke="#14263E"/>
  <text x="775" y="109" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="10">mergeThreadLocal()</text>
  <!-- arrows -->
  <line x1="200" y1="104" x2="228" y2="104" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="360" y1="104" x2="388" y2="104" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="520" y1="104" x2="548" y2="104" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="680" y1="104" x2="708" y2="104" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- ── WorkQueue ── -->
  <rect x="320" y="170" width="260" height="60" rx="6" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="450" y="190" text-anchor="middle" fill="#1E88E5" font-family="monospace" font-size="11" font-weight="bold">WorkQueue (SPMC, lock-free)</text>
  <text x="450" y="208" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="9">head: atomic(u32)   tail: u32 (single-producer)</text>
  <text x="450" y="222" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="9">pop(): CAS loop on head   capacity: 256</text>
  <!-- main → queue -->
  <line x1="450" y1="135" x2="450" y2="168" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- ── Workers ── -->
  <!-- Worker 0 -->
  <rect x="30" y="270" width="175" height="200" rx="6" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="117" y="291" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="11" font-weight="bold">Worker 0</text>
  <rect x="48" y="300" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="118" y="318" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">workerFn(): pop loop</text>
  <rect x="48" y="333" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="118" y="351" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">WorkItem.execute()</text>
  <rect x="48" y="366" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="118" y="384" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">A*: scratch → arena</text>
  <rect x="48" y="420" width="140" height="36" rx="3" fill="#1A2A1A" stroke="#43A047" stroke-width="1"/>
  <text x="118" y="436" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="9">ThreadLocalState</text>
  <text x="118" y="450" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="8">arena + local_segments</text>

  <!-- Worker 1 -->
  <rect x="230" y="270" width="175" height="200" rx="6" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="317" y="291" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="11" font-weight="bold">Worker 1</text>
  <rect x="248" y="300" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="318" y="318" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">workerFn(): pop loop</text>
  <rect x="248" y="333" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="318" y="351" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">WorkItem.execute()</text>
  <rect x="248" y="366" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="318" y="384" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">A*: scratch → arena</text>
  <rect x="248" y="420" width="140" height="36" rx="3" fill="#1A2A1A" stroke="#43A047" stroke-width="1"/>
  <text x="318" y="436" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="9">ThreadLocalState</text>
  <text x="318" y="450" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="8">arena + local_segments</text>

  <!-- Worker N-1 -->
  <rect x="430" y="270" width="175" height="200" rx="6" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="517" y="291" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="11" font-weight="bold">Worker N−1</text>
  <rect x="448" y="300" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="518" y="318" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">workerFn(): pop loop</text>
  <rect x="448" y="333" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="518" y="351" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">WorkItem.execute()</text>
  <rect x="448" y="366" width="140" height="26" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="518" y="384" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">A*: scratch → arena</text>
  <rect x="448" y="420" width="140" height="36" rx="3" fill="#1A2A1A" stroke="#43A047" stroke-width="1"/>
  <text x="518" y="436" text-anchor="middle" fill="#43A047" font-family="monospace" font-size="9">ThreadLocalState</text>
  <text x="518" y="450" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="8">arena + local_segments</text>

  <!-- Ellipsis between workers -->
  <text x="620" y="375" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="18">···</text>

  <!-- queue → workers -->
  <line x1="380" y1="200" x2="117" y2="268" stroke="#43A047" stroke-width="1.3" marker-end="url(#arr-g)"/>
  <line x1="420" y1="226" x2="317" y2="268" stroke="#43A047" stroke-width="1.3" marker-end="url(#arr-g)"/>
  <line x1="470" y1="230" x2="517" y2="268" stroke="#43A047" stroke-width="1.3" marker-end="url(#arr-g)"/>

  <!-- Shared read-only structures -->
  <rect x="650" y="270" width="230" height="170" rx="6" fill="#09111F" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="6,3"/>
  <text x="765" y="291" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="10" font-weight="bold">Read-Only (no locks)</text>
  <rect x="668" y="302" width="195" height="24" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="765" y="319" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">SpatialGrid (rebuilt per wavefront)</text>
  <rect x="668" y="334" width="195" height="24" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="765" y="351" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">AnalogGroupDB (group metadata)</text>
  <rect x="668" y="366" width="195" height="24" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="765" y="383" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">PdkConfig (layer rules)</text>
  <rect x="668" y="398" width="195" height="24" rx="3" fill="#0D1B2E" stroke="#14263E"/>
  <text x="765" y="415" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">DeviceArrays / PinEdgeArrays</text>
  <!-- dashed read arrows -->
  <line x1="188" y1="350" x2="666" y2="350" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,3" marker-end="url(#arr)"/>

  <!-- Merge step (after join) -->
  <rect x="30" y="500" width="840" height="60" rx="6" fill="#09111F" stroke="#FB8C00" stroke-width="1.5"/>
  <text x="450" y="522" text-anchor="middle" fill="#FB8C00" font-family="monospace" font-size="11" font-weight="bold">SYNC POINT — Main Thread Only</text>
  <text x="450" y="542" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="9">mergeThreadLocalSegments() → AnalogSegmentDB  |  mergeThreadLocalToRouteArrays() → RouteArrays  |  reset ThreadLocalState</text>
  <!-- workers → merge -->
  <line x1="117" y1="470" x2="200" y2="498" stroke="#FB8C00" stroke-width="1.2" marker-end="url(#arr-a)"/>
  <line x1="317" y1="470" x2="380" y2="498" stroke="#FB8C00" stroke-width="1.2" marker-end="url(#arr-a)"/>
  <line x1="517" y1="470" x2="480" y2="498" stroke="#FB8C00" stroke-width="1.2" marker-end="url(#arr-a)"/>

  <!-- Repeat annotation -->
  <text x="450" y="590" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="10">↻  repeat for each wavefront color (num_colors iterations total)</text>

  <!-- Legend -->
  <line x1="60"  y1="618" x2="85"  y2="618" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>
  <text x="90"  y="622" fill="#B8D0E8" font-family="monospace" font-size="9">control flow</text>
  <line x1="180" y1="618" x2="205" y2="618" stroke="#43A047" stroke-width="2" marker-end="url(#arr-g)"/>
  <text x="210" y="622" fill="#B8D0E8" font-family="monospace" font-size="9">work dispatch</text>
  <line x1="310" y1="618" x2="335" y2="618" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arr)"/>
  <text x="340" y="622" fill="#B8D0E8" font-family="monospace" font-size="9">read-only access</text>
  <line x1="460" y1="618" x2="485" y2="618" stroke="#FB8C00" stroke-width="2" marker-end="url(#arr-a)"/>
  <text x="490" y="622" fill="#B8D0E8" font-family="monospace" font-size="9">merge (single-threaded)</text>
</svg>
```

## ThreadPool

`ThreadPool` lives in `src/router/thread_pool.zig`. It owns a flat worker-thread array (`[]std.Thread`) and a single `WorkQueue`. There are no mutexes anywhere in the structure.

```
pub const ThreadPool = struct {
    threads:    []std.Thread,
    work_queue: WorkQueue,
    done_count: std.atomic.Value(u32),
    total_work: u32,
    num_threads: u8,
    allocator:  std.mem.Allocator,
}
```

**`init(allocator, num_threads)`** allocates the thread slice and the `WorkQueue` with a fixed capacity of 256 work items per wavefront. `num_threads` is clamped to at least 1.

**`submitAndWait(items)`** is the primary entry point for the main thread. It:
1. Stores `total_work` and resets `done_count` to 0.
2. Resets and refills the `WorkQueue` with all items for this wavefront.
3. Spawns all `N` threads with `std.Thread.spawn`, each executing `workerFn`.
4. Calls `thread.join()` on every thread — blocking until all work is consumed.

**`submitWavefronts`** is the higher-level loop that iterates over wavefront colors. For each color it collects matching group indices, builds `WorkItem`s with round-robin thread-local assignment, calls `submitAndWait`, then calls `mergeThreadLocalSegments` and resets all `ThreadLocalState`s.

**`workerFn(pool, thread_id)`** is the per-thread body: a `while (pool.work_queue.pop()) |item|` loop that calls `item.execute(thread_id)` and increments `done_count` atomically after each item.

**Thread count selection** is automated by `selectThreadCount(num_groups)`: reads `std.Thread.getCpuCount()` (falls back to 4), clamps to `min(num_groups, hw_threads, 16)`. Values above 16 produce diminishing returns for routing workloads.

---

## WorkQueue

`WorkQueue` is a bounded single-producer / multi-consumer (SPMC) queue using a flat `[]WorkItem` array and two indices:

| Field | Type | Description |
|-------|------|-------------|
| `items` | `[]WorkItem` | Flat circular buffer, capacity 256 |
| `head` | `std.atomic.Value(u32)` | Consumer-side pop index — atomic |
| `tail` | `u32` | Producer-side push index — not atomic (main-thread only) |
| `capacity` | `u32` | Always 256 in current usage |

**`push(item)`** — main thread only. Writes `items[tail % capacity] = item` and increments `tail`. No atomic needed because only one thread ever calls `push`.

**`pop()`** — called by any worker thread. CAS loop:
```
h = head.load(.acquire)
if h >= tail: return null
item = items[h % capacity]
if cmpxchgWeak(h, h+1, .acq_rel, .acquire) fails: retry
return item
```
The weak CAS tolerates spurious failure; the loop retries until it either wins the race or sees an empty queue.

**`reset()`** — stores 0 to `head` with `.release` ordering and sets `tail = 0`. Called before each wavefront by `submitAndWait`.

**`isEmpty()`** — `head.load(.acquire) >= tail`. Used in tests; not called in the hot path.

---

## WorkItem

`WorkItem` is the unit of work dispatched to each thread. One item = one analog group.

```
pub const WorkItem = struct {
    group_idx:    u32,
    net_ids:      []const u32,   // net IDs in this group
    routes:       *RouteArrays,
    thread_local: *ThreadLocalState,
}
```

**`execute(thread_id)`** — stub path used when full grid context is not present. Iterates over `net_ids` and appends a zero-geometry segment per net to `thread_local.local_segments`, setting `net` and `group` fields. On any allocation failure it returns early without crashing.

**`executeWithRouter(router, grid, pins_p, pins_n)`** — production path. Calls `MatchedRouter.routeGroup(grid, net_p, net_n, pins_p, pins_n, null)` for real A*-routed geometry. On success calls `router.emitToSegmentDB(&tl.local_segments, group, 0.14)` to transfer geometry into the thread-local buffer. Both failure modes return silently rather than propagating errors to the caller.

---

## ThreadLocalState

Each worker thread is assigned one `ThreadLocalState`. Workers never share states.

```
pub const ThreadLocalState = struct {
    arena:          std.heap.ArenaAllocator,
    local_segments: AnalogSegmentDB,
    thread_id:      u8,
}
```

**`arena`** — a heap arena allocator used for A* open/closed sets, Steiner tree scratch buffers, and any other per-route allocations. Backed by the global allocator passed to `init`.

**`local_segments`** — a full `AnalogSegmentDB` (SoA layout) holding segments produced by this thread during the current wavefront. Initialized with capacity 256.

**`reset()`** — called after every wavefront merge. Calls `arena.reset(.retain_capacity)` (frees all arena memory but keeps the backing pages mapped for reuse) and sets `local_segments.len = 0` (keeps capacity).

**`allocator()`** — returns `arena.allocator()` for use inside routing algorithms.

---

## Wavefront Coloring

Wavefront parallelism is achieved by graph-coloring the `GroupDependencyGraph` before any routing begins. Groups with the same color are guaranteed to be independent — they share no routing resources that could produce a data race — and are dispatched as a single parallel batch.

### GroupDependencyGraph

```
GroupDependencyGraph {
    adjacency:  []std.ArrayListUnmanaged(AnalogGroupIdx),  // per-group neighbor list
    num_groups: usize,
    allocator:  std.mem.Allocator,
}
```

Two groups are adjacent (have an edge) if they share a net, overlap spatially, or have a shield/guard-ring dependency. The graph is built once per routing invocation before the thread pool is started.

### colorGroups

`colorGroups(graph, allocator)` runs a greedy sequential graph coloring algorithm:

```
colors = [0xFF] × n   // uncolored sentinel

for i in 0..n:
    used = StaticBitSet(256)
    for each neighbor j of group i:
        if colors[j] != 0xFF: used.set(colors[j])
    color = smallest c not in used
    colors[i] = color
    max_color = max(max_color, color)

return ColorResult{ colors, max_color + 1 }
```

The algorithm is O(V + E) and produces at most `Δ + 1` colors where `Δ` is the maximum degree. For typical analog designs (< 100 groups, sparse dependency graph) this produces very few wavefronts and keeps parallelism high.

**Edge cases:**
- Empty graph → `ColorResult{ colors: []u8{}, num_colors: 0 }`
- K3 (complete triangle) → exactly 3 colors (verified by test `colorGroups triangle graph needs 3 colors`)
- All independent → 1 color, all groups in single wavefront

`ColorResult` is `{ colors: []u8, num_colors: u8 }`. The caller owns `colors` and must free it.

---

## Segment Merge

Segment merge happens in the single-threaded window after every `submitAndWait` returns (all threads joined). There are two merge functions:

### mergeThreadLocalSegments

Copies all segments from each `ThreadLocalState.local_segments` into the master `AnalogSegmentDB`. Field-by-field copy: `x1, y1, x2, y2, width, layer, net, group, flags`. After merge the thread-local buffers are reset before the next wavefront.

### mergeThreadLocalToRouteArrays

Copies geometry columns only (`x1, y1, x2, y2, layer, net`, `width`) into a `RouteArrays` for consumption by downstream stages (GDS writer, LVS checker). Calls `ensureUnusedCapacity` in a single shot before the copy loop to avoid repeated reallocation.

Both functions are serial and must only be called from the main thread. No locks are taken because all worker threads have already been joined.

---

## Synchronization Points

The routing pipeline alternates between parallel and serial phases on a strict schedule:

| Phase | Threading | Description |
|-------|-----------|-------------|
| Build `GroupDependencyGraph` | Serial | Scan group nets for shared pins |
| `colorGroups` | Serial | Greedy graph coloring |
| Rebuild `SpatialGrid` | Serial | Cell size = `2 × max(min_spacing)` |
| Submit wavefront *k* | Parallel | All groups with `color == k` route simultaneously |
| Join all workers | Sync point | `submitAndWait` blocks until all threads complete |
| `mergeThreadLocalSegments` | Serial | Append thread segments to global AnalogSegmentDB |
| `mergeThreadLocalToRouteArrays` | Serial | Append to RouteArrays |
| Reset `ThreadLocalState` | Serial | Arena reset + len = 0 |
| Increment wavefront color | Serial | → next iteration |
| PEX feedback extract | Serial | After all wavefronts complete |
| PEX repair dispatch | Serial | Repairs route one group at a time |
| Digital routing | Serial | `DetailedRouter` follows analog pass |

The PEX feedback loop (up to 5 iterations) runs entirely serially — it invokes `pexFeedbackLoop` which calls `routeAllGroups` again for each repair iteration. Each call to `routeAllGroups` re-enters the parallel wavefront dispatch.

---

## Data Race Analysis

| Data structure | Shared? | Protection mechanism |
|----------------|---------|---------------------|
| `WorkQueue.head` | Shared (all workers) | `std.atomic.Value(u32)` with CAS |
| `WorkQueue.tail` | Not shared | Written only by main thread |
| `WorkQueue.items[]` | Read by workers, written by main | Main writes before spawn; workers read after |
| `SpatialGrid` | Shared read-only | Rebuilt before wavefront; no writes during routing |
| `AnalogGroupDB` | Shared read-only | Metadata fixed before routing begins |
| `PdkConfig` | Shared read-only | Immutable after init |
| `DeviceArrays` | Shared read-only | Immutable after placement |
| `ThreadLocalState.arena` | Per-thread private | No sharing; indexed by thread_id |
| `ThreadLocalState.local_segments` | Per-thread private | No sharing |
| `AnalogSegmentDB` (global) | Serial only | Written only during merge (after join) |
| `RouteArrays` (global) | Serial only | Written only during merge (after join) |
| `done_count` | Shared | `fetchAdd(.release)` in worker; read by `submitAndWait` after join |

The only atomic variable used during parallel execution is `WorkQueue.head`. All other coordination is achieved through program-order guarantees: `Thread.spawn` establishes a happens-before edge for all writes before spawn; `thread.join()` establishes a happens-before edge for all worker writes before the post-join merge.

---

## RouteJob and RouteResult

`RouteJob` is a higher-level descriptor above `WorkItem`, used for scheduling and result collection:

```
RouteJob {
    group_idx:       u32,
    net_ids:         []const u32,
    priority:        u8,      // lower = higher priority
    preferred_layer: u8,      // 0 = auto-select
}
```

Jobs are sorted by `priority` ascending before dispatch (`RouteJob.lessThan`). This allows power-ground nets or critical matched pairs to be routed first.

`RouteResult` collects per-group routing statistics after the wavefront:

```
RouteResult {
    group_idx:      u32,
    segment_count:  u32,
    via_count:      u32,
    total_length:   f32,    // sum of Euclidean segment lengths (µm)
    success:        bool,   // segment_count > 0
    drc_violations: u32,    // populated by detectSegmentConflicts
}
```

`collectRouteResults(thread_locals, jobs, allocator)` scans all thread-local segment buffers linearly for each job's `group_idx`, counting segments and accumulating total length (`sqrt(dx² + dy²)`). Via count is left at 0 and populated separately by the DRC checker.

---

## Conflict Detection

`detectSegmentConflicts(segments, min_spacing, allocator)` implements a post-route O(n²) spacing check across all analog segments. For each pair `(i, j)` where `layer[i] == layer[j]` and `net[i] != net[j]`, it expands segment `i`'s bounding box by `min_spacing` on all sides and checks AABB overlap with segment `j`:

```
ax1 = min(x1[i], x2[i]) - min_spacing
ay1 = min(y1[i], y2[i]) - min_spacing
ax2 = max(x1[i], x2[i]) + width[i] + min_spacing
ay2 = max(y1[i], y2[i]) + width[i] + min_spacing

conflict if: ax1 < bx2 AND ax2 > bx1 AND ay1 < by2 AND ay2 > by1
```

`SegmentConflict` records both segment indices, both net indices, and the layer. The check is only applied to analog segments (< 1000 in typical designs); digital segments are checked by the inline DRC in the detailed router via `SpatialGrid`.

---

## Memory Model

Memory is partitioned into four regions with disjoint ownership:

```
┌────────────────────────────────────────────────────────────────┐
│ Global (main thread owns, persists across wavefronts)          │
│   AnalogGroupDB · AnalogSegmentDB · RouteArrays                │
│   SpatialGrid (rebuilt between wavefronts)                     │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ Per-thread (worker thread owns, lives for one wavefront)       │
│   ThreadLocalState.arena (A* open/closed, Steiner scratch)     │
│   ThreadLocalState.local_segments (AnalogSegmentDB)            │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ WorkQueue items (main thread writes before spawn)              │
│   WorkItem array[256] (stack-allocated per wavefront)          │
└────────────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────────┐
│ PEX feedback (serial, between parallel routing passes)         │
│   NetResult array · MatchReport array · RepairAction list      │
└────────────────────────────────────────────────────────────────┘
```

The arena reset strategy (`retain_capacity`) ensures that after the first wavefront, all per-thread arenas have pre-faulted pages of appropriate size. Subsequent wavefronts reuse those pages without touching the kernel allocator.

---

## Fallback Sequential Mode

If `num_groups == 0` or `selectThreadCount` returns 1, `submitAndWait` still spawns one worker thread and joins it. The code path is identical; no special serial fallback branch exists. Tests exercise the single-thread path via `ThreadPool.init(allocator, 0)` (clamped to 1).

For debugging, the sequential fallback can be forced by calling `item.execute(0)` directly from the main thread without spawning workers — the thread pool structure is not required for routing correctness, only for performance.
