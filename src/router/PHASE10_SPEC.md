# Phase 10: Thread Pool + Parallel Dispatch — Specification

## Overview

Route independent analog groups in parallel using a work-stealing thread pool. Dependent groups (shared nets, overlapping bboxes) are colored into wavefronts and routed sequentially per wavefront. The PEX feedback loop runs sequentially between wavefront batches.

## Thread Pool

### `ThreadPool`

```zig
pub const ThreadPool = struct {
    threads:     []std.Thread,
    work_queue:  WorkQueue,
    done_count:  std.atomic.Value(u32),
    total_work:  u32,
    allocator:   std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_threads: u8) !ThreadPool
    pub fn deinit(self: *ThreadPool) void
    pub fn submitAndWait(self: *ThreadPool, items: []const WorkItem) void
};
```

### `WorkQueue` (lock-free bounded SPMC)

```zig
pub const WorkQueue = struct {
    items:    []WorkItem,
    head:     std.atomic.Value(u32),  // consumer reads
    tail:     u32,                      // producer writes (single-threaded)
    capacity: u32,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !WorkQueue
    pub fn deinit(self: *WorkQueue, allocator: std.mem.Allocator) void
    pub fn push(self: *WorkQueue, item: WorkItem) void
    pub fn pop(self: *WorkQueue) ?WorkItem
};
```

### `WorkItem`

```zig
pub const WorkItem = struct {
    group_idx:   AnalogGroupIdx,
    route港:     *RouteArrays,
    pdk:         *const PdkConfig,

    pub fn execute(self: WorkItem, thread_id: u8) void {
        // Route the group using thread-local arena
        // Write segments to thread-local buffer (not shared)
        // On failure: mark group status as failed
    }
};
```

## Group Dependency Graph

### `GroupDependencyGraph`

```zig
pub const GroupDependencyGraph = struct {
    adjacency:   []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups:  u32,
    allocator:   std.mem.Allocator,

    pub fn build(
        groups: []const AnalogGroup,
        pin_bboxes: []const Rect,
    ) !GroupDependencyGraph

    pub fn deinit(self: *GroupDependencyGraph) void
};
```

Two groups conflict if:
1. They share a net
2. Their pin bounding boxes overlap (with 2× max_spacing margin)

### `colorGroups(graph, allocator) ![]u8`

Greedy graph coloring — assigns color (wavefront index) to each group. Returns color per group. Groups with same color are independent and can route in parallel.

## Parallel Dispatch

### `routeAllGroups(db, context, num_threads) !void`

```
1. If num_threads == 1 or groups.len < 4:
      route sequentially (no threading overhead)
2. Else:
      a. Build GroupDependencyGraph
      b. Color groups into wavefronts
      c. For each wavefront:
         - Submit all groups of this color as WorkItems
         - ThreadPool.submitAndWait()
         - Merge thread-local segments into global RouteArrays
         - Run PEX feedback loop (sequential)
         - Rebuild spatial index
```

### `mergeThreadLocalSegments(db, num_threads) !void`

For each thread `t` (0..num_threads-1), copy `db.thread_segments[t]` into `db.routes`. Used after each wavefront completes.

## Thread-Local State

```zig
pub const ThreadLocalState = struct {
    arena:           std.heap.ArenaAllocator,
    local_segments:  RouteArrays,
    thread_id:       u8,

    pub fn reset(self: *ThreadLocalState) void {
        _ = self.arena.reset(.retain_capacity)
        self.local_segments.len = 0
    }
};
```

Each thread gets its own `ThreadLocalState` with a scratch arena for A* open/closed sets and a local `RouteArrays` buffer. After the wavefront, the main thread merges local buffers sequentially — no locks needed during routing.

## Synchronization

| Point | Mechanism | Cost |
|-------|-----------|------|
| Wavefront barrier | `Thread.join()` on all workers | O(num_threads) |
| Segment merge | Sequential `@memcpy` | O(segments_per_wavefront) |
| Spatial grid rebuild | Sequential cell assignment | O(total_segments) |
| PEX extraction | Sequential | O(segments × neighbors) |

**Total mutexes in system: zero.** All synchronization is structural (barriers, atomic counters).

## Fallback: Sequential Mode

When `num_threads <= 1` or `groups.len < 4`, `routeAllGroups` routes groups sequentially using the main thread arena. This avoids thread pool overhead for small designs.

## Dependencies

- `src/router/pex_feedback.zig` — PEX feedback between wavefronts
- `src/router/detailed.zig` — `DetailedRouter` for per-group routing
- `src/core/route_arrays.zig` — `RouteArrays` for segment storage
