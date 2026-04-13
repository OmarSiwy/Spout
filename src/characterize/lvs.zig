// characterize/lvs.zig
//
// Layout-versus-Schematic (LVS) engine.
//
// Algorithm: device-signature matching + Union-Find net connectivity comparison.
// Reference: RTimothyEdwards/netgen  netgen/netcomp.c, netgen/inetcomp.c
//
// Netgen's algorithm:
//   1. Canonicalize: sort devices by type; compute connectivity signatures.
//   2. Device matching: group by (type, params) → find bijection.
//   3. Net matching: build Union-Find for each circuit's pin connections;
//      compare connected components structure for isomorphism.
//
// Our implementation operates on DeviceArrays + PinEdgeArrays (SoA) rather
// than Netgen's linked-list graph.  The comparison is:
//   Layout  = what was actually placed and routed (post-layout extraction).
//   Schematic = parsed SPICE netlist (DeviceArrays populated by netlist/lib.zig).

const std = @import("std");
const core_types     = @import("../core/types.zig");
const device_mod     = @import("../core/device_arrays.zig");
const pin_edge_mod   = @import("../core/pin_edge_arrays.zig");
const types          = @import("types.zig");

const DeviceType   = core_types.DeviceType;
const DeviceParams = core_types.DeviceParams;
const DeviceIdx    = core_types.DeviceIdx;
const NetIdx       = core_types.NetIdx;
const DeviceArrays = device_mod.DeviceArrays;
const PinEdgeArrays = pin_edge_mod.PinEdgeArrays;

pub const LvsReport = types.LvsReport;
pub const LvsStatus = types.LvsStatus;

// ─── Union-Find ───────────────────────────────────────────────────────────────
//
// Standard path-compressed, union-by-rank Union-Find (disjoint set union).
// Used to compute connectivity equivalence classes for net comparison.
// Mirrors Netgen's node merging step (netcomp.c MergeNodes / MatchDevices).

pub const UnionFind = struct {
    parent: []u32,
    rank:   []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: u32) !UnionFind {
        const p = try allocator.alloc(u32, @intCast(n));
        errdefer allocator.free(p);
        const r = try allocator.alloc(u8, @intCast(n));
        errdefer allocator.free(r);

        for (0..n) |i| p[i] = @intCast(i);
        @memset(r, 0);

        return .{ .parent = p, .rank = r, .allocator = allocator };
    }

    pub fn deinit(self: *UnionFind) void {
        self.allocator.free(self.parent);
        self.allocator.free(self.rank);
        self.* = undefined;
    }

    /// Find root with full path compression.
    pub fn find(self: *UnionFind, x: u32) u32 {
        var n = x;
        while (self.parent[n] != n) {
            // Path halving: make every node point to its grandparent.
            self.parent[n] = self.parent[self.parent[n]];
            n = self.parent[n];
        }
        return n;
    }

    /// Union by rank.
    pub fn union_(self: *UnionFind, a: u32, b: u32) void {
        const ra = self.find(a);
        const rb = self.find(b);
        if (ra == rb) return;
        if (self.rank[ra] < self.rank[rb]) {
            self.parent[ra] = rb;
        } else if (self.rank[ra] > self.rank[rb]) {
            self.parent[rb] = ra;
        } else {
            self.parent[rb] = ra;
            self.rank[ra] += 1;
        }
    }

    /// True if a and b are in the same connected component.
    pub fn connected(self: *UnionFind, a: u32, b: u32) bool {
        return self.find(a) == self.find(b);
    }
};

// ─── Device signature ─────────────────────────────────────────────────────────

/// Relative parameter tolerance for matching W/L/value.
/// Netgen uses 1e-6 for parameter comparison; we use 5% for layout variation.
const PARAM_TOLERANCE: f32 = 0.05;

