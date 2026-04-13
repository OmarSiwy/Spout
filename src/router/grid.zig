const std = @import("std");
const core_types = @import("../core/types.zig");
const device_arrays = @import("../core/device_arrays.zig");
const layout_if = @import("../core/layout_if.zig");
const pin_edge_arrays_mod = @import("../core/pin_edge_arrays.zig");

const NetIdx = core_types.NetIdx;
const TerminalType = core_types.TerminalType;
const DeviceArrays = device_arrays.DeviceArrays;
const PdkConfig = layout_if.PdkConfig;
const MetalDirection = layout_if.MetalDirection;
const PinEdgeArrays = pin_edge_arrays_mod.PinEdgeArrays;

// ─── Multi-Layer Routing Grid ────────────────────────────────────────────────
//
// Track-based multi-layer grid replacing the old uniform RoutingGrid.
// Each metal layer has its own pitch and preferred direction.  Cells are
// addressed as (layer, track_a, track_b) where track_a runs along the
// layer's preferred direction and track_b along the cross direction.
//
// Layers use route layer indices (0 = M1, 1 = M2, …).

/// State of a single grid cell.
pub const CellState = enum(u8) {
    free = 0,
    blocked = 1,
    net_owned = 2,
};

/// A single grid cell stores its state plus the owning net (if any).
pub const Cell = struct {
    state: CellState,
    net_owner: NetIdx,
    /// Accumulated congestion: incremented each time a net is routed through
    /// this cell, decremented on rip-up.  Used to bias A* away from hot spots.
    congestion: u16,
};

/// Track geometry for a single metal layer.
pub const LayerTracks = struct {
    direction: MetalDirection,
    pitch: f32,
    offset: f32,
    num_tracks: u32,
    origin: f32, // World-space start of the track region

    pub fn init(pitch: f32, direction: MetalDirection, region_start: f32, region_end: f32) LayerTracks {
        const p = @max(pitch, 0.1); // Minimum 100nm pitch
        const off = p * 0.5;
        const span = region_end - region_start;
        const n: u32 = if (span > 0) @intFromFloat(@max(@ceil(span / p), 1.0)) else 1;
        return .{
            .direction = direction,
            .pitch = p,
            .offset = off,
            .num_tracks = @min(n, 8192),
            .origin = region_start,
        };
    }

    /// Convert world coordinate (along this layer's direction) to track index.
    pub fn worldToTrack(self: *const LayerTracks, world: f32) u32 {
        if (world <= self.origin + self.offset) return 0;
        const rel = world - self.origin - self.offset;
        const idx: u32 = @intFromFloat(@min(
            @max(@round(rel / self.pitch), 0.0),
            @as(f32, @floatFromInt(self.num_tracks -| 1)),
        ));
        return @min(idx, self.num_tracks -| 1);
    }

    /// Convert track index to world coordinate (track centre).
    pub fn trackToWorld(self: *const LayerTracks, idx: u32) f32 {
        return self.origin + self.offset + @as(f32, @floatFromInt(idx)) * self.pitch;
    }
};

/// Maximum routing layers supported.
pub const MAX_LAYERS: u8 = 8;

/// 3D node on the multi-layer grid.
pub const GridNode = struct {
    layer: u8,
    track_a: u32, // Along preferred direction of this layer
    track_b: u32, // Along cross direction

    pub fn eql(a: GridNode, b: GridNode) bool {
        return a.layer == b.layer and a.track_a == b.track_a and a.track_b == b.track_b;
    }
};

