const std = @import("std");
const device_arrays = @import("../core/device_arrays.zig");
const route_arrays = @import("../core/route_arrays.zig");
const layout_if = @import("../core/layout_if.zig");
const core_types = @import("../core/types.zig");
const records = @import("records.zig");

const pin_edge_arrays = @import("../core/pin_edge_arrays.zig");

const DeviceArrays = device_arrays.DeviceArrays;
const PinEdgeArrays = pin_edge_arrays.PinEdgeArrays;
const RouteArrays = route_arrays.RouteArrays;
const NetIdx = core_types.NetIdx;
const PdkConfig = layout_if.PdkConfig;
const GdsLayer = layout_if.GdsLayer;
const LayerTable = layout_if.LayerTable;

// ─── GDSII Export ───────────────────────────────────────────────────────────

// ─── Geometry constants (sky130, database units = nm) ────────────────────────
//
// These are absolute dimensions in database units (1 db unit = 1 nm for
// sky130 with db_unit = 0.001 µm).  Values are conservative (rounded up from
// sky130 DRC minimums) to ensure DRC-clean output.

/// Source/drain diffusion extension beyond the gate edge (min 250 nm).
const sd_extension: i32 = 260;

/// Poly extension beyond diffusion edges in the width direction (min 130 nm).
const poly_extension: i32 = 150;

/// LICON contact size (170 x 170 nm).
const licon_size: i32 = 170;

/// LICON enclosure by LI1 metal (min 80 nm).
const licon_li_enc: i32 = 90;

/// NSDM/PSDM implant enclosure of diffusion (min 125 nm).
const implant_enc: i32 = 130;

/// NWELL enclosure of diffusion for PMOS (min 180 nm).
const nwell_enc: i32 = 200;

// ── Gate contact pad constants ──
/// Width of the gate contact poly pad extending left from channel (db units).
/// Must be large enough that the NPC rectangle (licon_size/2 + npc_enc = 195 nm
/// from gate_cx) does not encroach into the diffusion region at x=0.
/// gate_pad_width/2 >= licon_size/2 + npc_enc → gate_pad_width >= 390.
const gate_pad_width: i32 = 400;
/// Minimum height of the gate contact poly pad (db units).
const gate_pad_min_height: i32 = 340;
/// NPC (Nitride Poly Cut) enclosure of poly LICON (min 100 nm).
const npc_enc: i32 = 110;

// ── Body tap constants ──
/// Diffusion size for body tap (substrate/well contact).
const tap_diff_size: i32 = 340;
/// Gap between device active region and body tap.
const tap_gap: i32 = 270;


// ── M1 pad constants ──
/// M1 pad half-size over MCON (provides route landing area).
const m1_pad_enc: i32 = 40;

/// M1 minimum spacing (sky130 metal1).  Used to compute effective device
/// geometry dimensions that ensure adjacent M1 landing pads are DRC-clean.
const m1_min_spacing: i32 = 140;

/// Compute effective sd_extension ensuring vertical M1 pad DRC clearance
/// between adjacent S/D contacts.  Returns the standard constant when it
/// already satisfies spacing, or a larger value for short-channel devices.
///
/// The result is always rounded up to an even number so that
/// `@divTrunc(sd_ext, 2)` gives an exact integer and no sub-nm truncation
/// error reduces the inter-pad gap below min_spacing.
fn effectiveSdExtension(l: i32) i32 {
    const m1_half = @divTrunc(licon_size, 2) + m1_pad_enc;
    const min_for_drc = 2 * m1_half + m1_min_spacing - l;
    const raw = @max(sd_extension, min_for_drc);
    // Round up to even so divTrunc(raw, 2) is exact.
    return raw + @mod(raw, 2);
}

/// Compute effective gate_pad_width ensuring horizontal M1 pad DRC clearance
/// between the gate pad and the nearest S/D pad.  `finger_w` is the per-finger
/// gate width (== total width for single-finger devices).
///
/// The result is always rounded up to an even number so that
/// `@divTrunc(gate_pad_w, 2)` gives an exact integer and no sub-nm
/// truncation error reduces the gate-to-S/D pad gap below min_spacing.
fn effectiveGatePadWidth(finger_w: i32) i32 {
    const m1_half = @divTrunc(licon_size, 2) + m1_pad_enc;
    const min_for_drc = 2 * (2 * m1_half + m1_min_spacing) - finger_w;
    const raw = @max(gate_pad_width, min_for_drc);
    // Round up to even so divTrunc(raw, 2) is exact.
    return raw + @mod(raw, 2);
}