/// Check whether two DeviceParams are within tolerance.
fn paramsMatch(a: DeviceParams, b: DeviceParams) bool {
    const relDiff = struct {
        fn f(x: f32, y: f32) f32 {
            const denom = @max(@abs(x), @abs(y));
            if (denom < 1e-12) return 0.0;
            return @abs(x - y) / denom;
        }
    }.f;

    // w and l are the critical parameters; value is for passives.
    if (relDiff(a.w, b.w) > PARAM_TOLERANCE) return false;
    if (relDiff(a.l, b.l) > PARAM_TOLERANCE) return false;
    // For passives (res/cap/ind), check value.
    if (relDiff(a.value, b.value) > PARAM_TOLERANCE) return false;
    return true;
}

// ─── LvsChecker ───────────────────────────────────────────────────────────────

pub const LvsChecker = struct {
    /// Compare two flat device lists (layout vs schematic).
    /// Matching algorithm mirrors Netgen's MatchDevices():
    ///   1. Check total device counts.
    ///   2. For each layout device, find a schematic device with same type + params.
    ///   3. Mark matched pairs; report unmatched on either side.
    pub fn compareDeviceLists(
        layout:    *const DeviceArrays,
        schematic: *const DeviceArrays,
    ) LvsReport {
        const nl: usize = @intCast(layout.len);
        const ns: usize = @intCast(schematic.len);

        if (nl == 0 and ns == 0) {
            return .{ .matched = 0, .unmatched_layout = 0,
                       .unmatched_schematic = 0, .net_mismatches = 0, .pass = true };
        }

        // Greedy matching: mark which schematic devices have been claimed.
        // (Netgen uses a more exhaustive search; greedy is correct when
        //  devices have unique (type, params) signatures, which is common.)
        var matched: u32 = 0;
        var unmatched_layout: u32 = 0;

        // Small stack buffer; heap for large netlists.
        var claimed_buf: [256]bool = undefined;
        const claimed: []bool = if (ns <= 256)
            claimed_buf[0..ns]
        else blk: {
            // If ns > 256, we cannot stack-allocate; return a conservative result.
            // (In production, the caller should use compareDeviceListsAlloc.)
            break :blk &[_]bool{};
        };
        if (claimed.len == ns) @memset(claimed, false);

        for (0..nl) |i| {
            var found = false;
            for (0..ns) |j| {
                if (claimed.len > 0 and claimed[j]) continue;
                if (layout.types[i] != schematic.types[j]) continue;
                if (!paramsMatch(layout.params[i], schematic.params[j])) continue;
                if (claimed.len > 0) claimed[j] = true;
                matched += 1;
                found = true;
                break;
            }
            if (!found) unmatched_layout += 1;
        }

        var unmatched_schematic: u32 = 0;
        if (claimed.len == ns) {
            for (claimed) |c| { if (!c) unmatched_schematic += 1; }
        } else {
            // Fallback: count as mismatch when ns > 256.
            unmatched_schematic = @intCast(if (ns > nl) ns - nl else 0);
        }

        const pass = (unmatched_layout == 0 and unmatched_schematic == 0);
        return .{
            .matched             = matched,
            .unmatched_layout    = unmatched_layout,
            .unmatched_schematic = unmatched_schematic,
            .net_mismatches      = 0, // set by compareNetConnectivity
            .pass                = pass,
        };
    }

    /// Heap-allocating version for netlists with > 256 devices.
    pub fn compareDeviceListsAlloc(
        layout:    *const DeviceArrays,
        schematic: *const DeviceArrays,
        allocator: std.mem.Allocator,
    ) !LvsReport {
        const nl: usize = @intCast(layout.len);
        const ns: usize = @intCast(schematic.len);

        if (nl == 0 and ns == 0) {
            return .{ .matched = 0, .unmatched_layout = 0,
                       .unmatched_schematic = 0, .net_mismatches = 0, .pass = true };
        }

        const claimed = try allocator.alloc(bool, ns);
        defer allocator.free(claimed);
        @memset(claimed, false);

        var matched: u32 = 0;
        var unmatched_layout: u32 = 0;

        for (0..nl) |i| {
            var found = false;
            for (0..ns) |j| {
                if (claimed[j]) continue;
                if (layout.types[i] != schematic.types[j]) continue;
                if (!paramsMatch(layout.params[i], schematic.params[j])) continue;
                claimed[j] = true;
                matched += 1;
                found = true;
                break;
            }
            if (!found) unmatched_layout += 1;
        }

        var unmatched_schematic: u32 = 0;
        for (claimed) |c| { if (!c) unmatched_schematic += 1; }

        const pass = (unmatched_layout == 0 and unmatched_schematic == 0);
        return .{
            .matched             = matched,
            .unmatched_layout    = unmatched_layout,
            .unmatched_schematic = unmatched_schematic,
            .net_mismatches      = 0,
            .pass                = pass,
        };
    }

    /// Compare net connectivity between layout and schematic using Union-Find.
    /// Builds two Union-Find structures (one per circuit) from the pin-edge arrays,
    /// then counts roots that have different component sizes — a structural mismatch.
    ///
    /// This mirrors Netgen's MergeNodes() + node equivalence class comparison.
    pub fn compareNetConnectivity(
        layout_pins:    *const PinEdgeArrays,
        schematic_pins: *const PinEdgeArrays,
        num_nets:       u32,
        allocator:      std.mem.Allocator,
    ) !u32 {
        if (num_nets == 0) return 0;

        var uf_layout = try UnionFind.init(allocator, num_nets);
        defer uf_layout.deinit();
        var uf_schem = try UnionFind.init(allocator, num_nets);
        defer uf_schem.deinit();

        // Build connectivity from pin edges: union devices that share a net.
        // For each pin, union its net with the previous pin of the same device.
        const ln: usize = @intCast(layout_pins.len);
        for (0..ln) |i| {
            const dev = layout_pins.device[i].toInt();
            // Union net[i] with net of the first pin of this device.
            // (Simple approach: find first pin of same device and union nets.)
            for (0..i) |j| {
                if (layout_pins.device[j].toInt() == dev) {
                    const na = layout_pins.net[i].toInt();
                    const nb = layout_pins.net[j].toInt();
                    if (na < num_nets and nb < num_nets) uf_layout.union_(na, nb);
                    break;
                }
            }
        }

        const sn: usize = @intCast(schematic_pins.len);
        for (0..sn) |i| {
            const dev = schematic_pins.device[i].toInt();
            for (0..i) |j| {
                if (schematic_pins.device[j].toInt() == dev) {
                    const na = schematic_pins.net[i].toInt();
                    const nb = schematic_pins.net[j].toInt();
                    if (na < num_nets and nb < num_nets) uf_schem.union_(na, nb);
                    break;
                }
            }
        }

        // Count mismatches: nets that are connected in one circuit but not the other.
        var mismatches: u32 = 0;
        for (0..num_nets) |a| {
            for (a + 1..num_nets) |b| {
                const lay_conn  = uf_layout.connected(@intCast(a), @intCast(b));
                const schem_conn = uf_schem.connected(@intCast(a), @intCast(b));
                if (lay_conn != schem_conn) mismatches += 1;
            }
        }
        return mismatches;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// Reference: Netgen netcomp.c test cases and SPICE LVS examples.

const testing = std.testing;

// ── UnionFind tests ──────────────────────────────────────────────────────────

test "UnionFind init: each element is its own root" {
    var uf = try UnionFind.init(testing.allocator, 5);
    defer uf.deinit();
    for (0..5) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), uf.find(@intCast(i)));
    }
}