/// Multi-layer routing grid with per-layer track arrays.
pub const MultiLayerGrid = struct {
    /// Per-layer preferred-direction tracks (along tracks).
    layers: [MAX_LAYERS]LayerTracks,
    /// Per-layer cross-direction tracks.
    cross_layers: [MAX_LAYERS]LayerTracks,

    /// Flat cell storage: all layers concatenated.
    cells: []Cell,
    /// Per-layer offset into the cells array.
    cell_offsets: [MAX_LAYERS]usize,

    num_layers: u8,

    /// World-space bounding box.
    bb_xmin: f32,
    bb_ymin: f32,
    bb_xmax: f32,
    bb_ymax: f32,

    allocator: std.mem.Allocator,

    /// Build a multi-layer routing grid covering all device bounding boxes
    /// plus `margin` um on each side.
    ///
    /// Route layers: min(pdk.num_metal_layers, 4) for signal routing.
    /// Each layer gets its own pitch and preferred direction from the PDK.
    pub fn init(
        allocator: std.mem.Allocator,
        devices: *const DeviceArrays,
        pdk: *const PdkConfig,
        margin: f32,
        pins: ?*const PinEdgeArrays,
    ) !MultiLayerGrid {
        // Determine bounding box of all devices.
        var bb_xmin: f32 = std.math.inf(f32);
        var bb_ymin: f32 = std.math.inf(f32);
        var bb_xmax: f32 = -std.math.inf(f32);
        var bb_ymax: f32 = -std.math.inf(f32);

        const n_dev: usize = @intCast(devices.len);
        if (n_dev == 0) {
            // Degenerate: create a minimal grid with a small region.
            bb_xmin = 0.0;
            bb_ymin = 0.0;
            bb_xmax = 1.0;
            bb_ymax = 1.0;
        } else {
            for (0..n_dev) |i| {
                const cx = devices.positions[i][0];
                const cy = devices.positions[i][1];
                const hw = devices.dimensions[i][0] * 0.5;
                const hh = devices.dimensions[i][1] * 0.5;
                bb_xmin = @min(bb_xmin, cx - hw);
                bb_ymin = @min(bb_ymin, cy - hh);
                bb_xmax = @max(bb_xmax, cx + hw);
                bb_ymax = @max(bb_ymax, cy + hh);
            }
        }

        // Add margin on all sides.
        bb_xmin -= margin;
        bb_ymin -= margin;
        bb_xmax += margin;
        bb_ymax += margin;

        // Number of routing layers: use up to 4 for signal routing.
        const nl: u8 = @min(pdk.num_metal_layers, 4);
        const num_layers: u8 = @max(nl, 1);

        // Build per-layer track arrays.
        var layers: [MAX_LAYERS]LayerTracks = undefined;
        var cross_layers: [MAX_LAYERS]LayerTracks = undefined;
        var cell_offsets: [MAX_LAYERS]usize = .{0} ** MAX_LAYERS;
        var total_cells: usize = 0;

        for (0..num_layers) |l_idx| {
            const l: u8 = @intCast(l_idx);
            const dir = pdk.metal_direction[l];
            const pitch = pdk.metal_pitch[l];

            // Cross-direction pitch: use next layer's pitch, or previous if last layer.
            const cross_idx: u8 = if (l + 1 < num_layers) l + 1 else if (l > 0) l - 1 else l;
            const cross_pitch = pdk.metal_pitch[cross_idx];
            const cross_dir: MetalDirection = if (dir == .horizontal) .vertical else .horizontal;

            // Build preferred-direction tracks.
            // Horizontal layers: preferred direction is along Y.
            // Vertical layers: preferred direction is along X.
            if (dir == .horizontal) {
                layers[l] = LayerTracks.init(pitch, dir, bb_ymin, bb_ymax);
                cross_layers[l] = LayerTracks.init(cross_pitch, cross_dir, bb_xmin, bb_xmax);
            } else {
                layers[l] = LayerTracks.init(pitch, dir, bb_xmin, bb_xmax);
                cross_layers[l] = LayerTracks.init(cross_pitch, cross_dir, bb_ymin, bb_ymax);
            }

            cell_offsets[l] = total_cells;
            const layer_cells: usize = @as(usize, layers[l].num_tracks) * @as(usize, cross_layers[l].num_tracks);
            total_cells += layer_cells;
        }

        // Ensure at least 1 cell.
        if (total_cells == 0) total_cells = 1;

        const cells = try allocator.alloc(Cell, total_cells);
        @memset(cells, Cell{ .state = .free, .net_owner = NetIdx.fromInt(0), .congestion = 0 });

        var grid = MultiLayerGrid{
            .layers = layers,
            .cross_layers = cross_layers,
            .cells = cells,
            .cell_offsets = cell_offsets,
            .num_layers = num_layers,
            .bb_xmin = bb_xmin,
            .bb_ymin = bb_ymin,
            .bb_xmax = bb_xmax,
            .bb_ymax = bb_ymax,
            .allocator = allocator,
        };

        // Mark device obstacles.
        grid.markDeviceObstacles(devices, pdk, pins);

        return grid;
    }

    /// Free all grid cell storage.
    pub fn deinit(self: *MultiLayerGrid) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    // ─── Cell access ─────────────────────────────────────────────────────

    /// Flat index into the cells array for a given GridNode.
    pub fn cellIndex(self: *const MultiLayerGrid, node: GridNode) usize {
        const base = self.cell_offsets[node.layer];
        const cross_count: usize = @intCast(self.cross_layers[node.layer].num_tracks);
        const a: usize = @intCast(node.track_a);
        const b: usize = @intCast(node.track_b);
        return base + a * cross_count + b;
    }

    /// Get a mutable pointer to the cell at the given GridNode.
    pub fn cellAt(self: *MultiLayerGrid, node: GridNode) *Cell {
        const idx = self.cellIndex(node);
        return &self.cells[idx];
    }

    /// Get a const pointer to the cell at the given GridNode.
    pub fn cellAtConst(self: *const MultiLayerGrid, node: GridNode) *const Cell {
        const idx = self.cellIndex(node);
        return &self.cells[idx];
    }

    /// Check if a cell is routable (free or owned by `net`).
    pub fn isCellRoutable(self: *const MultiLayerGrid, node: GridNode, net: NetIdx) bool {
        const cell = self.cellAtConst(node);
        return switch (cell.state) {
            .free => true,
            .blocked => false,
            .net_owned => cell.net_owner.toInt() == net.toInt(),
        };
    }

    /// Claim a cell for a given net.
    pub fn claimCell(self: *MultiLayerGrid, node: GridNode, net: NetIdx) void {
        const cell = self.cellAt(node);
        cell.state = .net_owned;
        cell.net_owner = net;
        cell.congestion += 1;
    }

    /// Release a cell (used in rip-up).  Decrements congestion but does not
    /// reset it to zero so the history biases future routing.
    pub fn releaseCell(self: *MultiLayerGrid, node: GridNode) void {
        const cell = self.cellAt(node);
        if (cell.state == .net_owned) {
            cell.state = .free;
            cell.net_owner = NetIdx.fromInt(0);
        }
    }

    // ─── Coordinate conversion ───────────────────────────────────────────

    /// Convert world coordinates to a GridNode on the given layer.
    ///
    /// For horizontal layers:
    ///   track_a = preferred direction = Y (along tracks)
    ///   track_b = cross direction = X
    ///
    /// For vertical layers:
    ///   track_a = preferred direction = X (along tracks)
    ///   track_b = cross direction = Y
    pub fn worldToNode(self: *const MultiLayerGrid, layer: u8, x: f32, y: f32) GridNode {
        const dir = self.layers[layer].direction;
        if (dir == .horizontal) {
            return GridNode{
                .layer = layer,
                .track_a = self.layers[layer].worldToTrack(y),
                .track_b = self.cross_layers[layer].worldToTrack(x),
            };
        } else {
            return GridNode{
                .layer = layer,
                .track_a = self.layers[layer].worldToTrack(x),
                .track_b = self.cross_layers[layer].worldToTrack(y),
            };
        }
    }

    /// Convert a GridNode back to world coordinates [x, y].
    pub fn nodeToWorld(self: *const MultiLayerGrid, node: GridNode) [2]f32 {
        const a_world = self.layers[node.layer].trackToWorld(node.track_a);
        const b_world = self.cross_layers[node.layer].trackToWorld(node.track_b);
        const dir = self.layers[node.layer].direction;

        if (dir == .horizontal) {
            // a = Y, b = X
            return .{ b_world, a_world };
        } else {
            // a = X, b = Y
            return .{ a_world, b_world };
        }
    }

    // ─── Obstacle marking ────────────────────────────────────────────────

    /// Mark a world-space rectangle as blocked on the specified layer
    /// (or all layers if `layer` is null).
    pub fn markWorldRect(
        self: *MultiLayerGrid,
        x_min: f32,
        y_min: f32,
        x_max: f32,
        y_max: f32,
        layer: ?u8,
    ) void {
        const l_start: u8 = if (layer) |l| l else 0;
        const l_end: u8 = if (layer) |l| l + 1 else self.num_layers;

        var l: u8 = l_start;
        while (l < l_end) : (l += 1) {
            // Get track ranges for this rectangle on this layer.
            const node_min = self.worldToNode(l, x_min, y_min);
            const node_max = self.worldToNode(l, x_max, y_max);

            const a_lo = @min(node_min.track_a, node_max.track_a);
            const a_hi = @max(node_min.track_a, node_max.track_a);
            const b_lo = @min(node_min.track_b, node_max.track_b);
            const b_hi = @max(node_min.track_b, node_max.track_b);

            var a: u32 = a_lo;
            while (a <= a_hi) : (a += 1) {
                var b: u32 = b_lo;
                while (b <= b_hi) : (b += 1) {
                    self.cellAt(.{ .layer = l, .track_a = a, .track_b = b }).state = .blocked;
                }
            }
        }
    }

    /// Mark all cells overlapping device bounding boxes as blocked, and
    /// claim M1 pad keepout zones as net_owned so only the pad's own net
    /// can route through those cells (preventing DRC spacing violations).
    pub fn markDeviceObstacles(
        self: *MultiLayerGrid,
        devices: *const DeviceArrays,
        pdk: *const PdkConfig,
        pins: ?*const PinEdgeArrays,
    ) void {
        const n_dev: usize = @intCast(devices.len);

        // Pass 0: Block device bounding boxes on all layers.
        for (0..n_dev) |i| {
            const cx = devices.positions[i][0];
            const cy = devices.positions[i][1];
            const hw = devices.dimensions[i][0] * 0.5;
            const hh = devices.dimensions[i][1] * 0.5;

            if (hw <= 0.0 or hh <= 0.0) continue;

            self.markWorldRect(cx - hw, cy - hh, cx + hw, cy + hh, null);
        }

        // Block keepout zones around ALL MOSFET terminal positions on M1
        // so routes maintain DRC spacing from device pads.
        //
        // Two-pass approach:
        //   Pass 1: force-block the entire keepout zone for every terminal.
        //   Pass 2: un-block just the pad cell for each connected terminal
        //           so A* can terminate there.
        const m1_half = (170.0 / 2.0 + 40.0) * pdk.db_unit;
        const m1_pitch = pdk.metal_pitch[0];
        const keepout = m1_half + pdk.min_spacing[0] + pdk.min_width[0] / 2.0 + m1_pitch * 0.5;

        // Hardcoded pin offsets matching computePinOffsets / gdsii.zig.
        const sd_contact_y: f32 = 0.13;
        const gate_contact_x: f32 = 0.20;
        const body_tap_y: f32 = 0.70;

        // Pass 1: force-block all keepout zones on M1 (layer 0).
        for (0..n_dev) |i| {
            const dt = devices.types[i];
            if (dt != .nmos and dt != .pmos) continue;

            const px = devices.positions[i][0];
            const py = devices.positions[i][1];
            const params = devices.params[i];

            const w_raw = if (params.w > 0.0) params.w else 1.0;
            const l_raw = if (params.l > 0.0) params.l else 1.0;
            const w_base = if (w_raw < 1e-3) w_raw * 1e6 else w_raw;
            const l_scaled = if (l_raw < 1e-3) l_raw * 1e6 else l_raw;
            const mult: f32 = @floatFromInt(@max(@as(u16, 1), params.mult));
            const w_scaled = w_base * mult;

            const terminals = [_]struct { ox: f32, oy: f32 }{
                .{ .ox = w_scaled * 0.5, .oy = -sd_contact_y },
                .{ .ox = w_scaled * 0.5, .oy = l_scaled + sd_contact_y },
                .{ .ox = -gate_contact_x, .oy = l_scaled * 0.5 },
                .{ .ox = w_scaled * 0.5, .oy = -body_tap_y },
            };

            for (terminals) |term| {
                const abs_x = px + term.ox;
                const abs_y = py + term.oy;
                self.markWorldRect(abs_x - keepout, abs_y - keepout, abs_x + keepout, abs_y + keepout, 0);
            }
        }

        // Pass 2: un-block just the pad cell for each connected terminal.
        for (0..n_dev) |i| {
            const dt = devices.types[i];
            if (dt != .nmos and dt != .pmos) continue;

            const px = devices.positions[i][0];
            const py = devices.positions[i][1];
            const params = devices.params[i];

            const w_raw = if (params.w > 0.0) params.w else 1.0;
            const l_raw = if (params.l > 0.0) params.l else 1.0;
            const w_base = if (w_raw < 1e-3) w_raw * 1e6 else w_raw;
            const l_scaled = if (l_raw < 1e-3) l_raw * 1e6 else l_raw;
            const mult_f: f32 = @floatFromInt(@max(@as(u16, 1), params.mult));
            const w_scaled = w_base * mult_f;

            const idx: u32 = @intCast(i);
            const term_defs = [_]struct { t: TerminalType, ox: f32, oy: f32 }{
                .{ .t = .source, .ox = w_scaled * 0.5, .oy = -sd_contact_y },
                .{ .t = .drain, .ox = w_scaled * 0.5, .oy = l_scaled + sd_contact_y },
                .{ .t = .gate, .ox = -gate_contact_x, .oy = l_scaled * 0.5 },
                .{ .t = .body, .ox = w_scaled * 0.5, .oy = -body_tap_y },
            };

            for (term_defs) |term| {
                const net_id: ?u32 = if (pins) |pd| pinNetForTerminal(pd, idx, term.t) else null;
                if (net_id) |nid| {
                    const abs_x = px + term.ox;
                    const abs_y = py + term.oy;
                    const node = self.worldToNode(0, abs_x, abs_y);
                    const cell = self.cellAt(node);
                    cell.state = .net_owned;
                    cell.net_owner = NetIdx.fromInt(@intCast(nid));
                }
            }
        }
    }

    // ─── Legacy compatibility helpers ────────────────────────────────────

    /// Number of tracks along the preferred direction for a given layer.
    pub fn tracksA(self: *const MultiLayerGrid, layer: u8) u32 {
        return self.layers[layer].num_tracks;
    }

    /// Number of tracks along the cross direction for a given layer.
    pub fn tracksB(self: *const MultiLayerGrid, layer: u8) u32 {
        return self.cross_layers[layer].num_tracks;
    }
};

