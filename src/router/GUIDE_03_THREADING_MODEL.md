# Threading Model for Analog Router

## Design Constraints

1. **Grid is read-only during routing.** Built once, queried by all threads. No locks needed for spatial queries.
2. **Segments are append-only per thread.** Each thread writes to its own arena. Merge after all threads complete.
3. **Net groups are independent.** Matched nets within a group must be routed together, but different groups can be routed in parallel.
4. **PEX feedback is sequential.** Extract → analyze → repair is a serial phase between parallel routing passes.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PARALLEL ROUTING PASS                     │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Phase 1: BUILD (sequential)                         │   │
│  │  - Build MultiLayerGrid from devices + PDK           │   │
│  │  - Build SpatialGrid from existing segments          │   │
│  │  - Build ThermalMap from hotspot list                 │   │
│  │  - Sort groups by priority                           │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Phase 2: PARTITION (sequential)                     │   │
│  │  - Build dependency graph between groups             │   │
│  │  - Partition into independent wavefronts              │   │
│  │  - Assign groups to wavefronts                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Phase 3: ROUTE (parallel per wavefront)              │   │
│  │                                                       │   │
│  │  for each wavefront:                                  │   │
│  │    spawn N threads                                    │   │
│  │    each thread:                                       │   │
│  │      claim next unrouted group from wavefront         │   │
│  │      route group using thread-local arena             │   │
│  │      write segments to thread-local SegmentDB         │   │
│  │    barrier: wait for all threads                       │   │
│  │    merge thread-local segments into global SegmentDB   │   │
│  │    rebuild SpatialGrid (sequential, O(n))              │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Phase 4: PEX + REPAIR (sequential)                   │   │
│  │  - Extract parasitics for all analog segments         │   │
│  │  - Compute MatchReport per group                      │   │
│  │  - If failing: rip up + adjust + goto Phase 3         │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Phase 5: COMMIT (sequential)                         │   │
│  │  - Merge analog segments into RouteArrays              │   │
│  │  - Hand off to FlexDR for remaining digital nets      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Dependency Graph Between Groups

Two analog groups are **dependent** if:
1. They share a net (e.g., ground shield net used by multiple shielded groups)
2. Their routing regions overlap (bounding boxes of their pin sets intersect)
3. One group's guard ring encloses the other group's pins

Independent groups can be routed in parallel. Dependent groups must be in different wavefronts.

```zig
// src/router/parallel_router.zig

pub const GroupDependencyGraph = struct {
    /// adjacency_list[i] = list of group indices that conflict with group i
    adjacency: []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups: u32,
    allocator: std.mem.Allocator,

    pub fn build(
        groups: *const AnalogGroupDB,
        pin_bboxes: []const Rect,  // per-group bounding box of pins
    ) !GroupDependencyGraph {
        var graph: GroupDependencyGraph = undefined;
        graph.num_groups = groups.len;
        graph.adjacency = try allocator.alloc(
            std.ArrayListUnmanaged(AnalogGroupIdx),
            groups.len,
        );

        // Initialize empty lists
        for (graph.adjacency) |*list| list.* = .{};

        // Check all pairs for conflicts
        for (0..groups.len) |i| {
            for (i + 1..groups.len) |j| {
                if (groupsConflict(groups, pin_bboxes, i, j)) {
                    try graph.adjacency[i].append(allocator, AnalogGroupIdx.fromInt(@intCast(j)));
                    try graph.adjacency[j].append(allocator, AnalogGroupIdx.fromInt(@intCast(i)));
                }
            }
        }

        return graph;
    }

    fn groupsConflict(
        groups: *const AnalogGroupDB,
        bboxes: []const Rect,
        i: usize,
        j: usize,
    ) bool {
        // 1. Shared net check
        const nets_i = groups.netsForGroup(@intCast(i));
        const nets_j = groups.netsForGroup(@intCast(j));
        for (nets_i) |ni| {
            for (nets_j) |nj| {
                if (ni.toInt() == nj.toInt()) return true;
            }
        }

        // 2. Bounding box overlap (with margin = 2 * max_spacing)
        if (bboxes[i].overlapsWithMargin(bboxes[j], margin)) return true;

        return false;
    }
};
```