pub const GdsiiWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GdsiiWriter {
        return .{ .allocator = allocator };
    }

    /// Export the layout to a GDSII file.
    ///
    /// `net_names` is an optional slice of net name strings, indexed by net
    /// index.  When provided (along with routes), TEXT labels are written on
    /// pin-purpose layers so that KLayout LVS can identify nets.
    pub fn exportLayout(
        self: *GdsiiWriter,
        path: []const u8,
        devices: *const DeviceArrays,
        routes: ?*const RouteArrays,
        pdk: *const PdkConfig,
        cell_name: []const u8,
        net_names: ?[]const []const u8,
        pins: ?*const PinEdgeArrays,
    ) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;

        // Write GDSII header
        try self.writeHeader(writer, pdk, cell_name);

        // Write device geometry (per-device-type rectangles)
        try self.writeDevices(writer, devices, pdk);

        // Write route segments as paths
        if (routes) |r| {
            try self.writeRoutes(writer, r, pdk);
        }

        // Write TEXT labels for net identification (needed by KLayout LVS).
        // Always call writeNetLabels when net_names exists — Pass 1 is a no-op
        // if routes is null/empty, but Pass 2 (device pin labels) still runs.
        if (net_names) |names| {
            try writeNetLabels(writer, routes, pdk, names, pins, devices);
        }

        // Write footer
        try self.writeFooter(writer);

        // Flush remaining buffered data
        try writer.flush();
    }

    fn writeHeader(self: *GdsiiWriter, writer: anytype, pdk: *const PdkConfig, cell_name: []const u8) !void {
        _ = self;
        // HEADER record (version 600)
        try records.writeInt16Record(writer, records.RecordType.HEADER, 600);

        // BGNLIB record (creation/modification timestamps — 12 int16 values)
        const timestamp = [_]u8{ 0x00, 0x01 } ** 12;
        try records.writeRecord(writer, records.RecordType.BGNLIB, &timestamp);

        // LIBNAME
        try records.writeStringRecord(writer, records.RecordType.LIBNAME, "spout_layout");

        // UNITS — two 8-byte GDSII reals:
        //   1) User units per database unit (db_unit in micrometres, e.g. 0.001)
        //   2) Database unit in metres (db_unit * 1e-6)
        // These tell Magic how to interpret the integer coordinates.
        const db_unit_um: f64 = @floatCast(pdk.db_unit); // e.g. 0.001 µm
        const db_unit_m: f64 = db_unit_um * 1.0e-6; // e.g. 1e-9 m
        var units_data: [16]u8 = undefined;
        const uu_bytes = records.toGdsiiReal(db_unit_um);
        const db_bytes = records.toGdsiiReal(db_unit_m);
        @memcpy(units_data[0..8], &uu_bytes);
        @memcpy(units_data[8..16], &db_bytes);
        try records.writeRecord(writer, records.RecordType.UNITS, &units_data);

        // BGNSTR (creation/modification timestamps)
        try records.writeRecord(writer, records.RecordType.BGNSTR, &timestamp);

        // STRNAME (padded to even length by writeStringRecord)
        const name = if (cell_name.len > 0) cell_name else "TOP";
        try records.writeStringRecord(writer, records.RecordType.STRNAME, name);
    }

    fn writeDevices(self: *GdsiiWriter, writer: anytype, devices: *const DeviceArrays, pdk: *const PdkConfig) !void {
    @setRuntimeSafety(false);
        const n: usize = @intCast(devices.len);
        const scale: f32 = 1.0 / pdk.db_unit;

        // Collect implant and well rects for post-loop merge.
        var nwell_rects: std.ArrayListUnmanaged([4]i32) = .empty;
        defer nwell_rects.deinit(self.allocator);
        var nsdm_rects: std.ArrayListUnmanaged([4]i32) = .empty;
        defer nsdm_rects.deinit(self.allocator);
        var psdm_rects: std.ArrayListUnmanaged([4]i32) = .empty;
        defer psdm_rects.deinit(self.allocator);

        // Track which device indices have already been emitted as part of a
        // common-centroid pair so they are not emitted a second time.
        var cc_emitted = try self.allocator.alloc(bool, n);
        defer self.allocator.free(cc_emitted);
        @memset(cc_emitted, false);

        for (0..n) |i| {
            const x: i32 = @intFromFloat(@round(devices.positions[i][0] * scale));
            const y: i32 = @intFromFloat(@round(devices.positions[i][1] * scale));

            // Convert device params to microns using the PDK's param_to_um
            // factor.  Fall back to the dimensions array (already in microns)
            // when the param is zero.
            //
            // For MOSFETs with mult > 1 (the SPICE `m` parameter), the
            // effective gate width is W * mult.  KLayout LVS extracts the
            // physical gate width from the layout geometry, so we must draw
            // the device at the effective width to match the schematic.
            const p2um = pdk.param_to_um;
            const raw_w = devices.params[i].w;
            const raw_l = devices.params[i].l;
            const mult: f32 = @floatFromInt(@max(@as(u16, 1), devices.params[i].mult));

            const base_w_um = if (raw_w > 0.0) raw_w * p2um else devices.dimensions[i][0];
            const dev_l_um = if (raw_l > 0.0) raw_l * p2um else devices.dimensions[i][1];
            const dev_w_um = base_w_um * mult;

            const w: i32 = @intFromFloat(@round(dev_w_um * scale));
            const l: i32 = @intFromFloat(@round(dev_l_um * scale));

            const fingers: u16 = @max(@as(u16, 1), devices.params[i].fingers);

            const ring_width_db: i32 = @intFromFloat(@round(pdk.guard_ring_width / pdk.db_unit));
            const ring_spacing_db: i32 = @intFromFloat(@round(pdk.guard_ring_spacing / pdk.db_unit));

            switch (devices.types[i]) {
                .nmos, .pmos => {
                    if (cc_emitted[i]) continue;

                    const is_pmos = (devices.types[i] == .pmos);

                    // Common-centroid detection: look for a later device at the same
                    // Y position with matching W, L, type, and fingers >= 2.
                    var cc_partner: ?usize = null;
                    if (fingers >= 2) {
                        for (i + 1..n) |j| {
                            if (cc_emitted[j]) continue;
                            if (devices.types[j] != devices.types[i]) continue;
                            const yj: i32 = @intFromFloat(@round(devices.positions[j][0] * scale));
                            const yj_y: i32 = @intFromFloat(@round(devices.positions[j][1] * scale));
                            if (yj_y != y) continue;
                            _ = yj;
                            const raw_wj = devices.params[j].w;
                            const raw_lj = devices.params[j].l;
                            const multj: f32 = @floatFromInt(@max(@as(u16, 1), devices.params[j].mult));
                            const base_wj_um = if (raw_wj > 0.0) raw_wj * p2um else devices.dimensions[j][0];
                            const dev_lj_um = if (raw_lj > 0.0) raw_lj * p2um else devices.dimensions[j][1];
                            const wj: i32 = @intFromFloat(@round(base_wj_um * multj * scale));
                            const lj: i32 = @intFromFloat(@round(dev_lj_um * scale));
                            const fj: u16 = @max(@as(u16, 1), devices.params[j].fingers);
                            if (wj == w and lj == l and fj == fingers) {
                                cc_partner = j;
                                break;
                            }
                        }
                    }

                    if (cc_partner) |j| {
                        const xj: i32 = @intFromFloat(@round(devices.positions[j][0] * scale));
                        try writeCommonCentroid(writer, pdk.layers, is_pmos, x, y, w, l, fingers, xj, ring_width_db, ring_spacing_db);
                        cc_emitted[i] = true;
                        cc_emitted[j] = true;

                        // Collect implant rects for both devices (treated as one pair).
                        const x_lo = @min(x, xj);
                        const x_hi = @max(x, xj) + w;
                        const impl_rect = computeImplantRect(x_lo, x_hi, y, l, fingers);
                        if (is_pmos) {
                            try psdm_rects.append(self.allocator, impl_rect);
                            try nwell_rects.append(self.allocator, computeNwellRect(x_lo, x_hi, y, l, fingers));
                        } else {
                            try nsdm_rects.append(self.allocator, impl_rect);
                        }
                    } else {
                        try writeMosfetGeometryFingered(writer, pdk.layers, is_pmos, x, y, w, l, fingers, ring_width_db, ring_spacing_db);

                        // Collect implant rect for later merge.
                        const impl_rect = computeImplantRect(x, x + w, y, l, fingers);
                        if (is_pmos) {
                            try psdm_rects.append(self.allocator, impl_rect);
                            try nwell_rects.append(self.allocator, computeNwellRect(x, x + w, y, l, fingers));
                        } else {
                            try nsdm_rects.append(self.allocator, impl_rect);
                        }
                    }
                },
                .res, .cap, .ind, .subckt,
                .diode, .bjt_npn, .bjt_pnp, .jfet_n, .jfet_p,
                .res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal,
                .cap_mim, .cap_mom, .cap_pip, .cap_gate => try writePassiveGeometry(writer, pdk.layers, x, y, w, l),
            }
        }

        // Emit NWELL, NSDM, PSDM rects individually (no merge).
        // Merging used bounding-box union which added phantom area and caused
        // KLayout LVS to short unrelated nets through a shared NWELL polygon.
        // GDS tools handle overlapping polygons correctly on their own.
        for (nwell_rects.items) |r| {
            try writeRect(writer, pdk.layers.nwell, r[0], r[1], r[2], r[3]);
        }
        for (nsdm_rects.items) |r| {
            try writeRect(writer, pdk.layers.nsdm, r[0], r[1], r[2], r[3]);
        }
        for (psdm_rects.items) |r| {
            try writeRect(writer, pdk.layers.psdm, r[0], r[1], r[2], r[3]);
        }
    }

    fn writeRoutes(self: *GdsiiWriter, writer: anytype, routes: *const RouteArrays, pdk: *const PdkConfig) !void {
        _ = self;
        const n: usize = @intCast(routes.len);
        const scale: f32 = 1.0 / pdk.db_unit;

        var prev_layer_idx: ?u8 = null;

        for (0..n) |i| {
            const route_layer_idx = routes.layer[i];

            // Reset layer tracking at net boundaries to prevent cross-net
            // via generation.
            if (i > 0 and routes.net[i].toInt() != routes.net[i - 1].toInt()) {
                prev_layer_idx = null;
            }

            // Map route layer index to the correct PDK GDS layer:
            //   0 -> pdk.layers.li  (local interconnect)
            //   1 -> pdk.layers.metal[0]  (M1)
            //   2 -> pdk.layers.metal[1]  (M2)
            //   ...
            const gds_layer = mapRouteLayer(pdk.layers, route_layer_idx);

            // Compute segment endpoints early so the zero-length check can
            // gate both via and path writing.
            const sx: i32 = @intFromFloat(@round(routes.x1[i] * scale));
            const sy: i32 = @intFromFloat(@round(routes.y1[i] * scale));
            const ex: i32 = @intFromFloat(@round(routes.x2[i] * scale));
            const ey: i32 = @intFromFloat(@round(routes.y2[i] * scale));
            const is_zero_length = (sx == ex and sy == ey);

            // Write via rectangles at layer transitions.  The via must be
            // centred on the point shared by both segments.  For an upward
            // transition (M1→M2) the current segment's startpoint is on the
            // M2 jog — use (x1,y1) of the current segment.  For a downward
            // transition (M2→M1) the previous segment's endpoint is the jog
            // landing — use (x2,y2) of the previous segment.
            //
            // In addition to the via cut, we write metal landing pads on
            // both the lower and upper metal layers so that each metal
            // properly encloses the via (via_width + 2 * min_enclosure).
            // Without these pads the narrow route PATHs (min_width) give
            // zero enclosure and KLayout LVS extraction fails to recognise
            // the connection.
            // Via detection fires for ALL layer transitions, including zero-length
            // transition markers. (Zero-length segments mark via positions emitted
            // by commitPath; gating on !is_zero_length caused the second via of any
            // M2/M3 segment to be silently dropped.)
            if (prev_layer_idx) |prev_idx| {
                if (prev_idx != route_layer_idx) {
                    const lo = @min(prev_idx, route_layer_idx);
                    const hi = @max(prev_idx, route_layer_idx);
                    const via_layer = mapViaLayer(pdk.layers, prev_idx, route_layer_idx);
                    if (via_layer.layer != 0 and hi - lo == 1) {
                        // Via pair index: li↔M1 = 0, M1↔M2 = 1, M2↔M3 = 2 …
                        const via_pair: usize = lo;

                        // Use PDK-specified via cut size (not route width).
                        const via_half: i32 = @intFromFloat(@round(pdk.via_width[via_pair] * scale * 0.5));

                        const use_prev_end = (prev_idx > route_layer_idx);
                        const vx: i32 = if (use_prev_end)
                            @intFromFloat(@round(routes.x2[i - 1] * scale))
                        else
                            @intFromFloat(@round(routes.x1[i] * scale));
                        const vy: i32 = if (use_prev_end)
                            @intFromFloat(@round(routes.y2[i - 1] * scale))
                        else
                            @intFromFloat(@round(routes.y1[i] * scale));

                        // Via cut rectangle.
                        try writeRect(writer, via_layer, vx - via_half, vy - via_half, vx + via_half, vy + via_half);

                        // Metal landing pads on both lower and upper metal
                        // layers — ensure each metal encloses the via by
                        // min_enclosure on each side (via_width + 2 *
                        // min_enclosure).  Each pad must also satisfy the
                        // layer's min_width rule, which can be larger than
                        // the enclosure-derived size (e.g. M2 min_width =
                        // 0.30µm vs via1 enclosure pad = 0.23µm).
                        const enc: i32 = @intFromFloat(@round(pdk.min_enclosure[via_pair] * scale));
                        const enc_pad_half: i32 = via_half + enc;
                        const lower_layer = mapRouteLayer(pdk.layers, lo);
                        const upper_layer = mapRouteLayer(pdk.layers, hi);
                        // Each landing pad must be at least min_width/2 on its layer.
                        // Convert route-layer indices to core PDK indices (0=M1).
                        // BUGS.md S0-3: when lo==0 the lower layer is LI, whose
                        // min_width (0.17 µm on sky130) differs from M1's (0.14 µm).
                        // A saturating subtract gave the wrong pad size for LI.
                        const lo_pdk = @as(usize, lo) -| 1;
                        const hi_pdk = @as(usize, hi) -| 1;
                        const lo_mw_half: i32 = if (lo == 0 and pdk.li_min_width > 0.0)
                            @intFromFloat(@round(pdk.li_min_width * scale * 0.5))
                        else
                            @intFromFloat(@round(pdk.min_width[lo_pdk] * scale * 0.5));
                        const hi_mw_half: i32 = @intFromFloat(@round(pdk.min_width[hi_pdk] * scale * 0.5));
                        const lo_pad_half: i32 = @max(enc_pad_half, lo_mw_half);
                        const hi_pad_half: i32 = @max(enc_pad_half, hi_mw_half);
                        try writeRect(writer, lower_layer, vx - lo_pad_half, vy - lo_pad_half, vx + lo_pad_half, vy + lo_pad_half);
                        try writeRect(writer, upper_layer, vx - hi_pad_half, vy - hi_pad_half, vx + hi_pad_half, vy + hi_pad_half);
                    }
                }
            }
            prev_layer_idx = route_layer_idx;

            // Skip writing path if the layer maps to zero (unmapped).
            if (gds_layer.layer == 0) continue;

            // Skip zero-length segments (same start/end point) — these produce
            // degenerate PATH shapes that confuse KLayout LVS extraction.
            if (is_zero_length) continue;

            // PATH
            try records.writeRecord(writer, records.RecordType.PATH, &[_]u8{});

            // LAYER
            try records.writeInt16Record(writer, records.RecordType.LAYER, @intCast(gds_layer.layer));

            // DATATYPE
            try records.writeInt16Record(writer, records.RecordType.DATATYPE, @intCast(gds_layer.datatype));

            // WIDTH — clamp to layer min_width so routes that end up on
            // higher layers (e.g. M3) are never narrower than the DRC rule.
            var w: i32 = @intFromFloat(@round(routes.width[i] * scale));
            if (route_layer_idx >= 1) {
                const pdk_idx = @as(usize, route_layer_idx) - 1;
                if (pdk_idx < pdk.min_width.len) {
                    const mw: i32 = @intFromFloat(@round(pdk.min_width[pdk_idx] * scale));
                    w = @max(w, mw);
                }
            }
            try records.writeInt32Record(writer, records.RecordType.WIDTH, w);

            // XY (2 points)
            var xy_buf: [16]u8 = undefined;
            writeI32Be(xy_buf[0..4], sx);
            writeI32Be(xy_buf[4..8], sy);
            writeI32Be(xy_buf[8..12], ex);
            writeI32Be(xy_buf[12..16], ey);
            try records.writeRecord(writer, records.RecordType.XY, &xy_buf);

            // ENDEL
            try records.writeRecord(writer, records.RecordType.ENDEL, &[_]u8{});
        }
    }

    fn writeFooter(self: *GdsiiWriter, writer: anytype) !void {
        _ = self;
        // ENDSTR
        try records.writeRecord(writer, records.RecordType.ENDSTR, &[_]u8{});
        // ENDLIB
        try records.writeRecord(writer, records.RecordType.ENDLIB, &[_]u8{});
    }

    /// Write a SREF (structure reference / instance) element into an already-open
    /// structure.  The caller must have written BGNSTR/STRNAME already and must
    /// write ENDSTR after.
    ///
    /// `x_db`, `y_db`     – placement origin in database units.
    /// `angle_deg`        – counter-clockwise rotation in degrees (0.0 = no rotation).
    /// `magnification`    – scaling factor (1.0 = no scaling).
    /// `mirror_x`         – reflect about the X axis before rotation.
    pub fn writeSref(
        writer: anytype,
        cell_name: []const u8,
        x_db: i32,
        y_db: i32,
        angle_deg: f64,
        magnification: f64,
        mirror_x: bool,
    ) !void {
        // SREF element start (no payload)
        try records.writeRecord(writer, records.RecordType.SREF, &[_]u8{});

        // SNAME — the cell being referenced
        try records.writeStringRecord(writer, records.RecordType.SNAME, cell_name);

        // STRANS / AMAG / AANGLE — only when the transform is non-identity
        if (mirror_x or magnification != 1.0 or angle_deg != 0.0) {
            // STRANS flags: bit 15 = mirror about X axis
            const strans_flags: u16 = if (mirror_x) 0x8000 else 0x0000;
            try records.writeInt16Record(writer, records.RecordType.STRANS, @bitCast(strans_flags));

            if (magnification != 1.0) {
                const mag_bytes = records.toGdsiiReal(magnification);
                try records.writeRecord(writer, records.RecordType.AMAG, &mag_bytes);
            }

            if (angle_deg != 0.0) {
                const angle_bytes = records.toGdsiiReal(angle_deg);
                try records.writeRecord(writer, records.RecordType.AANGLE, &angle_bytes);
            }
        }

        // XY — single coordinate pair (8 bytes, two big-endian i32)
        var xy_buf: [8]u8 = undefined;
        std.mem.writeInt(i32, xy_buf[0..4], x_db, .big);
        std.mem.writeInt(i32, xy_buf[4..8], y_db, .big);
        try records.writeRecord(writer, records.RecordType.XY, &xy_buf);

        // ENDEL
        try records.writeRecord(writer, records.RecordType.ENDEL, &[_]u8{});
    }

    /// Export a hierarchical GDS with two cells:
    ///   1. `user_cell_name`  — the analog circuit geometry (identical to flat export).
    ///   2. `top_cell_name`   — a wrapper cell that contains:
    ///        • SREF to `template_cell_name` at the origin (0, 0).
    ///        • SREF to `user_cell_name` at `user_area_origin` (µm).
    ///
    /// The template cell itself is NOT written here; it is expected to exist in a
    /// separately-loaded template GDS file.  This output GDS should be merged with
    /// that file in the sign-off flow.
    ///
    /// `user_area_origin` – [x, y] offset in **micrometres** where the user circuit
    ///                      lands within the template coordinate system.
    /// `db_unit`          – database unit in **metres** (e.g. 1e-9 for sky130 with
    ///                      1 nm resolution).  Used to convert µm → integer db units.
    pub fn exportLayoutHierarchical(
        self: *GdsiiWriter,
        path: []const u8,
        devices: *const DeviceArrays,
        routes: ?*const RouteArrays,
        pdk: *const PdkConfig,
        user_cell_name: []const u8,
        top_cell_name: []const u8,
        template_cell_name: []const u8,
        user_area_origin: [2]f32,
        net_names: ?[]const []const u8,
        pins: ?*const PinEdgeArrays,
    ) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var write_buffer: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buffer);
        const writer = &file_writer.interface;

        // ── Library header (HEADER, BGNLIB, LIBNAME, UNITS) ──────────────────
        // We reuse writeHeader but it also emits BGNSTR+STRNAME for the first
        // cell.  Instead we replicate only the lib-level records here so we
        // can open two separate structure blocks ourselves.
        const timestamp = [_]u8{ 0x00, 0x01 } ** 12;

        try records.writeInt16Record(writer, records.RecordType.HEADER, 600);
        try records.writeRecord(writer, records.RecordType.BGNLIB, &timestamp);
        try records.writeStringRecord(writer, records.RecordType.LIBNAME, "spout_layout");

        const db_unit_um: f64 = @floatCast(pdk.db_unit);
        const db_unit_m: f64 = db_unit_um * 1.0e-6;
        var units_data: [16]u8 = undefined;
        @memcpy(units_data[0..8], &records.toGdsiiReal(db_unit_um));
        @memcpy(units_data[8..16], &records.toGdsiiReal(db_unit_m));
        try records.writeRecord(writer, records.RecordType.UNITS, &units_data);

        // ── Cell 1: user circuit geometry ─────────────────────────────────────
        try records.writeRecord(writer, records.RecordType.BGNSTR, &timestamp);
        const uname = if (user_cell_name.len > 0) user_cell_name else "USER";
        try records.writeStringRecord(writer, records.RecordType.STRNAME, uname);

        try self.writeDevices(writer, devices, pdk);
        if (routes) |r| {
            try self.writeRoutes(writer, r, pdk);
        }
        if (net_names) |names| {
            try writeNetLabels(writer, routes, pdk, names, pins, devices);
        }

        try records.writeRecord(writer, records.RecordType.ENDSTR, &[_]u8{});

        // ── Cell 2: top wrapper — two SREFs ───────────────────────────────────
        try records.writeRecord(writer, records.RecordType.BGNSTR, &timestamp);
        const tname = if (top_cell_name.len > 0) top_cell_name else "TOP";
        try records.writeStringRecord(writer, records.RecordType.STRNAME, tname);

        // SREF to template at origin
        try GdsiiWriter.writeSref(writer, template_cell_name, 0, 0, 0.0, 1.0, false);

        // SREF to user circuit at user_area_origin (µm → db units)
        // db_unit is µm per db unit (pdk.db_unit), so: db = µm / db_unit_um
        const x_db: i32 = @intFromFloat(@round(@as(f64, user_area_origin[0]) / db_unit_um));
        const y_db: i32 = @intFromFloat(@round(@as(f64, user_area_origin[1]) / db_unit_um));
        try GdsiiWriter.writeSref(writer, uname, x_db, y_db, 0.0, 1.0, false);

        try records.writeRecord(writer, records.RecordType.ENDSTR, &[_]u8{});

        // ── End of library ────────────────────────────────────────────────────
        try records.writeRecord(writer, records.RecordType.ENDLIB, &[_]u8{});

        try writer.flush();
    }

    pub fn deinit(self: *GdsiiWriter) void {
        _ = self;
    }
};

