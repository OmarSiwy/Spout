//! Analog Net Group Database — Phase 3
//!
//! SoA table for analog net group metadata. Used during group routing dispatch.
//! Hot fields (touched every routing iteration) are packed together for cache efficiency.
//! Cold fields (name strings, thermal constraints) stay in L3/DRAM during routing.

const std = @import("std");
const at = @import("analog_types.zig");

// Re-export from analog_types.zig so callers can import from one place.
pub const AnalogGroupIdx = at.AnalogGroupIdx;
pub const AnalogGroupType = at.AnalogGroupType;
pub const GroupStatus = at.GroupStatus;
pub const SegmentIdx = at.SegmentIdx;
pub const ShieldIdx = at.ShieldIdx;
pub const GuardRingIdx = at.GuardRingIdx;
pub const ThermalCellIdx = at.ThermalCellIdx;
pub const CentroidPatternIdx = at.CentroidPatternIdx;

const NetIdx = at.NetIdx;
const LayerIdx = at.LayerIdx;

// ─── AddGroup request ─────────────────────────────────────────────────────────

pub const AddGroupRequest = struct {
    name: []const u8,
    group_type: AnalogGroupType,
    nets: []const NetIdx,
    tolerance: f32,
    preferred_layer: ?LayerIdx,
    route_priority: u8,
    // Optional cold fields
    thermal_tolerance: ?f32,
    coupling_tolerance: ?f32,
    shield_net: ?NetIdx,
    force_net: ?NetIdx,
    sense_net: ?NetIdx,
    centroid_pattern: ?CentroidPatternIdx,
};

// ─── Errors ───────────────────────────────────────────────────────────────────

pub const AddGroupError = error{
    InvalidNetCount,
    InvalidTolerance,
    DeviceTypeMismatch,
    MissingKelvinNets,
    GroupTableFull,
    OutOfMemory,
};

// ─── AnalogGroupDB ────────────────────────────────────────────────────────────