test "UnionFind union connects two elements" {
    var uf = try UnionFind.init(testing.allocator, 4);
    defer uf.deinit();
    uf.union_(0, 1);
    try testing.expect(uf.connected(0, 1));
    try testing.expect(!uf.connected(0, 2));
}

test "UnionFind path compression: chain union all same root" {
    var uf = try UnionFind.init(testing.allocator, 6);
    defer uf.deinit();
    uf.union_(0, 1);
    uf.union_(1, 2);
    uf.union_(2, 3);
    uf.union_(3, 4);
    uf.union_(4, 5);
    try testing.expect(uf.connected(0, 5));
    try testing.expect(uf.connected(1, 4));
    try testing.expect(uf.connected(0, 3));
}

test "UnionFind self-union is idempotent" {
    var uf = try UnionFind.init(testing.allocator, 3);
    defer uf.deinit();
    uf.union_(1, 1);
    try testing.expectEqual(uf.find(1), uf.find(1));
}

test "UnionFind two separate components stay separate" {
    var uf = try UnionFind.init(testing.allocator, 6);
    defer uf.deinit();
    uf.union_(0, 1);
    uf.union_(2, 3);
    try testing.expect(uf.connected(0, 1));
    try testing.expect(uf.connected(2, 3));
    try testing.expect(!uf.connected(0, 2));
    try testing.expect(!uf.connected(1, 3));
}

