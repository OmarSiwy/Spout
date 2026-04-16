//! Analog router database — SoA tables for segments, groups, and match reports.

const std = @import("std");
const at = @import("analog_types.zig");
const layout_if = @import("../core/layout_if.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");

const Rect = at.Rect;
const AnalogGroupIdx = at.AnalogGroupIdx;
const SegmentIdx = at.SegmentIdx;
const NetIdx = at.NetIdx;
const GroupStatus = at.GroupStatus;
const AnalogGroupType = at.AnalogGroupType;
const RoutingResult = at.RoutingResult;
const PdkConfig = layout_if.PdkConfig;
const RouteArrays = route_arrays_mod.RouteArrays;

// ── SegmentFlags ─────────────────────────────────────────────────────────────

pub const SegmentFlags = packed struct(u8) {
    is_shield: bool = false,
    is_dummy_via: bool = false,
    is_jog: bool = false,
    _padding: u5 = 0,
};

// ── AnalogSegmentDB ─────────────────────────────────────────────────────────

/// SoA segment storage for analog-routed wires.
/// Geometry columns match RouteArrays for zero-copy output.
pub const AnalogSegmentDB = struct {
    // ── Geometry (hot) ──
    x1: []f32,
    y1: []f32,
    x2: []f32,
    y2: []f32,
    width: []f32,
    layer: []u8,
    net: []NetIdx,

    // ── Analog metadata (warm) ──
    group: []AnalogGroupIdx,
    segment_flags: []SegmentFlags,

    // ── PEX cache (cold) ──
    resistance: []f32,
    capacitance: []f32,
    coupling_cap: []f32,

    // ── Bookkeeping ──
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    pub const AppendParams = struct {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        width: f32,
        layer: u8,
        net: NetIdx,
        group: AnalogGroupIdx,
        flags: SegmentFlags = .{},
    };

    pub fn init(allocator: std.mem.Allocator, cap: u32) !AnalogSegmentDB {
        const n: usize = @intCast(cap);
        return .{
            .x1 = try allocator.alloc(f32, n),
            .y1 = try allocator.alloc(f32, n),
            .x2 = try allocator.alloc(f32, n),
            .y2 = try allocator.alloc(f32, n),
            .width = try allocator.alloc(f32, n),
            .layer = try allocator.alloc(u8, n),
            .net = try allocator.alloc(NetIdx, n),
            .group = try allocator.alloc(AnalogGroupIdx, n),
            .segment_flags = try allocator.alloc(SegmentFlags, n),
            .resistance = try allocator.alloc(f32, n),
            .capacitance = try allocator.alloc(f32, n),
            .coupling_cap = try allocator.alloc(f32, n),
            .len = 0,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalogSegmentDB) void {
        if (self.capacity == 0) return;
        self.allocator.free(self.x1);
        self.allocator.free(self.y1);
        self.allocator.free(self.x2);
        self.allocator.free(self.y2);
        self.allocator.free(self.width);
        self.allocator.free(self.layer);
        self.allocator.free(self.net);
        self.allocator.free(self.group);
        self.allocator.free(self.segment_flags);
        self.allocator.free(self.resistance);
        self.allocator.free(self.capacitance);
        self.allocator.free(self.coupling_cap);
    }

    pub fn append(self: *AnalogSegmentDB, p: AppendParams) !void {
        if (self.len >= self.capacity) {
            try self.grow();
        }
        const i: usize = @intCast(self.len);
        self.x1[i] = p.x1;
        self.y1[i] = p.y1;
        self.x2[i] = p.x2;
        self.y2[i] = p.y2;
        self.width[i] = p.width;
        self.layer[i] = p.layer;
        self.net[i] = p.net;
        self.group[i] = p.group;
        self.segment_flags[i] = p.flags;
        self.resistance[i] = 0.0;
        self.capacitance[i] = 0.0;
        self.coupling_cap[i] = 0.0;
        self.len += 1;
    }

    fn grow(self: *AnalogSegmentDB) !void {
        const new_cap = if (self.capacity == 0) @as(u32, 256) else self.capacity * 2;
        const n: usize = @intCast(new_cap);
        self.x1 = try self.allocator.realloc(self.x1, n);
        self.y1 = try self.allocator.realloc(self.y1, n);
        self.x2 = try self.allocator.realloc(self.x2, n);
        self.y2 = try self.allocator.realloc(self.y2, n);
        self.width = try self.allocator.realloc(self.width, n);
        self.layer = try self.allocator.realloc(self.layer, n);
        self.net = try self.allocator.realloc(self.net, n);
        self.group = try self.allocator.realloc(self.group, n);
        self.segment_flags = try self.allocator.realloc(self.segment_flags, n);
        self.resistance = try self.allocator.realloc(self.resistance, n);
        self.capacitance = try self.allocator.realloc(self.capacitance, n);
        self.coupling_cap = try self.allocator.realloc(self.coupling_cap, n);
        self.capacity = new_cap;
    }

    /// Copy geometry + flags to RouteArrays.
    pub fn toRouteArrays(self: *const AnalogSegmentDB, out: *RouteArrays) !void {
        const n: usize = @intCast(self.len);
        if (n == 0) return;
        const needed = out.len + @as(u32, @intCast(n));
        if (needed > out.capacity) try out.growTo(needed);
        const base: usize = @intCast(out.len);
        @memcpy(out.layer[base..][0..n], self.layer[0..n]);
        @memcpy(out.x1[base..][0..n], self.x1[0..n]);
        @memcpy(out.y1[base..][0..n], self.y1[0..n]);
        @memcpy(out.x2[base..][0..n], self.x2[0..n]);
        @memcpy(out.y2[base..][0..n], self.y2[0..n]);
        @memcpy(out.width[base..][0..n], self.width[0..n]);
        @memcpy(out.net[base..][0..n], self.net[0..n]);
        for (0..n) |i| {
            out.flags[base + i] = .{
                .is_shield = self.segment_flags[i].is_shield,
                .is_dummy_via = self.segment_flags[i].is_dummy_via,
                .is_jog = self.segment_flags[i].is_jog,
            };
        }
        out.len = needed;
    }

    /// Remove all segments belonging to a group (for rip-up).
    pub fn removeGroup(self: *AnalogSegmentDB, gid: AnalogGroupIdx) void {
        var write: u32 = 0;
        const len: usize = @intCast(self.len);
        for (0..len) |read| {
            if (self.group[read].toInt() != gid.toInt()) {
                if (write != read) {
                    self.x1[write] = self.x1[read];
                    self.y1[write] = self.y1[read];
                    self.x2[write] = self.x2[read];
                    self.y2[write] = self.y2[read];
                    self.width[write] = self.width[read];
                    self.layer[write] = self.layer[read];
                    self.net[write] = self.net[read];
                    self.group[write] = self.group[read];
                    self.segment_flags[write] = self.segment_flags[read];
                    self.resistance[write] = self.resistance[read];
                    self.capacitance[write] = self.capacitance[read];
                    self.coupling_cap[write] = self.coupling_cap[read];
                }
                write += 1;
            }
        }
        self.len = write;
    }

    /// Total wire length of segments belonging to a net.
    pub fn netLength(self: *const AnalogSegmentDB, net: NetIdx) f32 {
        var total: f32 = 0.0;
        const len: usize = @intCast(self.len);
        for (0..len) |i| {
            if (self.net[i].toInt() == net.toInt()) {
                total += @abs(self.x2[i] - self.x1[i]) + @abs(self.y2[i] - self.y1[i]);
            }
        }
        return total;
    }

    /// Count vias for a net (zero-length segments = vias).
    pub fn viaCount(self: *const AnalogSegmentDB, net: NetIdx) u32 {
        var count: u32 = 0;
        const len: usize = @intCast(self.len);
        for (0..len) |i| {
            if (self.net[i].toInt() == net.toInt()) {
                if (self.x1[i] == self.x2[i] and self.y1[i] == self.y2[i]) count += 1;
            }
        }
        return count;
    }
};

// ── MatchReportDB ────────────────────────────────────────────────────────────

/// SoA table for PEX match analysis results.
pub const MatchReportDB = struct {
    group: []AnalogGroupIdx,
    passes: []bool,
    r_ratio: []f32,
    c_ratio: []f32,
    length_ratio: []f32,
    via_delta: []i16,
    coupling_delta: []f32,
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cap: u32) !MatchReportDB {
        const n: usize = @intCast(cap);
        return .{
            .group = try allocator.alloc(AnalogGroupIdx, n),
            .passes = try allocator.alloc(bool, n),
            .r_ratio = try allocator.alloc(f32, n),
            .c_ratio = try allocator.alloc(f32, n),
            .length_ratio = try allocator.alloc(f32, n),
            .via_delta = try allocator.alloc(i16, n),
            .coupling_delta = try allocator.alloc(f32, n),
            .len = 0,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatchReportDB) void {
        if (self.capacity == 0) return;
        self.allocator.free(self.group);
        self.allocator.free(self.passes);
        self.allocator.free(self.r_ratio);
        self.allocator.free(self.c_ratio);
        self.allocator.free(self.length_ratio);
        self.allocator.free(self.via_delta);
        self.allocator.free(self.coupling_delta);
    }

    pub fn ensureCapacity(self: *MatchReportDB, new_cap: u32) !void {
        if (new_cap <= self.capacity) return;
        const n: usize = @intCast(new_cap);
        self.group = try self.allocator.realloc(self.group, n);
        self.passes = try self.allocator.realloc(self.passes, n);
        self.r_ratio = try self.allocator.realloc(self.r_ratio, n);
        self.c_ratio = try self.allocator.realloc(self.c_ratio, n);
        self.length_ratio = try self.allocator.realloc(self.length_ratio, n);
        self.via_delta = try self.allocator.realloc(self.via_delta, n);
        self.coupling_delta = try self.allocator.realloc(self.coupling_delta, n);
        self.capacity = new_cap;
    }

    pub fn append(self: *MatchReportDB, p: ReportParams) !void {
        if (self.len >= self.capacity) {
            try self.ensureCapacity(self.capacity * 2);
        }
        const i: usize = @intCast(self.len);
        self.group[i] = p.group;
        self.passes[i] = p.passes;
        self.r_ratio[i] = p.r_ratio;
        self.c_ratio[i] = p.c_ratio;
        self.length_ratio[i] = p.length_ratio;
        self.via_delta[i] = p.via_delta;
        self.coupling_delta[i] = p.coupling_delta;
        self.len += 1;
    }

    /// Remove all match reports for a given group (called on rip-up).
    pub fn clearGroupReports(self: *MatchReportDB, gid: AnalogGroupIdx) void {
        var write: u32 = 0;
        const len: usize = @intCast(self.len);
        for (0..len) |read| {
            if (self.group[read].toInt() != gid.toInt()) {
                if (write != read) {
                    self.group[write] = self.group[read];
                    self.passes[write] = self.passes[read];
                    self.r_ratio[write] = self.r_ratio[read];
                    self.c_ratio[write] = self.c_ratio[read];
                    self.length_ratio[write] = self.length_ratio[read];
                    self.via_delta[write] = self.via_delta[read];
                    self.coupling_delta[write] = self.coupling_delta[read];
                }
                write += 1;
            }
        }
        self.len = write;
    }

    pub const ReportParams = struct {
        group: AnalogGroupIdx,
        passes: bool,
        r_ratio: f32,
        c_ratio: f32,
        length_ratio: f32,
        via_delta: i16,
        coupling_delta: f32,
    };
};

// ── AnalogRouteDB ────────────────────────────────────────────────────────────

/// The master database. Owns all analog routing state.
pub const AnalogRouteDB = struct {
    segments: AnalogSegmentDB,
    match_reports: MatchReportDB,
    pdk: *const PdkConfig,
    die_bbox: Rect,
    pass_arena: std.heap.ArenaAllocator,
    thread_arenas: []std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const PdkConfig,
        die_bbox: Rect,
        num_threads: u8,
    ) !AnalogRouteDB {
        const nt: usize = @intCast(@max(num_threads, 1));
        const thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, nt);
        for (thread_arenas) |*ta| {
            ta.* = std.heap.ArenaAllocator.init(allocator);
        }
        return .{
            .segments = try AnalogSegmentDB.init(allocator, 4096),
            .match_reports = try MatchReportDB.init(allocator, 64),
            .pdk = pdk,
            .die_bbox = die_bbox,
            .pass_arena = std.heap.ArenaAllocator.init(allocator),
            .thread_arenas = thread_arenas,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalogRouteDB) void {
        for (self.thread_arenas) |*ta| ta.deinit();
        self.allocator.free(self.thread_arenas);
        self.pass_arena.deinit();
        self.match_reports.deinit();
        self.segments.deinit();
    }

    /// Reset scratch between PEX iterations.
    pub fn resetPass(self: *AnalogRouteDB) void {
        _ = self.pass_arena.reset(.retain_capacity);
        for (self.thread_arenas) |*ta| {
            _ = ta.reset(.retain_capacity);
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "AnalogSegmentDB init and deinit" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 64);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.len);
    try std.testing.expectEqual(@as(u32, 64), db.capacity);
}