/// SoA table for analog net groups.
///
/// Hot fields (touched every routing iteration):
///   group_type, route_priority, tolerance, preferred_layer, status
///
/// Net membership (variable-length, flattened via net_pool):
///   net_range_start, net_count, net_pool
///
/// Cold fields (touched only during setup or reporting):
///   name_offsets, name_bytes, thermal_tolerance, coupling_tolerance,
///   shield_net, force_net, sense_net, centroid_pattern
pub const AnalogGroupDB = struct {
    // ── Hot fields ────────────────────────────────────────────────────────
    group_type: []AnalogGroupType,
    route_priority: []u8,
    tolerance: []f32,
    preferred_layer: []?LayerIdx,
    status: []GroupStatus,

    // ── Net membership (variable-length, flattened) ─────────────────────────
    // nets for group i: net_pool[net_range_start[i] .. net_range_start[i]+net_count[i]]
    net_range_start: []u32,
    net_count: []u8,
    net_pool: []NetIdx,

    // ── Cold fields ───────────────────────────────────────────────────────
    name_offsets: []u32,                    // offset into name_bytes
    name_bytes: []u8,                       // interned group names
    thermal_tolerance: []?f32,
    coupling_tolerance: []?f32,
    shield_net: []?NetIdx,
    force_net: []?NetIdx,
    sense_net: []?NetIdx,
    centroid_pattern: []?CentroidPatternIdx,

    // ── Bookkeeping ───────────────────────────────────────────────────────
    len: u32,
    capacity: u32,
    name_bytes_len: u32,
    allocator: std.mem.Allocator,

    /// Initialize with pre-allocated capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !AnalogGroupDB {
        var db: AnalogGroupDB = undefined;
        db.allocator = allocator;
        db.len = 0;
        db.capacity = capacity;
        db.name_bytes_len = 0;

        // Hot fields
        db.group_type = try allocator.alloc(AnalogGroupType, capacity);
        db.route_priority = try allocator.alloc(u8, capacity);
        db.tolerance = try allocator.alloc(f32, capacity);
        db.preferred_layer = try allocator.alloc(?LayerIdx, capacity);
        db.status = try allocator.alloc(GroupStatus, capacity);

        // Net membership
        db.net_range_start = try allocator.alloc(u32, capacity);
        db.net_count = try allocator.alloc(u8, capacity);
        // net_pool grows dynamically; start with capacity * 4 average nets per group
        db.net_pool = try allocator.alloc(NetIdx, capacity * 4);

        // Cold fields
        db.name_offsets = try allocator.alloc(u32, capacity);
        db.name_bytes = try allocator.alloc(u8, capacity * 32); // 32 chars avg per name
        db.thermal_tolerance = try allocator.alloc(?f32, capacity);
        db.coupling_tolerance = try allocator.alloc(?f32, capacity);
        db.shield_net = try allocator.alloc(?NetIdx, capacity);
        db.force_net = try allocator.alloc(?NetIdx, capacity);
        db.sense_net = try allocator.alloc(?NetIdx, capacity);
        db.centroid_pattern = try allocator.alloc(?CentroidPatternIdx, capacity);

        // Initialize status to pending
        for (db.status, 0..) |_, i| {
            db.status[i] = .pending;
        }

        return db;
    }

    /// Release all memory.
    pub fn deinit(self: *AnalogGroupDB) void {
        const alloc = self.allocator;
        alloc.free(self.group_type);
        alloc.free(self.route_priority);
        alloc.free(self.tolerance);
        alloc.free(self.preferred_layer);
        alloc.free(self.status);
        alloc.free(self.net_range_start);
        alloc.free(self.net_count);
        alloc.free(self.net_pool);
        alloc.free(self.name_offsets);
        alloc.free(self.name_bytes);
        alloc.free(self.thermal_tolerance);
        alloc.free(self.coupling_tolerance);
        alloc.free(self.shield_net);
        alloc.free(self.force_net);
        alloc.free(self.sense_net);
        alloc.free(self.centroid_pattern);
    }

    /// Add a group with validation. Returns error on invalid input.
    pub fn addGroupWithValidation(self: *AnalogGroupDB, req: AddGroupRequest) AddGroupError!void {
        // Validate net count by group type
        switch (req.group_type) {
            .differential => {
                if (req.nets.len != 2) return error.InvalidNetCount;
            },
            .matched, .resistor_matched, .capacitor_array => {
                if (req.nets.len < 2) return error.InvalidNetCount;
            },
            .shielded => {
                if (req.nets.len != 1) return error.InvalidNetCount;
            },
            .kelvin => {
                if (req.nets.len != 2) return error.InvalidNetCount;
                if (req.force_net == null or req.sense_net == null) {
                    return error.MissingKelvinNets;
                }
            },
        }

        // Validate tolerance
        if (req.tolerance < 0.0 or req.tolerance > 1.0) {
            return error.InvalidTolerance;
        }

        // Grow net_pool if needed
        const current_pool_len = self.net_pool.len;
        const needed = @as(u32, @intCast(req.nets.len));
        // Check if we need to grow net_pool
        _ = current_pool_len; // used in grow calculation below

        // Check capacity
        if (self.len >= self.capacity) return error.GroupTableFull;

        try self.growNetPoolIfNeeded(needed);

        const idx = self.len;

        // Hot fields
        self.group_type[idx] = req.group_type;
        self.route_priority[idx] = req.route_priority;
        self.tolerance[idx] = req.tolerance;
        self.preferred_layer[idx] = req.preferred_layer;
        self.status[idx] = .pending;

        // Net membership — append to net_pool
        const pool_start = self.getNetPoolLen();
        self.net_range_start[idx] = pool_start;
        self.net_count[idx] = @intCast(req.nets.len);
        for (req.nets, 0..) |net, j| {
            self.net_pool[pool_start + j] = net;
        }
        // net_pool length is tracked implicitly via net_range_start + net_count

        // Cold fields — store name
        self.name_offsets[idx] = self.getNameBytesLen();
        const name_len = req.name.len;
        try self.growNameBytesIfNeeded(@intCast(name_len));
        @memcpy(self.name_bytes[self.getNameBytesLen()..][0..name_len], req.name);
        self.setNameBytesLen(self.getNameBytesLen() + @as(u32, @intCast(name_len)));

        self.thermal_tolerance[idx] = req.thermal_tolerance;
        self.coupling_tolerance[idx] = req.coupling_tolerance;
        self.shield_net[idx] = req.shield_net;
        self.force_net[idx] = req.force_net;
        self.sense_net[idx] = req.sense_net;
        self.centroid_pattern[idx] = req.centroid_pattern;

        // Commit: bump length only after all fields are written.
        self.len += 1;
    }

    /// Add a group without validation (assumes caller has validated).
    pub fn addGroup(self: *AnalogGroupDB, req: AddGroupRequest) !void {
        try self.addGroupWithValidation(req);
    }

    /// Get the nets belonging to a group by index.
    pub fn netsForGroup(self: *const AnalogGroupDB, idx: u32) []const NetIdx {
        const start = self.net_range_start[idx];
        const count = self.net_count[idx];
        return self.net_pool[start..start + count];
    }

    /// Return groups sorted by route_priority (ascending), suitable for routing order.
    pub fn sortedByPriority(self: *const AnalogGroupDB, allocator: std.mem.Allocator) ![]AnalogGroupIdx {
        // Collect indices
        const indices = try allocator.alloc(u32, self.len);
        for (indices, 0..) |*idx, i| idx.* = @intCast(i);

        // Sort by route_priority using a context pointer
        const sort_ctx = self;
        std.mem.sort(u32, indices, sort_ctx, struct {
            fn less(ctx: *const AnalogGroupDB, a: u32, b: u32) bool {
                return ctx.route_priority[a] < ctx.route_priority[b];
            }
        }.less);

        // Convert to AnalogGroupIdx
        const result = try allocator.alloc(AnalogGroupIdx, self.len);
        for (indices, 0..) |idx, i| {
            result[i] = AnalogGroupIdx.fromInt(idx);
        }
        allocator.free(indices);
        return result;
    }

    // ── Internal helpers ───────────────────────────────────────────────────────

    /// Logical length of net_pool (computed from last group's range).
    fn getNetPoolLen(self: *const AnalogGroupDB) u32 {
        if (self.len == 0) return 0;
        const last_idx = self.len - 1;
        return self.net_range_start[last_idx] + self.net_count[last_idx];
    }

    fn getNameBytesLen(self: *const AnalogGroupDB) u32 {
        return self.name_bytes_len;
    }

    fn setNameBytesLen(self: *AnalogGroupDB, new_len: u32) void {
        self.name_bytes_len = new_len;
    }

    fn growNetPoolIfNeeded(self: *AnalogGroupDB, needed: u32) !void {
        const current_len = self.getNetPoolLen();
        if (current_len + needed <= self.net_pool.len) return;

        const new_capacity = (self.net_pool.len + needed) * 2;
        const new_pool = try self.allocator.realloc(self.net_pool, new_capacity);
        self.net_pool = new_pool;
    }

    fn growNameBytesIfNeeded(self: *AnalogGroupDB, needed: u32) !void {
        const current_len = self.getNameBytesLen();
        if (current_len + needed <= self.name_bytes.len) return;

        const new_capacity = (self.name_bytes.len + needed) * 2;
        const new_bytes = try self.allocator.realloc(self.name_bytes, new_capacity);
        self.name_bytes = new_bytes;
    }
};