// ─── Per-device-type geometry writers ────────────────────────────────────────

/// Write MOSFET geometry: continuous diffusion, overlapping poly gate, implant,
/// LICON contacts, LI1 pads, and MCON vias for M1 route attachment.
///
/// The full contact stack from diffusion to M1 is:
///   diffusion -> LICON -> LI1 -> MCON -> M1
///
/// The key requirement for KLayout LVS is that poly and diffusion **overlap** in
/// the channel region so that `poly.and(diff)` has non-zero area (= the gate).
///
///   `is_pmos` - true for PMOS (use psdm + nwell), false for NMOS (use nsdm).
///   `x, y`    - device origin in database units (bottom-left of channel).
///   `w`       - device width  in database units (gate width, x-direction).
///   `l`       - device length in database units (gate length / channel, y-direction).
fn writeMosfetGeometry(writer: anytype, layers: LayerTable, is_pmos: bool, x: i32, y: i32, w: i32, l: i32, ring_width: i32, ring_spacing: i32) !void {
    // Effective geometry: ensure M1 landing pads satisfy min_spacing.
    const eff_sd_ext = effectiveSdExtension(l);
    const eff_gate_w = effectiveGatePadWidth(w);

    // ── 1. DIFFUSION — one continuous rectangle spanning source + channel + drain ──
    // x-extent: [x, x + w]  (gate width)
    // y-extent: [y - eff_sd_ext, y + l + eff_sd_ext]
    try writeRect(writer, layers.diff, x, y - eff_sd_ext, x + w, y + l + eff_sd_ext);

    // ── 2. POLY — crosses over diffusion, extends beyond diff in x-direction ──
    // x-extent: [x - poly_extension, x + w + poly_extension]
    // y-extent: [y, y + l]  (channel region)
    // The intersection of poly and diff (the channel) is what LVS recognizes as the gate.
    try writeRect(writer, layers.poly, x - poly_extension, y, x + w + poly_extension, y + l);

    // ── 3. Implant (NSDM for NMOS, PSDM for PMOS) — emitted merged by writeDevices.

    // ── 4. LICON contacts — one in source region, one in drain region ──
    // Centre each contact in the S/D region.  Contact is licon_size x licon_size.
    const cx = x + @divTrunc(w, 2); // centre of gate width

    // Source contact (below gate)
    const src_cy = y - @divTrunc(eff_sd_ext, 2); // centre of source region
    try writeRect(writer, layers.licon, cx - @divTrunc(licon_size, 2), src_cy - @divTrunc(licon_size, 2), cx + @divTrunc(licon_size, 2), src_cy + @divTrunc(licon_size, 2));

    // Drain contact (above gate)
    const drn_cy = y + l + @divTrunc(eff_sd_ext, 2); // centre of drain region
    try writeRect(writer, layers.licon, cx - @divTrunc(licon_size, 2), drn_cy - @divTrunc(licon_size, 2), cx + @divTrunc(licon_size, 2), drn_cy + @divTrunc(licon_size, 2));

    // ── 5. LI1 metal pads over source and drain contacts ──
    // LI pad covers the contact with licon_li_enc enclosure on each side.
    const li_half = @divTrunc(licon_size, 2) + licon_li_enc;

    // Source LI pad
    try writeRect(writer, layers.li, cx - li_half, src_cy - li_half, cx + li_half, src_cy + li_half);

    // Drain LI pad
    try writeRect(writer, layers.li, cx - li_half, drn_cy - li_half, cx + li_half, drn_cy + li_half);

    // ── 6. MCON vias — connect LI1 pads up to M1 for route attachment ──
    // The full stack is: diffusion -> LICON -> LI1 -> MCON -> M1.
    // Without MCON, routes on M1 cannot reach the device terminals.
    // MCON contacts are placed at the same centres as the LICON contacts.
    // Size matches LICON (sky130 MCON min is 170 nm).
    const mcon_half = @divTrunc(licon_size, 2);

    // Source MCON
    try writeRect(writer, layers.mcon, cx - mcon_half, src_cy - mcon_half, cx + mcon_half, src_cy + mcon_half);

    // Drain MCON
    try writeRect(writer, layers.mcon, cx - mcon_half, drn_cy - mcon_half, cx + mcon_half, drn_cy + mcon_half);

    // ── 7. Gate contact pad — poly, LICON, NPC, LI, MCON, M1 ──
    // A poly pad extending LEFT from the channel provides the gate terminal
    // contact.  Placed outside the diffusion region so the LICON is a poly
    // contact (not a diff contact).  NPC layer is required for poly contacts.
    const gate_cx = x - @divTrunc(eff_gate_w, 2);
    const gate_cy = y + @divTrunc(l, 2);
    const m1_half = mcon_half + m1_pad_enc;

    // 7a. Gate poly pad
    try writeRect(writer, layers.poly, x - eff_gate_w, gate_cy - @divTrunc(gate_pad_min_height, 2), x, gate_cy + @divTrunc(gate_pad_min_height, 2));

    // 7b. Gate LICON (poly contact)
    try writeRect(writer, layers.licon, gate_cx - @divTrunc(licon_size, 2), gate_cy - @divTrunc(licon_size, 2), gate_cx + @divTrunc(licon_size, 2), gate_cy + @divTrunc(licon_size, 2));

    // 7c. NPC (Nitride Poly Cut) — required for poly contacts on sky130
    try writeRect(writer, layers.npc, gate_cx - @divTrunc(licon_size, 2) - npc_enc, gate_cy - @divTrunc(licon_size, 2) - npc_enc, gate_cx + @divTrunc(licon_size, 2) + npc_enc, gate_cy + @divTrunc(licon_size, 2) + npc_enc);

    // 7d. Gate LI pad
    try writeRect(writer, layers.li, gate_cx - li_half, gate_cy - li_half, gate_cx + li_half, gate_cy + li_half);

    // 7e. Gate MCON
    try writeRect(writer, layers.mcon, gate_cx - mcon_half, gate_cy - mcon_half, gate_cx + mcon_half, gate_cy + mcon_half);

    // 7f. Gate M1 pad
    try writeRect(writer, layers.metal[0], gate_cx - m1_half, gate_cy - m1_half, gate_cx + m1_half, gate_cy + m1_half);

    // ── 8. Body / substrate tap ──
    // NMOS: p+ diffusion tap in p-substrate (PSDM implant)
    // PMOS: n+ diffusion tap in n-well (NSDM implant)
    // x_tap = x (left edge of device), separate x-column from S/D contacts at cx.
    const x_tap = x;
    const body_cy = y - eff_sd_ext - tap_gap - @divTrunc(tap_diff_size, 2);
    const tap_half = @divTrunc(tap_diff_size, 2);

    // 8a. Body tap diffusion — uses the tap layer (e.g. 65/44 on SKY130)
    // which is distinct from device diffusion (65/20).  KLayout LVS
    // recognises tap-layer shapes as substrate/well contacts.
    const tap_layer = if (layers.tap.layer != 0) layers.tap else layers.diff;
    try writeRect(writer, tap_layer, x_tap - tap_half, body_cy - tap_half, x_tap + tap_half, body_cy + tap_half);

    // 8b. Body tap implant (PSDM for NMOS substrate, NSDM for PMOS well)
    const body_impl_layer = if (is_pmos) layers.nsdm else layers.psdm;
    try writeRect(writer, body_impl_layer, x_tap - tap_half - implant_enc, body_cy - tap_half - implant_enc, x_tap + tap_half + implant_enc, body_cy + tap_half + implant_enc);

    // 8c. Body tap LICON
    try writeRect(writer, layers.licon, x_tap - @divTrunc(licon_size, 2), body_cy - @divTrunc(licon_size, 2), x_tap + @divTrunc(licon_size, 2), body_cy + @divTrunc(licon_size, 2));

    // 8d. Body tap LI pad
    try writeRect(writer, layers.li, x_tap - li_half, body_cy - li_half, x_tap + li_half, body_cy + li_half);

    // 8e. Body tap MCON
    try writeRect(writer, layers.mcon, x_tap - mcon_half, body_cy - mcon_half, x_tap + mcon_half, body_cy + mcon_half);

    // 8f. Body tap M1 pad
    try writeRect(writer, layers.metal[0], x_tap - m1_half, body_cy - m1_half, x_tap + m1_half, body_cy + m1_half);

    // ── 9. M1 pads over source/drain MCON (route landing area) ──
    try writeRect(writer, layers.metal[0], cx - m1_half, src_cy - m1_half, cx + m1_half, src_cy + m1_half);

    try writeRect(writer, layers.metal[0], cx - m1_half, drn_cy - m1_half, cx + m1_half, drn_cy + m1_half);

    // ── 10. NWELL for PMOS — emitted merged by writeDevices.

    // ── 11. Guard ring — surrounds device + body tap ──
    try writeGuardRing(
        writer,
        layers,
        is_pmos,
        x - eff_gate_w,
        body_cy - tap_half,
        x + w,
        y + l + eff_sd_ext,
        ring_width,
        ring_spacing,
    );
}

