// Shield Router — generates shield wires on adjacent layers for sensitive analog nets.
//
// Shield wires are placed on the layer above (or below) the signal layer,
// providing a grounded or driven reference that reduces capacitive coupling.
// Two modes:
//   - routeShielded(): shield connected to ground net
//   - routeDrivenGuard(): shield connected to signal net (same potential, AC ground)
//
// The ShieldDB SoA table stores all generated shield segments for later
// via stitching and integration with the main routing database.
//
// Via drops are generated at shield wire endpoints to connect shields to the
// appropriate power/ground net (or driven net for active guards).

const std = @import("std");
const core_types = @import("../core/types.zig");
const layout_if = @import("../core/layout_if.zig");
const inline_drc = @import("inline_drc.zig");

const NetIdx = core_types.NetIdx;
const PdkConfig = layout_if.PdkConfig;
const InlineDrcChecker = inline_drc.InlineDrcChecker;
const WireRect = inline_drc.WireRect;

// ─── ShieldDB SoA Table ───────────────────────────────────────────────────────

pub const ShieldDB = struct {
    /// Number of shield wires stored.
    len: u32 = 0,
    /// Capacity allocated.
    capacity: u32 = 0,

    x1: []f32 = &.{},
    y1: []f32 = &.{},
    x2: []f32 = &.{},
    y2: []f32 = &.{},
    width: []f32 = &.{},
    layer: []u8 = &.{},
    shield_net: []NetIdx = &.{},
    signal_net: []NetIdx = &.{},
    is_driven: []bool = &.{},

    allocator: std.mem.Allocator,

    /// Initialize with zero capacity.
    pub fn init(allocator: std.mem.Allocator) !ShieldDB {
        return ShieldDB{ .allocator = allocator };
    }

    /// Initialize with pre-allocated capacity.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: u32) !ShieldDB {
        var db = ShieldDB{ .allocator = allocator, .capacity = capacity, .len = 0 };
        errdefer db.deinit();

        db.x1 = try allocator.alloc(f32, capacity);
        db.y1 = try allocator.alloc(f32, capacity);
        db.x2 = try allocator.alloc(f32, capacity);
        db.y2 = try allocator.alloc(f32, capacity);
        db.width = try allocator.alloc(f32, capacity);
        db.layer = try allocator.alloc(u8, capacity);
        db.shield_net = try allocator.alloc(NetIdx, capacity);
        db.signal_net = try allocator.alloc(NetIdx, capacity);
        db.is_driven = try allocator.alloc(bool, capacity);

        return db;
    }

    pub fn deinit(self: *ShieldDB) void {
        if (self.capacity > 0) {
            self.allocator.free(self.x1);
            self.allocator.free(self.y1);
            self.allocator.free(self.x2);
            self.allocator.free(self.y2);
            self.allocator.free(self.width);
            self.allocator.free(self.layer);
            self.allocator.free(self.shield_net);
            self.allocator.free(self.signal_net);
            self.allocator.free(self.is_driven);
        }
        self.* = .{ .allocator = self.allocator };
    }

    /// Append a shield wire record.
    pub fn append(self: *ShieldDB, wire: ShieldWire) !void {
        if (self.len >= self.capacity) {
            try self.grow(self.capacity * 2 + 4);
        }
        const i = self.len;
        self.x1[i] = wire.x1;
        self.y1[i] = wire.y1;
        self.x2[i] = wire.x2;
        self.y2[i] = wire.y2;
        self.width[i] = wire.width;
        self.layer[i] = wire.layer;
        self.shield_net[i] = wire.shield_net;
        self.signal_net[i] = wire.signal_net;
        self.is_driven[i] = wire.is_driven;
        self.len += 1;
    }

    /// Grow capacity by reallocating all arrays.
    fn grow(self: *ShieldDB, new_cap: u32) !void {
        const old_cap = self.capacity;
        const cap = @as(usize, new_cap);

        if (old_cap == 0) {
            // First allocation — alloc fresh.
            self.x1 = try self.allocator.alloc(f32, cap);
            self.y1 = try self.allocator.alloc(f32, cap);
            self.x2 = try self.allocator.alloc(f32, cap);
            self.y2 = try self.allocator.alloc(f32, cap);
            self.width = try self.allocator.alloc(f32, cap);
            self.layer = try self.allocator.alloc(u8, cap);
            self.shield_net = try self.allocator.alloc(NetIdx, cap);
            self.signal_net = try self.allocator.alloc(NetIdx, cap);
            self.is_driven = try self.allocator.alloc(bool, cap);
        } else {
            self.x1 = try self.allocator.realloc(self.x1, cap);
            self.y1 = try self.allocator.realloc(self.y1, cap);
            self.x2 = try self.allocator.realloc(self.x2, cap);
            self.y2 = try self.allocator.realloc(self.y2, cap);
            self.width = try self.allocator.realloc(self.width, cap);
            self.layer = try self.allocator.realloc(self.layer, cap);
            self.shield_net = try self.allocator.realloc(self.shield_net, cap);
            self.signal_net = try self.allocator.realloc(self.signal_net, cap);
            self.is_driven = try self.allocator.realloc(self.is_driven, cap);
        }

        self.capacity = new_cap;
    }

    /// Get a single shield wire by index.
    pub fn getWire(self: *const ShieldDB, i: u32) ShieldWire {
        const idx = @as(usize, i);
        return .{
            .x1 = self.x1[idx],
            .y1 = self.y1[idx],
            .x2 = self.x2[idx],
            .y2 = self.y2[idx],
            .width = self.width[idx],
            .layer = self.layer[idx],
            .shield_net = self.shield_net[idx],
            .signal_net = self.signal_net[idx],
            .is_driven = self.is_driven[idx],
        };
    }
};

