//! Uniform 2D spatial grid for O(1) cell lookup with 9-cell neighborhood queries.
//! Replaces O(n) linear scans in DRC/coupling checks.
//!
//! Design: uniform grid (not R-tree), O(1) cell lookup, flat segment pool.
//! Not thread-safe — read-only during routing, rebuilt between wavefronts.

const std = @import("std");
const at = @import("analog_types.zig");
const layout_if = @import("../core/layout_if.zig");

const Rect = at.Rect;
const SegmentIdx = at.SegmentIdx;
const NetIdx = at.NetIdx;
const PdkConfig = layout_if.PdkConfig;

// ── SpatialGrid ──────────────────────────────────────────────────────────────

pub const SpatialGrid = struct {
    /// Number of cells in X direction.
    cells_x: u32,
    /// Number of cells in Y direction.
    cells_y: u32,
    /// Cell size in µm (typically 2 * max min_spacing).
    cell_size: f32,
    /// Die origin X (bbox.x1).
    origin_x: f32,
    /// Die origin Y (bbox.y1).
    origin_y: f32,

    /// Per-cell offset into segment_pool (cells_x * cells_y entries).
    cell_offsets: []u32,
    /// Per-cell segment count (cells_x * cells_y entries).
    cell_counts: []u16,
    /// Flat pool of segment indices, indexed by cell_offsets.
    segment_pool: std.ArrayListUnmanaged(SegmentIdx),

    allocator: std.mem.Allocator,

    /// Initialize a spatial grid from die bbox and PDK.
    /// cell_size = max_spacing * 2.0, bounded below by 0.01 µm.
    pub fn init(allocator: std.mem.Allocator, die_bbox: Rect, pdk: *const PdkConfig) !SpatialGrid {
        // Compute cell size = 2 * max(min_spacing)
        var max_sp: f32 = 0.0;
        for (0..pdk.num_metal_layers) |i| {
            max_sp = @max(max_sp, pdk.min_spacing[i]);
        }
        const cell_size = @max(max_sp * 2.0, 0.01);

        const w = die_bbox.x2 - die_bbox.x1;
        const h = die_bbox.y2 - die_bbox.y1;
        const cx: u32 = @as(u32, @intFromFloat(@as(f32, @ceil(w / cell_size)))) + 1;
        const cy: u32 = @as(u32, @intFromFloat(@as(f32, @ceil(h / cell_size)))) + 1;
        const total: usize = @intCast(@as(u64, cx) * @as(u64, cy));

        const offsets = try allocator.alloc(u32, total);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);

        const counts = try allocator.alloc(u16, total);
        errdefer allocator.free(counts);
        @memset(counts, 0);

        return .{
            .cells_x = cx,
            .cells_y = cy,
            .cell_size = cell_size,
            .origin_x = die_bbox.x1,
            .origin_y = die_bbox.y1,
            .cell_offsets = offsets,
            .cell_counts = counts,
            .segment_pool = .{},
            .allocator = allocator,
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *SpatialGrid) void {
        self.allocator.free(self.cell_offsets);
        self.allocator.free(self.cell_counts);
        self.segment_pool.deinit(self.allocator);
    }

    /// O(1) cell index from world coordinates. Clamps to grid bounds.
    pub inline fn cellIndex(self: *const SpatialGrid, x: f32, y: f32) u32 {
        const fx = @max(0.0, (x - self.origin_x) / self.cell_size);
        const fy = @max(0.0, (y - self.origin_y) / self.cell_size);
        const cx: u32 = @min(@as(u32, @intFromFloat(fx)), self.cells_x - 1);
        const cy: u32 = @min(@as(u32, @intFromFloat(fy)), self.cells_y - 1);
        return cy * self.cells_x + cx;
    }

    /// Rebuild grid from segment geometry arrays. O(n).
    /// Called between routing wavefronts.
    pub fn rebuild(
        self: *SpatialGrid,
        x1: []const f32,
        y1: []const f32,
        x2: []const f32,
        y2: []const f32,
        count: u32,
    ) !void {
        // Phase 1: count segments per cell
        @memset(self.cell_counts, 0);
        const n: usize = @intCast(count);

        for (0..n) |i| {
            const min_x = @min(x1[i], x2[i]);
            const max_x = @max(x1[i], x2[i]);
            const min_y = @min(y1[i], y2[i]);
            const max_y = @max(y1[i], y2[i]);

            const cx_lo = self.cellCol(min_x);
            const cx_hi = self.cellCol(max_x);
            const cy_lo = self.cellRow(min_y);
            const cy_hi = self.cellRow(max_y);

            var cy = cy_lo;
            while (cy <= cy_hi) : (cy += 1) {
                var cx = cx_lo;
                while (cx <= cx_hi) : (cx += 1) {
                    const idx = cy * self.cells_x + cx;
                    self.cell_counts[idx] +|= 1;
                }
            }
        }

        // Phase 2: compute offsets (prefix sum)
        var total: u32 = 0;
        const total_cells: usize = @intCast(@as(u64, self.cells_x) * @as(u64, self.cells_y));
        for (0..total_cells) |c| {
            self.cell_offsets[c] = total;
            total += self.cell_counts[c];
        }

        // Phase 3: fill pool
        self.segment_pool.clearRetainingCapacity();
        try self.segment_pool.resize(self.allocator, total);

        // Temp write cursors (reuse cell_counts as scratch)
        var write_cursors = try self.allocator.alloc(u32, total_cells);
        defer self.allocator.free(write_cursors);
        @memset(write_cursors, 0);

        for (0..n) |i| {
            const min_x = @min(x1[i], x2[i]);
            const max_x = @max(x1[i], x2[i]);
            const min_y = @min(y1[i], y2[i]);
            const max_y = @max(y1[i], y2[i]);

            const cx_lo = self.cellCol(min_x);
            const cx_hi = self.cellCol(max_x);
            const cy_lo = self.cellRow(min_y);
            const cy_hi = self.cellRow(max_y);

            var cy = cy_lo;
            while (cy <= cy_hi) : (cy += 1) {
                var cx = cx_lo;
                while (cx <= cx_hi) : (cx += 1) {
                    const cell: u32 = cy * self.cells_x + cx;
                    const pos = self.cell_offsets[cell] + write_cursors[cell];
                    self.segment_pool.items[pos] = SegmentIdx.fromInt(@intCast(i));
                    write_cursors[cell] += 1;
                }
            }
        }
    }

    /// Query 3x3 neighborhood around (x,y). Returns iterator.
    /// Caller must do actual geometry check against returned segment indices.
    pub fn queryNeighborhood(self: *const SpatialGrid, x: f32, y: f32) NeighborIterator {
        return .{
            .grid = self,
            .center_col = self.cellCol(x),
            .center_row = self.cellRow(y),
            .dy = 0,
            .dx = 0,
            .seg_idx = 0,
            .started = false,
        };
    }

    fn cellCol(self: *const SpatialGrid, x: f32) u32 {
        const f = @max(0.0, (x - self.origin_x) / self.cell_size);
        return @min(@as(u32, @intFromFloat(f)), self.cells_x - 1);
    }

    fn cellRow(self: *const SpatialGrid, y: f32) u32 {
        const f = @max(0.0, (y - self.origin_y) / self.cell_size);
        return @min(@as(u32, @intFromFloat(f)), self.cells_y - 1);
    }

    pub const NeighborIterator = struct {
        grid: *const SpatialGrid,
        center_col: u32,
        center_row: u32,
        dy: i8, // -1, 0, +1
        dx: i8, // -1, 0, +1
        seg_idx: u16,
        started: bool,

        pub fn next(self: *NeighborIterator) ?SegmentIdx {
            if (!self.started) {
                self.dy = -1;
                self.dx = -1;
                self.seg_idx = 0;
                self.started = true;
            }

            while (self.dy <= 1) {
                const r = @as(i64, self.center_row) + self.dy;
                if (r >= 0 and r < self.grid.cells_y) {
                    while (self.dx <= 1) {
                        const c = @as(i64, self.center_col) + self.dx;
                        if (c >= 0 and c < self.grid.cells_x) {
                            const cell: u32 = @intCast(r * @as(i64, self.grid.cells_x) + c);
                            const count = self.grid.cell_counts[cell];
                            if (self.seg_idx < count) {
                                const offset = self.grid.cell_offsets[cell];
                                const result = self.grid.segment_pool.items[offset + self.seg_idx];
                                self.seg_idx += 1;
                                return result;
                            }
                        }
                        self.dx += 1;
                        self.seg_idx = 0;
                    }
                }
                self.dy += 1;
                self.dx = -1;
                self.seg_idx = 0;
            }
            return null;
        }
    };
};