// ─── Legacy RoutingGrid shim ─────────────────────────────────────────────
//
// Backward-compatible wrapper so that astar.zig and detailed.zig (which use
// the old uniform-pitch (layer, row, col) API) continue to compile.
// Tasks 3-5 will migrate those files to MultiLayerGrid and remove this shim.

pub const RoutingGrid = struct {
    cells: []Cell,
    num_layers: u8,
    rows: u32,
    cols: u32,
    origin_x: f32,
    origin_y: f32,
    pitch_x: f32,
    pitch_y: f32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        devices: *const DeviceArrays,
        pdk: *const PdkConfig,
        margin: f32,
        pins: ?*const PinEdgeArrays,
    ) !RoutingGrid {
        var bb_xmin: f32 = std.math.inf(f32);
        var bb_ymin: f32 = std.math.inf(f32);
        var bb_xmax: f32 = -std.math.inf(f32);
        var bb_ymax: f32 = -std.math.inf(f32);

        const n_dev: usize = @intCast(devices.len);
        if (n_dev == 0) {
            const cells = try allocator.alloc(Cell, @as(usize, pdk.num_metal_layers));
            @memset(cells, Cell{ .state = .free, .net_owner = NetIdx.fromInt(0), .congestion = 0 });
            return RoutingGrid{
                .cells = cells,
                .num_layers = pdk.num_metal_layers,
                .rows = 1,
                .cols = 1,
                .origin_x = 0.0,
                .origin_y = 0.0,
                .pitch_x = pdk.metal_pitch[0],
                .pitch_y = pdk.metal_pitch[0],
                .allocator = allocator,
            };
        }

        for (0..n_dev) |i| {
            const cx = devices.positions[i][0];
            const cy = devices.positions[i][1];
            const hw = devices.dimensions[i][0] * 0.5;
            const hh = devices.dimensions[i][1] * 0.5;
            bb_xmin = @min(bb_xmin, cx - hw);
            bb_ymin = @min(bb_ymin, cy - hh);
            bb_xmax = @max(bb_xmax, cx + hw);
            bb_ymax = @max(bb_ymax, cy + hh);
        }

        bb_xmin -= margin;
        bb_ymin -= margin;
        bb_xmax += margin;
        bb_ymax += margin;

        const pitch = @max(pdk.metal_pitch[0], 0.28);
        const width = bb_xmax - bb_xmin;
        const height = bb_ymax - bb_ymin;
        const cols_f = @ceil(width / pitch);
        const rows_f = @ceil(height / pitch);
        const max_dim: u32 = 8192;
        const cols: u32 = @max(@as(u32, @intFromFloat(@min(cols_f, @as(f32, @floatFromInt(max_dim))))), 1);
        const rows: u32 = @max(@as(u32, @intFromFloat(@min(rows_f, @as(f32, @floatFromInt(max_dim))))), 1);

        const nl: u32 = @intCast(pdk.num_metal_layers);
        const total: usize = @as(usize, nl) * @as(usize, rows) * @as(usize, cols);
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{ .state = .free, .net_owner = NetIdx.fromInt(0), .congestion = 0 });

        var grid = RoutingGrid{
            .cells = cells,
            .num_layers = pdk.num_metal_layers,
            .rows = rows,
            .cols = cols,
            .origin_x = bb_xmin,
            .origin_y = bb_ymin,
            .pitch_x = pitch,
            .pitch_y = pitch,
            .allocator = allocator,
        };

        grid.markDeviceObstacles(devices, pdk, pins);
        return grid;
    }

    pub fn markDeviceObstacles(self: *RoutingGrid, devices: *const DeviceArrays, pdk: *const PdkConfig, pins: ?*const PinEdgeArrays) void {
        const n_dev: usize = @intCast(devices.len);
        for (0..n_dev) |i| {
            const cx = devices.positions[i][0];
            const cy = devices.positions[i][1];
            const hw = devices.dimensions[i][0] * 0.5;
            const hh = devices.dimensions[i][1] * 0.5;
            if (hw <= 0.0 or hh <= 0.0) continue;
            self.markRect(cx - hw, cy - hh, cx + hw, cy + hh, null);
        }

        const m1_half = (170.0 / 2.0 + 40.0) * pdk.db_unit;
        const keepout = m1_half + pdk.min_spacing[0] + pdk.min_width[0] / 2.0 + self.pitch_x * 0.5;
        const sd_contact_y: f32 = 0.13;
        const gate_contact_x: f32 = 0.20;
        const body_tap_y: f32 = 0.70;

        for (0..n_dev) |i| {
            const dt = devices.types[i];
            if (dt != .nmos and dt != .pmos) continue;
            const px = devices.positions[i][0];
            const py = devices.positions[i][1];
            const params = devices.params[i];
            const w_raw = if (params.w > 0.0) params.w else 1.0;
            const l_raw = if (params.l > 0.0) params.l else 1.0;
            const w_base = if (w_raw < 1e-3) w_raw * 1e6 else w_raw;
            const l_scaled = if (l_raw < 1e-3) l_raw * 1e6 else l_raw;
            const mult: f32 = @floatFromInt(@max(@as(u16, 1), params.mult));
            const w_scaled = w_base * mult;
            const terminals = [_]struct { ox: f32, oy: f32 }{
                .{ .ox = w_scaled * 0.5, .oy = -sd_contact_y },
                .{ .ox = w_scaled * 0.5, .oy = l_scaled + sd_contact_y },
                .{ .ox = -gate_contact_x, .oy = l_scaled * 0.5 },
                .{ .ox = w_scaled * 0.5, .oy = -body_tap_y },
            };
            for (terminals) |term| {
                const abs_x = px + term.ox;
                const abs_y = py + term.oy;
                const c_min = self.worldToCol(abs_x - keepout);
                const c_max = self.worldToCol(abs_x + keepout);
                const r_min = self.worldToRow(abs_y - keepout);
                const r_max = self.worldToRow(abs_y + keepout);
                var r: u32 = r_min;
                while (r <= r_max) : (r += 1) {
                    var c: u32 = c_min;
                    while (c <= c_max) : (c += 1) {
                        self.cellAt(0, r, c).state = .blocked;
                    }
                }
            }
        }

        for (0..n_dev) |i| {
            const dt = devices.types[i];
            if (dt != .nmos and dt != .pmos) continue;
            const px = devices.positions[i][0];
            const py = devices.positions[i][1];
            const params = devices.params[i];
            const w_raw = if (params.w > 0.0) params.w else 1.0;
            const l_raw = if (params.l > 0.0) params.l else 1.0;
            const w_base = if (w_raw < 1e-3) w_raw * 1e6 else w_raw;
            const l_scaled = if (l_raw < 1e-3) l_raw * 1e6 else l_raw;
            const mult_f: f32 = @floatFromInt(@max(@as(u16, 1), params.mult));
            const w_scaled = w_base * mult_f;
            const idx: u32 = @intCast(i);
            const term_defs = [_]struct { t: TerminalType, ox: f32, oy: f32 }{
                .{ .t = .source, .ox = w_scaled * 0.5, .oy = -sd_contact_y },
                .{ .t = .drain, .ox = w_scaled * 0.5, .oy = l_scaled + sd_contact_y },
                .{ .t = .gate, .ox = -gate_contact_x, .oy = l_scaled * 0.5 },
                .{ .t = .body, .ox = w_scaled * 0.5, .oy = -body_tap_y },
            };
            for (term_defs) |term| {
                const net_id: ?u32 = if (pins) |pd| pinNetForTerminal(pd, idx, term.t) else null;
                if (net_id) |nid| {
                    const abs_x = px + term.ox;
                    const abs_y = py + term.oy;
                    const pc = self.worldToCol(abs_x);
                    const pr = self.worldToRow(abs_y);
                    const cell = self.cellAt(0, pr, pc);
                    cell.state = .net_owned;
                    cell.net_owner = NetIdx.fromInt(@intCast(nid));
                }
            }
        }
    }

    pub fn markRect(self: *RoutingGrid, x_min: f32, y_min: f32, x_max: f32, y_max: f32, layer: ?u8) void {
        const c_min = self.worldToCol(x_min);
        const c_max = self.worldToCol(x_max);
        const r_min = self.worldToRow(y_min);
        const r_max = self.worldToRow(y_max);
        const l_start: u8 = if (layer) |l| l else 0;
        const l_end: u8 = if (layer) |l| l + 1 else self.num_layers;
        var l: u8 = l_start;
        while (l < l_end) : (l += 1) {
            var r: u32 = r_min;
            while (r <= r_max) : (r += 1) {
                var c: u32 = c_min;
                while (c <= c_max) : (c += 1) {
                    self.cellAt(l, r, c).state = .blocked;
                }
            }
        }
    }

    pub fn worldToCol(self: *const RoutingGrid, x: f32) u32 {
        if (x <= self.origin_x) return 0;
        const offset = x - self.origin_x;
        const col_f = offset / self.pitch_x;
        const col: u32 = @intFromFloat(@min(@max(col_f, 0.0), @as(f32, @floatFromInt(self.cols - 1))));
        return @min(col, self.cols - 1);
    }

    pub fn worldToRow(self: *const RoutingGrid, y: f32) u32 {
        if (y <= self.origin_y) return 0;
        const offset = y - self.origin_y;
        const row_f = offset / self.pitch_y;
        const row: u32 = @intFromFloat(@min(@max(row_f, 0.0), @as(f32, @floatFromInt(self.rows - 1))));
        return @min(row, self.rows - 1);
    }

    pub fn colToWorld(self: *const RoutingGrid, col: u32) f32 {
        return self.origin_x + @as(f32, @floatFromInt(col)) * self.pitch_x + self.pitch_x * 0.5;
    }

    pub fn rowToWorld(self: *const RoutingGrid, row: u32) f32 {
        return self.origin_y + @as(f32, @floatFromInt(row)) * self.pitch_y + self.pitch_y * 0.5;
    }

    pub fn cellAt(self: *RoutingGrid, layer: u8, row: u32, col: u32) *Cell {
        const idx = self.cellIndexLegacy(layer, row, col);
        return &self.cells[idx];
    }

    pub fn cellAtConst(self: *const RoutingGrid, layer: u8, row: u32, col: u32) *const Cell {
        const idx = self.cellIndexLegacy(layer, row, col);
        return &self.cells[idx];
    }

    pub fn isCellRoutable(self: *const RoutingGrid, layer: u8, row: u32, col: u32, net: NetIdx) bool {
        const cell = self.cellAtConst(layer, row, col);
        return switch (cell.state) {
            .free => true,
            .blocked => false,
            .net_owned => cell.net_owner.toInt() == net.toInt(),
        };
    }

    pub fn claimCell(self: *RoutingGrid, layer: u8, row: u32, col: u32, net: NetIdx) void {
        const cell = self.cellAt(layer, row, col);
        cell.state = .net_owned;
        cell.net_owner = net;
        cell.congestion += 1;
    }

    pub fn releaseCell(self: *RoutingGrid, layer: u8, row: u32, col: u32) void {
        const cell = self.cellAt(layer, row, col);
        if (cell.state == .net_owned) {
            cell.state = .free;
            cell.net_owner = NetIdx.fromInt(0);
        }
    }

    fn cellIndexLegacy(self: *const RoutingGrid, layer: u8, row: u32, col: u32) usize {
        const l: usize = @intCast(layer);
        const r: usize = @intCast(row);
        const c: usize = @intCast(col);
        return l * @as(usize, self.rows) * @as(usize, self.cols) + r * @as(usize, self.cols) + c;
    }

    pub fn deinit(self: *RoutingGrid) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