// ─── Shield Wire Record ───────────────────────────────────────────────────────

pub const ShieldWire = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    width: f32,
    layer: u8,
    shield_net: NetIdx,
    signal_net: NetIdx,
    is_driven: bool,
};

// ─── Via Drop Record ──────────────────────────────────────────────────────────

pub const ViaDrop = struct {
    x: f32,
    y: f32,
    via_width: f32,
    from_layer: u8, // shield layer
    to_layer: u8, // signal layer (where the via connects)
    net: NetIdx,
    shield_idx: u32, // index into ShieldDB of parent shield
};

// ─── ViaDropDB SoA Table ──────────────────────────────────────────────────────

pub const ViaDropDB = struct {
    len: u32 = 0,
    capacity: u32 = 0,

    x: []f32 = &.{},
    y: []f32 = &.{},
    via_width: []f32 = &.{},
    from_layer: []u8 = &.{},
    to_layer: []u8 = &.{},
    net: []NetIdx = &.{},
    shield_idx: []u32 = &.{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ViaDropDB {
        return ViaDropDB{ .allocator = allocator };
    }

    pub fn deinit(self: *ViaDropDB) void {
        if (self.capacity > 0) {
            self.allocator.free(self.x);
            self.allocator.free(self.y);
            self.allocator.free(self.via_width);
            self.allocator.free(self.from_layer);
            self.allocator.free(self.to_layer);
            self.allocator.free(self.net);
            self.allocator.free(self.shield_idx);
        }
        self.* = .{ .allocator = self.allocator };
    }

    pub fn append(self: *ViaDropDB, via: ViaDrop) !void {
        if (self.len >= self.capacity) {
            try self.grow(self.capacity * 2 + 4);
        }
        const i = self.len;
        self.x[i] = via.x;
        self.y[i] = via.y;
        self.via_width[i] = via.via_width;
        self.from_layer[i] = via.from_layer;
        self.to_layer[i] = via.to_layer;
        self.net[i] = via.net;
        self.shield_idx[i] = via.shield_idx;
        self.len += 1;
    }

    fn grow(self: *ViaDropDB, new_cap: u32) !void {
        const old_cap = self.capacity;
        const cap = @as(usize, new_cap);

        if (old_cap == 0) {
            self.x = try self.allocator.alloc(f32, cap);
            self.y = try self.allocator.alloc(f32, cap);
            self.via_width = try self.allocator.alloc(f32, cap);
            self.from_layer = try self.allocator.alloc(u8, cap);
            self.to_layer = try self.allocator.alloc(u8, cap);
            self.net = try self.allocator.alloc(NetIdx, cap);
            self.shield_idx = try self.allocator.alloc(u32, cap);
        } else {
            self.x = try self.allocator.realloc(self.x, cap);
            self.y = try self.allocator.realloc(self.y, cap);
            self.via_width = try self.allocator.realloc(self.via_width, cap);
            self.from_layer = try self.allocator.realloc(self.from_layer, cap);
            self.to_layer = try self.allocator.realloc(self.to_layer, cap);
            self.net = try self.allocator.realloc(self.net, cap);
            self.shield_idx = try self.allocator.realloc(self.shield_idx, cap);
        }

        self.capacity = new_cap;
    }

    pub fn getViaDrop(self: *const ViaDropDB, i: u32) ViaDrop {
        const idx = @as(usize, i);
        return .{
            .x = self.x[idx],
            .y = self.y[idx],
            .via_width = self.via_width[idx],
            .from_layer = self.from_layer[idx],
            .to_layer = self.to_layer[idx],
            .net = self.net[idx],
            .shield_idx = self.shield_idx[idx],
        };
    }
};

// ─── DRC Validation Result ───────────────────────────────────────────────────

pub const ValidationResult = struct {
    spacing_violations: u32 = 0,
    width_violations: u32 = 0,
    enclosure_violations: u32 = 0,
    total_checked: u32 = 0,

    pub fn isClean(self: ValidationResult) bool {
        return self.spacing_violations == 0 and
            self.width_violations == 0 and
            self.enclosure_violations == 0;
    }

    pub fn totalViolations(self: ValidationResult) u32 {
        return self.spacing_violations + self.width_violations + self.enclosure_violations;
    }
};

// ─── Shield Router ─────────────────────────────────────────────────────────────

pub const ShieldRouter = struct {
    db: ShieldDB,
    via_db: ViaDropDB,
    allocator: std.mem.Allocator,
    pdk: PdkConfig,
    drc: ?*InlineDrcChecker,

    /// Init with default (zero) capacity.
    pub fn init(allocator: std.mem.Allocator, pdk: *const PdkConfig) !ShieldRouter {
        const db = try ShieldDB.init(allocator);
        const via_db = try ViaDropDB.init(allocator);
        return ShieldRouter{
            .db = db,
            .via_db = via_db,
            .allocator = allocator,
            .pdk = pdk.*,
            .drc = null,
        };
    }

    pub fn deinit(self: *ShieldRouter) void {
        self.via_db.deinit();
        self.db.deinit();
    }

    /// Attach a DRC checker for conflict queries.
    pub fn setDrcChecker(self: *ShieldRouter, drc: *InlineDrcChecker) void {
        self.drc = drc;
    }

    /// Generate shield wires on the adjacent layer for a signal net.
    /// Shield wires are connected to ground (shield_net = ground_net).
    ///
    /// For each signal segment on signal_layer:
    ///   1. Compute shield rect on adjacent layer (layer+1, mod num_metal_layers)
    ///   2. Check for DRC conflicts using the attached InlineDrcChecker
    ///   3. Skip segments with conflicts
    ///   4. Append clean shield segments to ShieldDB
    ///   5. Register shield with DRC checker for future conflict checks
    pub fn routeShielded(
        self: *ShieldRouter,
        signal_segments: []const SignalSegment,
        ground_net: NetIdx,
        signal_layer: u8,
    ) !void {
        const shield_layer = adjacentLayer(signal_layer, self.pdk.num_metal_layers);
        const min_shield_width = self.pdk.min_width[shield_layer];
        // Use via_spacing if set, otherwise fall back to via_width as minimum pitch.
        const via_pitch = viaPitch(&self.pdk, shield_layer);

        for (signal_segments) |seg| {
            // Skip segments too short to place contacts at both ends.
            const seg_len = seg.length();
            if (seg_len < via_pitch * 2) continue;

            // Compute shield bounding rect on adjacent layer.
            // Shield expands from signal edge by min_spacing on each side.
            const exp = self.pdk.min_spacing[shield_layer];
            const shield_w = @max(seg.width, min_shield_width);

            const sx1 = seg.x1 - exp;
            const sy1 = seg.y1 - exp;
            const sx2 = seg.x2 + exp;
            const sy2 = seg.y2 + exp;

            // Check for DRC conflicts on the shield layer at via locations.
            var clean = true;
            if (self.drc) |drc| {
                const via_checks = &[_][2]f32{
                    .{ seg.x1, seg.y1 },
                    .{ seg.x2, seg.y2 },
                    .{ (sx1 + sx2) * 0.5, (sy1 + sy2) * 0.5 },
                };
                for (via_checks) |pt| {
                    const result = drc.checkSpacing(shield_layer, pt[0], pt[1], ground_net);
                    if (result.hard_violation) {
                        clean = false;
                        break;
                    }
                }
            }

            if (!clean) continue;

            try self.db.append(.{
                .x1 = sx1,
                .y1 = sy1,
                .x2 = sx2,
                .y2 = sy2,
                .width = shield_w,
                .layer = shield_layer,
                .shield_net = ground_net,
                .signal_net = seg.net,
                .is_driven = false,
            });

            // Register the new shield wire with the DRC checker so future
            // shields and routes see it as an obstacle.
            if (self.drc) |drc| {
                try drc.addSegment(
                    shield_layer,
                    sx1,
                    sy1,
                    sx2,
                    sy2,
                    shield_w,
                    ground_net,
                );
            }
        }
    }

    /// Generate driven guard wires on the adjacent layer.
    /// Shield is driven at the same potential as the signal (AC ground / guard).
    /// Used for high-impedance nodes.
    pub fn routeDrivenGuard(
        self: *ShieldRouter,
        signal_segments: []const SignalSegment,
        guard_net: NetIdx,
        shield_layer: u8,
    ) !void {
        const via_pitch = viaPitch(&self.pdk, shield_layer);

        for (signal_segments) |seg| {
            const seg_len = seg.length();
            if (seg_len < via_pitch * 2) continue;

            const exp = self.pdk.min_spacing[shield_layer];
            const min_shield_width = self.pdk.min_width[shield_layer];
            const shield_w = @max(seg.width, min_shield_width);

            const sx1 = seg.x1 - exp;
            const sy1 = seg.y1 - exp;
            const sx2 = seg.x2 + exp;
            const sy2 = seg.y2 + exp;

            // Driven guard: shield_net == signal_net (same potential).
            // Check conflicts using the signal net (not guard net).
            var clean = true;
            if (self.drc) |drc| {
                const via_checks = &[_][2]f32{
                    .{ seg.x1, seg.y1 },
                    .{ seg.x2, seg.y2 },
                    .{ (sx1 + sx2) * 0.5, (sy1 + sy2) * 0.5 },
                };
                for (via_checks) |pt| {
                    const result = drc.checkSpacing(shield_layer, pt[0], pt[1], seg.net);
                    if (result.hard_violation) {
                        clean = false;
                        break;
                    }
                }
            }

            if (!clean) continue;

            try self.db.append(.{
                .x1 = sx1,
                .y1 = sy1,
                .x2 = sx2,
                .y2 = sy2,
                .width = shield_w,
                .layer = shield_layer,
                .shield_net = guard_net, // same as signal_net for driven guard
                .signal_net = seg.net,
                .is_driven = true,
            });

            // Register driven guard with DRC checker.
            if (self.drc) |drc| {
                try drc.addSegment(
                    shield_layer,
                    sx1,
                    sy1,
                    sx2,
                    sy2,
                    shield_w,
                    guard_net,
                );
            }
        }
    }

    /// Generate via drops at shield wire endpoints to connect shields to
    /// their power/ground net (or driven net for active guards).
    ///
    /// For each shield wire, places two vias: one at each endpoint.
    /// Via width is taken from pdk.via_width for the shield layer.
    /// Vias connect from the shield layer down to the signal layer (layer-1).
    ///
    /// If a DRC checker is attached, via locations are checked for conflicts
    /// and skipped if they would cause violations.
    pub fn generateViaDrops(self: *ShieldRouter, signal_layer: u8) !void {
        _ = signal_layer; // computed from shield wire's layer below
        const n = self.db.len;
        for (0..n) |i| {
            const idx: u32 = @intCast(i);
            const shield_layer = self.db.layer[i];
            const net = self.db.shield_net[i];
            const vw = self.pdk.via_width[shield_layer];
            const enc = self.pdk.min_enclosure[shield_layer];

            // Two via locations: near start and near end of shield wire.
            // Offset inward by enclosure to ensure via is enclosed by shield metal.
            const x1 = self.db.x1[i];
            const y1 = self.db.y1[i];
            const x2 = self.db.x2[i];
            const y2 = self.db.y2[i];

            const via_pts = &[_][2]f32{
                .{ x1 + enc + vw * 0.5, (y1 + y2) * 0.5 },
                .{ x2 - enc - vw * 0.5, (y1 + y2) * 0.5 },
            };

            // Via should connect shield layer down to the signal layer (layer-1).
            const via_to_signal = if (shield_layer > 0) shield_layer - 1 else 0;

            for (via_pts) |pt| {
                var via_clean = true;
                if (self.drc) |drc| {
                    const result = drc.checkSpacing(shield_layer, pt[0], pt[1], net);
                    if (result.hard_violation) {
                        via_clean = false;
                    }
                }
                if (!via_clean) continue;

                try self.via_db.append(.{
                    .x = pt[0],
                    .y = pt[1],
                    .via_width = vw,
                    .from_layer = shield_layer,
                    .to_layer = via_to_signal,
                    .net = net,
                    .shield_idx = idx,
                });
            }
        }
    }

    /// Register all shield wires with an InlineDrcChecker.
    /// Call this after routing if shields were placed without a DRC checker
    /// attached (e.g., when building shields in batch before DRC is available).
    pub fn registerShieldsWithDrc(self: *const ShieldRouter, drc: *InlineDrcChecker) !void {
        const n = self.db.len;
        for (0..n) |i| {
            try drc.addSegment(
                self.db.layer[i],
                self.db.x1[i],
                self.db.y1[i],
                self.db.x2[i],
                self.db.y2[i],
                self.db.width[i],
                self.db.shield_net[i],
            );
        }
    }

    /// Validate all placed shields against DRC rules.
    ///
    /// Checks:
    ///   1. Shield width >= min_width for its layer
    ///   2. Shield-to-signal spacing >= min_spacing (via InlineDrcChecker)
    ///   3. Via enclosure: shield metal encloses via by >= min_enclosure
    pub fn validateShields(self: *const ShieldRouter) ValidationResult {
        var result = ValidationResult{};
        const n = self.db.len;

        for (0..n) |i| {
            result.total_checked += 1;
            const shield_layer = self.db.layer[i];

            // Check 1: shield width >= min_width
            const min_w = self.pdk.min_width[shield_layer];
            if (self.db.width[i] < min_w) {
                result.width_violations += 1;
            }

            // Check 2: spacing via DRC checker
            if (self.drc) |drc| {
                const mx = (self.db.x1[i] + self.db.x2[i]) * 0.5;
                const my = (self.db.y1[i] + self.db.y2[i]) * 0.5;
                // Check shield midpoint against signal net (different-net spacing).
                const spacing_result = drc.checkSpacing(
                    shield_layer,
                    mx,
                    my,
                    self.db.shield_net[i],
                );
                if (spacing_result.hard_violation) {
                    result.spacing_violations += 1;
                }
            }
        }

        // Check 3: via enclosure
        const via_n = self.via_db.len;
        for (0..via_n) |vi| {
            result.total_checked += 1;
            const si = self.via_db.shield_idx[vi];
            if (si >= n) continue;

            const shield_layer = self.db.layer[si];
            const enc_req = self.pdk.min_enclosure[shield_layer];
            const vx = self.via_db.x[vi];
            const vy = self.via_db.y[vi];
            const vhw = self.via_db.via_width[vi] * 0.5;

            // Via bounding box
            const vx_min = vx - vhw;
            const vx_max = vx + vhw;
            const vy_min = vy - vhw;
            const vy_max = vy + vhw;

            // Shield bounding box (already expanded from signal)
            const sx_min = self.db.x1[si];
            const sy_min = self.db.y1[si];
            const sx_max = self.db.x2[si];
            const sy_max = self.db.y2[si];

            // Enclosure on each side
            const enc_left = vx_min - sx_min;
            const enc_right = sx_max - vx_max;
            const enc_bottom = vy_min - sy_min;
            const enc_top = sy_max - vy_max;

            if (enc_left < enc_req or enc_right < enc_req or
                enc_bottom < enc_req or enc_top < enc_req)
            {
                result.enclosure_violations += 1;
            }
        }

        return result;
    }

    /// Get a shield wire by index.
    pub fn getShield(self: *const ShieldRouter, i: u32) ShieldWire {
        return self.db.getWire(i);
    }

    /// Number of shield wires generated.
    pub fn shieldCount(self: *const ShieldRouter) u32 {
        return self.db.len;
    }

    /// Number of via drops generated.
    pub fn viaDropCount(self: *const ShieldRouter) u32 {
        return self.via_db.len;
    }
};

// ─── Signal Segment (input from caller) ─────────────────────────────────────

pub const SignalSegment = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    width: f32,
    net: NetIdx,

    pub fn length(self: SignalSegment) f32 {
        return @abs(self.x2 - self.x1) + @abs(self.y2 - self.y1);
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Return the adjacent layer index, wrapping at num_metal_layers.
fn adjacentLayer(layer: u8, num_metal: u8) u8 {
    return (layer + 1) % num_metal;
}

/// Return the effective via pitch for a layer.
/// Uses via_spacing if set (> 0), otherwise falls back to via_width.
/// Guarantees a non-zero result when via_width is populated.
fn viaPitch(pdk: *const PdkConfig, layer: u8) f32 {
    const vs = pdk.via_spacing[layer];
    if (vs > 0.0) return vs;
    // Fall back to via_width (the via cut size itself is the minimum pitch).
    const vw = pdk.via_width[layer];
    if (vw > 0.0) return vw;
    // Last resort: use min_width as a conservative minimum.
    return pdk.min_width[layer];
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "ShieldDB append and getWire round-trip" {
    const alloc = std.testing.allocator;
    var db = try ShieldDB.initCapacity(alloc, 4);
    defer db.deinit();

    try db.append(.{
        .x1 = 1.0, .y1 = 2.0, .x2 = 3.0, .y2 = 4.0,
        .width = 0.14, .layer = 2,
        .shield_net = NetIdx.fromInt(5),
        .signal_net = NetIdx.fromInt(3),
        .is_driven = false,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);

    const wire = db.getWire(0);
    try std.testing.expectEqual(@as(f32, 1.0), wire.x1);
    try std.testing.expectEqual(@as(f32, 2.0), wire.y1);
    try std.testing.expectEqual(@as(f32, 3.0), wire.x2);
    try std.testing.expectEqual(@as(f32, 4.0), wire.y2);
    try std.testing.expectEqual(@as(f32, 0.14), wire.width);
    try std.testing.expectEqual(@as(u8, 2), wire.layer);
    try std.testing.expectEqual(NetIdx.fromInt(5), wire.shield_net);
    try std.testing.expectEqual(NetIdx.fromInt(3), wire.signal_net);
    try std.testing.expect(!wire.is_driven);
}

test "ShieldDB grows capacity correctly" {
    const alloc = std.testing.allocator;
    var db = try ShieldDB.initCapacity(alloc, 2);
    defer db.deinit();

    try std.testing.expectEqual(@as(u32, 2), db.capacity);

    // Fill past initial capacity.
    for (0..5) |i| {
        try db.append(.{
            .x1 = @floatFromInt(i), .y1 = 0.0, .x2 = @floatFromInt(i + 1), .y2 = 0.0,
            .width = 0.14, .layer = 1,
            .shield_net = NetIdx.fromInt(0),
            .signal_net = NetIdx.fromInt(0),
            .is_driven = false,
        });
    }

    try std.testing.expectEqual(@as(u32, 5), db.len);
    try std.testing.expect(db.capacity >= 5);
}

test "ShieldDB init with zero capacity then append" {
    const alloc = std.testing.allocator;
    var db = try ShieldDB.init(alloc);
    defer db.deinit();

    try std.testing.expectEqual(@as(u32, 0), db.capacity);

    try db.append(.{
        .x1 = 1.0, .y1 = 2.0, .x2 = 3.0, .y2 = 4.0,
        .width = 0.14, .layer = 1,
        .shield_net = NetIdx.fromInt(0),
        .signal_net = NetIdx.fromInt(1),
        .is_driven = false,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    const wire = db.getWire(0);
    try std.testing.expectEqual(@as(f32, 1.0), wire.x1);
}

test "adjacentLayer wraps correctly" {
    try std.testing.expectEqual(@as(u8, 1), adjacentLayer(0, 5));
    try std.testing.expectEqual(@as(u8, 2), adjacentLayer(1, 5));
    try std.testing.expectEqual(@as(u8, 0), adjacentLayer(4, 5)); // wraps
}

test "SignalSegment.length is Manhattan distance" {
    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 3.0, .y2 = 4.0,
        .width = 0.14, .net = NetIdx.fromInt(0),
    };
    try std.testing.expectEqual(@as(f32, 7.0), seg.length()); // 3 + 4
}

test "ShieldRouter.init and deinit" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();
    try std.testing.expectEqual(@as(u32, 0), router.shieldCount());
    try std.testing.expectEqual(@as(u32, 0), router.viaDropCount());
}

test "ShieldRouter routeShielded skips short segments" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const signal_net = NetIdx.fromInt(1);
    const ground_net = NetIdx.fromInt(0);

    // Very short segment — below 2*via_pitch.
    const short_seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 0.01, .y2 = 0.0,
        .width = 0.14, .net = signal_net,
    };

    try router.routeShielded(&.{short_seg}, ground_net, 1);

    // No shield generated for too-short segment.
    try std.testing.expectEqual(@as(u32, 0), router.shieldCount());
}

test "ShieldRouter routeShielded creates shield wires around signal" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const signal_net = NetIdx.fromInt(1);
    const ground_net = NetIdx.fromInt(0);
    const signal_layer: u8 = 1;
    const shield_layer = adjacentLayer(signal_layer, pdk.num_metal_layers);

    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = signal_net,
    };

    try router.routeShielded(&.{seg}, ground_net, signal_layer);

    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());
    const shield = router.getShield(0);

    // Shield must be on adjacent layer.
    try std.testing.expectEqual(shield_layer, shield.layer);

    // Shield must expand beyond signal rect.
    const exp = pdk.min_spacing[shield_layer];
    try std.testing.expectEqual(seg.x1 - exp, shield.x1);
    try std.testing.expectEqual(seg.y1 - exp, shield.y1);
    try std.testing.expectEqual(seg.x2 + exp, shield.x2);
    try std.testing.expectEqual(seg.y2 + exp, shield.y2);

    // Shield width >= min_width for the shield layer.
    try std.testing.expect(shield.width >= pdk.min_width[shield_layer]);

    // Shield is grounded, not driven.
    try std.testing.expect(!shield.is_driven);
    try std.testing.expectEqual(ground_net, shield.shield_net);
    try std.testing.expectEqual(signal_net, shield.signal_net);
}