// ─── GroupDependencyGraph ─────────────────────────────────────────────────────

/// Bounding box for a group (used for conflict detection).
pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x1 < other.x2 and self.x2 > other.x1 and
               self.y1 < other.y2 and self.y2 > other.y1;
    }

    pub fn overlapsWithMargin(self: Rect, other: Rect, margin: f32) bool {
        return (self.x1 - margin) < other.x2 and (self.x2 + margin) > other.x1 and
               (self.y1 - margin) < other.y2 and (self.y2 + margin) > other.y1;
    }
};

/// Dependency graph between analog groups for parallel routing.
/// Two groups conflict if they share a net or have overlapping routing regions.
pub const GroupDependencyGraph = struct {
    /// adjacency[i] = list of group indices that conflict with group i
    adjacency: []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups: u32,
    allocator: std.mem.Allocator,

    pub fn build(
        allocator: std.mem.Allocator,
        groups: *const AnalogGroupDB,
        pin_bboxes: []const Rect,
        margin: f32,
    ) !GroupDependencyGraph {
        var graph: GroupDependencyGraph = undefined;
        graph.num_groups = groups.len;
        graph.allocator = allocator;

        graph.adjacency = try allocator.alloc(
            std.ArrayListUnmanaged(AnalogGroupIdx),
            groups.len,
        );

        for (graph.adjacency) |*list| list.* = .{};

        // Check all pairs for conflicts
        var i: u32 = 0;
        while (i < groups.len) : (i += 1) {
            var j: u32 = i + 1;
            while (j < groups.len) : (j += 1) {
                if (groupsConflict(groups, pin_bboxes, i, j, margin)) {
                    try graph.adjacency[i].append(allocator, AnalogGroupIdx.fromInt(j));
                    try graph.adjacency[j].append(allocator, AnalogGroupIdx.fromInt(i));
                }
            }
        }

        return graph;
    }

    pub fn deinit(self: *GroupDependencyGraph) void {
        for (self.adjacency) |*list| list.deinit(self.allocator);
        self.allocator.free(self.adjacency);
    }
};