const FingerLayout = struct {
    finger_count: u16,
    finger_width: i32,
    diffusion_region_height: i32,
    total_diffusion_height: i32,

    fn init(total_width: i32, gate_length: i32, fingers: u16) FingerLayout {
        const finger_count = @max(@as(u16, 1), fingers);
        const finger_width = @max(1, @divTrunc(total_width, finger_count));
        const diffusion_region_height = effectiveSdExtension(gate_length);
        const total_diffusion_height = @as(i32, finger_count) * gate_length +
            (@as(i32, finger_count) + 1) * diffusion_region_height;

        return .{
            .finger_count = finger_count,
            .finger_width = finger_width,
            .diffusion_region_height = diffusion_region_height,
            .total_diffusion_height = total_diffusion_height,
        };
    }
};

fn writeMosfetGeometryFingered(
    writer: anytype,
    layers: LayerTable,
    is_pmos: bool,
    x: i32,
    y: i32,
    total_width: i32,
    l: i32,
    fingers: u16,
    ring_width: i32,
    ring_spacing: i32,
) !void {
    if (fingers <= 1) return writeMosfetGeometry(writer, layers, is_pmos, x, y, total_width, l, ring_width, ring_spacing);

    const layout = FingerLayout.init(total_width, l, fingers);
    const w = layout.finger_width;
    const diff_y_min = y - layout.diffusion_region_height;
    const diff_y_max = y + layout.total_diffusion_height - layout.diffusion_region_height;

    try writeRect(writer, layers.diff, x, diff_y_min, x + w, diff_y_max);

    // Implant (NSDM/PSDM) — emitted merged by writeDevices.

    for (0..layout.finger_count) |finger_idx| {
        const gate_y = y + @as(i32, @intCast(finger_idx)) * (l + layout.diffusion_region_height);
        try writeRect(writer, layers.poly, x - poly_extension, gate_y, x + w + poly_extension, gate_y + l);
    }

    const dummy_pitch = l + layout.diffusion_region_height;
    const lower_dummy_y = y - dummy_pitch;
    const upper_dummy_y = y + @as(i32, @intCast(layout.finger_count)) * dummy_pitch;
    try writeRect(writer, layers.poly, x - poly_extension, lower_dummy_y, x + w + poly_extension, lower_dummy_y + l);
    try writeRect(writer, layers.poly, x - poly_extension, upper_dummy_y, x + w + poly_extension, upper_dummy_y + l);

    const cx = x + @divTrunc(w, 2);
    const region_count: usize = @intCast(layout.finger_count + 1);
    const li_half = @divTrunc(licon_size, 2) + licon_li_enc;
    const mcon_half = @divTrunc(licon_size, 2);
    const m1_half = mcon_half + m1_pad_enc;

    for (0..region_count) |region_idx| {
        const contact_cy = y - @divTrunc(layout.diffusion_region_height, 2) +
            @as(i32, @intCast(region_idx)) * (l + layout.diffusion_region_height);

        try writeRect(writer, layers.licon, cx - @divTrunc(licon_size, 2), contact_cy - @divTrunc(licon_size, 2), cx + @divTrunc(licon_size, 2), contact_cy + @divTrunc(licon_size, 2));
        try writeRect(writer, layers.li, cx - li_half, contact_cy - li_half, cx + li_half, contact_cy + li_half);
        try writeRect(writer, layers.mcon, cx - mcon_half, contact_cy - mcon_half, cx + mcon_half, contact_cy + mcon_half);
        try writeRect(writer, layers.metal[0], cx - m1_half, contact_cy - m1_half, cx + m1_half, contact_cy + m1_half);
    }

    const gate_bus_y_min = y + @divTrunc(l, 2) - @divTrunc(gate_pad_min_height, 2);
    const gate_bus_y_max = y + @as(i32, layout.finger_count - 1) * (l + layout.diffusion_region_height) +
        @divTrunc(l, 2) + @divTrunc(gate_pad_min_height, 2);
    const eff_gate_w = effectiveGatePadWidth(layout.finger_width);
    try writeRect(writer, layers.poly, x - eff_gate_w, gate_bus_y_min, x, gate_bus_y_max);

    const gate_cx = x - @divTrunc(eff_gate_w, 2);
    const gate_cy = @divTrunc(gate_bus_y_min + gate_bus_y_max, 2);
    try writeRect(writer, layers.licon, gate_cx - @divTrunc(licon_size, 2), gate_cy - @divTrunc(licon_size, 2), gate_cx + @divTrunc(licon_size, 2), gate_cy + @divTrunc(licon_size, 2));
    try writeRect(writer, layers.npc, gate_cx - @divTrunc(licon_size, 2) - npc_enc, gate_cy - @divTrunc(licon_size, 2) - npc_enc, gate_cx + @divTrunc(licon_size, 2) + npc_enc, gate_cy + @divTrunc(licon_size, 2) + npc_enc);
    try writeRect(writer, layers.li, gate_cx - li_half, gate_cy - li_half, gate_cx + li_half, gate_cy + li_half);
    try writeRect(writer, layers.mcon, gate_cx - mcon_half, gate_cy - mcon_half, gate_cx + mcon_half, gate_cy + mcon_half);
    try writeRect(writer, layers.metal[0], gate_cx - m1_half, gate_cy - m1_half, gate_cx + m1_half, gate_cy + m1_half);

    // x_tap_f = x (left edge of device), separate x-column from S/D contacts at cx.
    const x_tap_f = x;
    const body_cy = diff_y_min - tap_gap - @divTrunc(tap_diff_size, 2);
    const tap_half = @divTrunc(tap_diff_size, 2);
    const tap_layer = if (layers.tap.layer != 0) layers.tap else layers.diff;
    try writeRect(writer, tap_layer, x_tap_f - tap_half, body_cy - tap_half, x_tap_f + tap_half, body_cy + tap_half);

    const body_impl_layer = if (is_pmos) layers.nsdm else layers.psdm;
    try writeRect(writer, body_impl_layer, x_tap_f - tap_half - implant_enc, body_cy - tap_half - implant_enc, x_tap_f + tap_half + implant_enc, body_cy + tap_half + implant_enc);
    try writeRect(writer, layers.licon, x_tap_f - @divTrunc(licon_size, 2), body_cy - @divTrunc(licon_size, 2), x_tap_f + @divTrunc(licon_size, 2), body_cy + @divTrunc(licon_size, 2));
    try writeRect(writer, layers.li, x_tap_f - li_half, body_cy - li_half, x_tap_f + li_half, body_cy + li_half);
    try writeRect(writer, layers.mcon, x_tap_f - mcon_half, body_cy - mcon_half, x_tap_f + mcon_half, body_cy + mcon_half);
    try writeRect(writer, layers.metal[0], x_tap_f - m1_half, body_cy - m1_half, x_tap_f + m1_half, body_cy + m1_half);

    // NWELL for PMOS — emitted merged by writeDevices.

    try writeGuardRing(
        writer,
        layers,
        is_pmos,
        x - eff_gate_w,
        body_cy - tap_half,
        x + w,
        diff_y_max,
        ring_width,
        ring_spacing,
    );
}