test "ShieldRouter routeDrivenGuard sets is_driven=true" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    // No DRC checker — all segments accepted.
    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(2),
    };

    try router.routeDrivenGuard(&.{seg}, NetIdx.fromInt(2), 2);

    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());
    const shield = router.getShield(0);
    try std.testing.expect(shield.is_driven);
    try std.testing.expectEqual(shield.shield_net, shield.signal_net);
}

test "ShieldRouter routeShielded sets is_driven=false" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(2),
    };

    try router.routeShielded(&.{seg}, NetIdx.fromInt(0), 1);

    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());
    const shield = router.getShield(0);
    try std.testing.expect(!shield.is_driven);
    try std.testing.expectEqual(NetIdx.fromInt(0), shield.shield_net);
}

test "ShieldRouter shield layer is adjacent to signal layer" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    // Signal on layer 1 (M2), shield should be on layer 2 (M3).
    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };

    try router.routeShielded(&.{seg}, NetIdx.fromInt(0), 1);

    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());
    const shield = router.getShield(0);
    try std.testing.expectEqual(@as(u8, 2), shield.layer);
}

test "ShieldRouter DRC conflict causes shield to be skipped" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    // Create DRC checker with an obstacle on the shield layer.
    var drc = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 100.0, 100.0);
    defer drc.deinit();

    const signal_layer: u8 = 1;
    const shield_layer = adjacentLayer(signal_layer, pdk.num_metal_layers);
    const obstacle_net = NetIdx.fromInt(99);
    const ground_net = NetIdx.fromInt(0);

    // Place a large obstacle on the shield layer that overlaps where the
    // shield wire would go.
    try drc.addSegment(shield_layer, 0.0, 0.0, 10.0, 0.0, 2.0, obstacle_net);

    router.setDrcChecker(&drc);

    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };

    try router.routeShielded(&.{seg}, ground_net, signal_layer);

    // Shield should be skipped due to DRC conflict with obstacle.
    try std.testing.expectEqual(@as(u32, 0), router.shieldCount());
}