/// Look up the net ID for a specific terminal on a device from pin data.
fn pinNetForTerminal(pins: *const PinEdgeArrays, dev_idx: u32, terminal: TerminalType) ?u32 {
    const pin_len: usize = @intCast(pins.len);
    for (0..pin_len) |p| {
        if (pins.device[p].toInt() == dev_idx and pins.terminal[p] == terminal) {
            return pins.net[p].toInt();
        }
    }
    return null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "LayerTracks from sky130 M1" {
    const pdk = PdkConfig.loadDefault(.sky130);
    const tracks = LayerTracks.init(pdk.metal_pitch[0], pdk.metal_direction[0], 0.0, 20.0);
    // M1 pitch=0.34, horizontal, covering 20um -> ~59 tracks
    try std.testing.expect(tracks.num_tracks > 50);
    try std.testing.expect(tracks.num_tracks < 70);
    try std.testing.expectEqual(MetalDirection.horizontal, tracks.direction);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), tracks.pitch, 1e-6);
    // First track at offset = pitch/2
    try std.testing.expectApproxEqAbs(@as(f32, 0.17), tracks.offset, 1e-2);
}

test "LayerTracks trackPosition round-trip" {
    const tracks = LayerTracks.init(0.46, .vertical, 0.0, 10.0);
    const idx = tracks.worldToTrack(2.5);
    const world = tracks.trackToWorld(idx);
    try std.testing.expect(@abs(world - 2.5) <= tracks.pitch);
}