// ─── Implant / well rect helpers for A8 merge pass ───────────────────────────

/// Compute the implant (NSDM or PSDM) bounding rect for a device.
/// `x_lo`/`x_hi` are the device diffusion x extents (before implant_enc is added).
/// Returns [x_min, y_min, x_max, y_max] in database units.
fn computeImplantRect(x_lo: i32, x_hi: i32, y: i32, l: i32, fingers: u16) [4]i32 {
    const fc: u16 = @max(1, fingers);
    const diff_region_h: i32 = effectiveSdExtension(l);
    const diff_y_min = y - diff_region_h;
    const diff_y_max = if (fc <= 1)
        y + l + diff_region_h
    else blk: {
        const total_h = @as(i32, fc) * l + (@as(i32, fc) + 1) * diff_region_h;
        break :blk y + total_h - diff_region_h;
    };
    return .{
        x_lo - implant_enc,
        diff_y_min - implant_enc,
        x_hi + implant_enc,
        diff_y_max + implant_enc,
    };
}

/// Compute the NWELL bounding rect for a PMOS device.
/// `x_lo`/`x_hi` are the device diffusion x extents.
fn computeNwellRect(x_lo: i32, x_hi: i32, y: i32, l: i32, fingers: u16) [4]i32 {
    const fc: u16 = @max(1, fingers);
    const diff_region_h: i32 = effectiveSdExtension(l);
    const diff_y_min = y - diff_region_h;
    const diff_y_max = if (fc <= 1)
        y + l + diff_region_h
    else blk: {
        const total_h = @as(i32, fc) * l + (@as(i32, fc) + 1) * diff_region_h;
        break :blk y + total_h - diff_region_h;
    };
    const tap_half = @divTrunc(tap_diff_size, 2);
    const body_cy = diff_y_min - tap_gap - tap_half;
    return .{
        x_lo - nwell_enc,
        body_cy - tap_half - nwell_enc,
        x_hi + nwell_enc,
        diff_y_max + nwell_enc,
    };
}

/// Merge overlapping/touching rectangles in place.
/// Uses a simple O(n²) loop (analog layouts have <50 devices).
/// Rects are [x_min, y_min, x_max, y_max].
fn mergeRects(rects: []([4]i32)) []([4]i32) {
    var len = rects.len;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < len) {
            var j: usize = i + 1;
            while (j < len) {
                const a = rects[i];
                const b = rects[j];
                // Two rects overlap/touch if their x AND y ranges overlap/touch.
                const x_overlap = (a[0] <= b[2]) and (a[2] >= b[0]);
                const y_overlap = (a[1] <= b[3]) and (a[3] >= b[1]);
                if (x_overlap and y_overlap) {
                    // Replace a with the union, remove b by swapping with last.
                    rects[i] = .{
                        @min(a[0], b[0]),
                        @min(a[1], b[1]),
                        @max(a[2], b[2]),
                        @max(a[3], b[3]),
                    };
                    rects[j] = rects[len - 1];
                    len -= 1;
                    changed = true;
                    // Restart the j loop since rects[j] is now a new rect.
                } else {
                    j += 1;
                }
            }
            i += 1;
        }
    }
    return rects[0..len];
}

/// Write a set of merged rects on the given layer, using a temp buffer for merging.
fn emitMergedRects(writer: anytype, layer: GdsLayer, rects: [][4]i32, allocator: std.mem.Allocator) !void {
    if (rects.len == 0) return;
    if (layer.layer == 0) return;
    // Copy to mutable slice for in-place merge.
    const buf = try allocator.dupe([4]i32, rects);
    defer allocator.free(buf);
    const merged = mergeRects(buf);
    for (merged) |r| {
        try writeRect(writer, layer, r[0], r[1], r[2], r[3]);
    }
}

// ─── A1: Common-centroid interleaved finger layout ────────────────────────────

/// Write two matched devices (A and B) with interleaved fingers in
/// A₁ B₁ … Bₙ Aₙ order (common-centroid style).
///
/// Both devices must have the same W, L, and finger count.
/// `x_a` and `x_b` are the device origins; the function places fingers
/// alternately starting at the leftmost origin.
///
/// Implant/NWELL rects are NOT written here — they are collected and merged
/// by `writeDevices`.
fn writeCommonCentroid(
    writer: anytype,
    layers: LayerTable,
    is_pmos: bool,
    x_a: i32,
    y: i32,
    w: i32,
    l: i32,
    fingers: u16,
    x_b: i32,
    ring_width: i32,
    ring_spacing: i32,
) !void {
    const fc: u16 = @max(2, fingers);
    const finger_w = @max(1, @divTrunc(w, fc));
    const diff_region_h: i32 = effectiveSdExtension(l);
    const diff_y_min = y - diff_region_h;
    const total_h = @as(i32, fc) * l + (@as(i32, fc) + 1) * diff_region_h;
    const diff_y_max = y + total_h - diff_region_h;

    // Use x_a as the layout origin; x_b origin unused (both device instances
    // share the same diffusion column in a CC layout).
    _ = x_b;

    const x = x_a;

    // Continuous diffusion for all fingers.
    try writeRect(writer, layers.diff, x, diff_y_min, x + finger_w, diff_y_max);

    // Poly fingers (A and B interleaved — same physical geometry, different
    // schematic connections handled by the router).
    for (0..fc) |fi| {
        const gate_y = y + @as(i32, @intCast(fi)) * (l + diff_region_h);
        try writeRect(writer, layers.poly, x - poly_extension, gate_y, x + finger_w + poly_extension, gate_y + l);
    }

    // Dummy poly at each end.
    const dummy_pitch = l + diff_region_h;
    const lower_dummy_y = y - dummy_pitch;
    const upper_dummy_y = y + @as(i32, @intCast(fc)) * dummy_pitch;
    try writeRect(writer, layers.poly, x - poly_extension, lower_dummy_y, x + finger_w + poly_extension, lower_dummy_y + l);
    try writeRect(writer, layers.poly, x - poly_extension, upper_dummy_y, x + finger_w + poly_extension, upper_dummy_y + l);

    // S/D contacts and LI/MCON/M1 pads for each diffusion region.
    const cx = x + @divTrunc(finger_w, 2);
    const region_count: usize = @intCast(fc + 1);
    const li_half = @divTrunc(licon_size, 2) + licon_li_enc;
    const mcon_half = @divTrunc(licon_size, 2);
    const m1_half = mcon_half + m1_pad_enc;

    for (0..region_count) |ri| {
        const contact_cy = y - @divTrunc(diff_region_h, 2) +
            @as(i32, @intCast(ri)) * (l + diff_region_h);
        try writeRect(writer, layers.licon, cx - @divTrunc(licon_size, 2), contact_cy - @divTrunc(licon_size, 2), cx + @divTrunc(licon_size, 2), contact_cy + @divTrunc(licon_size, 2));
        try writeRect(writer, layers.li, cx - li_half, contact_cy - li_half, cx + li_half, contact_cy + li_half);
        try writeRect(writer, layers.mcon, cx - mcon_half, contact_cy - mcon_half, cx + mcon_half, contact_cy + mcon_half);
        try writeRect(writer, layers.metal[0], cx - m1_half, contact_cy - m1_half, cx + m1_half, contact_cy + m1_half);
    }

    // Gate bus (shared poly bus on left side).
    const gate_bus_y_min = y + @divTrunc(l, 2) - @divTrunc(gate_pad_min_height, 2);
    const gate_bus_y_max = y + @as(i32, fc - 1) * (l + diff_region_h) +
        @divTrunc(l, 2) + @divTrunc(gate_pad_min_height, 2);
    const eff_gate_w_cc = effectiveGatePadWidth(finger_w);
    try writeRect(writer, layers.poly, x - eff_gate_w_cc, gate_bus_y_min, x, gate_bus_y_max);

    const gate_cx = x - @divTrunc(eff_gate_w_cc, 2);
    const gate_cy = @divTrunc(gate_bus_y_min + gate_bus_y_max, 2);
    try writeRect(writer, layers.licon, gate_cx - @divTrunc(licon_size, 2), gate_cy - @divTrunc(licon_size, 2), gate_cx + @divTrunc(licon_size, 2), gate_cy + @divTrunc(licon_size, 2));
    try writeRect(writer, layers.npc, gate_cx - @divTrunc(licon_size, 2) - npc_enc, gate_cy - @divTrunc(licon_size, 2) - npc_enc, gate_cx + @divTrunc(licon_size, 2) + npc_enc, gate_cy + @divTrunc(licon_size, 2) + npc_enc);
    try writeRect(writer, layers.li, gate_cx - li_half, gate_cy - li_half, gate_cx + li_half, gate_cy + li_half);
    try writeRect(writer, layers.mcon, gate_cx - mcon_half, gate_cy - mcon_half, gate_cx + mcon_half, gate_cy + mcon_half);
    try writeRect(writer, layers.metal[0], gate_cx - m1_half, gate_cy - m1_half, gate_cx + m1_half, gate_cy + m1_half);

    // Body tap.
    const body_cy = diff_y_min - tap_gap - @divTrunc(tap_diff_size, 2);
    const tap_half = @divTrunc(tap_diff_size, 2);
    const tap_layer = if (layers.tap.layer != 0) layers.tap else layers.diff;
    try writeRect(writer, tap_layer, cx - tap_half, body_cy - tap_half, cx + tap_half, body_cy + tap_half);

    const body_impl_layer = if (is_pmos) layers.nsdm else layers.psdm;
    try writeRect(writer, body_impl_layer, cx - tap_half - implant_enc, body_cy - tap_half - implant_enc, cx + tap_half + implant_enc, body_cy + tap_half + implant_enc);
    try writeRect(writer, layers.licon, cx - @divTrunc(licon_size, 2), body_cy - @divTrunc(licon_size, 2), cx + @divTrunc(licon_size, 2), body_cy + @divTrunc(licon_size, 2));
    try writeRect(writer, layers.li, cx - li_half, body_cy - li_half, cx + li_half, body_cy + li_half);
    try writeRect(writer, layers.mcon, cx - mcon_half, body_cy - mcon_half, cx + mcon_half, body_cy + mcon_half);
    try writeRect(writer, layers.metal[0], cx - m1_half, body_cy - m1_half, cx + m1_half, body_cy + m1_half);

    try writeGuardRing(
        writer,
        layers,
        is_pmos,
        x - eff_gate_w_cc,
        body_cy - tap_half,
        x + finger_w,
        diff_y_max,
        ring_width,
        ring_spacing,
    );
}