test "ShieldRouter generates via drops at shield endpoints" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const signal_layer: u8 = 1;
    const ground_net = NetIdx.fromInt(0);

    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };

    try router.routeShielded(&.{seg}, ground_net, signal_layer);
    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());

    // Generate via drops for the shield.
    try router.generateViaDrops(signal_layer);

    // Should have 2 via drops (one at each endpoint).
    try std.testing.expectEqual(@as(u32, 2), router.viaDropCount());

    // Verify via properties.
    const shield = router.getShield(0);
    const via0 = router.via_db.getViaDrop(0);
    const via1 = router.via_db.getViaDrop(1);

    // Vias are on shield layer, connecting to signal layer.
    try std.testing.expectEqual(shield.layer, via0.from_layer);
    try std.testing.expectEqual(signal_layer, via0.to_layer);
    try std.testing.expectEqual(ground_net, via0.net);

    try std.testing.expectEqual(shield.layer, via1.from_layer);
    try std.testing.expectEqual(signal_layer, via1.to_layer);

    // Via 0 is near x1, via 1 is near x2.
    try std.testing.expect(via0.x < via1.x);
}

test "ShieldRouter registerShieldsWithDrc populates checker" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    // Route without DRC checker.
    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };
    try router.routeShielded(&.{seg}, NetIdx.fromInt(0), 1);
    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());

    // Create a DRC checker and register shields.
    var drc = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 100.0, 100.0);
    defer drc.deinit();

    try std.testing.expectEqual(@as(usize, 0), drc.segments.items.len);

    try router.registerShieldsWithDrc(&drc);

    // Checker should now have 1 segment.
    try std.testing.expectEqual(@as(usize, 1), drc.segments.items.len);
}