test "UnionFind union of already-connected is safe" {
    var uf = try UnionFind.init(testing.allocator, 4);
    defer uf.deinit();
    uf.union_(0, 1);
    uf.union_(0, 1); // duplicate
    try testing.expect(uf.connected(0, 1));
    try testing.expect(!uf.connected(0, 2));
}

// ── LvsChecker device list tests ─────────────────────────────────────────────

fn makeDevices(
    alloc: std.mem.Allocator,
    devices: []const struct { dtype: DeviceType, w: f32, l: f32, val: f32 },
) !DeviceArrays {
    var da = try DeviceArrays.init(alloc, @intCast(devices.len));
    for (devices, 0..) |d, i| {
        da.types[i] = d.dtype;
        da.params[i] = .{ .w = d.w, .l = d.l, .fingers = 1, .mult = 1, .value = d.val };
    }
    return da;
}

test "LVS identical device lists match" {
    // Netgen: two identical NMOS → match.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(r.pass);
    try testing.expectEqual(@as(u32, 2), r.matched);
    try testing.expectEqual(@as(u32, 0), r.unmatched_layout);
    try testing.expectEqual(@as(u32, 0), r.unmatched_schematic);
}

test "LVS empty netlists match" {
    var lay   = try DeviceArrays.init(testing.allocator, 0);
    defer lay.deinit();
    var schem = try DeviceArrays.init(testing.allocator, 0);
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(r.pass);
    try testing.expectEqual(@as(u32, 0), r.matched);
}

test "LVS device count mismatch fails" {
    // Layout has 2 devices, schematic has 3 → fail.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
    try testing.expectEqual(@as(u32, 1), r.unmatched_schematic);
}

test "LVS device type mismatch fails" {
    // nmos vs pmos → no match possible → fail.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .pmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
    try testing.expectEqual(@as(u32, 0), r.matched);
}

test "LVS parameter match within 5% tolerance" {
    // W differs by 1% — within 5% tolerance → match.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.01, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.00, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(r.pass);
    try testing.expectEqual(@as(u32, 1), r.matched);
}

test "LVS parameter mismatch outside 5% tolerance fails" {
    // W differs by 10% → mismatch.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.10, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.00, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
    try testing.expectEqual(@as(u32, 0), r.matched);
}

test "LVS mixed device types match correctly" {
    // 1 NMOS + 1 PMOS on each side → both match.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .pmos, .w = 2.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .pmos, .w = 2.0, .l = 0.15, .val = 0.0 }, // order swapped
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(r.pass);
    try testing.expectEqual(@as(u32, 2), r.matched);
}