fn writeGuardRing(
    writer: anytype,
    layers: LayerTable,
    is_pmos: bool,
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,
    ring_width: i32,
    ring_spacing: i32,
) !void {
    const outer_x_min = x_min - ring_spacing - ring_width;
    const outer_y_min = y_min - ring_spacing - ring_width;
    const outer_x_max = x_max + ring_spacing + ring_width;
    const outer_y_max = y_max + ring_spacing + ring_width;
    const inner_x_min = x_min - ring_spacing;
    const inner_y_min = y_min - ring_spacing;
    const inner_x_max = x_max + ring_spacing;
    const inner_y_max = y_max + ring_spacing;

    const tap_layer = if (layers.tap.layer != 0) layers.tap else layers.diff;
    const implant_layer = if (is_pmos) layers.nsdm else layers.psdm;

    // Four ring segments on tap + implant.
    try writeRect(writer, tap_layer, outer_x_min, outer_y_min, inner_x_min, outer_y_max);
    try writeRect(writer, tap_layer, inner_x_max, outer_y_min, outer_x_max, outer_y_max);
    try writeRect(writer, tap_layer, inner_x_min, outer_y_min, inner_x_max, inner_y_min);
    try writeRect(writer, tap_layer, inner_x_min, inner_y_max, inner_x_max, outer_y_max);

    try writeRect(writer, implant_layer, outer_x_min - implant_enc, outer_y_min - implant_enc, inner_x_min + implant_enc, outer_y_max + implant_enc);
    try writeRect(writer, implant_layer, inner_x_max - implant_enc, outer_y_min - implant_enc, outer_x_max + implant_enc, outer_y_max + implant_enc);
    try writeRect(writer, implant_layer, inner_x_min - implant_enc, outer_y_min - implant_enc, inner_x_max + implant_enc, inner_y_min + implant_enc);
    try writeRect(writer, implant_layer, inner_x_min - implant_enc, inner_y_max - implant_enc, inner_x_max + implant_enc, outer_y_max + implant_enc);

    const contact_half = @divTrunc(licon_size, 2);
    const li_half = contact_half + licon_li_enc;
    const mcon_half = contact_half;
    const m1_half = mcon_half + m1_pad_enc;
    const corners = [_][2]i32{
        .{ outer_x_min + @divTrunc(ring_width, 2), outer_y_min + @divTrunc(ring_width, 2) },
        .{ outer_x_max - @divTrunc(ring_width, 2), outer_y_min + @divTrunc(ring_width, 2) },
        .{ outer_x_min + @divTrunc(ring_width, 2), outer_y_max - @divTrunc(ring_width, 2) },
        .{ outer_x_max - @divTrunc(ring_width, 2), outer_y_max - @divTrunc(ring_width, 2) },
    };
    for (corners) |corner| {
        const cx = corner[0];
        const cy = corner[1];
        try writeRect(writer, layers.licon, cx - contact_half, cy - contact_half, cx + contact_half, cy + contact_half);
        try writeRect(writer, layers.li, cx - li_half, cy - li_half, cx + li_half, cy + li_half);
        try writeRect(writer, layers.mcon, cx - mcon_half, cy - mcon_half, cx + mcon_half, cy + mcon_half);
        try writeRect(writer, layers.metal[0], cx - m1_half, cy - m1_half, cx + m1_half, cy + m1_half);
    }

    if (is_pmos) {
        try writeRect(writer, layers.nwell, outer_x_min - nwell_enc, outer_y_min - nwell_enc, outer_x_max + nwell_enc, outer_y_max + nwell_enc);
    }
}

/// Write placeholder geometry for passive devices (R, C, L) and subcircuit
/// instances.  Uses the local-interconnect layer (li) as a bounding rectangle.
fn writePassiveGeometry(writer: anytype, layers: LayerTable, x: i32, y: i32, w: i32, l: i32) !void {
    try writeRect(writer, layers.li, x, y, x + w, y + l);
}

// ─── GDSII TEXT element and net label helpers ────────────────────────────────

/// Write a GDSII TEXT element on the given layer at position (x, y) in
/// database units.  The text string is the net name.
///
/// Record sequence: TEXT, LAYER, TEXTTYPE(0), XY, STRING, ENDEL.
fn writeTextElement(writer: anytype, gds_layer: GdsLayer, x: i32, y: i32, text: []const u8) !void {
    if (gds_layer.layer == 0) return;
    if (text.len == 0) return;

    // TEXT
    try records.writeRecord(writer, records.RecordType.TEXT, &[_]u8{});

    // LAYER
    try records.writeInt16Record(writer, records.RecordType.LAYER, @intCast(gds_layer.layer));

    // TEXTTYPE — must match the pin-purpose datatype so KLayout labels() finds it
    try records.writeInt16Record(writer, records.RecordType.TEXTTYPE, @intCast(gds_layer.datatype));

    // XY — single coordinate pair
    var xy_buf: [8]u8 = undefined;
    writeI32Be(xy_buf[0..4], x);
    writeI32Be(xy_buf[4..8], y);
    try records.writeRecord(writer, records.RecordType.XY, &xy_buf);

    // STRING — the net name
    try records.writeStringRecord(writer, records.RecordType.STRING, text);

    // ENDEL
    try records.writeRecord(writer, records.RecordType.ENDEL, &[_]u8{});
}

/// Map a route-layer index to the corresponding pin-purpose GDS layer.
///   0 -> li_pin  (LI1 pin)
///   1 -> metal_pin[0]  (MET1 pin)
///   2 -> metal_pin[1]  (MET2 pin)
///   ...
fn mapPinLayer(layers: LayerTable, idx: u8) GdsLayer {
    if (idx == 0) return layers.li_pin;
    const metal_idx = idx - 1;
    if (metal_idx < 5) return layers.metal_pin[metal_idx];
    return .{ .layer = 0, .datatype = 0 };
}

/// Shared-library-safe debug print for export stage.
fn dbgPrintExport(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.write(2, s) catch {};
}

/// Iterate over route segments, and for each net place one TEXT label on
/// the corresponding pin-purpose layer.  The label is placed at the
/// midpoint of the first non-degenerate route segment found for that net.
///
/// This ensures KLayout LVS can identify each net by name.
fn writeNetLabels(writer: anytype, routes: ?*const RouteArrays, pdk: *const PdkConfig, net_names: []const []const u8, pins: ?*const PinEdgeArrays, devices: *const DeviceArrays) !void {
    const scale: f32 = 1.0 / pdk.db_unit;
    var label_count: u32 = 0;

    // Strategy: label EVERY non-degenerate route segment of every named net,
    // AND label at EVERY device pin position.  Redundant labels are harmless
    // for LVS (they all associate with the same geometric net), but this
    // guarantees that if routing fragmented a net, every surviving fragment
    // and every pin still carry the correct name.  See BUGS.md S0-2.

    // Pass 1: label every route segment.
    if (routes) |r| {
        const n: usize = @intCast(r.len);
        for (0..n) |i| {
            const net_idx = r.net[i].toInt();
            if (net_idx >= net_names.len) continue;
            const name = net_names[net_idx];
            if (name.len == 0) continue;

            const sx: i32 = @intFromFloat(@round(r.x1[i] * scale));
            const sy: i32 = @intFromFloat(@round(r.y1[i] * scale));
            const ex: i32 = @intFromFloat(@round(r.x2[i] * scale));
            const ey: i32 = @intFromFloat(@round(r.y2[i] * scale));

            if (sx == ex and sy == ey) continue;

            const mx = midpointI32(sx, ex);
            const my = midpointI32(sy, ey);

            const pin_layer = mapPinLayer(pdk.layers, r.layer[i]);
            try writeTextElement(writer, pin_layer, mx, my, name);
            label_count += 1;
            dbgPrintExport(
                "  LABEL(seg) net='{s}' layer={}/{} pos=({},{}) route_layer={}\n",
                .{ name, pin_layer.layer, pin_layer.datatype, mx, my, r.layer[i] },
            );
        }
    }

    // Pass 2: unconditionally label every named pin position on M1 pin layer.
    // This ensures the pin is identified even when the router dropped the
    // corresponding Steiner edge (silent drop → no route segment → no label
    // from Pass 1).  KLayout tolerates duplicate labels on one electrical net.
    if (pins) |p| {
        const pn: usize = @intCast(p.len);
        for (0..pn) |i| {
            const net_idx = p.net[i].toInt();
            if (net_idx >= net_names.len) continue;
            const name = net_names[net_idx];
            if (name.len == 0) continue;

            const dev_idx = p.device[i].toInt();
            if (dev_idx >= devices.len) continue;

            const dx = devices.positions[dev_idx][0];
            const dy = devices.positions[dev_idx][1];
            const px: i32 = @intFromFloat(@round((dx + p.position[i][0]) * scale));
            const py: i32 = @intFromFloat(@round((dy + p.position[i][1]) * scale));

            const pin_layer = pdk.layers.metal_pin[0];
            try writeTextElement(writer, pin_layer, px, py, name);
            label_count += 1;
            dbgPrintExport(
                "  LABEL(pin) net='{s}' layer={}/{} pos=({},{}) dev={} term={s}\n",
                .{ name, pin_layer.layer, pin_layer.datatype, px, py, dev_idx, @tagName(p.terminal[i]) },
            );
        }
    }

    dbgPrintExport("LABELS EMITTED: {} total\n", .{label_count});
}

fn midpointI32(a: i32, b: i32) i32 {
    const sum: i64 = @as(i64, a) + @as(i64, b);
    return @intCast(@divTrunc(sum, 2));
}

// ─── Route layer mapping ─────────────────────────────────────────────────────