---

## Wavefront Partitioning

Graph coloring assigns groups to wavefronts such that no two conflicting groups share a wavefront:

```zig
/// Greedy graph coloring. Returns color (wavefront) per group.
pub fn colorGroups(
    graph: *const GroupDependencyGraph,
    allocator: std.mem.Allocator,
) ![]u8 {
    const n = graph.num_groups;
    const colors = try allocator.alloc(u8, n);
    @memset(colors, 0xFF); // uncolored

    for (0..n) |i| {
        // Find smallest color not used by neighbors
        var used = std.StaticBitSet(256).initEmpty();
        for (graph.adjacency[i].items) |neighbor| {
            const nc = colors[neighbor.toInt()];
            if (nc != 0xFF) used.set(nc);
        }
        // First unused color
        colors[i] = @intCast(used.findFirstUnset() orelse 0);
    }

    return colors;
}
```

Groups with the same color form a wavefront. Wavefronts execute sequentially; within each wavefront, all groups route in parallel.

**Expected wavefront count:** 2-4 for typical analog designs (most groups are spatially independent).

---

## Thread Pool

```zig
// src/router/thread_pool.zig

pub const ThreadPool = struct {
    threads: []std.Thread,
    work_queue: WorkQueue,
    done_count: std.atomic.Value(u32),
    total_work: u32,

    pub fn init(allocator: std.mem.Allocator, num_threads: u8) !ThreadPool {
        var pool: ThreadPool = undefined;
        pool.threads = try allocator.alloc(std.Thread, num_threads);
        pool.work_queue = WorkQueue.init(allocator);
        pool.done_count = std.atomic.Value(u32).init(0);
        return pool;
    }

    /// Submit a batch of work items and wait for all to complete.
    pub fn submitAndWait(
        self: *ThreadPool,
        items: []const WorkItem,
    ) void {
        self.total_work = @intCast(items.len);
        self.done_count.store(0, .release);

        for (items) |item| self.work_queue.push(item);

        // Spawn threads
        for (self.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerFn, .{
                self,
                @as(u8, @intCast(i)),
            }) catch unreachable;
        }

        // Wait for completion
        for (self.threads) |t| t.join();
    }

    fn workerFn(pool: *ThreadPool, thread_id: u8) void {
        while (pool.work_queue.pop()) |item| {
            item.execute(thread_id);
            _ = pool.done_count.fetchAdd(1, .release);
        }
    }
};

pub const WorkItem = struct {
    group_idx: AnalogGroupIdx,
    db: *AnalogRouteDB,
    context: *RoutingContext,

    pub fn execute(self: WorkItem, thread_id: u8) void {
        const arena = &self.db.thread_arenas[thread_id];
        routeAnalogGroup(self.db, self.group_idx, self.context, arena.allocator()) catch |err| {
            // Mark group as failed; don't propagate — other groups continue
            self.db.groups.status[self.group_idx.toInt()] = .failed;
            _ = err;
        };
    }
};
```

---

## Thread-Local Storage Pattern

Each thread gets:
1. **Thread-local arena** — scratch memory for A* open/closed sets, Steiner tree construction. Reset after each group.
2. **Thread-local segment buffer** — `AnalogSegmentDB` for segments produced by this thread. Merged into global DB after wavefront completes.

```zig
pub const ThreadLocalState = struct {
    arena: std.heap.ArenaAllocator,
    local_segments: AnalogSegmentDB,
    thread_id: u8,

    pub fn reset(self: *ThreadLocalState) void {
        _ = self.arena.reset(.retain_capacity);
        self.local_segments.len = 0; // logical reset, keep capacity
    }
};
```

**Why no locks on segments:** Each thread appends to its own `local_segments`. After the wavefront barrier, the main thread merges all local segments into the global `AnalogSegmentDB` sequentially. This is a classic "fork-join with local accumulation" pattern — zero contention during the parallel phase.

