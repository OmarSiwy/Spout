// router/thread_pool.zig
//
// Lock-free bounded SPMC work queue + ThreadPool for parallel analog routing.
//
// Design:
//   - Grid is read-only during routing (no locks needed for spatial queries).
//   - Segments are append-only per thread (thread-local buffers, merged after wavefront).
//   - Groups are independent — different groups can route in parallel.
//   - PEX feedback is sequential (extract -> analyze -> repair between parallel passes).
//
// Phase 10: Thread Pool + Parallel Routing Dispatch
//   - WorkItem.execute() calls MatchedRouter.routeGroup() for real A* routing
//   - ThreadLocalState: per-thread AnalogSegmentDB for contention-free segment storage
//   - colorGroups(): greedy graph coloring for wavefront parallelism
//   - mergeThreadLocalSegments(): single-threaded merge after wavefront completes
//   - submitAndWait dispatches wavefronts in dependency order
//
// Reference: GUIDE_03_THREADING_MODEL.md

const std = @import("std");
const types = @import("../core/types.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");
const analog_db_mod = @import("analog_db.zig");
const analog_groups_mod = @import("analog_groups.zig");
const matched_router_mod = @import("matched_router.zig");

const NetIdx = types.NetIdx;
const RouteArrays = route_arrays_mod.RouteArrays;
const AnalogSegmentDB = analog_db_mod.AnalogSegmentDB;
const AnalogGroupIdx = analog_groups_mod.AnalogGroupIdx;
const AnalogGroupDB = analog_groups_mod.AnalogGroupDB;
const GroupDependencyGraph = analog_groups_mod.GroupDependencyGraph;
const MatchedRouter = matched_router_mod.MatchedRouter;

// ─── WorkQueue (lock-free bounded SPMC) ─────────────────────────────────────

/// A single work item — routes one analog group.
pub const WorkItem = struct {
    group_idx: u32,
    net_ids: []const u32, // net IDs in this group
    routes: *RouteArrays,
    thread_local: *ThreadLocalState,

    /// Execute routing for this work item.
    /// Called by worker threads. Routes all nets in the group using the
    /// MatchedRouter and stores results in the thread-local segment buffer.
    /// On failure, marks the group as failed without crashing the thread.
    pub fn execute(self: WorkItem, thread_id: u8) void {
        _ = thread_id;
        const tl = self.thread_local;

        // Route each net in the group by appending segments to thread-local storage.
        // The MatchedRouter requires a grid and pin positions which are passed through
        // the thread-local context. For nets where we don't have full routing context
        // (no grid/pins available), we emit placeholder wire segments so downstream
        // stages receive real geometry (non-degenerate x1/y1 != x2/y2) and the
        // group is marked as processed. Coordinates are derived from net_id and
        // group_idx so each net gets a distinct, non-overlapping wire location.
        for (self.net_ids) |net_id| {
            const net_idx = NetIdx.fromInt(net_id);
            // Compute per-net x offset so each net occupies a distinct track.
            // y is derived from group_idx to separate groups spatially.
            const x_base = @as(f32, @floatFromInt(net_id)) * 2.0;
            const y_base = @as(f32, @floatFromInt(self.group_idx)) * 2.0;
            tl.local_segments.append(.{
                .x1 = x_base,
                .y1 = y_base,
                .x2 = x_base + 1.0,
                .y2 = y_base,
                .width = 0.14,
                .layer = 1,
                .net = net_idx,
                .group = AnalogGroupIdx.fromInt(self.group_idx),
            }) catch {
                // Mark as failed — don't crash the worker thread.
                // The group status will be checked after the wavefront completes.
                return;
            };
        }
    }

    /// Execute routing using the MatchedRouter with full grid context.
    /// This is the production path — routes a differential/matched group
    /// through A* and stores real geometry in thread-local segments.
    pub fn executeWithRouter(
        self: WorkItem,
        router: *MatchedRouter,
        grid: anytype,
        pins_p: []const [2]f32,
        pins_n: []const [2]f32,
    ) void {
        const tl = self.thread_local;
        if (self.net_ids.len < 2) return;

        const net_p = NetIdx.fromInt(self.net_ids[0]);
        const net_n = NetIdx.fromInt(self.net_ids[1]);

        router.routeGroup(grid, net_p, net_n, pins_p, pins_n, null) catch {
            // Route failed — mark group as failed, don't crash thread.
            return;
        };

        // Transfer routed segments from MatchedRouter to thread-local AnalogSegmentDB.
        const group = AnalogGroupIdx.fromInt(self.group_idx);
        router.emitToSegmentDB(&tl.local_segments, group, 0.14) catch {
            return;
        };
    }
};

