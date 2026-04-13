const std = @import("std");
const types = @import("../core/types.zig");

const NetIdx = types.NetIdx;
const PinIdx = types.PinIdx;

// ─── Net / Pin adjacency data ──────────────────────────────────────────────
//
// The placer works on flattened adjacency arrays (CSR-style) so that we don't
// need a full netlist module yet.  The convention is:
//
//   net_pin_starts[n] .. net_pin_starts[n+1]  →  indices into `pin_list`
//   pin_list[k]                                →  PinIdx
//
// Pin positions are stored in a parallel array of [2]f32.
// ────────────────────────────────────────────────────────────────────────────

pub const NetAdjacency = struct {
    /// Length = num_nets + 1.  net_pin_starts[n] .. net_pin_starts[n+1] are the
    /// offsets into `pin_list` for the pins belonging to net n.
    net_pin_starts: []const u32,
    /// Flat list of pin indices referenced by each net.
    pin_list: []const PinIdx,
    /// Total number of nets.
    num_nets: u32,
};

/// RUDY (Rectangular Uniform wire DensitY) congestion estimator.
///
/// Reference: Spindler & Johannes, DATE 2007 — "Fast and Accurate Routing
/// Demand Estimation for Efficient Routability-Driven Placement".
///
/// The grid divides the layout region into uniform tiles.  Each tile stores a
/// demand value (sum of per-net RUDY contributions) and a capacity.
///
/// The key feature is **incremental update**: when a device moves only the nets
/// it belongs to are recomputed, not the entire grid.
pub const RudyGrid = struct {
    /// Flattened demand grid [rows * cols].
    demand: []f32,
    /// Flattened capacity grid [rows * cols].
    capacity: []f32,
    rows: u32,
    cols: u32,
    tile_size: f32,
    origin_x: f32,
    origin_y: f32,
    allocator: std.mem.Allocator,

    // ── Construction / Destruction ──────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        area_width: f32,
        area_height: f32,
        tile_size: f32,
        metal_pitch: f32,
    ) !RudyGrid {
        const cols: u32 = @max(1, @as(u32, @intFromFloat(@ceil(area_width / tile_size))));
        const rows: u32 = @max(1, @as(u32, @intFromFloat(@ceil(area_height / tile_size))));
        const total: usize = @as(usize, rows) * @as(usize, cols);

        const demand = try allocator.alloc(f32, total);
        errdefer allocator.free(demand);
        @memset(demand, 0.0);

        const cap = try allocator.alloc(f32, total);
        errdefer allocator.free(cap);

        // Capacity model: available_tracks * tile_dim / metal_pitch.
        // We assume 2 routing layers are available (one horizontal, one vertical)
        // so available_tracks ≈ 2.  Each layer contributes tile_size / metal_pitch
        // tracks, giving capacity = 2 * tile_size / metal_pitch  (wire-length units).
        const cap_val: f32 = if (metal_pitch > 0.0) 2.0 * tile_size / metal_pitch else 1.0e9;
        @memset(cap, cap_val);

        return RudyGrid{
            .demand = demand,
            .capacity = cap,
            .rows = rows,
            .cols = cols,
            .tile_size = tile_size,
            .origin_x = 0.0,
            .origin_y = 0.0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RudyGrid) void {
        self.allocator.free(self.demand);
        self.allocator.free(self.capacity);
        self.* = undefined;
    }

    // ── Full computation ────────────────────────────────────────────────

    /// Recompute the entire demand grid from scratch.
    pub fn computeFull(
        self: *RudyGrid,
        pin_positions: []const [2]f32,
        adj: NetAdjacency,
    ) void {
        @memset(self.demand, 0.0);

        var net: u32 = 0;
        while (net < adj.num_nets) : (net += 1) {
            self.addNetContribution(net, pin_positions, adj, 1.0);
        }
    }

    // ── Incremental update ──────────────────────────────────────────────

    /// Subtract the old contributions of `affected_nets`, then re-add them
    /// with the current pin positions.
    ///
    /// `old_pin_positions` must contain the pin positions **before** the move
    /// for all pins; only those belonging to the affected nets matter.
    pub fn updateIncremental(
        self: *RudyGrid,
        affected_nets: []const u32,
        old_pin_positions: []const [2]f32,
        new_pin_positions: []const [2]f32,
        adj: NetAdjacency,
    ) void {
        // 1. Subtract old contribution for each affected net.
        for (affected_nets) |net| {
            self.addNetContribution(net, old_pin_positions, adj, -1.0);
        }
        // 2. Add new contribution.
        for (affected_nets) |net| {
            self.addNetContribution(net, new_pin_positions, adj, 1.0);
        }
    }

    // ── Overflow metric ─────────────────────────────────────────────────

    /// Σ max(0, D(i,j) - C(i,j))  over all tiles.
    pub fn totalOverflow(self: *const RudyGrid) f32 {
        var overflow: f32 = 0.0;
        const total: usize = @as(usize, self.rows) * @as(usize, self.cols);
        for (0..total) |k| {
            const excess = self.demand[k] - self.capacity[k];
            if (excess > 0.0) overflow += excess;
        }
        return overflow;
    }

    // ── Private helpers ─────────────────────────────────────────────────

    /// Compute the bounding-box of all pins on `net` and splat the RUDY
    /// value onto overlapping tiles, scaled by `sign` (+1 to add, -1 to
    /// subtract).
    fn addNetContribution(
        self: *RudyGrid,
        net: u32,
        pin_positions: []const [2]f32,
        adj: NetAdjacency,
        sign: f32,
    ) void {
        const start = adj.net_pin_starts[net];
        const end = adj.net_pin_starts[net + 1];
        if (end <= start) return; // empty net

        // Compute bounding box of all pins on this net.
        var x_min: f32 = std.math.inf(f32);
        var x_max: f32 = -std.math.inf(f32);
        var y_min: f32 = std.math.inf(f32);
        var y_max: f32 = -std.math.inf(f32);

        for (start..end) |k| {
            const pid = adj.pin_list[k].toInt();
            const px = pin_positions[pid][0];
            const py = pin_positions[pid][1];
            x_min = @min(x_min, px);
            x_max = @max(x_max, px);
            y_min = @min(y_min, py);
            y_max = @max(y_max, py);
        }

        const w_n = x_max - x_min;
        const h_n = y_max - y_min;

        // Degenerate nets (single pin or all-collinear) have zero area;
        // use a small epsilon to avoid division by zero.  For a single-pin
        // net the contribution is 0 anyway because the HPWL is 0.
        if (w_n <= 0.0 and h_n <= 0.0) return;

        const area_n = @max(w_n, 1.0e-6) * @max(h_n, 1.0e-6);
        const rudy_density: f32 = (w_n + h_n) / area_n;

        // Determine which tiles the bounding box overlaps.
        const col_lo = self.tileCol(x_min);
        const col_hi = self.tileCol(x_max);
        const row_lo = self.tileRow(y_min);
        const row_hi = self.tileRow(y_max);

        var r = row_lo;
        while (r <= row_hi) : (r += 1) {
            var c = col_lo;
            while (c <= col_hi) : (c += 1) {
                // Compute overlap area between tile (r,c) and the net bbox.
                const tile_x0 = self.origin_x + @as(f32, @floatFromInt(c)) * self.tile_size;
                const tile_y0 = self.origin_y + @as(f32, @floatFromInt(r)) * self.tile_size;
                const tile_x1 = tile_x0 + self.tile_size;
                const tile_y1 = tile_y0 + self.tile_size;

                const ox = @max(@as(f32, 0.0), @min(tile_x1, x_max) - @max(tile_x0, x_min));
                const oy = @max(@as(f32, 0.0), @min(tile_y1, y_max) - @max(tile_y0, y_min));
                const overlap = ox * oy;

                const idx: usize = @as(usize, r) * @as(usize, self.cols) + @as(usize, c);
                self.demand[idx] += sign * rudy_density * overlap;
            }
        }
    }

    /// Map an x-coordinate to a tile column (clamped).
    fn tileCol(self: *const RudyGrid, x: f32) u32 {
        if (x <= self.origin_x) return 0;
        const c = @as(u32, @intFromFloat(@floor((x - self.origin_x) / self.tile_size)));
        return @min(c, self.cols - 1);
    }

    /// Map a y-coordinate to a tile row (clamped).
    fn tileRow(self: *const RudyGrid, y: f32) u32 {
        if (y <= self.origin_y) return 0;
        const r = @as(u32, @intFromFloat(@floor((y - self.origin_y) / self.tile_size)));
        return @min(r, self.rows - 1);
    }
};

// ─── Module-level tests ─────────────────────────────────────────────────────

test "RudyGrid init creates correct grid dimensions" {
    var grid = try RudyGrid.init(std.testing.allocator, 100.0, 50.0, 10.0, 0.5);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 10), grid.cols);
    try std.testing.expectEqual(@as(u32, 5), grid.rows);
    try std.testing.expectEqual(@as(usize, 50), grid.demand.len);
}

test "RudyGrid totalOverflow zero when demand is zero" {
    var grid = try RudyGrid.init(std.testing.allocator, 20.0, 20.0, 10.0, 0.5);
    defer grid.deinit();

    try std.testing.expectEqual(@as(f32, 0.0), grid.totalOverflow());
}