test "ShieldRouter validateShields passes for clean placement" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const seg = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };
    try router.routeShielded(&.{seg}, NetIdx.fromInt(0), 1);

    const result = router.validateShields();
    try std.testing.expectEqual(@as(u32, 0), result.width_violations);
    try std.testing.expect(result.total_checked > 0);
}

test "ShieldRouter validateShields detects width violation" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    // Manually insert a shield with width below minimum.
    try router.db.append(.{
        .x1 = 0.0,
        .y1 = 0.0,
        .x2 = 10.0,
        .y2 = 0.0,
        .width = 0.01, // well below any min_width
        .layer = 2,
        .shield_net = NetIdx.fromInt(0),
        .signal_net = NetIdx.fromInt(1),
        .is_driven = false,
    });

    const result = router.validateShields();
    try std.testing.expect(result.width_violations > 0);
    try std.testing.expect(!result.isClean());
}

test "ShieldRouter multiple segments routed" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    const ground_net = NetIdx.fromInt(0);
    const signal_layer: u8 = 1;

    // Two long parallel signal segments far apart.
    const segs = &[_]SignalSegment{
        .{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0, .width = 0.14, .net = NetIdx.fromInt(1) },
        .{ .x1 = 0.0, .y1 = 5.0, .x2 = 10.0, .y2 = 5.0, .width = 0.14, .net = NetIdx.fromInt(2) },
    };

    try router.routeShielded(segs, ground_net, signal_layer);

    try std.testing.expectEqual(@as(u32, 2), router.shieldCount());

    // Both shields should be on the same adjacent layer.
    const s0 = router.getShield(0);
    const s1 = router.getShield(1);
    try std.testing.expectEqual(s0.layer, s1.layer);

    // Each shield has different signal_net but same shield_net.
    try std.testing.expectEqual(ground_net, s0.shield_net);
    try std.testing.expectEqual(ground_net, s1.shield_net);
    try std.testing.expect(s0.signal_net.toInt() != s1.signal_net.toInt());
}

