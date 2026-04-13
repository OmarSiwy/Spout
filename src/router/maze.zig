const std = @import("std");
const core_types = @import("../core/types.zig");
const route_arrays = @import("../core/route_arrays.zig");
const net_arrays = @import("../core/net_arrays.zig");
const pin_edge_arrays = @import("../core/pin_edge_arrays.zig");
const device_arrays = @import("../core/device_arrays.zig");
const adjacency_mod = @import("../core/adjacency.zig");
const layout_if = @import("../core/layout_if.zig");

const NetIdx = core_types.NetIdx;
const PinIdx = core_types.PinIdx;
const RouteArrays = route_arrays.RouteArrays;
const NetArrays = net_arrays.NetArrays;
const PinEdgeArrays = pin_edge_arrays.PinEdgeArrays;
const DeviceArrays = device_arrays.DeviceArrays;
const FlatAdjList = adjacency_mod.FlatAdjList;
const PdkConfig = layout_if.PdkConfig;

// ─── Maze Router ────────────────────────────────────────────────────────────
//
// Route layer index convention (see route_arrays.zig for the canonical doc):
//   0 = local interconnect (LI)
//   1 = metal 1 (M1)  — horizontal preferred
//   2 = metal 2 (M2)  — vertical preferred
//   3 = metal 3 (M3), 4 = metal 4 (M4), 5 = metal 5 (M5)
//
// PdkConfig arrays (min_width, min_spacing, …) are 0-indexed from M1,
// so route layer L maps to pdk index (L - 1) for metal layers (L >= 1).

/// Route layer indices used by the maze router.
const LAYER_M1: u8 = 1;
const LAYER_M2: u8 = 2;

/// Convert a route layer index (1-based for metals) to a PdkConfig array
/// index (0-based from M1). Caller must ensure layer >= 1.
fn pdkIndex(route_layer: u8) usize {
    return @as(usize, route_layer) - 1;
}