test "AnalogSegmentDB append segment" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
        .group = AnalogGroupIdx.fromInt(0),
        .flags = .{ .is_shield = false, .is_dummy_via = false, .is_jog = false },
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expectEqual(@as(f32, 10.0), db.x2[0]);
    try std.testing.expectEqual(@as(u8, 1), db.layer[0]);
}

test "AnalogSegmentDB append auto-grows" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 2);
    defer db.deinit();

    for (0..5) |i| {
        try db.append(.{
            .x1 = @floatFromInt(i), .y1 = 0.0,
            .x2 = @floatFromInt(i + 1), .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
            .group = AnalogGroupIdx.fromInt(0),
        });
    }
    try std.testing.expectEqual(@as(u32, 5), db.len);
    try std.testing.expect(db.capacity >= 5);
}

test "AnalogSegmentDB toRouteArrays" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
        .group = AnalogGroupIdx.fromInt(0),
    });

    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    try db.toRouteArrays(&ra);
    try std.testing.expectEqual(@as(u32, 1), ra.len);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x2[0]);
}

test "AnalogSegmentDB toRouteArrays lossless" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Add 10 segments with distinct geometry
    for (0..10) |i| {
        try db.append(.{
            .x1 = @as(f32, @floatFromInt(i)) * 2.0,
            .y1 = @as(f32, @floatFromInt(i)) * 3.0,
            .x2 = @as(f32, @floatFromInt(i)) * 2.0 + 5.0,
            .y2 = @as(f32, @floatFromInt(i)) * 3.0 + 1.0,
            .width = 0.14 + @as(f32, @floatFromInt(i)) * 0.01,
            .layer = @as(u8, @intCast(i % 5 + 1)),
            .net = NetIdx.fromInt(@intCast(i)),
            .group = AnalogGroupIdx.fromInt(@intCast(i % 3)),
        });
    }

    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    try db.toRouteArrays(&ra);
    try std.testing.expectEqual(@as(u32, 10), ra.len);

    // Verify all columns match
    for (0..10) |i| {
        try std.testing.expectEqual(db.x1[i], ra.x1[i]);
        try std.testing.expectEqual(db.y1[i], ra.y1[i]);
        try std.testing.expectEqual(db.x2[i], ra.x2[i]);
        try std.testing.expectEqual(db.y2[i], ra.y2[i]);
        try std.testing.expectEqual(db.width[i], ra.width[i]);
        try std.testing.expectEqual(db.layer[i], ra.layer[i]);
        try std.testing.expectEqual(db.net[i], ra.net[i]);
    }
}