test "MultiLayerGrid init from sky130" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 4.0, 3.0 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 5.0, null);
    defer grid.deinit();

    // Should have layers for M1 through M4 (first 4 routable metals)
    try std.testing.expect(grid.num_layers >= 4);
    // Each layer should have tracks
    for (0..grid.num_layers) |l| {
        try std.testing.expect(grid.layers[l].num_tracks > 0);
    }
}

test "MultiLayerGrid init no devices" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 0);
    defer da.deinit();

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 5.0, null);
    defer grid.deinit();

    try std.testing.expect(grid.num_layers >= 1);
}

test "MultiLayerGrid cell claim and release" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 2.0 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 10.0, null);
    defer grid.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Pick a cell in the margin (should be free)
    const node = GridNode{ .layer = 0, .track_a = 0, .track_b = 0 };
    try std.testing.expect(grid.isCellRoutable(node, net0));

    grid.claimCell(node, net0);
    try std.testing.expect(grid.isCellRoutable(node, net0));
    try std.testing.expect(!grid.isCellRoutable(node, net1));

    grid.releaseCell(node);
    try std.testing.expect(grid.isCellRoutable(node, net1));
}

test "MultiLayerGrid coordinate round-trip" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 0.0, 0.0 };
    da.dimensions[0] = .{ 10.0, 10.0 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 5.0, null);
    defer grid.deinit();

    // World -> grid -> world should be within one pitch
    const test_x: f32 = 3.0;
    const test_y: f32 = 2.0;
    const node = grid.worldToNode(0, test_x, test_y);
    const pos = grid.nodeToWorld(node);
    try std.testing.expect(@abs(pos[0] - test_x) < pdk.metal_pitch[0]);
    try std.testing.expect(@abs(pos[1] - test_y) < pdk.metal_pitch[0]);
}