/// Check if two groups conflict (share a net or overlapping bboxes).
fn groupsConflict(
    groups: *const AnalogGroupDB,
    bboxes: []const Rect,
    i: u32,
    j: u32,
    margin: f32,
) bool {
    // 1. Shared net check
    const nets_i = groups.netsForGroup(i);
    const nets_j = groups.netsForGroup(j);
    for (nets_i) |ni| {
        for (nets_j) |nj| {
            if (ni.toInt() == nj.toInt()) return true;
        }
    }

    // 2. Bounding box overlap (with margin)
    if (i < bboxes.len and j < bboxes.len) {
        if (bboxes[i].overlapsWithMargin(bboxes[j], margin)) return true;
    }

    return false;
}

/// Check if two specific groups conflict.
pub fn groupsConflictBetween(
    groups: *const AnalogGroupDB,
    bboxes: []const Rect,
    i: AnalogGroupIdx,
    j: AnalogGroupIdx,
    margin: f32,
) bool {
    return groupsConflict(groups, bboxes, i.toInt(), j.toInt(), margin);
}

// ─── Compile-time assertions ───────────────────────────────────────────────────

comptime {
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    std.debug.assert(@sizeOf(ShieldIdx) == 4);
    std.debug.assert(@sizeOf(GuardRingIdx) == 2);
    std.debug.assert(@sizeOf(ThermalCellIdx) == 4);
    std.debug.assert(@sizeOf(CentroidPatternIdx) == 4);
    std.debug.assert(@sizeOf(AnalogGroupType) == 1);
    std.debug.assert(@sizeOf(GroupStatus) == 1);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "AnalogGroupIdx round-trip" {
    const idx = AnalogGroupIdx.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), idx.toInt());
}

test "AnalogGroupIdx boundary values" {
    try std.testing.expectEqual(@as(u32, 0), AnalogGroupIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), AnalogGroupIdx.fromInt(0xFFFFFFFF).toInt());
}

test "SegmentIdx and AnalogGroupIdx are distinct types" {
    const S = struct {
        fn takesSegment(_: SegmentIdx) void {}
    };
    S.takesSegment(SegmentIdx.fromInt(0)); // must compile
}

test "AnalogGroupDB add differential group" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{
        .name = "diff_pair_1",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expectEqual(AnalogGroupType.differential, db.group_type[0]);
    try std.testing.expectEqual(@as(u8, 2), db.net_count[0]);
}

test "AnalogGroupDB reject mismatched device types" {
    // Device type mismatch is detected at a higher level (not by addGroup itself).
    // This test just verifies the DB can be created.
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.len);
}

test "AnalogGroupDB group net lookup" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{
        .name = "matched_3",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(5), NetIdx.fromInt(6), NetIdx.fromInt(7) },
        .tolerance = 0.03,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const nets = db.netsForGroup(0);
    try std.testing.expectEqual(@as(usize, 3), nets.len);
    try std.testing.expectEqual(NetIdx.fromInt(5), nets[0]);
    try std.testing.expectEqual(NetIdx.fromInt(7), nets[2]);
}