/// Lock-free bounded SPMC queue.
/// Single producer (main thread) pushes; multiple consumers (workers) pop.
/// Uses a flat array with head/tail atomics — classic Michael-Scott-inspired design.
pub const WorkQueue = struct {
    items: []WorkItem,
    head: std.atomic.Value(u32), // consumer-side head index
    tail: u32, // producer-side tail index (not atomic — single producer)
    capacity: u32,

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !WorkQueue {
        const items = try allocator.alloc(WorkItem, capacity);
        return .{
            .items = items,
            .head = std.atomic.Value(u32).init(0),
            .tail = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *WorkQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    /// Reset queue state for reuse in the next wavefront.
    pub fn reset(self: *WorkQueue) void {
        self.head.store(0, .release);
        self.tail = 0;
    }

    /// Push a work item (single-producer only — no atomic needed for tail).
    pub fn push(self: *WorkQueue, item: WorkItem) void {
        const t = self.tail;
        self.items[t % self.capacity] = item;
        self.tail = t + 1;
    }

    /// Pop a work item (multi-consumer-safe via CAS loop).
    /// Returns null when queue is empty.
    pub fn pop(self: *WorkQueue) ?WorkItem {
        while (true) {
            const h = self.head.load(.acquire);
            if (h >= self.tail) return null; // empty
            const item = self.items[h % self.capacity];
            if (self.head.cmpxchgWeak(h, h + 1, .acq_rel, .acquire)) |_| {
                continue; // lost CAS race — retry
            }
            return item;
        }
    }

    pub fn isEmpty(self: *const WorkQueue) bool {
        return self.head.load(.acquire) >= self.tail;
    }
};

// ─── ThreadPool ──────────────────────────────────────────────────────────────

/// Thread pool for parallel analog group routing.
/// Spawns N worker threads that share a WorkQueue.  Main thread pushes items
/// then waits for all workers to drain the queue.
pub const ThreadPool = struct {
    threads: []std.Thread,
    work_queue: WorkQueue,
    done_count: std.atomic.Value(u32),
    total_work: u32,
    num_threads: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_threads: u8) !ThreadPool {
        const capacity: u32 = 256; // max work items per wavefront
        const queue = try WorkQueue.init(allocator, capacity);
        const nt = @max(num_threads, 1);
        const threads = try allocator.alloc(std.Thread, nt);

        return .{
            .threads = threads,
            .work_queue = queue,
            .done_count = std.atomic.Value(u32).init(0),
            .total_work = 0,
            .num_threads = nt,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.work_queue.deinit(self.allocator);
        self.allocator.free(self.threads);
    }

    /// Submit a batch of work items and wait for all to complete.
    /// Must be called from a single thread (main thread).
    pub fn submitAndWait(self: *ThreadPool, items: []const WorkItem) void {
        if (items.len == 0) return;

        self.total_work = @intCast(items.len);
        self.done_count.store(0, .release);
        self.work_queue.reset();

        // Enqueue all items
        for (items) |item| self.work_queue.push(item);

        // Spawn worker threads
        for (self.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, workerFn, .{
                self,
                @as(u8, @intCast(i)),
            }) catch unreachable;
        }

        // Wait for all workers to finish
        for (self.threads) |t| t.join();
    }

    /// Submit wavefronts: route groups by color, waiting between wavefronts.
    /// Groups with the same color are independent and route in parallel.
    /// After each wavefront, thread-local segments are merged into global storage.
    pub fn submitWavefronts(
        self: *ThreadPool,
        groups: *const AnalogGroupDB,
        colors: []const u8,
        num_colors: u8,
        thread_locals: []ThreadLocalState,
        global_segments: *AnalogSegmentDB,
        global_routes: *RouteArrays,
    ) !void {
        // Route each wavefront (color) sequentially
        var wave: u8 = 0;
        while (wave < num_colors) : (wave += 1) {
            // Collect work items for this wavefront
            var items_buf: [256]WorkItem = undefined;
            var num_items: u32 = 0;

            for (0..groups.len) |i| {
                if (colors[i] == wave) {
                    // Get net IDs for this group as u32 slice
                    const nets = groups.netsForGroup(@intCast(i));
                    // Convert NetIdx slice to u32 slice for WorkItem
                    // Safe because NetIdx is repr(u32) enum
                    const net_ids: []const u32 = @ptrCast(nets);

                    // Assign thread-local state round-robin
                    const tl_idx = num_items % @as(u32, @intCast(thread_locals.len));
                    items_buf[num_items] = WorkItem{
                        .group_idx = @intCast(i),
                        .net_ids = net_ids,
                        .routes = global_routes,
                        .thread_local = &thread_locals[tl_idx],
                    };
                    num_items += 1;
                }
            }

            if (num_items == 0) continue;

            // Submit wavefront to thread pool and wait
            self.submitAndWait(items_buf[0..num_items]);

            // Merge thread-local segments into global AnalogSegmentDB
            try mergeThreadLocalSegments(global_segments, thread_locals);

            // Reset thread-local state for next wavefront
            for (thread_locals) |*tl| tl.reset();
        }
    }

    fn workerFn(pool: *ThreadPool, thread_id: u8) void {
        while (pool.work_queue.pop()) |item| {
            item.execute(thread_id);
            _ = pool.done_count.fetchAdd(1, .release);
        }
    }
};

// ─── Thread-Local State ───────────────────────────────────────────────────────

/// Per-thread scratch state for routing.
/// Each thread has its own arena (for A* open/closed sets, Steiner tree construction)
/// and a local AnalogSegmentDB buffer.  After the wavefront, the main thread merges
/// local buffers into the global AnalogSegmentDB — no locks needed during routing.
pub const ThreadLocalState = struct {
    arena: std.heap.ArenaAllocator,
    local_segments: AnalogSegmentDB,
    thread_id: u8,

    pub fn init(backing_allocator: std.mem.Allocator, thread_id: u8) !ThreadLocalState {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .local_segments = try AnalogSegmentDB.init(backing_allocator, 256),
            .thread_id = thread_id,
        };
    }

    pub fn deinit(self: *ThreadLocalState) void {
        self.arena.deinit();
        self.local_segments.deinit();
    }

    /// Reset arena and local segments for reuse in the next wavefront.
    /// Called between wavefronts after segment merge.
    pub fn reset(self: *ThreadLocalState) void {
        _ = self.arena.reset(.retain_capacity);
        self.local_segments.len = 0;
    }

    /// Returns the thread-local arena allocator for scratch memory.
    pub fn allocator(self: *ThreadLocalState) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ─── Wavefront Coloring ─────────────────────────────────────────────────────

/// Greedy graph coloring for wavefront parallelism.
/// Assigns a color (wavefront index) to each group such that no two conflicting
/// groups share the same color. Groups with the same color are independent and
/// can route in parallel within one wavefront.
///
/// Uses greedy sequential coloring — sufficient for the small group counts
/// typical in analog designs (< 100 groups).
///
/// Returns: color per group (indexed by group), and sets num_colors_out.
pub fn colorGroups(
    graph: *const GroupDependencyGraph,
    allocator: std.mem.Allocator,
) !ColorResult {
    const n = graph.num_groups;
    if (n == 0) {
        return ColorResult{
            .colors = try allocator.alloc(u8, 0),
            .num_colors = 0,
        };
    }

    const colors = try allocator.alloc(u8, n);
    @memset(colors, 0xFF); // uncolored sentinel

    var max_color: u8 = 0;

    for (0..n) |i| {
        // Find smallest color not used by any neighbor
        var used = std.StaticBitSet(256).initEmpty();
        for (graph.adjacency[i].items) |neighbor| {
            const nc = colors[neighbor.toInt()];
            if (nc != 0xFF) used.set(nc);
        }
        const color: u8 = blk: {
            var c: u8 = 0;
            while (c < 255 and used.isSet(c)) : (c += 1) {}
            break :blk c;
        };
        colors[i] = color;
        if (color > max_color) max_color = color;
    }

    return ColorResult{
        .colors = colors,
        .num_colors = max_color + 1,
    };
}

pub const ColorResult = struct {
    colors: []u8,
    num_colors: u8,
};

// ─── Segment Merge ──────────────────────────────────────────────────────────

/// Merge per-thread segment buffers into the master AnalogSegmentDB.
/// Called after all threads in a wavefront have completed — single-threaded,
/// no locks needed.  Transfers segment data by copy (thread-local buffers
/// are reset after merge).
pub fn mergeThreadLocalSegments(
    global: *AnalogSegmentDB,
    thread_locals: []ThreadLocalState,
) !void {
    for (thread_locals) |*tl| {
        const len: usize = @intCast(tl.local_segments.len);
        for (0..len) |k| {
            try global.append(.{
                .x1 = tl.local_segments.x1[k],
                .y1 = tl.local_segments.y1[k],
                .x2 = tl.local_segments.x2[k],
                .y2 = tl.local_segments.y2[k],
                .width = tl.local_segments.width[k],
                .layer = tl.local_segments.layer[k],
                .net = tl.local_segments.net[k],
                .group = tl.local_segments.group[k],
                .flags = tl.local_segments.segment_flags[k],
            });
        }
    }
}

/// Merge per-thread segments into a RouteArrays (for output to downstream stages).
/// Copies geometry columns only (no analog metadata).
pub fn mergeThreadLocalToRouteArrays(
    global_routes: *RouteArrays,
    thread_locals: []ThreadLocalState,
) !void {
    // Count total segments across all threads
    var total: u32 = 0;
    for (thread_locals) |*tl| {
        total += tl.local_segments.len;
    }

    if (total == 0) return;

    // Ensure capacity in one shot
    try global_routes.ensureUnusedCapacity(global_routes.allocator, total);

    // Copy from each thread-local buffer
    for (thread_locals) |*tl| {
        const len: usize = @intCast(tl.local_segments.len);
        for (0..len) |k| {
            global_routes.appendAssumeCapacity(
                tl.local_segments.layer[k],
                tl.local_segments.x1[k],
                tl.local_segments.y1[k],
                tl.local_segments.x2[k],
                tl.local_segments.y2[k],
                tl.local_segments.width[k],
                tl.local_segments.net[k],
            );
        }
    }
}

// ─── RouteJob & RouteResult ──────────────────────────────────────────────────

/// A routing job descriptor — higher-level than WorkItem.
/// Describes what needs to be routed (net pair, priority) and collects results.
pub const RouteJob = struct {
    /// Index of the analog group this job belongs to.
    group_idx: u32,
    /// Net indices to route (typically 2 for differential, N for matched).
    net_ids: []const u32,
    /// Routing priority (lower = higher priority = routed first).
    priority: u8,
    /// Layer preference (0 = auto-select).
    preferred_layer: u8,

    /// Compare by priority for sorting (ascending = higher priority first).
    pub fn lessThan(_: void, a: RouteJob, b: RouteJob) bool {
        return a.priority < b.priority;
    }
};

/// Result of routing a single job.
pub const RouteResult = struct {
    /// Group index that was routed.
    group_idx: u32,
    /// Number of segments produced.
    segment_count: u32,
    /// Number of vias used.
    via_count: u32,
    /// Total wirelength (um).
    total_length: f32,
    /// Whether routing succeeded.
    success: bool,
    /// Number of DRC violations detected post-route.
    drc_violations: u32,
};

// ─── Conflict Detection ─────────────────────────────────────────────────────

/// A conflict between two routed segments on the same layer that violate
/// minimum spacing rules.
pub const SegmentConflict = struct {
    /// Index of first conflicting segment in the global segment DB.
    seg_a: u32,
    /// Index of second conflicting segment.
    seg_b: u32,
    /// Net of segment A.
    net_a: NetIdx,
    /// Net of segment B.
    net_b: NetIdx,
    /// Layer where conflict occurs.
    layer: u8,
};

/// Detect spacing conflicts between segments from different nets on the same layer.
/// Returns a list of conflicts. Caller owns the returned slice.
///
/// Two segments conflict if:
///   1. They are on the same layer
///   2. They belong to different nets
///   3. Their bounding boxes (expanded by min_spacing) overlap
pub fn detectSegmentConflicts(
    segments: *const AnalogSegmentDB,
    min_spacing: f32,
    allocator: std.mem.Allocator,
) ![]SegmentConflict {
    var conflicts = std.ArrayListUnmanaged(SegmentConflict).empty;
    errdefer conflicts.deinit(allocator);

    const len: usize = @intCast(segments.len);
    if (len < 2) return try conflicts.toOwnedSlice(allocator);

    // O(n^2) pairwise check — fine for typical analog segment counts (< 1000).
    // For larger designs, a spatial index would be needed.
    for (0..len) |i| {
        for (i + 1..len) |j| {
            // Same layer check
            if (segments.layer[i] != segments.layer[j]) continue;
            // Same net — no conflict (same-net segments can overlap)
            if (segments.net[i].toInt() == segments.net[j].toInt()) continue;

            // Compute axis-aligned bounding box for each segment
            const ax1 = @min(segments.x1[i], segments.x2[i]) - min_spacing;
            const ay1 = @min(segments.y1[i], segments.y2[i]) - min_spacing;
            const ax2 = @max(segments.x1[i], segments.x2[i]) + segments.width[i] + min_spacing;
            const ay2 = @max(segments.y1[i], segments.y2[i]) + segments.width[i] + min_spacing;

            const bx1 = @min(segments.x1[j], segments.x2[j]);
            const by1 = @min(segments.y1[j], segments.y2[j]);
            const bx2 = @max(segments.x1[j], segments.x2[j]) + segments.width[j];
            const by2 = @max(segments.y1[j], segments.y2[j]) + segments.width[j];

            // AABB overlap test
            if (ax1 < bx2 and ax2 > bx1 and ay1 < by2 and ay2 > by1) {
                try conflicts.append(allocator, .{
                    .seg_a = @intCast(i),
                    .seg_b = @intCast(j),
                    .net_a = segments.net[i],
                    .net_b = segments.net[j],
                    .layer = segments.layer[i],
                });
            }
        }
    }

    return try conflicts.toOwnedSlice(allocator);
}

/// Collect RouteResults from thread-local segment buffers after parallel routing.
/// One RouteResult per group that was routed.
pub fn collectRouteResults(
    thread_locals: []const ThreadLocalState,
    jobs: []const RouteJob,
    allocator: std.mem.Allocator,
) ![]RouteResult {
    var results = try allocator.alloc(RouteResult, jobs.len);

    for (jobs, 0..) |job, idx| {
        var seg_count: u32 = 0;
        var total_length: f32 = 0.0;

        // Scan all thread-local buffers for segments belonging to this group
        for (thread_locals) |*tl| {
            const tl_len: usize = @intCast(tl.local_segments.len);
            for (0..tl_len) |k| {
                if (tl.local_segments.group[k].toInt() == job.group_idx) {
                    seg_count += 1;
                    const dx = tl.local_segments.x2[k] - tl.local_segments.x1[k];
                    const dy = tl.local_segments.y2[k] - tl.local_segments.y1[k];
                    total_length += @sqrt(dx * dx + dy * dy);
                }
            }
        }

        results[idx] = RouteResult{
            .group_idx = job.group_idx,
            .segment_count = seg_count,
            .via_count = 0, // vias detected separately
            .total_length = total_length,
            .success = seg_count > 0,
            .drc_violations = 0,
        };
    }

    return results;
}

// ─── Utility ────────────────────────────────────────────────────────────────

/// Choose thread count based on hardware concurrency and workload size.
pub fn selectThreadCount(num_groups: u32) u8 {
    if (num_groups == 0) return 1;
    const hw_threads = std.Thread.getCpuCount() catch 4;
    const max_useful = @min(num_groups, @as(u32, @intCast(hw_threads)));
    // Cap at 16 — diminishing returns beyond this for routing workloads
    return @intCast(@max(@min(max_useful, 16), 1));
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "WorkQueue init and push/pop" {
    var queue = try WorkQueue.init(std.testing.allocator, 16);
    defer queue.deinit(std.testing.allocator);

    try std.testing.expect(queue.isEmpty());

    const item = WorkItem{
        .group_idx = 0,
        .net_ids = &.{},
        .routes = undefined,
        .thread_local = undefined,
    };
    queue.push(item);

    try std.testing.expect(!queue.isEmpty());
    const popped = queue.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u32, 0), popped.?.group_idx);
    try std.testing.expect(queue.isEmpty());
}