// ── SpatialDrcChecker ────────────────────────────────────────────────────────

/// Spatial-accelerated DRC checker. Wraps SpatialGrid + segment geometry
/// to provide O(1)+k spacing queries instead of O(n).
pub const SpatialDrcChecker = struct {
    grid: *const SpatialGrid,
    seg_x1: []const f32,
    seg_y1: []const f32,
    seg_x2: []const f32,
    seg_y2: []const f32,
    seg_width: []const f32,
    seg_layer: []const u8,
    seg_net: []const NetIdx,
    seg_count: u32,
    pdk: *const PdkConfig,

    pub const SpacingResult = struct {
        hard_violation: bool,
        soft_penalty: f32,
    };

    /// Check spacing at (layer, x, y) for net. Returns hard/soft result.
    pub fn checkSpacing(self: *const SpatialDrcChecker, layer: u8, x: f32, y: f32, net: NetIdx) SpacingResult {
        const pdk_idx = if (layer >= 1) @as(usize, layer) - 1 else 0;
        const min_sp = if (pdk_idx < 8) self.pdk.min_spacing[pdk_idx] else self.pdk.min_spacing[0];
        const min_w = if (pdk_idx < 8) self.pdk.min_width[pdk_idx] else self.pdk.min_width[0];
        const hw = min_w * 0.5;

        const px_min = x - hw;
        const px_max = x + hw;
        const py_min = y - hw;
        const py_max = y + hw;

        var hard = false;
        var soft: f32 = 0.0;

        var iter = self.grid.queryNeighborhood(x, y);
        while (iter.next()) |seg_idx| {
            const si: usize = seg_idx.toInt();
            if (si >= self.seg_count) continue;
            if (self.seg_layer[si] != layer) continue;
            if (self.seg_net[si].toInt() == net.toInt()) continue;

            // Compute segment bbox (wire with half-width on each side)
            const s_hw = self.seg_width[si] * 0.5;
            const sx_min = @min(self.seg_x1[si], self.seg_x2[si]) - s_hw;
            const sx_max = @max(self.seg_x1[si], self.seg_x2[si]) + s_hw;
            const sy_min = @min(self.seg_y1[si], self.seg_y2[si]) - s_hw;
            const sy_max = @max(self.seg_y1[si], self.seg_y2[si]) + s_hw;

            const gap_x = @max(px_min - sx_max, sx_min - px_max);
            const gap_y = @max(py_min - sy_max, sy_min - py_max);
            const gap = @max(gap_x, gap_y);

            if (gap < 0 or gap < min_sp) {
                hard = true;
                break;
            } else if (gap < min_sp * 1.5) {
                soft += 1.0;
            }
        }

        return .{ .hard_violation = hard, .soft_penalty = soft };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "SpatialGrid init and deinit" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();
    try std.testing.expect(grid.cells_x > 0);
    try std.testing.expect(grid.cells_y > 0);
}

test "SpatialGrid cellIndex basic" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // At origin
    const idx0 = grid.cellIndex(0.0, 0.0);
    try std.testing.expectEqual(@as(u32, 0), idx0);

    // Move 1 cell right
    const idx1 = grid.cellIndex(grid.cell_size, 0.0);
    try std.testing.expectEqual(@as(u32, 1), idx1);

    // Move 1 cell down (row stride)
    const idx_row = grid.cellIndex(0.0, grid.cell_size);
    try std.testing.expectEqual(@as(u32, grid.cells_x), idx_row);
}