---

## Spatial Grid: Read-Only During Routing

The spatial grid is **rebuilt** between wavefronts, not updated during routing:

```
Wavefront 1: route groups [A, B, C] in parallel
  - All threads read global SpatialGrid (immutable)
  - Each thread writes to thread-local segments
  barrier
  - Main thread: merge local segments → global SegmentDB
  - Main thread: rebuild SpatialGrid from global SegmentDB  (O(n))

Wavefront 2: route groups [D, E] in parallel
  - Updated SpatialGrid includes segments from wavefront 1
  ...
```

**Why rebuild instead of incremental update:**
- Rebuild is O(n) with simple cell assignment — fast for n < 100K
- No locks, no CAS, no contention
- Grid cells are contiguous arrays — prefetcher-friendly
- Incremental update requires synchronization (locks or atomic ops per cell)

---

## Work Queue

Lock-free bounded SPMC (single-producer, multi-consumer) queue:

```zig
pub const WorkQueue = struct {
    items: []WorkItem,
    head: std.atomic.Value(u32),  // consumer reads from here
    tail: u32,                     // producer writes here (single-producer, no atomic needed)
    capacity: u32,

    pub fn push(self: *WorkQueue, item: WorkItem) void {
        const t = self.tail;
        self.items[t % self.capacity] = item;
        self.tail = t + 1;
    }

    pub fn pop(self: *WorkQueue) ?WorkItem {
        while (true) {
            const h = self.head.load(.acquire);
            if (h >= self.tail) return null; // empty
            const item = self.items[h % self.capacity];
            if (self.head.cmpxchgWeak(h, h + 1, .acq_rel, .acquire)) |_| {
                continue; // lost race, retry
            }
            return item;
        }
    }
};
```

---

## Synchronization Points

| Point | Mechanism | Cost |
|-------|-----------|------|
| Wavefront barrier | `Thread.join()` on all worker threads | O(1) per thread |
| Segment merge | Sequential `@memcpy` of local → global | O(segments_per_wavefront) |
| Spatial grid rebuild | Sequential cell assignment | O(total_segments) |
| PEX extraction | Sequential (calls into existing `pex.zig`) | O(segments × neighbors) |
| Group status update | Atomic write to `status[group_idx]` | O(1) |

**Total locks in system: zero.** All synchronization is structural (barriers, atomic values, thread-local storage).

---

## Thread Count Selection

```zig
/// Choose thread count based on hardware and workload.
pub fn selectThreadCount(num_groups: u32) u8 {
    const hw_threads = std.Thread.getCpuCount() catch 4;
    const max_useful = @min(num_groups, hw_threads);
    // Cap at 16 — diminishing returns beyond this for routing workloads
    return @intCast(@min(max_useful, 16));
}
```

**Rationale:**
- Each thread needs ~1 MB stack + arena working set
- More threads than groups = idle threads
- More threads than cores = context switching overhead
- 16 cap: analog routing is memory-bandwidth-bound, not compute-bound; more threads compete for L3

---

## A* Thread Safety

`AStarRouter` currently uses `AutoHashMap` for open/closed sets. These are **not** thread-safe, but they don't need to be — each thread runs its own `AStarRouter` instance with its own maps allocated from the thread-local arena.

```zig
// In routeAnalogGroup():
fn routeAnalogGroup(
    db: *AnalogRouteDB,
    group_idx: AnalogGroupIdx,
    context: *const RoutingContext,
    thread_alloc: std.mem.Allocator,
) !void {
    // Thread-local A* instance — no sharing, no locks
    var astar = AStarRouter.init(thread_alloc, context.grid, context.drc_checker);
    defer astar.deinit();

    // Thread-local Steiner tree builder
    var steiner = SteinerTree.init(thread_alloc);
    defer steiner.deinit();

    // Route each edge of the Steiner tree
    const tree = try steiner.build(pins);
    for (tree.edges) |edge| {
        const path = try astar.findPath(edge.src, edge.dst, matchedCostFn);
        try commitPath(db, group_idx, path, thread_alloc);
    }
}
```