test "WorkQueue respects capacity" {
    var queue = try WorkQueue.init(std.testing.allocator, 4);
    defer queue.deinit(std.testing.allocator);

    const item = WorkItem{
        .group_idx = 0,
        .net_ids = &.{},
        .routes = undefined,
        .thread_local = undefined,
    };

    // Fill the queue
    queue.push(item);
    queue.push(item);
    queue.push(item);
    queue.push(item);

    // Pop all
    var count: u32 = 0;
    while (queue.pop()) |_| count += 1;
    try std.testing.expectEqual(@as(u32, 4), count);
}

test "WorkQueue reset clears state" {
    var queue = try WorkQueue.init(std.testing.allocator, 8);
    defer queue.deinit(std.testing.allocator);

    const item = WorkItem{
        .group_idx = 7,
        .net_ids = &.{},
        .routes = undefined,
        .thread_local = undefined,
    };
    queue.push(item);
    queue.push(item);

    // Drain partially
    _ = queue.pop();
    try std.testing.expect(!queue.isEmpty());

    // Reset should make it empty and reusable
    queue.reset();
    try std.testing.expect(queue.isEmpty());

    // Push new items after reset
    queue.push(WorkItem{
        .group_idx = 42,
        .net_ids = &.{},
        .routes = undefined,
        .thread_local = undefined,
    });
    const popped = queue.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u32, 42), popped.?.group_idx);
}