test "SpatialGrid cellIndex clamps out-of-bounds" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // Negative coords clamp to 0
    const idx_neg = grid.cellIndex(-50.0, -50.0);
    try std.testing.expectEqual(@as(u32, 0), idx_neg);

    // Beyond max clamps to last cell
    const idx_big = grid.cellIndex(999.0, 999.0);
    try std.testing.expect(idx_big < grid.cells_x * grid.cells_y);
}

test "SpatialGrid rebuild preserves all segments" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // Insert 100 segments along diagonal
    var x1s = try std.testing.allocator.alloc(f32, 100);
    var y1s = try std.testing.allocator.alloc(f32, 100);
    var x2s = try std.testing.allocator.alloc(f32, 100);
    var y2s = try std.testing.allocator.alloc(f32, 100);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    for (0..100) |i| {
        x1s[i] = @floatFromInt(i);
        y1s[i] = 0.0;
        x2s[i] = @floatFromInt(i + 1);
        y2s[i] = 0.0;
    }

    try grid.rebuild(x1s, y1s, x2s, y2s, 100);

    // Verify all are findable
    for (0..100) |i| {
        var found = false;
        var iter = grid.queryNeighborhood(@as(f32, @floatFromInt(i)) + 0.5, 0.0);
        while (iter.next()) |seg_idx| {
            if (seg_idx.toInt() == i) found = true;
        }
        try std.testing.expect(found);
    }
}