---

## Memory Model Summary

```
┌──────────────────────────────────────────────────┐
│                 MAIN THREAD                       │
│                                                  │
│  AnalogRouteDB (global, owned by main)            │
│  ├── groups: AnalogGroupDB (read-only during route)│
│  ├── segments: AnalogSegmentDB (append after merge)│
│  ├── spatial: SpatialGrid (rebuilt between waves)  │
│  ├── shields: ShieldDB (written by ShieldRouter)   │
│  ├── guard_rings: GuardRingDB (written by GR ins.) │
│  ├── thermal: ThermalMap (read-only, built once)   │
│  ├── lde: LDEConstraintDB (read-only)              │
│  └── match_reports: MatchReportDB (written by PEX) │
│                                                  │
│  pass_arena: scratch for sequential phases        │
└──────────────┬───────────────────────────────────┘
               │ spawns
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│Thread 0│ │Thread 1│ │Thread 2│  ...
│        │ │        │ │        │
│ arena  │ │ arena  │ │ arena  │  ← thread-local, reset per group
│ local_ │ │ local_ │ │ local_ │
│ segs   │ │ segs   │ │ segs   │  ← merged after wavefront barrier
│        │ │        │ │        │
│ READS: │ │ READS: │ │ READS: │
│ groups │ │ groups │ │ groups │  ← immutable during routing
│ spatial│ │ spatial│ │ spatial│  ← immutable during wavefront
│ thermal│ │ thermal│ │ thermal│  ← immutable always
│ pdk    │ │ pdk    │ │ pdk    │  ← immutable always
└────────┘ └────────┘ └────────┘
```

**Read-only during parallel phase:** groups, spatial, thermal, pdk, lde.
**Write-only per thread:** thread-local arena, local_segments.
**Written after barrier only:** global segments, spatial grid, match_reports.

---

## Parallel Correctness Checklist

| Property | How Enforced |
|----------|-------------|
| No data race on segments | Thread-local buffers, merged sequentially |
| No data race on spatial grid | Immutable during routing, rebuilt between waves |
| No data race on group status | Atomic store (relaxed ordering sufficient) |
| No data race on A* state | Thread-local instances, not shared |
| No use-after-free | Arena lifetime >= thread lifetime |
| No double-free | Arena reset, not individual free |
| Deterministic results | Groups within wavefront sorted by index; within each group, routing is deterministic |
| Deadlock-free | No locks; only barriers and atomics |

---

## Fallback: Sequential Mode

If `num_threads == 1` or `num_groups < 4`, skip threading entirely:

```zig
pub fn routeAllGroups(db: *AnalogRouteDB, context: *RoutingContext) !void {
    const num_threads = selectThreadCount(db.groups.len);

    if (num_threads <= 1 or db.groups.len < 4) {
        // Sequential — no thread pool overhead
        for (0..db.groups.len) |i| {
            try routeAnalogGroup(db, AnalogGroupIdx.fromInt(@intCast(i)), context,
                db.pass_arena.allocator());
        }
        return;
    }

    // Parallel path
    const dep_graph = try GroupDependencyGraph.build(&db.groups, pin_bboxes);
    const colors = try colorGroups(&dep_graph, db.pass_arena.allocator());
    const num_wavefronts = @max(colors) + 1;

    var pool = try ThreadPool.init(db.pass_arena.allocator(), num_threads);

    for (0..num_wavefronts) |wave| {
        var items = std.ArrayList(WorkItem).init(db.pass_arena.allocator());
        for (0..db.groups.len) |i| {
            if (colors[i] == wave) {
                try items.append(.{
                    .group_idx = AnalogGroupIdx.fromInt(@intCast(i)),
                    .db = db,
                    .context = context,
                });
            }
        }
        pool.submitAndWait(items.items);

        // Merge thread-local segments
        try mergeThreadLocalSegments(db, num_threads);

        // Rebuild spatial grid
        try db.spatial.rebuild(&db.segments);
    }
}
```