// ─── Fuzz Tests ─────────────────────────────────────────────────────────────
//
// Coverage-guided fuzzing for coordinate conversion and track position
// monotonicity.  These use std.testing.fuzz to exercise the grid logic
// with arbitrary byte inputs, filtering out non-finite / out-of-range
// values so the functions under test receive only valid-but-adversarial
// coordinates.

test "fuzz: MultiLayerGrid worldToNode never panics" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            if (input.len < 9) return;
            const x = @as(f32, @bitCast(input[0..4].*));
            const y = @as(f32, @bitCast(input[4..8].*));
            const layer_byte = input[8];

            if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;

            const allocator = std.testing.allocator;
            const da_mod = @import("../core/device_arrays.zig");
            var da = try da_mod.DeviceArrays.init(allocator, 0);
            defer da.deinit();

            const pkd = PdkConfig.loadDefault(.sky130);
            var grid = try MultiLayerGrid.init(allocator, &da, &pkd, 5.0, null);
            defer grid.deinit();

            const layer = layer_byte % grid.num_layers;

            // Should never panic regardless of input coordinates
            const node = grid.worldToNode(layer, x, y);
            _ = grid.nodeToWorld(node);
        }
    }.testOne, .{});
}

test "fuzz: track positions are monotonically increasing" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            if (input.len < 8) return;
            const pitch_f = @as(f32, @bitCast(input[0..4].*));
            const span_f = @as(f32, @bitCast(input[4..8].*));

            if (!std.math.isFinite(pitch_f) or pitch_f <= 0.0 or pitch_f > 100.0) return;
            if (!std.math.isFinite(span_f) or span_f <= 0.0 or span_f > 10000.0) return;

            const tracks = LayerTracks.init(pitch_f, .horizontal, 0.0, span_f);

            // Track positions must be monotonically increasing
            var prev: f32 = -std.math.inf(f32);
            for (0..tracks.num_tracks) |i| {
                const pos = tracks.trackToWorld(@intCast(i));
                try std.testing.expect(pos > prev);
                prev = pos;
            }
        }
    }.testOne, .{});
}