test "SpatialGrid empty query returns nothing" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    var iter = grid.queryNeighborhood(50.0, 50.0);
    try std.testing.expectEqual(@as(?SegmentIdx, null), iter.next());
}

test "SpatialGrid query finds segment at exact coordinate" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    var x1s = try std.testing.allocator.alloc(f32, 1);
    var y1s = try std.testing.allocator.alloc(f32, 1);
    var x2s = try std.testing.allocator.alloc(f32, 1);
    var y2s = try std.testing.allocator.alloc(f32, 1);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    x1s[0] = 15.0;
    y1s[0] = 15.0;
    x2s[0] = 35.0;
    y2s[0] = 15.0;
    try grid.rebuild(x1s, y1s, x2s, y2s, 1);

    var found = false;
    var iter = grid.queryNeighborhood(25.0, 15.0);
    while (iter.next()) |seg_idx| {
        if (seg_idx.toInt() == 0) found = true;
    }
    try std.testing.expect(found);
}

test "SpatialGrid segment spanning multiple cells" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // Long horizontal segment spanning 5 cells
    var x1s = try std.testing.allocator.alloc(f32, 1);
    var y1s = try std.testing.allocator.alloc(f32, 1);
    var x2s = try std.testing.allocator.alloc(f32, 1);
    var y2s = try std.testing.allocator.alloc(f32, 1);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    x1s[0] = 0.0;
    y1s[0] = 5.0;
    x2s[0] = grid.cell_size * 5.0; // spans 5+ cells
    y2s[0] = 5.0;
    try grid.rebuild(x1s, y1s, x2s, y2s, 1);

    // Should be findable from any point along its length
    for (0..6) |i| {
        const x = @as(f32, @floatFromInt(i)) * grid.cell_size;
        var found = false;
        var iter = grid.queryNeighborhood(x, 5.0);
        while (iter.next()) |seg_idx| {
            if (seg_idx.toInt() == 0) found = true;
        }
        try std.testing.expect(found);
    }
}

test "SpatialDrcChecker no violation far away" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // One segment at (10,10) to (20,10)
    var x1s = try std.testing.allocator.alloc(f32, 1);
    var y1s = try std.testing.allocator.alloc(f32, 1);
    var x2s = try std.testing.allocator.alloc(f32, 1);
    var y2s = try std.testing.allocator.alloc(f32, 1);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    x1s[0] = 10.0;
    y1s[0] = 10.0;
    x2s[0] = 20.0;
    y2s[0] = 10.0;
    try grid.rebuild(x1s, y1s, x2s, y2s, 1);

    var seg_widths = try std.testing.allocator.alloc(f32, 1);
    var seg_layers = try std.testing.allocator.alloc(u8, 1);
    var seg_nets = try std.testing.allocator.alloc(NetIdx, 1);
    defer {
        std.testing.allocator.free(seg_widths);
        std.testing.allocator.free(seg_layers);
        std.testing.allocator.free(seg_nets);
    }
    seg_widths[0] = 0.14;
    seg_layers[0] = 1;
    seg_nets[0] = NetIdx.fromInt(0);

    var checker = SpatialDrcChecker{
        .grid = &grid,
        .seg_x1 = x1s,
        .seg_y1 = y1s,
        .seg_x2 = x2s,
        .seg_y2 = y2s,
        .seg_width = seg_widths,
        .seg_layer = seg_layers,
        .seg_net = seg_nets,
        .seg_count = 1,
        .pdk = &pdk,
    };

    // Check far from segment — no violation
    const result = checker.checkSpacing(1, 50.0, 50.0, NetIdx.fromInt(1));
    try std.testing.expect(!result.hard_violation);
    try std.testing.expectEqual(@as(f32, 0.0), result.soft_penalty);
}