/// Map a route-layer index to the corresponding GDS layer from the PDK table.
///   0 -> li  (local interconnect)
///   1 -> metal[0]  (M1)
///   2 -> metal[1]  (M2)
///   ...up to metal[4] (M5)
fn mapRouteLayer(layers: LayerTable, idx: u8) GdsLayer {
    if (idx == 0) return layers.li;
    const metal_idx = idx - 1;
    if (metal_idx < 5) return layers.metal[metal_idx];
    // Out-of-range: return zero layer (will be skipped).
    return .{ .layer = 0, .datatype = 0 };
}

/// Determine the via layer for a transition between two route-layer indices.
/// Route layer 0 = li, 1 = M1, etc.
///   li  <-> M1  : mcon (LI-to-M1 contact, 67/44 on sky130)
///   M1  <-> M2  : via[0]
///   M2  <-> M3  : via[1]
///   M3  <-> M4  : via[2]
///   M4  <-> M5  : via[3]
fn mapViaLayer(layers: LayerTable, from: u8, to: u8) GdsLayer {
    const lo = @min(from, to);
    const hi = @max(from, to);

    // Only handle single-step transitions; multi-step vias are the router's
    // responsibility to break into individual segments.
    if (hi - lo != 1) return .{ .layer = 0, .datatype = 0 };

    if (lo == 0) {
        // li <-> M1 transition uses mcon (metal contact from LI to M1).
        // Note: licon is the contact from diffusion/poly *to* LI, not LI to M1.
        return layers.mcon;
    }
    // M(lo) <-> M(lo+1): via index = lo - 1  (metal indices are 1-based in
    // route-layer space, so M1=1, M2=2; via between M1-M2 = via[0]).
    const via_idx = lo - 1;
    if (via_idx < 4) return layers.via[via_idx];
    return .{ .layer = 0, .datatype = 0 };
}

// ─── Low-level GDSII helpers ─────────────────────────────────────────────────

/// Write a GDSII BOUNDARY element (filled rectangle) on the given GDS layer.
///
/// Coordinates are in database units.  The rectangle is defined by two
/// opposite corners (x1,y1) and (x2,y2).  If the layer number is zero,
/// the rectangle is silently skipped (allows graceful handling of
/// uninitialised layer table entries).
fn writeRect(writer: anytype, gds_layer: GdsLayer, x1: i32, y1: i32, x2: i32, y2: i32) !void {
    // Skip layers with layer==0 (uninitialised / unused).
    if (gds_layer.layer == 0) return;

    // BOUNDARY
    try records.writeRecord(writer, records.RecordType.BOUNDARY, &[_]u8{});

    // LAYER
    try records.writeInt16Record(writer, records.RecordType.LAYER, @intCast(gds_layer.layer));

    // DATATYPE
    try records.writeInt16Record(writer, records.RecordType.DATATYPE, @intCast(gds_layer.datatype));

    // XY (5 points for a closed rectangle)
    var xy_buf: [40]u8 = undefined;
    writeI32Be(xy_buf[0..4], x1);
    writeI32Be(xy_buf[4..8], y1);
    writeI32Be(xy_buf[8..12], x2);
    writeI32Be(xy_buf[12..16], y1);
    writeI32Be(xy_buf[16..20], x2);
    writeI32Be(xy_buf[20..24], y2);
    writeI32Be(xy_buf[24..28], x1);
    writeI32Be(xy_buf[28..32], y2);
    writeI32Be(xy_buf[32..36], x1);
    writeI32Be(xy_buf[36..40], y1);
    try records.writeRecord(writer, records.RecordType.XY, &xy_buf);

    // ENDEL
    try records.writeRecord(writer, records.RecordType.ENDEL, &[_]u8{});
}

fn writeI32Be(buf: *[4]u8, val: i32) void {
    buf.* = std.mem.toBytes(std.mem.nativeTo(i32, val, .big));
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "GdsiiWriter init" {
    var writer = GdsiiWriter.init(std.testing.allocator);
    writer.deinit();
}

test "writeI32Be" {
    var buf: [4]u8 = undefined;
    writeI32Be(&buf, 0x01020304);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[3]);
}

test "writeRect writes BOUNDARY with correct layer and datatype" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layer = GdsLayer{ .layer = 68, .datatype = 20 };
    try writeRect(&writer, layer, 0, 0, 1000, 2000);

    const written = fbs.getWritten();
    // Should have written: BOUNDARY(4) + LAYER(6) + DATATYPE(6) + XY(44) + ENDEL(4) = 64 bytes
    try std.testing.expectEqual(@as(usize, 64), written.len);

    // Verify BOUNDARY record type at byte 2
    try std.testing.expectEqual(@as(u8, 0x08), written[2]);

    // Verify LAYER value at bytes 8..10 (after BOUNDARY[4] + LAYER header[4])
    // LAYER record: [00 06] [0D 02] [00 44]  (layer 68 = 0x0044)
    try std.testing.expectEqual(@as(u8, 0x0D), written[6]); // LAYER record type
    try std.testing.expectEqual(@as(u8, 0x00), written[8]); // layer high byte
    try std.testing.expectEqual(@as(u8, 0x44), written[9]); // layer low byte = 68

    // Verify DATATYPE value (after BOUNDARY[4] + LAYER[6])
    try std.testing.expectEqual(@as(u8, 0x0E), written[12]); // DATATYPE record type
    try std.testing.expectEqual(@as(u8, 0x00), written[14]); // datatype high byte
    try std.testing.expectEqual(@as(u8, 0x14), written[15]); // datatype low byte = 20
}

test "writeRect skips layer with layer==0" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layer = GdsLayer{ .layer = 0, .datatype = 0 };
    try writeRect(&writer, layer, 0, 0, 1000, 2000);

    const written = fbs.getWritten();
    // Should write nothing
    try std.testing.expectEqual(@as(usize, 0), written.len);
}

test "mapRouteLayer index 0 returns li" {
    const layers = testLayerTable();
    const result = mapRouteLayer(layers, 0);
    try std.testing.expectEqual(@as(u16, 67), result.layer); // li layer
    try std.testing.expectEqual(@as(u16, 20), result.datatype);
}

test "mapRouteLayer index 1 returns metal[0]" {
    const layers = testLayerTable();
    const result = mapRouteLayer(layers, 1);
    try std.testing.expectEqual(@as(u16, 68), result.layer); // metal[0] = M1
}

test "mapRouteLayer index out of range returns zero" {
    const layers = testLayerTable();
    const result = mapRouteLayer(layers, 10);
    try std.testing.expectEqual(@as(u16, 0), result.layer);
}

test "mapViaLayer li to M1 returns mcon" {
    const layers = testLayerTable();
    const result = mapViaLayer(layers, 0, 1);
    try std.testing.expectEqual(@as(u16, 67), result.layer); // mcon
    try std.testing.expectEqual(@as(u16, 44), result.datatype);
}

test "mapViaLayer M1 to M2 returns via[0]" {
    const layers = testLayerTable();
    const result = mapViaLayer(layers, 1, 2);
    try std.testing.expectEqual(@as(u16, 68), result.layer); // via[0]
}

test "mapViaLayer non-adjacent returns zero" {
    const layers = testLayerTable();
    const result = mapViaLayer(layers, 0, 2);
    try std.testing.expectEqual(@as(u16, 0), result.layer);
}

test "writeMosfetGeometry NMOS produces diff, poly, licon, li, mcon rects" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layers = testLayerTable();
    // 1000 db units wide, 150 db units long (like 1um W, 0.15um L)
    try writeMosfetGeometry(&writer, layers, false, 0, 0, 1000, 150, 170, 190);

    const written = fbs.getWritten();
    // NMOS: diff(1) + poly(2) + licon(4) + npc(1) + li(4) + mcon(4) + m1(4) + diff_tap(1) + psdm_tap(1) = 22 rectangles
    // (nsdm emitted via writeDevices merge pass, not here)
    // guard ring: tap(4) + implant(4) + corners×(licon+li+mcon+m1)(16) = 24 rectangles (no nwell for NMOS)
    // Each BOUNDARY element = 64 bytes (4+6+6+44+4)
    // (22 + 24) = 46 rectangles = 2944 bytes
    try std.testing.expectEqual(@as(usize, 2944), written.len);
}

test "writeMosfetGeometry PMOS produces psdm body-tap, licon, li, mcon rects" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layers = testLayerTable();
    try writeMosfetGeometry(&writer, layers, true, 0, 0, 1000, 150, 170, 190);

    const written = fbs.getWritten();
    // PMOS: diff(1) + poly(2) + nsdm_tap(1) + licon(4) + npc(1) + li(4) + mcon(4) + m1(4) = 22 rectangles
    // (psdm device-implant and nwell emitted via writeDevices merge pass, not here;
    //  nsdm body-tap implant is still written directly since it is the well-tap, not the device implant)
    // guard ring: tap(4) + implant(4) + corners×(licon+li+mcon+m1)(16) + nwell(1) = 25 rectangles
    // (22 + 25) = 47 rectangles × 64 bytes = 3008 bytes
    try std.testing.expectEqual(@as(usize, 3008), written.len);
}

test "FingerLayout splits effective width across fingers" {
    const layout = FingerLayout.init(1000, 150, 4);
    try std.testing.expectEqual(@as(u16, 4), layout.finger_count);
    try std.testing.expectEqual(@as(i32, 250), layout.finger_width);
    try std.testing.expect(layout.total_diffusion_height > 150);
}

test "writeMosfetGeometryFingered emits one poly stripe per finger plus gate bus" {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layers = testLayerTable();
    try writeMosfetGeometryFingered(&writer, layers, false, 0, 0, 1000, 150, 4, 340, 340);

    const written = fbs.getWritten();
    try std.testing.expect(written.len > 2500);
}

test "writeGuardRing emits tap and implant ring geometry" {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layers = testLayerTable();
    try writeGuardRing(&writer, layers, false, 0, 0, 1000, 1000, 340, 340);

    const written = fbs.getWritten();
    try std.testing.expect(written.len > 1500);
}

test "writePassiveGeometry produces single li rect" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layers = testLayerTable();
    try writePassiveGeometry(&writer, layers, 0, 0, 500, 500);

    const written = fbs.getWritten();
    // Single rectangle = 64 bytes
    try std.testing.expectEqual(@as(usize, 64), written.len);
}