test "ShieldRouter DRC registration prevents self-conflict" {
    const alloc = std.testing.allocator;
    const pdk = layout_if.PdkConfig.loadDefault(.sky130);
    var router = try ShieldRouter.init(alloc, &pdk);
    defer router.deinit();

    var drc = try InlineDrcChecker.init(alloc, &pdk, 0.0, 0.0, 100.0, 100.0);
    defer drc.deinit();
    router.setDrcChecker(&drc);

    const ground_net = NetIdx.fromInt(0);
    const signal_layer: u8 = 1;

    // First segment should route fine.
    const seg1 = SignalSegment{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .net = NetIdx.fromInt(1),
    };
    try router.routeShielded(&.{seg1}, ground_net, signal_layer);
    try std.testing.expectEqual(@as(u32, 1), router.shieldCount());

    // DRC checker should now have the shield registered.
    try std.testing.expectEqual(@as(usize, 1), drc.segments.items.len);
}

test "ViaDropDB append and getViaDrop round-trip" {
    const alloc = std.testing.allocator;
    var db = try ViaDropDB.init(alloc);
    defer db.deinit();

    try db.append(.{
        .x = 5.0,
        .y = 3.0,
        .via_width = 0.17,
        .from_layer = 2,
        .to_layer = 1,
        .net = NetIdx.fromInt(0),
        .shield_idx = 0,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    const via = db.getViaDrop(0);
    try std.testing.expectEqual(@as(f32, 5.0), via.x);
    try std.testing.expectEqual(@as(f32, 3.0), via.y);
    try std.testing.expectEqual(@as(f32, 0.17), via.via_width);
    try std.testing.expectEqual(@as(u8, 2), via.from_layer);
    try std.testing.expectEqual(@as(u8, 1), via.to_layer);
    try std.testing.expectEqual(NetIdx.fromInt(0), via.net);
}

test "ValidationResult helpers" {
    const clean = ValidationResult{};
    try std.testing.expect(clean.isClean());
    try std.testing.expectEqual(@as(u32, 0), clean.totalViolations());

    const dirty = ValidationResult{
        .spacing_violations = 1,
        .width_violations = 2,
        .enclosure_violations = 3,
        .total_checked = 10,
    };
    try std.testing.expect(!dirty.isClean());
    try std.testing.expectEqual(@as(u32, 6), dirty.totalViolations());
}