test "AnalogSegmentDB removeGroup" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 100);
    defer db.deinit();

    // Add 50 segments for group A, 50 for group B
    for (0..50) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
            .group = AnalogGroupIdx.fromInt(0) });
    }
    for (50..100) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
            .group = AnalogGroupIdx.fromInt(1) });
    }

    db.removeGroup(AnalogGroupIdx.fromInt(0));
    try std.testing.expectEqual(@as(u32, 50), db.len);
    // Verify group 1 segments remain (all have group=1, net=1)
    try std.testing.expectEqual(NetIdx.fromInt(1), db.net[0]);
}

test "AnalogSegmentDB netLength" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Two segments on net 5: lengths 10 + 5 = 15 total
    try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0) });
    try db.append(.{ .x1 = 10.0, .y1 = 0.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0) });

    const len = db.netLength(NetIdx.fromInt(5));
    try std.testing.expectEqual(@as(f32, 15.0), len);
}

test "AnalogSegmentDB viaCount" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // 3 zero-length segments (vias) on net 3, plus 2 normal segments
    for (0..3) |_| {
        try db.append(.{ .x1 = 5.0, .y1 = 5.0, .x2 = 5.0, .y2 = 5.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
            .group = AnalogGroupIdx.fromInt(0) });
    }
    for (0..2) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
            .group = AnalogGroupIdx.fromInt(0) });
    }

    try std.testing.expectEqual(@as(u32, 3), db.viaCount(NetIdx.fromInt(3)));
}

test "MatchReportDB init and deinit" {
    var db = try MatchReportDB.init(std.testing.allocator, 64);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.len);
    try std.testing.expectEqual(@as(u32, 64), db.capacity);
}

test "MatchReportDB append and read" {
    var db = try MatchReportDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.append(.{
        .group = AnalogGroupIdx.fromInt(3),
        .passes = true,
        .r_ratio = 0.02,
        .c_ratio = 0.03,
        .length_ratio = 0.01,
        .via_delta = 0,
        .coupling_delta = 0.5,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expect(db.passes[0]);
    try std.testing.expectEqual(@as(f32, 0.02), db.r_ratio[0]);
}

test "AnalogRouteDB init and deinit" {
    const pdk = PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 4);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.segments.len);
    try std.testing.expectEqual(@as(usize, 4), db.thread_arenas.len);
}

test "AnalogRouteDB resetPass" {
    const pdk = PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 2);
    defer db.deinit();

    // Add some segments
    try db.segments.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });

    // resetPass should retain capacity
    db.resetPass();
    try std.testing.expectEqual(@as(u32, 1), db.segments.len); // data retained
}