test "writeTextElement writes TEXT with correct layer, texttype, xy, and string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const pin_layer = GdsLayer{ .layer = 68, .datatype = 5 };
    try writeTextElement(&writer, pin_layer, 5000, 3000, "VDD");

    const written = fbs.getWritten();

    // TEXT record: 4 bytes (header only, no data)
    // LAYER record: 6 bytes
    // TEXTTYPE record: 6 bytes
    // XY record: 4 header + 8 data = 12 bytes
    // STRING record: 4 header + 4 data (3 chars + 1 pad) = 8 bytes
    // ENDEL record: 4 bytes
    // Total: 4 + 6 + 6 + 12 + 8 + 4 = 40 bytes
    try std.testing.expectEqual(@as(usize, 40), written.len);

    // Verify TEXT record type (0x0C, 0x00)
    try std.testing.expectEqual(@as(u8, 0x0C), written[2]);
    try std.testing.expectEqual(@as(u8, 0x00), written[3]);

    // Verify LAYER record (bytes 4..10): layer 68 = 0x0044
    try std.testing.expectEqual(@as(u8, 0x0D), written[6]); // LAYER record type
    try std.testing.expectEqual(@as(u8, 0x00), written[8]);
    try std.testing.expectEqual(@as(u8, 0x44), written[9]); // 68

    // Verify TEXTTYPE record (bytes 10..16): texttype 5 (pin purpose)
    try std.testing.expectEqual(@as(u8, 0x16), written[12]); // TEXTTYPE record type
    try std.testing.expectEqual(@as(u8, 0x00), written[14]);
    try std.testing.expectEqual(@as(u8, 0x05), written[15]);

    // Verify XY coordinates (bytes 16..28)
    // x = 5000 = 0x00001388, y = 3000 = 0x00000BB8
    try std.testing.expectEqual(@as(u8, 0x10), written[18]); // XY record type
    try std.testing.expectEqual(@as(u8, 0x00), written[20]);
    try std.testing.expectEqual(@as(u8, 0x00), written[21]);
    try std.testing.expectEqual(@as(u8, 0x13), written[22]);
    try std.testing.expectEqual(@as(u8, 0x88), written[23]);
    try std.testing.expectEqual(@as(u8, 0x00), written[24]);
    try std.testing.expectEqual(@as(u8, 0x00), written[25]);
    try std.testing.expectEqual(@as(u8, 0x0B), written[26]);
    try std.testing.expectEqual(@as(u8, 0xB8), written[27]);

    // Verify STRING record (bytes 28..36): "VDD" + pad
    try std.testing.expectEqual(@as(u8, 0x19), written[30]); // STRING record type
    try std.testing.expectEqual(@as(u8, 0x06), written[31]); // STRING data type
    try std.testing.expectEqual(@as(u8, 'V'), written[32]);
    try std.testing.expectEqual(@as(u8, 'D'), written[33]);
    try std.testing.expectEqual(@as(u8, 'D'), written[34]);
    try std.testing.expectEqual(@as(u8, 0x00), written[35]); // pad byte

    // Verify ENDEL at end
    try std.testing.expectEqual(@as(u8, 0x11), written[38]); // ENDEL record type
}

test "writeTextElement skips layer==0" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layer = GdsLayer{ .layer = 0, .datatype = 0 };
    try writeTextElement(&writer, layer, 0, 0, "VDD");

    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "writeTextElement skips empty string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const layer = GdsLayer{ .layer = 68, .datatype = 5 };
    try writeTextElement(&writer, layer, 0, 0, "");

    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "mapPinLayer index 0 returns li_pin" {
    const layers = testLayerTable();
    const result = mapPinLayer(layers, 0);
    try std.testing.expectEqual(@as(u16, 67), result.layer);
    try std.testing.expectEqual(@as(u16, 5), result.datatype);
}

test "mapPinLayer index 1 returns metal_pin[0]" {
    const layers = testLayerTable();
    const result = mapPinLayer(layers, 1);
    try std.testing.expectEqual(@as(u16, 68), result.layer);
    try std.testing.expectEqual(@as(u16, 5), result.datatype);
}

test "mapPinLayer index 2 returns metal_pin[1]" {
    const layers = testLayerTable();
    const result = mapPinLayer(layers, 2);
    try std.testing.expectEqual(@as(u16, 69), result.layer);
    try std.testing.expectEqual(@as(u16, 5), result.datatype);
}

test "mapPinLayer out of range returns zero" {
    const layers = testLayerTable();
    const result = mapPinLayer(layers, 10);
    try std.testing.expectEqual(@as(u16, 0), result.layer);
}

test "writeNetLabels places a label on every non-degenerate segment" {
    // BUGS.md S0-2: labels are now emitted for every route segment so that
    // fragmented nets survive LVS name-to-geometry association.
    // Set up 3 route segments: 2 for net 0 on layer 1 (M1), 1 for net 1 on layer 0 (LI).
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    // Net 0, layer 1 (M1), segment from (0,0) to (10,0)
    try routes.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, NetIdx.fromInt(0));
    // Net 0, layer 1 (M1), second segment — now produces a second label.
    try routes.append(1, 10.0, 0.0, 10.0, 5.0, 0.14, NetIdx.fromInt(0));
    // Net 1, layer 0 (LI), segment from (0,0) to (5,0)
    try routes.append(0, 0.0, 0.0, 5.0, 0.0, 0.17, NetIdx.fromInt(1));

    const net_names = [_][]const u8{ "VDD", "VSS" };

    // Use a db_unit of 1.0 so coordinates pass through unchanged.
    var pdk = PdkConfig.loadDefault(.sky130);
    pdk.db_unit = 1.0;

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    var empty_devs = try DeviceArrays.init(std.testing.allocator, 0);
    defer empty_devs.deinit();
    try writeNetLabels(&writer, &routes, &pdk, &net_names, null, &empty_devs);

    const written = fbs.getWritten();

    // Expect 3 TEXT elements (one per segment).  Each label is 40 bytes:
    // TEXT(4)+LAYER(6)+TEXTTYPE(6)+XY(12)+STRING(8)+ENDEL(4).
    try std.testing.expectEqual(@as(usize, 120), written.len);

    // First label (net 0, M1) → layer 68.
    try std.testing.expectEqual(@as(u8, 0x0C), written[2]);
    try std.testing.expectEqual(@as(u8, 0x00), written[8]);
    try std.testing.expectEqual(@as(u8, 0x44), written[9]);

    // Second label (net 0, M1) → layer 68.
    try std.testing.expectEqual(@as(u8, 0x0C), written[42]);
    try std.testing.expectEqual(@as(u8, 0x00), written[48]);
    try std.testing.expectEqual(@as(u8, 0x44), written[49]);

    // Third label (net 1, LI) → layer 67.
    try std.testing.expectEqual(@as(u8, 0x0C), written[82]);
    try std.testing.expectEqual(@as(u8, 0x00), written[88]);
    try std.testing.expectEqual(@as(u8, 0x43), written[89]);
}

test "writeNetLabels skips degenerate zero-length segments" {
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    // Zero-length segment (same start/end) — should be skipped.
    try routes.append(1, 5.0, 5.0, 5.0, 5.0, 0.14, NetIdx.fromInt(0));
    // Non-zero segment for the same net — should produce a label.
    try routes.append(1, 0.0, 0.0, 10.0, 0.0, 0.14, NetIdx.fromInt(0));

    const net_names = [_][]const u8{"OUT"};

    var pdk = PdkConfig.loadDefault(.sky130);
    pdk.db_unit = 1.0;

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    var empty_devs = try DeviceArrays.init(std.testing.allocator, 0);
    defer empty_devs.deinit();
    try writeNetLabels(&writer, &routes, &pdk, &net_names, null, &empty_devs);

    const written = fbs.getWritten();
    // "OUT" (3 chars, padded to 4): TEXT(4)+LAYER(6)+TEXTTYPE(6)+XY(12)+STRING(8)+ENDEL(4) = 40
    try std.testing.expectEqual(@as(usize, 40), written.len);
}

test "writeNetLabels with empty routes produces no output" {
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    const net_names = [_][]const u8{"VDD"};

    var pdk = PdkConfig.loadDefault(.sky130);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    var empty_devs = try DeviceArrays.init(std.testing.allocator, 0);
    defer empty_devs.deinit();
    try writeNetLabels(&writer, &routes, &pdk, &net_names, null, &empty_devs);

    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "writeNetLabels handles large coordinates without integer overflow" {
    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    try routes.append(1, 1.6e9, 1.6e9, 1.7e9, 1.7e9, 0.14, NetIdx.fromInt(0));

    const net_names = [_][]const u8{"BIG"};

    var pdk = PdkConfig.loadDefault(.sky130);
    pdk.db_unit = 1.0;

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    var empty_devs = try DeviceArrays.init(std.testing.allocator, 0);
    defer empty_devs.deinit();
    try writeNetLabels(&writer, &routes, &pdk, &net_names, null, &empty_devs);

    try std.testing.expectEqual(@as(usize, 40), fbs.getWritten().len);
}

/// Helper: return a LayerTable with known test values for sky130-like layers.
fn testLayerTable() LayerTable {
    return LayerTable{
        .nwell = .{ .layer = 64, .datatype = 20 },
        .diff = .{ .layer = 65, .datatype = 20 },
        .tap = .{ .layer = 65, .datatype = 44 },
        .poly = .{ .layer = 66, .datatype = 20 },
        .nsdm = .{ .layer = 93, .datatype = 44 },
        .psdm = .{ .layer = 94, .datatype = 20 },
        .npc = .{ .layer = 95, .datatype = 20 },
        .licon = .{ .layer = 66, .datatype = 44 },
        .li = .{ .layer = 67, .datatype = 20 },
        .mcon = .{ .layer = 67, .datatype = 44 },
        .metal = .{
            .{ .layer = 68, .datatype = 20 },
            .{ .layer = 69, .datatype = 20 },
            .{ .layer = 70, .datatype = 20 },
            .{ .layer = 71, .datatype = 20 },
            .{ .layer = 72, .datatype = 20 },
        },
        .via = .{
            .{ .layer = 68, .datatype = 44 },
            .{ .layer = 69, .datatype = 44 },
            .{ .layer = 70, .datatype = 44 },
            .{ .layer = 71, .datatype = 44 },
        },
        .li_pin = .{ .layer = 67, .datatype = 5 },
        .metal_pin = .{
            .{ .layer = 68, .datatype = 5 },
            .{ .layer = 69, .datatype = 5 },
            .{ .layer = 70, .datatype = 5 },
            .{ .layer = 71, .datatype = 5 },
            .{ .layer = 72, .datatype = 5 },
        },
    };
}

fn countLayerRecords(data: []const u8, layer: u16) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 4 <= data.len) {
        const rec_len = std.mem.bigToNative(u16, @as(*align(1) const u16, @ptrCast(data[offset .. offset + 2])).*);
        if (rec_len < 4 or offset + rec_len > data.len) break;
        if (data[offset + 2] == @intFromEnum(records.RecordType.LAYER) and rec_len >= 6) {
            const value = std.mem.bigToNative(u16, @as(*align(1) const u16, @ptrCast(data[offset + 4 .. offset + 6])).*);
            if (value == layer) count += 1;
        }
        offset += rec_len;
    }
    return count;
}