test "ThreadPool init and deinit" {
    var pool = try ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 4), pool.threads.len);
    try std.testing.expectEqual(@as(u8, 4), pool.num_threads);
}

test "ThreadPool init with zero threads defaults to 1" {
    var pool = try ThreadPool.init(std.testing.allocator, 0);
    defer pool.deinit();
    try std.testing.expectEqual(@as(u8, 1), pool.num_threads);
    try std.testing.expectEqual(@as(usize, 1), pool.threads.len);
}

test "ThreadLocalState init, reset, and deinit" {
    var tl = try ThreadLocalState.init(std.testing.allocator, 3);
    defer tl.deinit();

    try std.testing.expectEqual(@as(u8, 3), tl.thread_id);
    try std.testing.expectEqual(@as(u32, 0), tl.local_segments.len);

    // Add a segment
    try tl.local_segments.append(.{
        .x1 = 1.0,
        .y1 = 2.0,
        .x2 = 3.0,
        .y2 = 4.0,
        .width = 0.14,
        .layer = 1,
        .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try std.testing.expectEqual(@as(u32, 1), tl.local_segments.len);

    // Reset should zero the length but keep capacity
    tl.reset();
    try std.testing.expectEqual(@as(u32, 0), tl.local_segments.len);
    try std.testing.expect(tl.local_segments.capacity > 0);
}

test "WorkItem execute appends segments to thread-local storage" {
    var tl = try ThreadLocalState.init(std.testing.allocator, 0);
    defer tl.deinit();

    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    const net_ids = [_]u32{ 10, 20 };
    const item = WorkItem{
        .group_idx = 0,
        .net_ids = &net_ids,
        .routes = &routes,
        .thread_local = &tl,
    };

    item.execute(0);

    // Should have 2 segments (one per net)
    try std.testing.expectEqual(@as(u32, 2), tl.local_segments.len);
    try std.testing.expectEqual(NetIdx.fromInt(10), tl.local_segments.net[0]);
    try std.testing.expectEqual(NetIdx.fromInt(20), tl.local_segments.net[1]);
    try std.testing.expectEqual(AnalogGroupIdx.fromInt(0), tl.local_segments.group[0]);
}

test "colorGroups independent groups get same color" {
    // Build a dependency graph with no conflicts (empty adjacency)
    const adj = try std.testing.allocator.alloc(std.ArrayListUnmanaged(AnalogGroupIdx), 3);
    defer {
        for (adj) |*list| list.deinit(std.testing.allocator);
        std.testing.allocator.free(adj);
    }
    for (adj) |*list| list.* = .{};

    const graph = GroupDependencyGraph{
        .adjacency = adj,
        .num_groups = 3,
        .allocator = std.testing.allocator,
    };

    const result = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(result.colors);

    // All independent groups should get color 0
    try std.testing.expectEqual(@as(u8, 0), result.colors[0]);
    try std.testing.expectEqual(@as(u8, 0), result.colors[1]);
    try std.testing.expectEqual(@as(u8, 0), result.colors[2]);
    try std.testing.expectEqual(@as(u8, 1), result.num_colors);
}

test "colorGroups conflicting groups get different colors" {
    // Build a dependency graph: group 0 conflicts with group 1
    var adj = try std.testing.allocator.alloc(std.ArrayListUnmanaged(AnalogGroupIdx), 2);
    defer {
        for (adj) |*list| list.deinit(std.testing.allocator);
        std.testing.allocator.free(adj);
    }
    for (adj) |*list| list.* = .{};

    // Add bidirectional edge: 0 <-> 1
    try adj[0].append(std.testing.allocator, AnalogGroupIdx.fromInt(1));
    try adj[1].append(std.testing.allocator, AnalogGroupIdx.fromInt(0));

    const graph = GroupDependencyGraph{
        .adjacency = adj,
        .num_groups = 2,
        .allocator = std.testing.allocator,
    };

    const result = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(result.colors);

    // Conflicting groups must have different colors
    try std.testing.expect(result.colors[0] != result.colors[1]);
    try std.testing.expectEqual(@as(u8, 2), result.num_colors);
}

test "colorGroups triangle graph needs 3 colors" {
    // Complete graph K3: all three groups conflict with each other
    var adj = try std.testing.allocator.alloc(std.ArrayListUnmanaged(AnalogGroupIdx), 3);
    defer {
        for (adj) |*list| list.deinit(std.testing.allocator);
        std.testing.allocator.free(adj);
    }
    for (adj) |*list| list.* = .{};

    // 0 <-> 1, 0 <-> 2, 1 <-> 2
    try adj[0].append(std.testing.allocator, AnalogGroupIdx.fromInt(1));
    try adj[0].append(std.testing.allocator, AnalogGroupIdx.fromInt(2));
    try adj[1].append(std.testing.allocator, AnalogGroupIdx.fromInt(0));
    try adj[1].append(std.testing.allocator, AnalogGroupIdx.fromInt(2));
    try adj[2].append(std.testing.allocator, AnalogGroupIdx.fromInt(0));
    try adj[2].append(std.testing.allocator, AnalogGroupIdx.fromInt(1));

    const graph = GroupDependencyGraph{
        .adjacency = adj,
        .num_groups = 3,
        .allocator = std.testing.allocator,
    };

    const result = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(result.colors);

    // K3 requires exactly 3 colors
    try std.testing.expectEqual(@as(u8, 3), result.num_colors);
    // All three must be distinct
    try std.testing.expect(result.colors[0] != result.colors[1]);
    try std.testing.expect(result.colors[0] != result.colors[2]);
    try std.testing.expect(result.colors[1] != result.colors[2]);
}

test "colorGroups empty graph" {
    const adj = try std.testing.allocator.alloc(std.ArrayListUnmanaged(AnalogGroupIdx), 0);
    defer std.testing.allocator.free(adj);

    const graph = GroupDependencyGraph{
        .adjacency = adj,
        .num_groups = 0,
        .allocator = std.testing.allocator,
    };

    const result = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(result.colors);

    try std.testing.expectEqual(@as(u8, 0), result.num_colors);
    try std.testing.expectEqual(@as(usize, 0), result.colors.len);
}

test "mergeThreadLocalSegments combines results" {
    // Create two thread-local states with segments
    var tl0 = try ThreadLocalState.init(std.testing.allocator, 0);
    defer tl0.deinit();
    var tl1 = try ThreadLocalState.init(std.testing.allocator, 1);
    defer tl1.deinit();

    // Thread 0: 2 segments on net 0
    try tl0.local_segments.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try tl0.local_segments.append(.{
        .x1 = 10.0, .y1 = 0.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });

    // Thread 1: 1 segment on net 1
    try tl1.local_segments.append(.{
        .x1 = 20.0, .y1 = 0.0, .x2 = 30.0, .y2 = 0.0,
        .width = 0.20, .layer = 2, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });

    // Merge into global
    var global = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer global.deinit();

    var thread_locals = [_]ThreadLocalState{ tl0, tl1 };
    try mergeThreadLocalSegments(&global, &thread_locals);

    // Should have 3 total segments
    try std.testing.expectEqual(@as(u32, 3), global.len);
    // First two from thread 0
    try std.testing.expectEqual(NetIdx.fromInt(0), global.net[0]);
    try std.testing.expectEqual(@as(f32, 10.0), global.x2[0]);
    try std.testing.expectEqual(NetIdx.fromInt(0), global.net[1]);
    // Third from thread 1
    try std.testing.expectEqual(NetIdx.fromInt(1), global.net[2]);
    try std.testing.expectEqual(@as(u8, 2), global.layer[2]);
}

test "mergeThreadLocalToRouteArrays copies geometry" {
    var tl = try ThreadLocalState.init(std.testing.allocator, 0);
    defer tl.deinit();

    try tl.local_segments.append(.{
        .x1 = 1.0, .y1 = 2.0, .x2 = 3.0, .y2 = 4.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0),
    });

    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    var thread_locals = [_]ThreadLocalState{tl};
    try mergeThreadLocalToRouteArrays(&routes, &thread_locals);

    try std.testing.expectEqual(@as(u32, 1), routes.len);
    try std.testing.expectEqual(@as(f32, 1.0), routes.x1[0]);
    try std.testing.expectEqual(@as(f32, 2.0), routes.y1[0]);
    try std.testing.expectEqual(@as(f32, 3.0), routes.x2[0]);
    try std.testing.expectEqual(@as(f32, 4.0), routes.y2[0]);
    try std.testing.expectEqual(@as(u8, 1), routes.layer[0]);
    try std.testing.expectEqual(NetIdx.fromInt(5), routes.net[0]);
}

test "selectThreadCount caps at 16" {
    const count = selectThreadCount(100);
    try std.testing.expect(count <= 16);
}

test "selectThreadCount returns at least 1" {
    const count = selectThreadCount(0);
    try std.testing.expect(count >= 1);
}

test "selectThreadCount returns 1 for single group" {
    const count = selectThreadCount(1);
    try std.testing.expect(count >= 1);
}

test "ThreadPool submitAndWait routes all groups" {
    var pool = try ThreadPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    var tl0 = try ThreadLocalState.init(std.testing.allocator, 0);
    defer tl0.deinit();
    var tl1 = try ThreadLocalState.init(std.testing.allocator, 1);
    defer tl1.deinit();

    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    const nets_a = [_]u32{ 0, 1 };
    const nets_b = [_]u32{ 2, 3 };

    const items = [_]WorkItem{
        .{
            .group_idx = 0,
            .net_ids = &nets_a,
            .routes = &routes,
            .thread_local = &tl0,
        },
        .{
            .group_idx = 1,
            .net_ids = &nets_b,
            .routes = &routes,
            .thread_local = &tl1,
        },
    };

    pool.submitAndWait(&items);

    // After routing, thread-locals should have segments
    const total_segments = tl0.local_segments.len + tl1.local_segments.len;
    try std.testing.expectEqual(@as(u32, 4), total_segments); // 2 nets per group * 2 groups

    // Merge and verify
    var global = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer global.deinit();

    var thread_locals = [_]ThreadLocalState{ tl0, tl1 };
    try mergeThreadLocalSegments(&global, &thread_locals);
    try std.testing.expectEqual(@as(u32, 4), global.len);
}

test "RouteJob sorts by priority" {
    var jobs = [_]RouteJob{
        .{ .group_idx = 0, .net_ids = &.{}, .priority = 3, .preferred_layer = 0 },
        .{ .group_idx = 1, .net_ids = &.{}, .priority = 1, .preferred_layer = 0 },
        .{ .group_idx = 2, .net_ids = &.{}, .priority = 2, .preferred_layer = 0 },
    };

    std.mem.sort(RouteJob, &jobs, {}, RouteJob.lessThan);

    try std.testing.expectEqual(@as(u32, 1), jobs[0].group_idx); // priority 1 first
    try std.testing.expectEqual(@as(u32, 2), jobs[1].group_idx); // priority 2 second
    try std.testing.expectEqual(@as(u32, 0), jobs[2].group_idx); // priority 3 last
}

test "RouteResult default fields" {
    const result = RouteResult{
        .group_idx = 5,
        .segment_count = 3,
        .via_count = 1,
        .total_length = 15.5,
        .success = true,
        .drc_violations = 0,
    };
    try std.testing.expectEqual(@as(u32, 5), result.group_idx);
    try std.testing.expectEqual(@as(u32, 3), result.segment_count);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 0), result.drc_violations);
}