pub const MazeRouter = struct {
    allocator: std.mem.Allocator,
    routes: RouteArrays,
    grid_resolution: f32,

    pub fn init(allocator: std.mem.Allocator, grid_resolution: f32) !MazeRouter {
        return .{
            .allocator = allocator,
            .routes = try RouteArrays.init(allocator, 0),
            .grid_resolution = grid_resolution,
        };
    }

    /// Route all nets using channel-based routing.
    ///
    /// Each routable net is assigned a unique horizontal M1 channel offset
    /// placed **outside** the device M1 geometry clearance zone, preventing
    /// inter-net shorts between trunk lines and device M1 pads.
    ///
    /// The clearance zone is computed from the y-extent of all device pin
    /// positions plus the M1 pad radius (0.125 µm).  Trunks fan out
    /// symmetrically below and above this zone, separated by the M1 channel
    /// pitch (min_width + min_spacing).
    ///
    /// Per-pin routing uses a small M1 stub at the exact pin position plus an
    /// M2 L-shaped jog (horizontal to jog column, then vertical to trunk).
    /// This prevents M1 stubs from spanning across other-net pin positions,
    /// eliminating false LVS short detections at the pin level.
    pub fn routeAll(
        self: *MazeRouter,
        devices: *const DeviceArrays,
        nets: *const NetArrays,
        pins: *const PinEdgeArrays,
        adj: *const FlatAdjList,
        pdk: *const PdkConfig,
    ) !void {
        const n_nets = nets.len;

        // M1 channel pitch: width + spacing + 2*LVS_SNAP + margin.
        //
        // The in-engine LVS short detector (pointNearSegment) uses a 100 nm
        // snap tolerance around each route segment.  Two trunk lines must be
        // separated by at least  m1w + 2*lvs_snap + m1s  so that a pin lying
        // on one trunk cannot be flagged as reached by the adjacent trunk.
        // This is larger than the pure DRC spacing (m1w + m1s = 0.28 µm);
        // the LVS-safe pitch is 0.28 + 0.2 = 0.48 µm (+ a small margin).
        const m1w = pdk.min_width[pdkIndex(LAYER_M1)];
        const m1s = pdk.min_spacing[pdkIndex(LAYER_M1)];
        const m2w = pdk.min_width[pdkIndex(LAYER_M2)];
        const m2s = pdk.min_spacing[pdkIndex(LAYER_M2)];
        const lvs_snap_m1: f32 = 0.1;
        const pitch: f32 = @max(m1w + 2.0 * lvs_snap_m1 + m1s, 0.48) + 0.001;

        // ── Compute device pin extent (x and y) ─────────────────────────
        //
        // M1 pads are 250 nm (±125 nm) squares centred on pin positions.
        // Collect y-extent for trunk clearance and x-extent for jog columns.
        const m1_pad_half: f32 = 0.125;
        var dev_m1_ymin: f32 = std.math.inf(f32);
        var dev_m1_ymax: f32 = -std.math.inf(f32);
        var all_pin_xmax: f32 = -std.math.inf(f32);

        const n_pins: usize = @intCast(pins.len);
        for (0..n_pins) |i| {
            const d = pins.device[i].toInt();
            if (d >= devices.len) continue;
            const px = devices.positions[d][0] + pins.position[i][0];
            const py = devices.positions[d][1] + pins.position[i][1];
            dev_m1_ymin  = @min(dev_m1_ymin,  py - m1_pad_half);
            dev_m1_ymax  = @max(dev_m1_ymax,  py + m1_pad_half);
            all_pin_xmax = @max(all_pin_xmax, px + m1_pad_half);
        }

        // Trunk channels start outside the device M1 clearance zone.
        // half_clear must be at least pitch/2 so that the first below-channel
        // and first above-channel are at least `pitch` apart from each other,
        // preventing LVS snap from detecting cross-net shorts between adjacent
        // trunks that straddle the device zone.
        const half_clear = pitch * 0.5 + 0.001;
        const has_devices = dev_m1_ymin < dev_m1_ymax;
        const below_start: f32 = if (has_devices) dev_m1_ymin - half_clear else 0.0;
        const above_start: f32 = if (has_devices) dev_m1_ymax + half_clear else 0.0;

        // ── Absolute M2 jog columns ─────────────────────────────────────
        //
        // Each channel is assigned a dedicated x-track to the RIGHT of all
        // device pins.  This guarantees that M2 jogs from different nets are
        // always separated by at least m2_jog_pitch regardless of where pins
        // happen to be placed — avoiding the convergence that occurs when
        // jog positions are computed relative to per-pin x coordinates.
        //
        // The LVS short-detection snap tolerance (100 nm) is factored into
        // both the pitch between columns and the clearance from the last pin:
        //   • m2_jog_pitch: m2w + 2*snap + m2s + margin  (prevents adjacent
        //     columns from detecting each other's pins)
        //   • jog_clearance: m2w/2 + snap + m2s + margin  (places the first
        //     column outside the snap zone of the rightmost device pin)
        const lvs_snap: f32 = 0.1;
        const m2_jog_pitch: f32 = @max(m2w + 2.0 * lvs_snap + m2s, 0.48) + 0.001;
        const jog_clearance: f32 = m2w * 0.5 + lvs_snap + m2s + 0.001;
        // First jog column: jog_clearance clear of the rightmost pin pad edge.
        const jog_col_base: f32 = if (has_devices)
            all_pin_xmax + jog_clearance
        else
            m2w * 0.5;

        // ── Collect per-net pin y-positions for trunk clearance ──────────
        //
        // Trunk lines must not land within (half_m1w + lvs_snap) of any
        // device pin y-coordinate from a *different* net.  Same-net pins
        // are fine — the trunk is designed to collect them.
        const trunk_snap: f32 = m1w * 0.5 + lvs_snap + 0.001;
        const PinYEntry = struct { y: f32, net: u32 };
        var pin_y_entries: std.ArrayList(PinYEntry) = .empty;
        defer pin_y_entries.deinit(self.allocator);
        for (0..n_pins) |i| {
            const d = pins.device[i].toInt();
            if (d >= devices.len) continue;
            const py = devices.positions[d][1] + pins.position[i][1];
            const net_i: u32 = @intCast(pins.net[i].toInt());
            try pin_y_entries.append(self.allocator, .{ .y = py, .net = net_i });
        }

        // Assign channels: even below, odd above, spreading outward.
        // After computing the nominal trunk_y, bump it outward until it is
        // at least `trunk_snap` away from every device pin y-position.
        var channel: u32 = 0;
        var n: u32 = 0;
        while (n < n_nets) : (n += 1) {
            const net_pins = adj.pinsOnNet(NetIdx.fromInt(n));
            if (net_pins.len < 2) continue;

            const extra: f32 = @as(f32, @floatFromInt(channel / 2)) * pitch;
            var trunk_y: f32 = if (channel % 2 == 0)
                below_start - extra
            else
                above_start + extra;

            // Bump trunk_y outward until it is at least trunk_snap clear of
            // every device pin that belongs to a *different* net.
            // Below channels bump further down; above channels bump further up.
            const going_below = (channel % 2 == 0);
            var bump_iters: u32 = 0;
            while (bump_iters < 512) : (bump_iters += 1) {
                var clear = true;
                for (pin_y_entries.items) |entry| {
                    if (entry.net == n) continue; // same net: trunk may touch own pins
                    if (@abs(trunk_y - entry.y) < trunk_snap) {
                        clear = false;
                        break;
                    }
                }
                if (clear) break;
                if (going_below) {
                    trunk_y -= pitch;
                } else {
                    trunk_y += pitch;
                }
            }

            // Absolute x position for this channel's M2 jog column.
            const jog_col_x: f32 = jog_col_base +
                @as(f32, @floatFromInt(channel)) * m2_jog_pitch;

            try self.routeNet(n, devices, pins, net_pins, pdk, trunk_y, jog_col_x, channel);
            channel += 1;
        }
    }

    /// Route a single net using channel routing with an absolute jog column.
    ///
    /// Topology (per pin):
    ///   Pin stub:   M1 ±half_m1w centred on pin_x at raw_py
    ///   M2 bridge:  short M2 vertical from raw_py to m2_jog_y at pin_x
    ///   M2 horiz:   M2 horizontal at m2_jog_y from pin_x to jog_col_x
    ///   M2 vert:    M2 vertical at jog_col_x from m2_jog_y to trunk_y
    ///   Trunk:      M1 horizontal at trunk_y
    ///
    /// Each net's M2 horizontals are offset from raw_py by channel * m2_pitch,
    /// preventing M2 shorts when multiple nets share the same pin y-coordinate.
    /// Route a single net: M1 trunk + direct M2 vertical drops per pin.
    ///
    /// Topology (per pin):
    ///   Pin stub:   M1 ±half_m1w centred on pin_x at pin_y
    ///   M2 drop:    M2 vertical from (pin_x, pin_y) to (pin_x, trunk_y)
    ///   Trunk:      M1 horizontal at trunk_y spanning all pin x positions
    ///
    /// This avoids M2 horizontals entirely, eliminating cross-net M2 shorts
    /// that occur when horizontal jogs cross other nets' vertical columns.
    fn routeNet(
        self: *MazeRouter,
        net: u32,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        net_pins: []const PinIdx,
        pdk: *const PdkConfig,
        trunk_y: f32,
        _: f32, // jog_col_x — unused with direct-drop topology
        _: u32, // channel — unused with direct-drop topology
    ) !void {
        const m1w = pdk.min_width[pdkIndex(LAYER_M1)];
        const m2w = pdk.min_width[pdkIndex(LAYER_M2)];
        const net_idx = NetIdx.fromInt(net);
        const half_m1w = m1w * 0.5;

        // Find x-extent of pins to anchor the trunk.
        var min_x: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        for (net_pins) |pin| {
            const d = pins.device[pin.toInt()].toInt();
            if (d >= devices.len) continue;
            const px = devices.positions[d][0] + pins.position[pin.toInt()][0];
            if (px < min_x) min_x = px;
            if (px > max_x) max_x = px;
        }

        // M1 trunk at trunk_y spanning all pins.
        if (max_x > min_x) {
            try self.routes.append(LAYER_M1, min_x, trunk_y, max_x, trunk_y, m1w, net_idx);
        }

        // Per-pin connections: M1 stub + direct M2 vertical drop to trunk.
        for (net_pins) |pin| {
            const d = pins.device[pin.toInt()].toInt();
            if (d >= devices.len) continue;
            const px = devices.positions[d][0] + pins.position[pin.toInt()][0];
            const raw_py = devices.positions[d][1] + pins.position[pin.toInt()][1];

            if (raw_py != trunk_y) {
                // Small M1 pin stub — contact pad at the device terminal.
                try self.routes.append(LAYER_M1,
                    px - half_m1w, raw_py,
                    px + half_m1w, raw_py,
                    m1w, net_idx);

                // Direct M2 vertical drop from pin to trunk.
                try self.routes.append(LAYER_M2,
                    px, raw_py, px, trunk_y, m2w, net_idx);
            }
        }
    }

    pub fn getRoutes(self: *const MazeRouter) *const RouteArrays {
        return &self.routes;
    }

    pub fn deinit(self: *MazeRouter) void {
        self.routes.deinit();
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "MazeRouter init and deinit" {
    var router = try MazeRouter.init(std.testing.allocator, 0.005);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}