test "fuzz: worldToTrack always returns valid index" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            if (input.len < 12) return;
            const pitch_f = @as(f32, @bitCast(input[0..4].*));
            const span_f = @as(f32, @bitCast(input[4..8].*));
            const coord_f = @as(f32, @bitCast(input[8..12].*));

            if (!std.math.isFinite(pitch_f) or pitch_f <= 0.0 or pitch_f > 100.0) return;
            if (!std.math.isFinite(span_f) or span_f <= 0.0 or span_f > 10000.0) return;
            if (!std.math.isFinite(coord_f)) return;

            const tracks = LayerTracks.init(pitch_f, .vertical, 0.0, span_f);

            // worldToTrack must always return an index within [0, num_tracks)
            const idx = tracks.worldToTrack(coord_f);
            try std.testing.expect(idx < tracks.num_tracks);
        }
    }.testOne, .{});
}

test "fuzz: worldToNode round-trip within one pitch" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) !void {
            if (input.len < 9) return;
            const x = @as(f32, @bitCast(input[0..4].*));
            const y = @as(f32, @bitCast(input[4..8].*));
            const layer_byte = input[8];

            if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
            // Restrict to reasonable coordinate range to avoid giant grids
            if (@abs(x) > 1000.0 or @abs(y) > 1000.0) return;

            const allocator = std.testing.allocator;
            const da_mod = @import("../core/device_arrays.zig");
            var da = try da_mod.DeviceArrays.init(allocator, 0);
            defer da.deinit();

            const pkd = PdkConfig.loadDefault(.sky130);
            var grid = try MultiLayerGrid.init(allocator, &da, &pkd, 5.0, null);
            defer grid.deinit();

            const layer = layer_byte % grid.num_layers;

            const node = grid.worldToNode(layer, x, y);
            const pos = grid.nodeToWorld(node);

            // The returned position should be finite
            try std.testing.expect(std.math.isFinite(pos[0]));
            try std.testing.expect(std.math.isFinite(pos[1]));

            // If the input was inside the grid bounding box, the round-trip
            // error should be within one pitch of the layer
            if (x >= grid.bb_xmin and x <= grid.bb_xmax and
                y >= grid.bb_ymin and y <= grid.bb_ymax)
            {
                const max_pitch = @max(grid.layers[layer].pitch, grid.cross_layers[layer].pitch);
                try std.testing.expect(@abs(pos[0] - x) <= max_pitch);
                try std.testing.expect(@abs(pos[1] - y) <= max_pitch);
            }
        }
    }.testOne, .{});
}