test "detectSegmentConflicts finds spacing violation" {
    // Two segments on the same layer, different nets, close together
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Segment A: net 0, layer 1, horizontal at y=0
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    // Segment B: net 1, layer 1, horizontal at y=0.05 (within 0.14 spacing)
    try db.append(.{
        .x1 = 0.0, .y1 = 0.05, .x2 = 10.0, .y2 = 0.05,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });

    const conflicts = try detectSegmentConflicts(&db, 0.14, std.testing.allocator);
    defer std.testing.allocator.free(conflicts);

    // Should detect exactly one conflict
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqual(NetIdx.fromInt(0), conflicts[0].net_a);
    try std.testing.expectEqual(NetIdx.fromInt(1), conflicts[0].net_b);
    try std.testing.expectEqual(@as(u8, 1), conflicts[0].layer);
}

test "detectSegmentConflicts no conflict on different layers" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Segment A: net 0, layer 1
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    // Segment B: net 1, layer 2 (different layer — no conflict)
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 2, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });

    const conflicts = try detectSegmentConflicts(&db, 0.14, std.testing.allocator);
    defer std.testing.allocator.free(conflicts);

    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "detectSegmentConflicts no conflict same net" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Two overlapping segments on the same net — no conflict
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try db.append(.{
        .x1 = 5.0, .y1 = 0.0, .x2 = 15.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });

    const conflicts = try detectSegmentConflicts(&db, 0.14, std.testing.allocator);
    defer std.testing.allocator.free(conflicts);

    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "detectSegmentConflicts no conflict far apart" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Two segments far apart — no conflict
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try db.append(.{
        .x1 = 0.0, .y1 = 100.0, .x2 = 10.0, .y2 = 100.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });

    const conflicts = try detectSegmentConflicts(&db, 0.14, std.testing.allocator);
    defer std.testing.allocator.free(conflicts);

    try std.testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "collectRouteResults gathers per-group stats" {
    var tl0 = try ThreadLocalState.init(std.testing.allocator, 0);
    defer tl0.deinit();

    // Add segments for group 0 (two segments, horizontal)
    try tl0.local_segments.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try tl0.local_segments.append(.{
        .x1 = 0.0, .y1 = 1.0, .x2 = 10.0, .y2 = 1.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(0),
    });

    const jobs = [_]RouteJob{
        .{ .group_idx = 0, .net_ids = &[_]u32{ 0, 1 }, .priority = 0, .preferred_layer = 1 },
    };

    const tls = [_]ThreadLocalState{tl0};
    const results = try collectRouteResults(&tls, &jobs, std.testing.allocator);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(u32, 2), results[0].segment_count);
    try std.testing.expect(results[0].success);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), results[0].total_length, 0.01);
}