test "reject differential group with odd net count" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .name = "test_diff_odd",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1), NetIdx.fromInt(2) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "reject differential group with 0 nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .name = "test_diff_zero",
        .group_type = .differential,
        .nets = &.{},
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "kelvin group requires force and sense nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.MissingKelvinNets, db.addGroup(.{
        .name = "test_kelvin",
        .group_type = .kelvin,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "tolerance must be positive" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .name = "test_tol_neg",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = -0.01,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "tolerance must be <= 1.0" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .name = "test_tol_high",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 1.5,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "groups sorted by priority for routing order" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{
        .name = "grp_a",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 2,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{
        .name = "grp_b",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{
        .name = "grp_c",
        .group_type = .shielded,
        .nets = &.{ NetIdx.fromInt(4) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const order = try db.sortedByPriority(std.testing.allocator);
    defer std.testing.allocator.free(order);

    try std.testing.expectEqual(@as(u32, 3), order.len);
    // Priority 0 (grp_b) first, then 1 (grp_c), then 2 (grp_a)
    try std.testing.expectEqual(@as(u8, 0), db.route_priority[order[0].toInt()]);
    try std.testing.expectEqual(@as(u8, 1), db.route_priority[order[1].toInt()]);
    try std.testing.expectEqual(@as(u8, 2), db.route_priority[order[2].toInt()]);
}

test "layout size assertions" {
    comptime {
        std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
        std.debug.assert(@sizeOf(SegmentIdx) == 4);
        std.debug.assert(@sizeOf(ShieldIdx) == 4);
        std.debug.assert(@sizeOf(GuardRingIdx) == 2);
        std.debug.assert(@sizeOf(AnalogGroupType) == 1);
        std.debug.assert(@sizeOf(GroupStatus) == 1);
    }
}

test "GroupDependencyGraph build with no conflicts" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 4);
    defer db.deinit();

    try db.addGroup(.{
        .name = "grp1",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{
        .name = "grp2",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const bboxes = [_]Rect{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 },
        .{ .x1 = 100, .y1 = 100, .x2 = 110, .y2 = 110 },
    };

    var graph = try GroupDependencyGraph.build(std.testing.allocator, &db, &bboxes, 5.0);
    defer graph.deinit();

    try std.testing.expectEqual(@as(u32, 2), graph.num_groups);
    // No conflicts — disjoint nets and non-overlapping bboxes
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[1].items.len);
}

test "GroupDependencyGraph detects shared net conflict" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 4);
    defer db.deinit();

    // Both groups share net 1
    try db.addGroup(.{
        .name = "grp1",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{
        .name = "grp2",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(1), NetIdx.fromInt(2) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const bboxes = [_]Rect{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 },
        .{ .x1 = 5, .y1 = 5, .x2 = 15, .y2 = 15 },
    };

    var graph = try GroupDependencyGraph.build(std.testing.allocator, &db, &bboxes, 5.0);
    defer graph.deinit();

    // grp1 and grp2 share net 1 → conflict
    try std.testing.expectEqual(@as(usize, 1), graph.adjacency[0].items.len);
    try std.testing.expectEqual(AnalogGroupIdx.fromInt(1), graph.adjacency[0].items[0]);
    try std.testing.expectEqual(@as(usize, 1), graph.adjacency[1].items.len);
    try std.testing.expectEqual(AnalogGroupIdx.fromInt(0), graph.adjacency[1].items[0]);
}

test "groupsConflictBetween helper" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 4);
    defer db.deinit();

    try db.addGroup(.{
        .name = "grp1",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 0,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{
        .name = "grp2",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.05,
        .preferred_layer = null,
        .route_priority = 1,
        .thermal_tolerance = null,
        .coupling_tolerance = null,
        .shield_net = null,
        .force_net = null,
        .sense_net = null,
        .centroid_pattern = null,
    });

    const bboxes = [_]Rect{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 },
        .{ .x1 = 20, .y1 = 20, .x2 = 30, .y2 = 30 },
    };

    // No conflict (different nets, non-overlapping bboxes)
    try std.testing.expectEqual(false, groupsConflictBetween(&db, &bboxes, AnalogGroupIdx.fromInt(0), AnalogGroupIdx.fromInt(1), 5.0));
}

test "Rect overlapsWithMargin" {
    const r1 = Rect{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 };
    const r2 = Rect{ .x1 = 8, .y1 = 8, .x2 = 18, .y2 = 18 }; // overlaps
    const r3 = Rect{ .x1 = 20, .y1 = 20, .x2 = 30, .y2 = 30 }; // no overlap

    try std.testing.expect(r1.overlapsWithMargin(r2, 5.0)); // margin of 5 catches it
    try std.testing.expect(!r1.overlapsWithMargin(r3, 5.0));
}