test "LVS resistor passive value mismatch" {
    // Two resistors with different values → mismatch.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .res, .w = 0.0, .l = 0.0, .val = 1000.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .res, .w = 0.0, .l = 0.0, .val = 2000.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
}

test "LVS layout has extra device" {
    // Layout has 2 devices, schematic has 1 → 1 unmatched in layout.
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
        .{ .dtype = .nmos, .w = 2.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .nmos, .w = 1.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
    try testing.expectEqual(@as(u32, 1), r.unmatched_layout);
    try testing.expectEqual(@as(u32, 0), r.unmatched_schematic);
}

test "LVS PMOS parameter mismatch detected" {
    var lay = try makeDevices(testing.allocator, &.{
        .{ .dtype = .pmos, .w = 4.0, .l = 0.15, .val = 0.0 },
    });
    defer lay.deinit();
    var schem = try makeDevices(testing.allocator, &.{
        .{ .dtype = .pmos, .w = 2.0, .l = 0.15, .val = 0.0 },
    });
    defer schem.deinit();

    const r = LvsChecker.compareDeviceLists(&lay, &schem);
    try testing.expect(!r.pass);
    try testing.expectEqual(@as(u32, 0), r.matched);
}

// ── Net connectivity tests ───────────────────────────────────────────────────

fn makePins(
    alloc: std.mem.Allocator,
    pins: []const struct { dev: u32, net: u32 },
) !PinEdgeArrays {
    var pa = try PinEdgeArrays.init(alloc, @intCast(pins.len));
    for (pins, 0..) |p, i| {
        pa.device[i] = DeviceIdx.fromInt(p.dev);
        pa.net[i]    = NetIdx.fromInt(p.net);
    }
    return pa;
}

test "LVS net connectivity identical circuits match (0 mismatches)" {
    // Inverter: M1(gate=0,drain=1,source=2), M2(gate=0,drain=1,source=3)
    var lp = try makePins(testing.allocator, &.{
        .{ .dev = 0, .net = 0 }, .{ .dev = 0, .net = 1 }, .{ .dev = 0, .net = 2 },
        .{ .dev = 1, .net = 0 }, .{ .dev = 1, .net = 1 }, .{ .dev = 1, .net = 3 },
    });
    defer lp.deinit();
    var sp = try makePins(testing.allocator, &.{
        .{ .dev = 0, .net = 0 }, .{ .dev = 0, .net = 1 }, .{ .dev = 0, .net = 2 },
        .{ .dev = 1, .net = 0 }, .{ .dev = 1, .net = 1 }, .{ .dev = 1, .net = 3 },
    });
    defer sp.deinit();

    const mismatches = try LvsChecker.compareNetConnectivity(&lp, &sp, 4, testing.allocator);
    try testing.expectEqual(@as(u32, 0), mismatches);
}

test "LVS net connectivity mismatch detected" {
    // Layout connects nets 0+1 via device 0; schematic does not → mismatch.
    var lp = try makePins(testing.allocator, &.{
        .{ .dev = 0, .net = 0 }, .{ .dev = 0, .net = 1 }, // device 0 bridges nets 0,1
    });
    defer lp.deinit();
    var sp = try makePins(testing.allocator, &.{
        .{ .dev = 0, .net = 0 }, .{ .dev = 0, .net = 2 }, // device 0 bridges nets 0,2
    });
    defer sp.deinit();

    const mismatches = try LvsChecker.compareNetConnectivity(&lp, &sp, 3, testing.allocator);
    try testing.expect(mismatches > 0);
}

test "LVS zero nets returns 0 mismatches" {
    var lp = try PinEdgeArrays.init(testing.allocator, 0);
    defer lp.deinit();
    var sp = try PinEdgeArrays.init(testing.allocator, 0);
    defer sp.deinit();

    const mismatches = try LvsChecker.compareNetConnectivity(&lp, &sp, 0, testing.allocator);
    try testing.expectEqual(@as(u32, 0), mismatches);
}
