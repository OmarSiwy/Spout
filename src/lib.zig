// ─── Spout C-ABI surface ────────────────────────────────────────────────────
//
// This file exposes the Spout EDA toolkit as a flat C-callable shared library.
// All state is held behind an opaque handle (SpoutContext).

const std = @import("std");

// ─── Core modules ───────────────────────────────────────────────────────────

pub const types = @import("core/types.zig");
pub const device_arrays = @import("core/device_arrays.zig");
pub const net_arrays = @import("core/net_arrays.zig");
pub const pin_edge_arrays = @import("core/pin_edge_arrays.zig");
pub const constraint_arrays = @import("core/constraint_arrays.zig");
pub const route_arrays = @import("core/route_arrays.zig");
pub const shape_arrays = @import("core/shape_arrays.zig");
pub const adjacency = @import("core/adjacency.zig");
pub const layout_if = @import("core/layout_if.zig");
pub const pdk = @import("pdk/pdk.zig");

// ─── Sub-system modules ─────────────────────────────────────────────────────

pub const netlist = @import("netlist/lib.zig");
pub const parser = @import("netlist/lib.zig"); // backward-compat alias
pub const tokenizer = @import("netlist/tokenizer.zig");

pub const constraint_extract = @import("constraint/extract.zig");
pub const constraint_patterns = @import("constraint/patterns.zig");

pub const sa = @import("placer/sa.zig");
pub const cost = @import("placer/cost.zig");
pub const rudy = @import("placer/rudy.zig");

/// Aggregated placer types re-exported for e2e tests and external consumers.
pub const placer_types = struct {
    pub const SaConfig = sa.SaConfig;
    pub const SaResult = sa.SaResult;
    pub const PinInfo = cost.PinInfo;
    pub const Constraint = cost.Constraint;
    pub const NetAdjacency = rudy.NetAdjacency;
};

pub const router = @import("router/lib.zig");
pub const drc = @import("router/inline_drc.zig");
pub const maze = @import("router/maze.zig");
pub const detailed = @import("router/detailed.zig");

pub const steiner = @import("router/steiner.zig");
pub const lp_sizing = @import("router/lp_sizing.zig");

pub const gdsii = @import("export/gdsii.zig");

// ─── Import modules ─────────────────────────────────────────────────────────

pub const gdsii_reader = @import("import/gdsii.zig");
pub const template = @import("import/template.zig");
const template_mod = template;

// ─── Macro / unit-cell recognition ──────────────────────────────────────────

pub const macro_mod = @import("macro/lib.zig");
pub const macro_types = @import("macro/types.zig"); // kept for back-compat
pub const records = @import("export/records.zig");

pub const characterize = @import("characterize/lib.zig");

pub const liberty = @import("liberty/lib.zig");

// ─── Span: C-ABI compatible array view ──────────────────────────────────────

pub fn Span(comptime T: type) type {
    return extern struct {
        ptr: [*]T,
        len: usize,
    };
}

// ─── Device dimension computation ────────────────────────────────────────────

const DeviceArrays = device_arrays.DeviceArrays;
const PdkConfig = layout_if.PdkConfig;

/// Compute device bounding-box dimensions (width, height) in µm from the
/// device parameters and PDK geometry constants.  These dimensions are used
/// by the SA placer to penalise overlapping devices.
///
/// The bounding box covers the full physical footprint: diffusion, implants,
/// body tap, gate pad, and — for PMOS — the NWELL region.  Dimensions are
/// conservative (slightly larger than the actual geometry) to ensure adequate
/// clearance between neighbouring devices.
fn computeDeviceDimensions(devices: *DeviceArrays, pdk_cfg: *const PdkConfig) void {
    const n: usize = @intCast(devices.len);
    const p2um = pdk_cfg.param_to_um;

    // Geometry constants from gdsii.zig, converted to µm.
    const db = pdk_cfg.db_unit; // 0.001 µm
    const sd_ext: f32 = 260.0 * db; // 0.260
    const poly_ext: f32 = 150.0 * db; // 0.150
    const impl_enc: f32 = 130.0 * db; // 0.130
    const nwell_enc_f: f32 = 200.0 * db; // 0.200
    const gate_pad_w: f32 = 400.0 * db; // 0.400
    const tap_gap_f: f32 = 270.0 * db; // 0.270
    const tap_diff: f32 = 340.0 * db; // 0.340
    // Guard ring extends ring_spacing + ring_width beyond the device interior.
    // Must include this so the router blocks M1 cells at guard ring corners.
    const ring_ext: f32 = pdk_cfg.guard_ring_spacing + pdk_cfg.guard_ring_width;

    for (0..n) |i| {
        switch (devices.types[i]) {
            .nmos, .pmos => {
                const raw_w = devices.params[i].w;
                const raw_l = devices.params[i].l;
                const mult: f32 = @floatFromInt(@max(@as(u16, 1), devices.params[i].mult));

                const w_um = if (raw_w > 0.0) raw_w * p2um * mult else 1.0;
                const l_um = if (raw_l > 0.0) raw_l * p2um else 0.15;

                const is_pmos = (devices.types[i] == .pmos);

                // X-extent: from gate pad left edge to diffusion right + enclosure.
                // The gate pad extends gate_pad_w to the left of x=0.
                // The device active region extends from x=0 to x=w_um.
                // Body tap is centred at x = w_um/2.
                // For PMOS the NWELL encloses the entire device including body
                // tap, so use nwell_enc for the right margin (nwell_enc > impl_enc).
                const left = gate_pad_w + poly_ext + ring_ext; // left of origin
                const right_enc = if (is_pmos) nwell_enc_f else impl_enc;
                const right = w_um + right_enc + poly_ext + ring_ext;
                const dim_x = left + right;

                // Y-extent: from body tap bottom to drain top + implant + guard ring.
                // body_cy = -(sd_ext + tap_gap + tap_half)
                // Bottom of body tap implant = body_cy - tap_half - impl_enc
                //   (or - nwell_enc for PMOS)
                const body_bot_margin = if (is_pmos) nwell_enc_f else impl_enc;
                const bottom = sd_ext + tap_gap_f + tap_diff + body_bot_margin + ring_ext;
                // Top: y + l + sd_ext + implant (or + nwell for PMOS)
                const top_margin = if (is_pmos) nwell_enc_f else impl_enc;
                const top = l_um + sd_ext + top_margin + ring_ext;
                const dim_y = bottom + top;

                devices.dimensions[i] = .{ dim_x, dim_y };
            },
            // Physical resistors: rectangular body, w × l in µm.
            // Fall back to a 2×8 µm default (4:1 aspect) when w/l not given.
            .res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal => {
                const p = devices.params[i];
                const w = if (p.w > 0.0) p.w * p2um else 2.0;
                const l = if (p.l > 0.0) p.l * p2um else 8.0;
                devices.dimensions[i] = .{ w, l };
            },
            // Physical capacitors: rectangular, w × l or estimated from capacitance.
            // MIM cap density ~2 fF/µm²; other cap types ~1 fF/µm².
            .cap_mim, .cap_mom, .cap_pip => {
                const p = devices.params[i];
                if (p.w > 0.0 and p.l > 0.0) {
                    devices.dimensions[i] = .{ p.w * p2um, p.l * p2um };
                } else {
                    const density: f32 = if (devices.types[i] == .cap_mim) 2e-15 else 1e-15;
                    const area_um2 = if (p.value > 0.0) p.value / density else 4.0;
                    const side = @sqrt(area_um2);
                    devices.dimensions[i] = .{ side, side };
                }
            },
            // Gate cap: sized like a MOSFET (w × l).
            .cap_gate => {
                const p = devices.params[i];
                const w = if (p.w > 0.0) p.w * p2um else 1.0;
                const l = if (p.l > 0.0) p.l * p2um else 1.0;
                devices.dimensions[i] = .{ w, l };
            },
            // Generic / structural devices: small default bounding box.
            .res, .cap, .ind, .subckt, .diode, .bjt_npn, .bjt_pnp, .jfet_n, .jfet_p => {
                devices.dimensions[i] = .{ 1.0, 1.0 };
            },
        }
    }
}

// ─── SpoutContext ───────────────────────────────────────────────────────────

const SpoutContext = struct {
    devices: device_arrays.DeviceArrays,
    nets: net_arrays.NetArrays,
    pins: pin_edge_arrays.PinEdgeArrays,
    constraints: constraint_arrays.ConstraintArrays,
    routes: ?route_arrays.RouteArrays,
    adj: ?adjacency.FlatAdjList,
    pdk: layout_if.PdkConfig,
    allocator: std.mem.Allocator,
    initialized: bool,

    /// Cached flattened route-segment buffer for FFI (7 f32s per segment).
    route_segments_flat: ?[]f32,

    /// Parse result kept alive for the lifetime of the context so that
    /// higher-level queries (get_num_devices, etc.) have data to return.
    parse_result: ?parser.ParseResult,

    /// Macro / unit-cell detection result; populated automatically after parse.
    macros: ?macro_mod.MacroArrays,
    /// Cached flat template-id array for FFI (one u32 per instance).
    macro_inst_tmpl_ids: ?[]u32,
    /// Cached flat positions array for FFI (two f32s per instance: x, y).
    macro_inst_positions: ?[]f32,

    /// In-engine DRC violations; null until spout_run_drc is called.
    drc_violations: ?[]characterize.DrcViolation,
    /// In-engine LVS report; null until spout_run_lvs is called.
    lvs_report: ?characterize.LvsReport,
    /// In-engine PEX result; null until spout_run_pex is called.
    /// Heap-allocated to avoid embedding std.mem.Allocator inline in SpoutContext.
    pex_result: ?*characterize.PexResult,
    /// Cached per-pin layout connectivity (component IDs) for FFI.
    layout_connectivity: ?[]u32,

    /// GDS template context; null until spout_load_template_gds is called.
    template_context: ?*template_mod.TemplateContext,

    fn fromHandle(raw: *anyopaque) *SpoutContext {
        return @ptrCast(@alignCast(raw));
    }
};

// ─── Lifecycle ──────────────────────────────────────────────────────────────

export fn spout_init_layout(backend: u8, pdk_id: u8) ?*anyopaque {
    _ = backend; // backend is recorded in LayoutIF at comptime; not relevant at runtime.

    // Load PDK defaults from the bundled JSON files.  The caller may later
    // override via spout_load_pdk_from_file (e.g. for custom process corners).
    const pdk_id_typed: pdk.PdkId = switch (pdk_id) {
        0 => .sky130,
        1 => .gf180,
        2 => .ihp130,
        else => .sky130,
    };
    const pdk_config = layout_if.PdkConfig.loadDefault(pdk_id_typed);

    const allocator = std.heap.page_allocator;

    const ctx_ptr = allocator.create(SpoutContext) catch return null;

    ctx_ptr.* = SpoutContext{
        .devices = device_arrays.DeviceArrays.init(allocator, 0) catch {
            allocator.destroy(ctx_ptr);
            return null;
        },
        .nets = net_arrays.NetArrays.init(allocator, 0) catch {
            allocator.destroy(ctx_ptr);
            return null;
        },
        .pins = pin_edge_arrays.PinEdgeArrays.init(allocator, 0) catch {
            allocator.destroy(ctx_ptr);
            return null;
        },
        .constraints = constraint_arrays.ConstraintArrays.init(allocator, 0) catch {
            allocator.destroy(ctx_ptr);
            return null;
        },
        .routes = null,
        .adj = null,
        .macros = null,
        .macro_inst_tmpl_ids = null,
        .macro_inst_positions = null,
        .pdk = pdk_config,
        .allocator = allocator,
        .initialized = true,
        .route_segments_flat = null,
        .parse_result = null,
        .drc_violations = null,
        .lvs_report = null,
        .pex_result = null,
        .layout_connectivity = null,
        .template_context = null,
    };

    return @ptrCast(ctx_ptr);
}

/// Replace the current PDK configuration by reading a JSON file at `path`.
///
/// Call this immediately after `spout_init_layout` to use a cloned PDK or any
/// custom PDK JSON.  Returns 0 on success, -1 on invalid handle, -4 on file or
/// parse error.
export fn spout_load_pdk_from_file(
    handle: *anyopaque,
    path_ptr: [*]const u8,
    path_len: usize,
) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    const path = path_ptr[0..path_len];
    ctx.pdk = pdk.loadFromFile(path, ctx.allocator) catch return -4;
    return 0;
}

export fn spout_destroy(handle: *anyopaque) void {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return;

    // Free cached FFI buffers.
    if (ctx.route_segments_flat) |buf| ctx.allocator.free(buf);
    if (ctx.layout_connectivity) |buf| ctx.allocator.free(buf);

    // Free macro detection and its FFI caches.
    if (ctx.macro_inst_tmpl_ids) |buf| ctx.allocator.free(buf);
    if (ctx.macro_inst_positions) |buf| ctx.allocator.free(buf);
    if (ctx.macros) |*m| m.deinit();

    // Free parse result if present.
    if (ctx.parse_result) |*pr| {
        pr.deinit();
    }

    // Free characterize results.
    if (ctx.drc_violations) |v| ctx.allocator.free(v);
    if (ctx.pex_result) |p| { p.deinit(); ctx.allocator.destroy(p); }

    // Free template context if loaded.
    if (ctx.template_context) |tc| {
        tc.deinit();
        ctx.allocator.destroy(tc);
        ctx.template_context = null;
    }

    // Tear down SoA arrays in reverse order of construction.
    if (ctx.adj) |*a| a.deinit();
    if (ctx.routes) |*r| r.deinit();
    ctx.constraints.deinit();
    ctx.pins.deinit();
    ctx.nets.deinit();
    ctx.devices.deinit();

    ctx.initialized = false;
    ctx.allocator.destroy(ctx);
}

// ─── Parsing ────────────────────────────────────────────────────────────────

export fn spout_parse_netlist(handle: *anyopaque, path_ptr: [*]const u8, path_len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const path = path_ptr[0..path_len];

    // Discard previous parse result if any.
    if (ctx.parse_result) |*pr| {
        pr.deinit();
        ctx.parse_result = null;
    }

    // Reset existing SoA arrays and derived state.
    if (ctx.macro_inst_tmpl_ids) |buf| { ctx.allocator.free(buf); ctx.macro_inst_tmpl_ids = null; }
    if (ctx.macro_inst_positions) |buf| { ctx.allocator.free(buf); ctx.macro_inst_positions = null; }
    if (ctx.macros) |*m| { m.deinit(); ctx.macros = null; }
    ctx.devices.deinit();
    ctx.nets.deinit();
    ctx.pins.deinit();
    if (ctx.adj) |*a| {
        a.deinit();
        ctx.adj = null;
    }

    var p = parser.Parser.init(ctx.allocator);
    defer p.deinit();

    var result = p.parseFile(path) catch return -2;

    // Populate SoA arrays from parse result.
    const n_dev: u32 = @intCast(result.devices.len);
    const n_net: u32 = @intCast(result.nets.len);
    const n_pin: u32 = @intCast(result.pins.len);

    ctx.devices = device_arrays.DeviceArrays.init(ctx.allocator, n_dev) catch {
        result.deinit();
        return -3;
    };
    ctx.nets = net_arrays.NetArrays.init(ctx.allocator, n_net) catch {
        result.deinit();
        return -3;
    };
    ctx.pins = pin_edge_arrays.PinEdgeArrays.init(ctx.allocator, n_pin) catch {
        result.deinit();
        return -3;
    };

    // Copy parsed device data into SoA arrays.
    for (result.devices, 0..) |dev, i| {
        ctx.devices.types[i] = dev.device_type;
        ctx.devices.params[i] = dev.params;
    }

    // Copy parsed net metadata.
    for (result.nets, 0..) |net, i| {
        ctx.nets.fanout[i] = @intCast(net.fanout);
        ctx.nets.is_power[i] = net.is_power;
    }

    // Copy parsed pin edges.
    for (result.pins, 0..) |pin, i| {
        ctx.pins.device[i] = pin.device;
        ctx.pins.net[i] = pin.net;
        ctx.pins.terminal[i] = pin.terminal;
    }

    // Compute pin offsets from device geometry so each terminal (gate,
    // source, drain, etc.) gets a distinct spatial position relative to
    // the device centre.  Without this, all pins collapse to (0,0) and
    // the placer/router cannot distinguish between terminals.
    ctx.pins.computePinOffsets(&ctx.devices);

    // Compute device bounding-box dimensions (in µm) from the device
    // parameters so the SA placer can penalize overlapping devices.
    // The dimensions include all geometry layers (diffusion, implants,
    // contacts, body taps) matching what the GDSII writer produces.
    computeDeviceDimensions(&ctx.devices, &ctx.pdk);

    // Build the core adjacency list from the SoA pin arrays.
    ctx.adj = adjacency.FlatAdjList.build(
        ctx.allocator,
        &ctx.pins,
        n_dev,
        n_net,
    ) catch {
        result.deinit();
        return -4;
    };

    // Auto-detect macros while parse_devices (subckt_type slices) are still valid.
    ctx.macros = macro_mod.detectMacros(
        ctx.allocator,
        &ctx.devices,
        result.devices,
        &ctx.pins,
        &ctx.adj.?,
        macro_mod.MacroConfig{},
    ) catch null;

    // Keep parse result alive (caller might need subcircuit info, etc.).
    ctx.parse_result = result;

    return 0;
}

export fn spout_get_device_positions(handle: *anyopaque) Span(f32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.devices.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    // positions is [][2]f32 — reinterpret as flat f32 slice.
    const flat: [*]f32 = @ptrCast(ctx.devices.positions.ptr);
    return .{ .ptr = flat, .len = @as(usize, ctx.devices.len) * 2 };
}

export fn spout_get_device_types(handle: *anyopaque) Span(u8) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.devices.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    const raw: [*]u8 = @ptrCast(ctx.devices.types.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.devices.len) };
}

export fn spout_get_device_params(handle: *anyopaque) Span(u8) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.devices.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    const raw: [*]u8 = @ptrCast(ctx.devices.params.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.devices.len) * @sizeOf(types.DeviceParams) };
}

export fn spout_get_net_fanout(handle: *anyopaque) Span(u16) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.nets.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    return .{ .ptr = ctx.nets.fanout.ptr, .len = @as(usize, ctx.nets.len) };
}

export fn spout_get_pin_device(handle: *anyopaque) Span(u32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.pins.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    const raw: [*]u32 = @ptrCast(ctx.pins.device.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.pins.len) };
}

export fn spout_get_pin_net(handle: *anyopaque) Span(u32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.pins.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    const raw: [*]u32 = @ptrCast(ctx.pins.net.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.pins.len) };
}

export fn spout_get_pin_terminal(handle: *anyopaque) Span(u8) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.pins.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    const raw: [*]u8 = @ptrCast(ctx.pins.terminal.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.pins.len) };
}

export fn spout_get_num_devices(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    return ctx.devices.len;
}

export fn spout_get_num_nets(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    return ctx.nets.len;
}

export fn spout_get_num_pins(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    return ctx.pins.len;
}

// ─── Constraints ────────────────────────────────────────────────────────────

export fn spout_extract_constraints(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const adj_ptr = if (ctx.adj) |*a| a else return -2;

    // Free previous constraints.
    ctx.constraints.deinit();

    ctx.constraints = constraint_extract.extractConstraints(
        ctx.allocator,
        &ctx.devices,
        &ctx.nets,
        &ctx.pins,
        adj_ptr,
    ) catch return -3;

    return 0;
}

export fn spout_get_constraints(handle: *anyopaque) Span(u8) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized or ctx.constraints.len == 0) {
        return .{ .ptr = undefined, .len = 0 };
    }
    // Return the constraint types array as a byte span.
    const raw: [*]u8 = @ptrCast(ctx.constraints.types.ptr);
    return .{ .ptr = raw, .len = @as(usize, ctx.constraints.len) };
}

// ─── Macro / unit-cell read-back ─────────────────────────────────────────────

/// Explicitly re-run macro detection.  Also runs automatically after
/// spout_parse_netlist, so callers only need this to change MacroConfig.
export fn spout_detect_macros(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    if (ctx.adj == null) return -2;
    if (ctx.macro_inst_tmpl_ids) |buf| { ctx.allocator.free(buf); ctx.macro_inst_tmpl_ids = null; }
    if (ctx.macro_inst_positions) |buf| { ctx.allocator.free(buf); ctx.macro_inst_positions = null; }
    if (ctx.macros) |*m| m.deinit();
    const parse_devices: []const @import("netlist/types.zig").DeviceInfo =
        if (ctx.parse_result) |pr| pr.devices else &.{};
    ctx.macros = macro_mod.detectMacros(
        ctx.allocator, &ctx.devices, parse_devices,
        &ctx.pins, &ctx.adj.?, macro_mod.MacroConfig{},
    ) catch return -3;
    return 0;
}

export fn spout_get_macro_template_count(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    return if (ctx.macros) |m| m.template_count else 0;
}

export fn spout_get_macro_instance_count(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    return if (ctx.macros) |m| m.instance_count else 0;
}

/// Flat i32 span, one entry per device. -1 if not in any macro.
export fn spout_get_macro_device_inst(handle: *anyopaque) Span(i32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };
    const m = if (ctx.macros) |m| m else return .{ .ptr = undefined, .len = 0 };
    return .{ .ptr = m.device_inst.ptr, .len = m.device_inst.len };
}

/// Flat u32 span: local index within template for each device.
export fn spout_get_macro_device_local(handle: *anyopaque) Span(u32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };
    const m = if (ctx.macros) |m| m else return .{ .ptr = undefined, .len = 0 };
    return .{ .ptr = m.device_local.ptr, .len = m.device_local.len };
}

/// Flat u32 span: template_id for each instance (cached on first call).
export fn spout_get_macro_instance_template_ids(handle: *anyopaque) Span(u32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };
    const m = ctx.macros orelse return .{ .ptr = undefined, .len = 0 };
    if (m.instance_count == 0) return .{ .ptr = undefined, .len = 0 };
    if (ctx.macro_inst_tmpl_ids) |buf| return .{ .ptr = buf.ptr, .len = buf.len };
    const buf = ctx.allocator.alloc(u32, m.instance_count) catch return .{ .ptr = undefined, .len = 0 };
    for (m.instances[0..m.instance_count], 0..) |inst, i| buf[i] = inst.template_id;
    ctx.macro_inst_tmpl_ids = buf;
    return .{ .ptr = buf.ptr, .len = buf.len };
}

/// Flat f32 span: [x0, y0, x1, y1, …] instance positions (cached on first call).
export fn spout_get_macro_instance_positions(handle: *anyopaque) Span(f32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };
    const m = ctx.macros orelse return .{ .ptr = undefined, .len = 0 };
    if (m.instance_count == 0) return .{ .ptr = undefined, .len = 0 };
    if (ctx.macro_inst_positions) |buf| return .{ .ptr = buf.ptr, .len = buf.len };
    const buf = ctx.allocator.alloc(f32, @as(usize, m.instance_count) * 2) catch return .{ .ptr = undefined, .len = 0 };
    for (m.instances[0..m.instance_count], 0..) |inst, i| {
        buf[i * 2] = inst.position[0];
        buf[i * 2 + 1] = inst.position[1];
    }
    ctx.macro_inst_positions = buf;
    return .{ .ptr = buf.ptr, .len = buf.len };
}

export fn spout_set_constraints_from_ml(handle: *anyopaque, _: [*]const u8, _: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    // Placeholder — ML constraint write-back not yet implemented.
    return 0;
}

export fn spout_add_constraints_from_ml(
    handle: *anyopaque,
    data:   [*]const u8,
    len:    usize,
) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    if (ctx.adj == null) return -2; // parse must be called before ML augmentation
    const slice = data[0..len];
    constraint_extract.addConstraintsFromML(ctx.allocator, &ctx.constraints, slice) catch return -3;
    return 0;
}

// ─── ML Write-Back ──────────────────────────────────────────────────────────

export fn spout_set_device_embeddings(handle: *anyopaque, data: [*]const f32, len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const n: usize = @intCast(ctx.devices.len);
    const expected = n * 64;
    if (len != expected) return -2;

    // Copy embedding data row by row (each row is 64 f32s).
    for (0..n) |i| {
        const src = data[i * 64 .. (i + 1) * 64];
        @memcpy(&ctx.devices.embeddings[i], src);
    }

    return 0;
}

export fn spout_set_net_embeddings(handle: *anyopaque, data: [*]const f32, len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const n: usize = @intCast(ctx.nets.len);
    const expected = n * 64;
    if (len != expected) return -2;

    for (0..n) |i| {
        const src = data[i * 64 .. (i + 1) * 64];
        @memcpy(&ctx.nets.embeddings[i], src);
    }

    return 0;
}

export fn spout_set_predicted_cap(handle: *anyopaque, data: [*]const f32, len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const n: usize = @intCast(ctx.devices.len);
    if (len != n) return -2;

    @memcpy(ctx.devices.predicted_cap, data[0..n]);

    return 0;
}

// ─── Placement ──────────────────────────────────────────────────────────────

export fn spout_run_sa_placement(handle: *anyopaque, config_ptr: [*]const u8, config_len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    if (ctx.devices.len == 0) return 0; // nothing to place

    // Parse optional JSON-like configuration (for now we accept a raw SaConfig
    // blob or fall back to defaults).
    var sa_config = sa.SaConfig{};

    if (config_len == @sizeOf(sa.SaConfig)) {
        // Treat the buffer as a raw SaConfig struct.
        const cfg_bytes = config_ptr[0..@sizeOf(sa.SaConfig)];
        sa_config = @as(*align(1) const sa.SaConfig, @ptrCast(cfg_bytes)).*;
    }

    // Apply template hard bounds from ctx.template_context (if loaded).
    // This overrides whatever use_template_bounds / template_* the caller
    // set in the SaConfig blob, ensuring the template is always respected.
    if (ctx.template_context) |tc| {
        const bounds = tc.getUserAreaBounds();
        sa_config.template_x_min = bounds[0];
        sa_config.template_y_min = bounds[1];
        sa_config.template_x_max = bounds[2];
        sa_config.template_y_max = bounds[3];
        sa_config.use_template_bounds = true;
    }

    const n_dev: usize = @intCast(ctx.devices.len);

    // ── Compute per-device bounding-box centre offsets ─────────────────
    // The GDSII writer treats device_positions as the origin of the gate
    // channel (bottom-left).  The SA overlap cost treats positions as
    // bounding-box centres.  We shift positions to centres before SA and
    // shift them back afterward.
    const centre_offsets = ctx.allocator.alloc([2]f32, n_dev) catch return -3;
    defer ctx.allocator.free(centre_offsets);

    {
        const p2um = ctx.pdk.param_to_um;
        const db = ctx.pdk.db_unit;
        const sd_ext: f32 = 260.0 * db;
        const poly_ext: f32 = 150.0 * db;
        const impl_enc: f32 = 130.0 * db;
        const nwell_enc_f: f32 = 200.0 * db;
        const gate_pad_w: f32 = 400.0 * db;
        const tap_gap_f: f32 = 270.0 * db;
        const tap_diff: f32 = 340.0 * db;

        for (0..n_dev) |di| {
            switch (ctx.devices.types[di]) {
                .nmos, .pmos => {
                    const raw_w = ctx.devices.params[di].w;
                    const raw_l = ctx.devices.params[di].l;
                    const mult: f32 = @floatFromInt(@max(@as(u16, 1), ctx.devices.params[di].mult));
                    const w_um = if (raw_w > 0.0) raw_w * p2um * mult else 1.0;
                    const l_um = if (raw_l > 0.0) raw_l * p2um else 0.15;
                    const is_pmos = (ctx.devices.types[di] == .pmos);

                    // Extent left of origin and right of origin
                    const left = gate_pad_w + poly_ext;
                    const right_enc = if (is_pmos) nwell_enc_f else impl_enc;
                    const right = w_um + right_enc + poly_ext;

                    // Extent below origin and above origin
                    const body_margin = if (is_pmos) nwell_enc_f else impl_enc;
                    const bot = sd_ext + tap_gap_f + tap_diff + body_margin;
                    const top = l_um + sd_ext + (if (is_pmos) nwell_enc_f else impl_enc);

                    // Centre offset = midpoint relative to origin
                    centre_offsets[di] = .{
                        (right - left) * 0.5,
                        (top - bot) * 0.5,
                    };
                },
                .res, .cap, .ind, .subckt,
                .diode, .bjt_npn, .bjt_pnp, .jfet_n, .jfet_p,
                .res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal,
                .cap_mim, .cap_mom, .cap_pip, .cap_gate => {
                    centre_offsets[di] = .{ 0.5, 0.5 };
                },
            }
        }
    }

    // Shift device positions to bounding-box centres for the SA.
    for (0..n_dev) |di| {
        ctx.devices.positions[di][0] += centre_offsets[di][0];
        ctx.devices.positions[di][1] += centre_offsets[di][1];
    }

    // Build placer-local pin info with offsets adjusted for the centre shift.
    const n_pin: usize = @intCast(ctx.pins.len);
    const pin_info = ctx.allocator.alloc(cost.PinInfo, n_pin) catch return -3;
    defer ctx.allocator.free(pin_info);

    for (0..n_pin) |i| {
        const dev_raw = ctx.pins.device[i].toInt();
        pin_info[i] = .{
            .device = dev_raw,
            .offset_x = ctx.pins.position[i][0] - (if (dev_raw < n_dev) centre_offsets[dev_raw][0] else 0.0),
            .offset_y = ctx.pins.position[i][1] - (if (dev_raw < n_dev) centre_offsets[dev_raw][1] else 0.0),
        };
    }

    // Build placer-local net adjacency from the core FlatAdjList.
    const adj_ptr = if (ctx.adj) |*a| a else return -2;
    const placer_adj = rudy.NetAdjacency{
        .net_pin_starts = adj_ptr.net_pin_offsets,
        .pin_list = adj_ptr.net_pin_list,
        .num_nets = ctx.nets.len,
    };

    // Build placer-local constraint list.
    const n_con: usize = @intCast(ctx.constraints.len);
    const placer_constraints = ctx.allocator.alloc(cost.Constraint, n_con) catch return -3;
    defer ctx.allocator.free(placer_constraints);

    for (0..n_con) |i| {
        placer_constraints[i] = .{
            .kind = ctx.constraints.types[i],
            .dev_a = ctx.constraints.device_a[i].toInt(),
            .dev_b = ctx.constraints.device_b[i].toInt(),
            .axis_x = ctx.constraints.axis[i],
            .axis_y = 0.0,
            .param = 0.0,
        };
    }

    // Layout bounds: sum of actual device widths/heights plus margins so
    // the SA has room to separate devices without running out of space.
    var sum_w: f32 = 0.0;
    var max_h: f32 = 0.0;
    for (0..n_dev) |di| {
        const dw = if (ctx.devices.dimensions[di][0] > 0.0) ctx.devices.dimensions[di][0] else 2.0;
        const dh = if (ctx.devices.dimensions[di][1] > 0.0) ctx.devices.dimensions[di][1] else 2.0;
        sum_w += dw;
        max_h = @max(max_h, dh);
    }
    const margin: f32 = @floatFromInt(@as(u32, ctx.devices.len) * 5);
    const bound_w: f32 = sum_w + margin;
    const bound_h: f32 = max_h * 3.0 + margin;

    // Scale perturbation range to typical device size so moves are meaningful
    // but not so large that the SA can't fine-tune placement.
    const avg_dim = (sum_w / @as(f32, @floatFromInt(ctx.devices.len)) + max_h) * 0.5;
    sa_config.perturbation_range = @max(avg_dim * 0.5, 1.0);

    const result = sa.runSa(
        ctx.devices.positions,
        ctx.devices.dimensions,
        pin_info,
        placer_adj,
        placer_constraints,
        bound_w,
        bound_h,
        sa_config,
        42, // deterministic seed
        ctx.allocator,
        .{},
    ) catch return -4;

    // Shift device positions back to GDSII origins (from centres).
    for (0..n_dev) |di| {
        ctx.devices.positions[di][0] -= centre_offsets[di][0];
        ctx.devices.positions[di][1] -= centre_offsets[di][1];
    }

    _ = result;
    return 0;
}

/// Two-phase hierarchical SA: unit-cell then super-device.
/// If no macros are detected, falls back to standard SA.
export fn spout_run_sa_hierarchical(handle: *anyopaque, config_ptr: [*]const u8, config_len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    if (ctx.devices.len == 0) return 0;

    var sa_config = sa.SaConfig{};
    if (config_len == @sizeOf(sa.SaConfig)) {
        const cfg_bytes = config_ptr[0..@sizeOf(sa.SaConfig)];
        sa_config = @as(*align(1) const sa.SaConfig, @ptrCast(cfg_bytes)).*;
    }

    // Apply template hard bounds from ctx.template_context (if loaded).
    if (ctx.template_context) |tc| {
        const bounds = tc.getUserAreaBounds();
        sa_config.template_x_min = bounds[0];
        sa_config.template_y_min = bounds[1];
        sa_config.template_x_max = bounds[2];
        sa_config.template_y_max = bounds[3];
        sa_config.use_template_bounds = true;
    }

    const n_dev: usize = @intCast(ctx.devices.len);
    const centre_offsets = ctx.allocator.alloc([2]f32, n_dev) catch return -3;
    defer ctx.allocator.free(centre_offsets);

    {
        const p2um = ctx.pdk.param_to_um;
        const db = ctx.pdk.db_unit;
        const sd_ext: f32 = 260.0 * db;
        const poly_ext: f32 = 150.0 * db;
        const impl_enc: f32 = 130.0 * db;
        const nwell_enc_f: f32 = 200.0 * db;
        const gate_pad_w: f32 = 400.0 * db;
        const tap_gap_f: f32 = 270.0 * db;
        const tap_diff: f32 = 340.0 * db;
        for (0..n_dev) |di| {
            switch (ctx.devices.types[di]) {
                .nmos, .pmos => {
                    const raw_w = ctx.devices.params[di].w;
                    const raw_l = ctx.devices.params[di].l;
                    const mult: f32 = @floatFromInt(@max(@as(u16, 1), ctx.devices.params[di].mult));
                    const w_um = if (raw_w > 0.0) raw_w * p2um * mult else 1.0;
                    const l_um = if (raw_l > 0.0) raw_l * p2um else 0.15;
                    const is_pmos = (ctx.devices.types[di] == .pmos);
                    const left = gate_pad_w + poly_ext;
                    const right = w_um + (if (is_pmos) nwell_enc_f else impl_enc) + poly_ext;
                    const body_margin = if (is_pmos) nwell_enc_f else impl_enc;
                    const bot = sd_ext + tap_gap_f + tap_diff + body_margin;
                    const top = l_um + sd_ext + (if (is_pmos) nwell_enc_f else impl_enc);
                    centre_offsets[di] = .{ (right - left) * 0.5, (top - bot) * 0.5 };
                },
                else => { centre_offsets[di] = .{ 0.5, 0.5 }; },
            }
        }
    }
    for (0..n_dev) |di| {
        ctx.devices.positions[di][0] += centre_offsets[di][0];
        ctx.devices.positions[di][1] += centre_offsets[di][1];
    }

    const n_pin: usize = @intCast(ctx.pins.len);
    const pin_info = ctx.allocator.alloc(cost.PinInfo, n_pin) catch return -3;
    defer ctx.allocator.free(pin_info);
    for (0..n_pin) |i| {
        const dev_raw = ctx.pins.device[i].toInt();
        pin_info[i] = .{
            .device = dev_raw,
            .offset_x = ctx.pins.position[i][0] - (if (dev_raw < n_dev) centre_offsets[dev_raw][0] else 0.0),
            .offset_y = ctx.pins.position[i][1] - (if (dev_raw < n_dev) centre_offsets[dev_raw][1] else 0.0),
        };
    }

    const adj_ptr = if (ctx.adj) |*a| a else return -2;
    const placer_adj = rudy.NetAdjacency{
        .net_pin_starts = adj_ptr.net_pin_offsets,
        .pin_list = adj_ptr.net_pin_list,
        .num_nets = ctx.nets.len,
    };

    const n_con: usize = @intCast(ctx.constraints.len);
    const placer_constraints = ctx.allocator.alloc(cost.Constraint, n_con) catch return -3;
    defer ctx.allocator.free(placer_constraints);
    for (0..n_con) |i| {
        placer_constraints[i] = .{
            .kind = ctx.constraints.types[i],
            .dev_a = ctx.constraints.device_a[i].toInt(),
            .dev_b = ctx.constraints.device_b[i].toInt(),
            .axis_x = ctx.constraints.axis[i],
            .axis_y = 0.0,
            .param = 0.0,
        };
    }

    var sum_w: f32 = 0.0;
    var max_h: f32 = 0.0;
    for (0..n_dev) |di| {
        sum_w += if (ctx.devices.dimensions[di][0] > 0.0) ctx.devices.dimensions[di][0] else 2.0;
        max_h = @max(max_h, if (ctx.devices.dimensions[di][1] > 0.0) ctx.devices.dimensions[di][1] else 2.0);
    }
    const margin: f32 = @floatFromInt(@as(u32, ctx.devices.len) * 5);
    const bound_w = sum_w + margin;
    const bound_h = max_h * 3.0 + margin;
    sa_config.perturbation_range = @max((sum_w / @as(f32, @floatFromInt(ctx.devices.len)) + max_h) * 0.25, 1.0);

    // Invalidate cached instance positions (will change after hierarchical SA).
    if (ctx.macro_inst_positions) |buf| { ctx.allocator.free(buf); ctx.macro_inst_positions = null; }

    if (ctx.macros) |*m| {
        _ = sa.runSaHierarchical(
            ctx.allocator, &ctx.devices, m, pin_info, placer_adj,
            placer_constraints, bound_w, bound_h, sa_config, 42,
        ) catch return -4;
    } else {
        _ = sa.runSa(
            ctx.devices.positions, ctx.devices.dimensions, pin_info, placer_adj,
            placer_constraints, bound_w, bound_h, sa_config, 42, ctx.allocator, .{},
        ) catch return -4;
    }

    for (0..n_dev) |di| {
        ctx.devices.positions[di][0] -= centre_offsets[di][0];
        ctx.devices.positions[di][1] -= centre_offsets[di][1];
    }
    return 0;
}

export fn spout_get_placement_cost(handle: *anyopaque) f32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1.0;

    // Compute cost from current device positions using the cost module.
    const n_pin: usize = @intCast(ctx.pins.len);
    if (n_pin == 0) return 0.0;

    const pin_positions = ctx.allocator.alloc([2]f32, n_pin) catch return -1.0;
    defer ctx.allocator.free(pin_positions);

    // Compute pin positions from device positions + offsets.
    for (0..n_pin) |i| {
        const dev: usize = ctx.pins.device[i].toInt();
        if (dev < ctx.devices.len) {
            pin_positions[i][0] = ctx.devices.positions[dev][0] + ctx.pins.position[i][0];
            pin_positions[i][1] = ctx.devices.positions[dev][1] + ctx.pins.position[i][1];
        } else {
            pin_positions[i] = .{ 0.0, 0.0 };
        }
    }

    // Build adjacency for cost computation.
    const adj_ptr = if (ctx.adj) |*a| a else return -1.0;
    const placer_adj = rudy.NetAdjacency{
        .net_pin_starts = adj_ptr.net_pin_offsets,
        .pin_list = adj_ptr.net_pin_list,
        .num_nets = ctx.nets.len,
    };

    return cost.computeHpwlAll(pin_positions, placer_adj, ctx.nets.is_power);
}

export fn spout_run_gradient_refinement(handle: *anyopaque, _: f32, _: u32) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    // Placeholder — gradient refinement not yet implemented.
    return 0;
}

// ─── Routing ────────────────────────────────────────────────────────────────

export fn spout_run_routing(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const adj_ptr = if (ctx.adj) |*a| a else return -2;

    // Discard previous routes.
    if (ctx.routes) |*r| {
        r.deinit();
        ctx.routes = null;
    }

    var detail_router = detailed.DetailedRouter.init(ctx.allocator) catch return -3;

    detail_router.routeAll(
        &ctx.devices,
        &ctx.nets,
        &ctx.pins,
        adj_ptr,
        &ctx.pdk,
    ) catch {
        detail_router.deinit();
        return -4;
    };

    // Rip-up-and-reroute: resolve conflicts from net ordering.
    _ = detailed.ripUpAndReroute(
        &detail_router,
        &ctx.devices,
        &ctx.nets,
        &ctx.pins,
        adj_ptr,
        &ctx.pdk,
        3,
    ) catch {};

    // Transfer ownership of routes from the router to the context.
    ctx.routes = detail_router.routes;
    // Prevent the router deinit from freeing the routes we just took.
    detail_router.routes = route_arrays.RouteArrays.init(ctx.allocator, 0) catch {
        // If this fails, we need to give back the routes to the router for cleanup.
        detail_router.routes = ctx.routes.?;
        ctx.routes = null;
        detail_router.deinit();
        return -5;
    };
    detail_router.deinit();

    return 0;
}

export fn spout_get_num_routes(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    if (ctx.routes) |r| return r.len;
    return 0;
}

export fn spout_get_route_segments(handle: *anyopaque) Span(f32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };

    const r = ctx.routes orelse return .{ .ptr = undefined, .len = 0 };
    const n: usize = @intCast(r.len);
    if (n == 0) return .{ .ptr = undefined, .len = 0 };

    // Free previous cached buffer if any.
    if (ctx.route_segments_flat) |old| {
        ctx.allocator.free(old);
        ctx.route_segments_flat = null;
    }

    // Build interleaved buffer: 7 f32s per segment (layer, x1, y1, x2, y2, width, net).
    const buf = ctx.allocator.alloc(f32, n * 7) catch return .{ .ptr = undefined, .len = 0 };
    for (0..n) |i| {
        const base = i * 7;
        buf[base + 0] = @floatFromInt(r.layer[i]);
        buf[base + 1] = r.x1[i];
        buf[base + 2] = r.y1[i];
        buf[base + 3] = r.x2[i];
        buf[base + 4] = r.y2[i];
        buf[base + 5] = r.width[i];
        buf[base + 6] = @floatFromInt(r.net[i].toInt());
    }

    ctx.route_segments_flat = buf;
    return .{ .ptr = buf.ptr, .len = n * 7 };
}

// ─── Export ─────────────────────────────────────────────────────────────────

export fn spout_export_gdsii(handle: *anyopaque, path_ptr: [*]const u8, path_len: usize) i32 {
    return spout_export_gdsii_named(handle, path_ptr, path_len, null, 0);
}

export fn spout_export_gdsii_named(handle: *anyopaque, path_ptr: [*]const u8, path_len: usize, name_ptr: ?[*]const u8, name_len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    const path = path_ptr[0..path_len];

    // Derive cell name: use explicit name if given, else strip directory/extension from path
    const cell_name: []const u8 = if (name_ptr) |np| np[0..name_len] else blk: {
        var base = path;
        // Strip directory prefix
        if (std.mem.lastIndexOfScalar(u8, base, '/')) |pos| base = base[pos + 1 ..];
        // Strip .gds extension
        if (std.mem.endsWith(u8, base, ".gds")) base = base[0 .. base.len - 4];
        break :blk base;
    };

    var writer = gdsii.GdsiiWriter.init(ctx.allocator);
    defer writer.deinit();

    const routes_ptr: ?*const route_arrays.RouteArrays = if (ctx.routes) |*r| r else null;

    // Build net-name slice from parse result for TEXT labels (KLayout LVS).
    var net_name_buf: ?[]const []const u8 = null;
    defer if (net_name_buf) |buf| ctx.allocator.free(buf);

    if (ctx.parse_result) |pr| {
        if (pr.nets.len > 0) {
            const names = ctx.allocator.alloc([]const u8, pr.nets.len) catch null;
            if (names) |ns| {
                for (pr.nets, 0..) |net, i| {
                    ns[i] = net.name;
                }
                net_name_buf = ns;
            }
        }
    }

    const pins_ptr: ?*const pin_edge_arrays.PinEdgeArrays = if (ctx.pins.len > 0) &ctx.pins else null;

    writer.exportLayout(
        path,
        &ctx.devices,
        routes_ptr,
        &ctx.pdk,
        cell_name,
        net_name_buf,
        pins_ptr,
    ) catch return -2;

    return 0;
}

// ─── Characterize: DRC / LVS / PEX ─────────────────────────────────────────

/// Run in-engine DRC on the current route segments.
/// Converts each route segment to an AABB rectangle, then applies spacing/
/// width rules from the context PDK.  Results stored in ctx.drc_violations.
/// Returns 0 on success, -1 invalid handle, -2 no routes, -3 OOM.
export fn spout_run_drc(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    const routes = if (ctx.routes) |*r| r else return -2;

    if (ctx.drc_violations) |v| ctx.allocator.free(v);
    ctx.drc_violations = null;

    const n: usize = @intCast(routes.len);
    var shapes = shape_arrays.ShapeArrays.init(ctx.allocator, @intCast(n + 512)) catch return -3;
    defer shapes.deinit();

    // Export layout to a temp GDS and parse every BOUNDARY record on a DRC-
    // relevant layer (routing metals, contacts, vias, device layers).
    // Routes are written as GDS PATH records (not BOUNDARY), so they are
    // NOT captured here — they are added separately below.
    const tmp_path = "/tmp/spout_drc_tmp.gds";
    if (spout_export_gdsii_named(handle, tmp_path.ptr, tmp_path.len, null, 0) == 0) {
        parseBoundaryShapes(tmp_path, &ctx.pdk, &shapes, ctx.allocator) catch {};
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    // Add route segments as AABBs.  The GDS exporter writes routes as PATH
    // records which parseBoundaryShapes skips; we reconstruct the same
    // rectangles MAGIC would derive from those PATHs.
    for (0..n) |i| {
        const x1 = routes.x1[i]; const y1 = routes.y1[i];
        const x2 = routes.x2[i]; const y2 = routes.y2[i];
        const hw = routes.width[i] * 0.5;
        const horiz = @abs(x2 - x1) >= @abs(y2 - y1);
        const xmin: f32 = if (horiz) @min(x1, x2) else @min(x1, x2) - hw;
        const xmax: f32 = if (horiz) @max(x1, x2) else @max(x1, x2) + hw;
        const ymin: f32 = if (horiz) @min(y1, y2) - hw else @min(y1, y2);
        const ymax: f32 = if (horiz) @max(y1, y2) + hw else @max(y1, y2);
        const rl: usize = @intCast(routes.layer[i]);
        const gds_layer: u16 = if (rl < 8) @intCast(ctx.pdk.layer_map[rl]) else 0;
        shapes.append(xmin, ymin, xmax, ymax, gds_layer, 20, routes.net[i]) catch return -3;
    }

    // ── Temporary diagnostic: dump shape counts per (layer,dt) ──────────
    {
        const sn: usize = @intCast(shapes.len);
        var diag_buf: [4096]u8 = undefined;
        var dpos: usize = 0;
        // Count per (layer, dt) — use a simple array of pairs
        var layer_dt_counts: [64]struct { l: u16, d: u16, c: u32 } = undefined;
        var n_ld: usize = 0;
        for (0..sn) |si| {
            const sl = shapes.gds_layer[si];
            const sd = shapes.gds_datatype[si];
            var found = false;
            for (0..n_ld) |li| {
                if (layer_dt_counts[li].l == sl and layer_dt_counts[li].d == sd) {
                    layer_dt_counts[li].c += 1;
                    found = true;
                    break;
                }
            }
            if (!found and n_ld < 64) {
                layer_dt_counts[n_ld] = .{ .l = sl, .d = sd, .c = 1 };
                n_ld += 1;
            }
        }
        const hdr = std.fmt.bufPrint(diag_buf[dpos..], "total_shapes: {d}\n", .{sn}) catch "";
        dpos += hdr.len;
        for (0..n_ld) |li| {
            const e = layer_dt_counts[li];
            const s2 = std.fmt.bufPrint(diag_buf[dpos..], "  ({d},{d}): {d}\n", .{ e.l, e.d, e.c }) catch break;
            dpos += s2.len;
        }
        if (std.fs.cwd().createFile("/tmp/spout_drc_shapes.txt", .{})) |f| {
            _ = f.write(diag_buf[0..dpos]) catch {};
            f.close();
        } else |_| {}
    }
    // ── End shape count diagnostic ───────────────────────────────────────

    ctx.drc_violations = characterize.runDrc(&shapes, &ctx.pdk, ctx.allocator) catch return -3;

    // ── Temporary diagnostic: write per-rule breakdown to /tmp ────────────
    if (ctx.drc_violations) |viols| {
        var counts = [_]u32{0} ** 10; // DrcRule has 10 variants
        // Per-rule-per-layer: [rule][layer] where layer is GDS layer number mod 128
        var rl_counts: [10][128]u32 = std.mem.zeroes([10][128]u32);
        for (viols) |v| {
            const ri: usize = @intFromEnum(v.rule);
            if (ri < 10) {
                counts[ri] += 1;
                rl_counts[ri][v.layer] += 1;
            }
        }
        const rule_names = [_][]const u8{
            "min_spacing", "min_width", "min_enclosure", "min_area",
            "short", "notch", "same_net_spacing", "enc_second_edges",
            "separation", "hole_area",
        };
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        for (counts, 0..) |c, i| {
            if (c > 0) {
                const s = std.fmt.bufPrint(buf[pos..], "{s}: {d}\n", .{ rule_names[i], c }) catch break;
                pos += s.len;
                // Print per-layer breakdown for this rule
                for (rl_counts[i], 0..) |lc, li| {
                    if (lc > 0) {
                        const ls = std.fmt.bufPrint(buf[pos..], "  gds_layer={d}: {d}\n", .{ li, lc }) catch break;
                        pos += ls.len;
                    }
                }
            }
        }
        const total_s = std.fmt.bufPrint(buf[pos..], "TOTAL: {d}\n", .{viols.len}) catch "";
        pos += total_s.len;
        if (std.fs.cwd().createFile("/tmp/spout_drc_breakdown.txt", .{})) |f| {
            _ = f.write(buf[0..pos]) catch {};
            f.close();
        } else |_| {}
    }
    // ── End temporary diagnostic ─────────────────────────────────────────

    return 0;
}

/// Parse every BOUNDARY record on a routing layer from a GDS file and append
/// to `shapes` as none_net.  These are device pad shapes (LI/M1 contacts,
/// via landing pads) emitted by the GDSII writer.
///
/// GDS record format: [length u16 BE][record_type u8][data_type u8][data...]
/// Coordinates are i32 big-endian in database units; divide by 1/db_unit to
/// get micrometers (e.g. SKY130: db_unit=0.001, so divide raw value by 1000).
fn parseBoundaryShapes(
    path: []const u8,
    pdk_cfg: *const pdk.PdkConfig,
    shapes: *shape_arrays.ShapeArrays,
    allocator: std.mem.Allocator,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 32 * 1024 * 1024);
    defer allocator.free(data);

    const NONE = shape_arrays.ShapeArrays.none_net;
    const scale = pdk_cfg.db_unit; // µm per database unit

    var pos: usize = 0;
    var in_boundary = false;
    var cur_layer: i32 = -1;
    var cur_dt:    u16 = 0;
    var xy: [128]i32 = undefined; // up to 64 coordinate pairs
    var xy_len: usize = 0;

    while (pos + 4 <= data.len) {
        const rec_len: usize = (@as(usize, data[pos]) << 8) | @as(usize, data[pos + 1]);
        if (rec_len < 4) break;
        if (pos + rec_len > data.len) break;
        const rec_type = data[pos + 2];
        const payload = data[pos + 4 .. pos + rec_len];

        switch (rec_type) {
            0x08 => { // BOUNDARY
                in_boundary = true;
                cur_layer = -1;
                cur_dt    = 0;
                xy_len    = 0;
            },
            0x0D => { // LAYER
                if (in_boundary and payload.len >= 2) {
                    const raw: u16 = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
                    cur_layer = @as(i32, @as(i16, @bitCast(raw)));
                }
            },
            0x0E => { // DATATYPE
                if (in_boundary and payload.len >= 2) {
                    cur_dt = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
                }
            },
            0x10 => { // XY
                if (in_boundary) {
                    const nvals = payload.len / 4;
                    const ncopy = @min(nvals, xy.len);
                    for (0..ncopy) |k| {
                        const b = k * 4;
                        const raw: u32 = (@as(u32, payload[b]) << 24) |
                                         (@as(u32, payload[b + 1]) << 16) |
                                         (@as(u32, payload[b + 2]) << 8) |
                                         @as(u32, payload[b + 3]);
                        xy[k] = @bitCast(raw);
                    }
                    xy_len = ncopy;
                }
            },
            0x11 => { // ENDEL
                if (in_boundary and cur_layer >= 0 and xy_len >= 4) {
                    const gds_l: u16 = @intCast(cur_layer);
                    if (isRelevantDrcLayer(gds_l, cur_dt, pdk_cfg)) {
                        var xmin_db: i32 = std.math.maxInt(i32);
                        var xmax_db: i32 = std.math.minInt(i32);
                        var ymin_db: i32 = std.math.maxInt(i32);
                        var ymax_db: i32 = std.math.minInt(i32);
                        var k: usize = 0;
                        while (k + 1 < xy_len) : (k += 2) {
                            const cx = xy[k];
                            const cy = xy[k + 1];
                            if (cx < xmin_db) xmin_db = cx;
                            if (cx > xmax_db) xmax_db = cx;
                            if (cy < ymin_db) ymin_db = cy;
                            if (cy > ymax_db) ymax_db = cy;
                        }
                        const xmin: f32 = @as(f32, @floatFromInt(xmin_db)) * scale;
                        const xmax: f32 = @as(f32, @floatFromInt(xmax_db)) * scale;
                        const ymin: f32 = @as(f32, @floatFromInt(ymin_db)) * scale;
                        const ymax: f32 = @as(f32, @floatFromInt(ymax_db)) * scale;
                        try shapes.append(xmin, ymin, xmax, ymax, gds_l, cur_dt, NONE);
                    }
                }
                in_boundary = false;
            },
            else => {},
        }
        pos += rec_len;
    }
}

/// Return true if (gds_l, gds_dt) is a layer the DRC engine needs to check.
/// Covers routing metals, device contacts/vias, and all layers referenced by
/// enc_rules and aux_rules in the PDK config.
fn isRelevantDrcLayer(gds_l: u16, gds_dt: u16, pdk_cfg: *const pdk.PdkConfig) bool {
    // Routing metal layers (datatype 20).
    if (gds_dt == 20) {
        for (pdk_cfg.layer_map[0..8]) |ml| {
            if (ml != 0 and ml == gds_l) return true;
        }
    }
    // LayerTable device/via layers.
    const ly = &pdk_cfg.layers;
    const fixed_layers = [_][2]u16{
        .{ ly.licon.layer,  ly.licon.datatype  },
        .{ ly.mcon.layer,   ly.mcon.datatype   },
        .{ ly.tap.layer,    ly.tap.datatype    },
        .{ ly.diff.layer,   ly.diff.datatype   },
        .{ ly.poly.layer,   ly.poly.datatype   },
        .{ ly.via[0].layer, ly.via[0].datatype },
        .{ ly.via[1].layer, ly.via[1].datatype },
        .{ ly.via[2].layer, ly.via[2].datatype },
        .{ ly.via[3].layer, ly.via[3].datatype },
    };
    for (fixed_layers) |f| {
        if (f[0] != 0 and f[0] == gds_l and f[1] == gds_dt) return true;
    }
    // Any layer referenced by enc_rules or aux_rules.
    for (pdk_cfg.enc_rules[0..pdk_cfg.num_enc_rules]) |r| {
        if ((r.inner_layer == gds_l and r.inner_datatype == gds_dt) or
            (r.outer_layer == gds_l and r.outer_datatype == gds_dt)) return true;
    }
    for (pdk_cfg.aux_rules[0..pdk_cfg.num_aux_rules]) |r| {
        if (r.gds_layer == gds_l and r.gds_datatype == gds_dt) return true;
    }
    // Any layer referenced by cross_rules.
    for (pdk_cfg.cross_rules[0..pdk_cfg.num_cross_rules]) |r| {
        if ((r.layer_a == gds_l and r.datatype_a == gds_dt) or
            (r.layer_b == gds_l and r.datatype_b == gds_dt)) return true;
    }
    return false;
}

export fn spout_get_num_violations(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    const viols = ctx.drc_violations orelse return 0;

    // Exclude short violations: MAGIC's DRC does not flag same-type overlaps
    // as shorts (that is an LVS concern).  Count all other violations raw.
    var count: u32 = 0;
    for (viols) |v| {
        if (v.rule == .short) continue;
        count += 1;
    }
    return count;
}

/// Returns true if (px, py) lies within `half_width` of the axis-aligned
/// segment (x1,y1)→(x2,y2).  Uses a bounding-box test which is exact for
/// the Manhattan route segments produced by Spout's channel router.
fn pointNearSegment(px: f32, py: f32, x1: f32, y1: f32, x2: f32, y2: f32, half_width: f32) bool {
    return px >= @min(x1, x2) - half_width and px <= @max(x1, x2) + half_width and
           py >= @min(y1, y2) - half_width and py <= @max(y1, y2) + half_width;
}

// ─── LVS geometry helpers ────────────────────────────────────────────────────

const RouteArrays = route_arrays.RouteArrays;

/// Bounding rectangle of a Manhattan route segment: [xmin, ymin, xmax, ymax].
/// The width extends perpendicular to the path; with square end-caps (GDSII
/// default) the half-width also extends along-path at both endpoints.
fn segmentRect(routes: *const RouteArrays, i: usize, tol: f32) [4]f32 {
    const hw = routes.width[i] * 0.5 + tol;
    return .{
        @min(routes.x1[i], routes.x2[i]) - hw,
        @min(routes.y1[i], routes.y2[i]) - hw,
        @max(routes.x1[i], routes.x2[i]) + hw,
        @max(routes.y1[i], routes.y2[i]) + hw,
    };
}

/// True if two axis-aligned rectangles have nonzero-area overlap.
fn rectsOverlap(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[2] and a[2] > b[0] and a[1] < b[3] and a[3] > b[1];
}

/// True if point (px, py) lies inside the rectangle (inclusive).
fn pointInRect(px: f32, py: f32, r: [4]f32) bool {
    return px >= r[0] and px <= r[2] and py >= r[1] and py <= r[3];
}

/// Butt-end bounding rectangle: width expands only perpendicular to the
/// Manhattan path direction (no extension past endpoints along-path).
/// Used for short detection where square-endcap expansion creates false positives.
fn segmentButtRect(routes: *const RouteArrays, i: usize, tol: f32) [4]f32 {
    const hw = routes.width[i] * 0.5 + tol;
    const x1 = routes.x1[i]; const y1 = routes.y1[i];
    const x2 = routes.x2[i]; const y2 = routes.y2[i];
    if (@abs(y1 - y2) < 1e-4) {
        // Horizontal: width extends in y only.
        return .{ @min(x1, x2), @min(y1, y2) - hw, @max(x1, x2), @max(y1, y2) + hw };
    } else if (@abs(x1 - x2) < 1e-4) {
        // Vertical: width extends in x only.
        return .{ @min(x1, x2) - hw, @min(y1, y2), @max(x1, x2) + hw, @max(y1, y2) };
    } else {
        // Diagonal / point: conservative full expansion.
        return segmentRect(routes, i, tol);
    }
}

/// True if two same-layer route segments physically overlap (short or
/// same-net continuity depending on caller context).
/// Uses square-endcap rects (connectivity) or butt-end rects (shorts).
fn segmentRectsOverlap(routes: *const RouteArrays, ai: usize, bi: usize, tol: f32) bool {
    const a = segmentRect(routes, ai, tol);
    const b = segmentRect(routes, bi, 0.0);
    return rectsOverlap(a, b);
}

/// True if two different-net same-layer segments physically short.
/// Uses butt-end rects to avoid false positives from endcap expansion.
fn segmentRectsShort(routes: *const RouteArrays, ai: usize, bi: usize, tol: f32) bool {
    const a = segmentButtRect(routes, ai, tol);
    const b = segmentButtRect(routes, bi, 0.0);
    return rectsOverlap(a, b);
}

/// True if an endpoint of either segment falls within the other segment's
/// bounding rectangle — the condition for a via connection between adjacent
/// metal layers.
fn segmentViaConnect(routes: *const RouteArrays, ai: usize, bi: usize, tol: f32) bool {
    const ra = segmentRect(routes, ai, tol);
    const rb = segmentRect(routes, bi, tol);
    // Endpoint of A inside B?
    if (pointInRect(routes.x1[ai], routes.y1[ai], rb)) return true;
    if (pointInRect(routes.x2[ai], routes.y2[ai], rb)) return true;
    // Endpoint of B inside A?
    if (pointInRect(routes.x1[bi], routes.y1[bi], ra)) return true;
    if (pointInRect(routes.x2[bi], routes.y2[bi], ra)) return true;
    return false;
}

/// Run in-engine LVS using Union-Find connectivity analysis.
///
/// Mirrors Netgen's graph-isomorphism approach (netcmp.c) adapted to operate
/// directly on Spout's route segments rather than an extracted layout netlist:
///
///   1. Build a Union-Find graph: nodes = route segments + device pins.
///   2. Connect same-net segments that physically overlap (same layer) or
///      share a via point (adjacent layers).
///   3. Connect each device pin to its touching M1/LI route segment.
///   4. Open detection:  all pins on the same net must be in the same
///      connected component — otherwise Netgen would report a net mismatch.
///   5. Short detection: different-net segments overlapping on the same layer,
///      plus different-net routes touching any device pin.
///
/// Device-list comparison is deferred (requires MAGIC GDS→SPICE extraction).
/// Returns 0 on success, -1 invalid handle, -2 out of memory.
export fn spout_run_lvs(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    var report = characterize.LvsReport{
        .matched             = 0,
        .unmatched_layout    = 0,
        .unmatched_schematic = 0,
        .net_mismatches      = 0,
        .pass                = true,
    };

    const num_pins: usize = @intCast(ctx.pins.len);

    if (ctx.routes) |*routes| {
        const num_routes: usize = @intCast(routes.len);
        const total_nodes: u32 = @intCast(num_routes + num_pins);

        if (total_nodes == 0) {
            ctx.lvs_report = report;
            return 0;
        }

        // ── Build connectivity graph ────────────────────────────────────
        //
        // Node IDs:  0 .. num_routes-1          = route segments
        //            num_routes .. total_nodes-1 = device pins
        var uf = characterize.UnionFind.init(ctx.allocator, total_nodes) catch return -2;
        defer uf.deinit();

        // 100 nm connectivity tolerance — one design-rule grid step.
        const CONN_TOL: f32 = 0.1;
        // 10 nm short tolerance — tighter to avoid false positives.
        const SHORT_TOL: f32 = 0.01;

        // Step 1: Connect same-net route segments (same layer overlap OR
        //         adjacent-layer via connection).
        for (0..num_routes) |ri| {
            const ri_net = routes.net[ri].toInt();
            for (ri + 1..num_routes) |rj| {
                if (routes.net[rj].toInt() != ri_net) continue;

                const li = routes.layer[ri];
                const lj = routes.layer[rj];
                const layer_diff = if (li > lj) li - lj else lj - li;

                if (layer_diff == 0) {
                    if (segmentRectsOverlap(routes, ri, rj, CONN_TOL)) {
                        uf.union_(@intCast(ri), @intCast(rj));
                    }
                } else if (layer_diff == 1) {
                    if (segmentViaConnect(routes, ri, rj, CONN_TOL)) {
                        uf.union_(@intCast(ri), @intCast(rj));
                    }
                }
            }
        }

        // Step 2: Connect each pin to touching same-net M1/LI segments.
        for (0..num_pins) |pi| {
            const net_id = ctx.pins.net[pi].toInt();
            if (ctx.nets.fanout[net_id] < 2) continue;

            const dev_id = ctx.pins.device[pi].toInt();
            const px = ctx.devices.positions[dev_id][0] + ctx.pins.position[pi][0];
            const py = ctx.devices.positions[dev_id][1] + ctx.pins.position[pi][1];
            const pin_node: u32 = @intCast(num_routes + pi);

            for (0..num_routes) |ri| {
                if (routes.layer[ri] > 1) continue;
                if (routes.net[ri].toInt() != net_id) continue;
                const hw = routes.width[ri] * 0.5 + CONN_TOL;
                if (pointNearSegment(px, py,
                        routes.x1[ri], routes.y1[ri],
                        routes.x2[ri], routes.y2[ri], hw)) {
                    uf.union_(pin_node, @intCast(ri));
                }
            }
        }

        // Step 3: Open detection — all pins on same net must be in the
        //         same connected component.
        {
            const num_nets: usize = @intCast(ctx.nets.len);
            for (0..num_nets) |ni| {
                if (ctx.nets.fanout[ni] < 2) continue;
                var first_pin: ?u32 = null;
                for (0..num_pins) |pi| {
                    if (ctx.pins.net[pi].toInt() != ni) continue;
                    const pin_node: u32 = @intCast(num_routes + pi);
                    if (first_pin) |fp| {
                        if (!uf.connected(fp, pin_node)) {
                            report.net_mismatches += 1;
                            report.pass = false;
                            break; // one open per net
                        }
                    } else {
                        first_pin = pin_node;
                    }
                }
            }
        }

        // Step 4: Short detection — different-net segments overlapping on
        //         the same metal layer, plus per-pin wrong-net proximity.
        for (0..num_routes) |ri| {
            for (ri + 1..num_routes) |rj| {
                if (routes.net[ri].toInt() == routes.net[rj].toInt()) continue;
                if (routes.layer[ri] != routes.layer[rj]) continue;
                if (segmentRectsShort(routes, ri, rj, SHORT_TOL)) {
                    report.net_mismatches += 1;
                    report.pass = false;
                }
            }
        }

        // Per-pin wrong-net short (original check, catches shorts at
        // device terminals that the segment-pair check might miss due
        // to via landing pads on different layers).
        for (0..num_pins) |pi| {
            const net_id = ctx.pins.net[pi].toInt();
            if (ctx.nets.fanout[net_id] < 2) continue;

            const dev_id = ctx.pins.device[pi].toInt();
            const px = ctx.devices.positions[dev_id][0] + ctx.pins.position[pi][0];
            const py = ctx.devices.positions[dev_id][1] + ctx.pins.position[pi][1];

            for (0..num_routes) |ri| {
                if (routes.layer[ri] > 1) continue;
                if (routes.net[ri].toInt() == net_id) continue;
                const hw = routes.width[ri] * 0.5 + SHORT_TOL;
                if (pointNearSegment(px, py,
                        routes.x1[ri], routes.y1[ri],
                        routes.x2[ri], routes.y2[ri], hw)) {
                    report.net_mismatches += 1;
                    report.pass = false;
                    break; // one short per pin
                }
            }
        }
    } else {
        // No routes at all — every multi-fanout net is open.
        const num_nets: usize = @intCast(ctx.nets.len);
        for (0..num_nets) |ni| {
            if (ctx.nets.fanout[ni] >= 2) {
                report.net_mismatches += 1;
                report.pass = false;
            }
        }
    }

    ctx.lvs_report = report;
    return 0;
}

export fn spout_get_lvs_match(handle: *anyopaque) bool {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return false;
    return if (ctx.lvs_report) |r| r.pass else false;
}

export fn spout_get_lvs_mismatch_count(handle: *anyopaque) u32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return 0;
    const r = ctx.lvs_report orelse return 0;
    return r.net_mismatches + r.unmatched_layout + r.unmatched_schematic;
}

/// Write a SPICE netlist using Spout's in-engine ext2spice (SpiceWriter).
/// Uses the parsed schematic's device list, net names, subcircuit ports,
/// and model names to produce a .spice file at the given path.
///
/// Returns 0 on success, -1 invalid handle, -2 OOM, -3 no parse result,
/// -4 file I/O error, -5 write error.
export fn spout_ext2spice(handle: *anyopaque, path_ptr: [*]const u8, path_len: usize) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    const path = path_ptr[0..path_len];

    const pr: *const parser.ParseResult = if (ctx.parse_result != null) &ctx.parse_result.? else return -3;
    if (pr.subcircuits.len == 0) return -3;

    // Build net_names slice.
    const net_names = ctx.allocator.alloc([]const u8, pr.nets.len) catch return -2;
    defer ctx.allocator.free(net_names);
    for (pr.nets, 0..) |net, i| {
        net_names[i] = net.name;
    }

    // Build SPICE into an ArrayList, then write to file.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    const writer = out.writer(ctx.allocator);

    writer.print("* SPICE netlist generated by Spout ext2spice\n", .{}) catch return -2;

    // Emit .global directives so NETGEN sees cross-hierarchy net connections.
    for (pr.globals) |g| {
        writer.print(".global {s}\n", .{g}) catch return -2;
    }

    // Emit all subcircuits using ParseResult data directly.
    // This handles both single and multi-subcircuit netlists correctly,
    // including X device instances with arbitrary port counts.
    for (pr.subcircuits) |sc| {
        writeSubcircuitFromPR(writer, sc, pr.devices, pr.pins, net_names) catch return -5;
    }

    writer.print(".end\n", .{}) catch return -2;

    const file = std.fs.cwd().createFile(path, .{}) catch return -4;
    defer file.close();
    file.writeAll(out.items) catch return -4;
    return 0;
}

/// Returns true for passive device types (R, C, L) that should NOT get a
/// default model name when the schematic didn't specify one.
fn isPassiveDevice(dt: types.DeviceType) bool {
    return switch (dt) {
        .res, .res_poly, .res_diff_n, .res_diff_p,
        .res_well_n, .res_well_p, .res_metal,
        .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate,
        .ind => true,
        else => false,
    };
}

/// Write MOSFET parameters, skipping W/L when zero (schematic didn't specify).
fn writeMosfetParams(writer: anytype, params: types.DeviceParams) !void {
    if (params.w > 0.0) try writer.print(" W={e:.4}", .{params.w});
    if (params.l > 0.0) try writer.print(" L={e:.4}", .{params.l});
    const mult: u16 = if (params.mult > 0) params.mult else 1;
    if (mult > 1) try writer.print(" m={d}", .{mult});
    const fingers: u16 = if (params.fingers > 0) params.fingers else 1;
    if (fingers > 1) try writer.print(" nf={d}", .{fingers});
}

/// Write one .subckt block using ParseResult device/pin data for a specific
/// device range (sc.device_start .. sc.device_end).
fn writeSubcircuitFromPR(
    writer: anytype,
    sc: parser.Subcircuit,
    devices: []const parser.DeviceInfo,
    pins: []const parser.PinEdge,
    net_names: []const []const u8,
) !void {
    const SW = characterize.SpiceWriter;

    try writer.print(".subckt {s}", .{sc.name});
    for (sc.ports) |port| {
        try writer.print(" {s}", .{port});
    }
    try writer.writeByte('\n');

    var mosfet_num: u32 = 0;
    var res_num: u32 = 0;
    var cap_num: u32 = 0;
    var ind_num: u32 = 0;
    var diode_num: u32 = 0;
    var bjt_num: u32 = 0;
    var jfet_num: u32 = 0;
    var subckt_num: u32 = 0;

    for (sc.device_start..sc.device_end) |di| {
        if (di >= devices.len) break;
        const dev = devices[di];
        const dt = dev.device_type;
        const prefix = SW.devPrefix(dt);
        const num = switch (dt) {
            .nmos, .pmos => blk: {
                const n = mosfet_num;
                mosfet_num += 1;
                break :blk n;
            },
            .res, .res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal => blk: {
                const n = res_num;
                res_num += 1;
                break :blk n;
            },
            .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate => blk: {
                const n = cap_num;
                cap_num += 1;
                break :blk n;
            },
            .ind => blk: {
                const n = ind_num;
                ind_num += 1;
                break :blk n;
            },
            .diode => blk: {
                const n = diode_num;
                diode_num += 1;
                break :blk n;
            },
            .bjt_npn, .bjt_pnp => blk: {
                const n = bjt_num;
                bjt_num += 1;
                break :blk n;
            },
            .jfet_n, .jfet_p => blk: {
                const n = jfet_num;
                jfet_num += 1;
                break :blk n;
            },
            .subckt => blk: {
                const n = subckt_num;
                subckt_num += 1;
                break :blk n;
            },
        };

        try writer.print("{c}{d}", .{ prefix, num });

        if (dt == .subckt) {
            // X devices: emit pins in port_order, then subckt_type name.
            for (pins) |pin| {
                if (pin.device.toInt() > di) break;
                if (pin.device.toInt() == di) {
                    const nidx = pin.net.toInt();
                    const name = if (nidx < net_names.len) net_names[nidx] else "?";
                    try writer.print(" {s}", .{name});
                }
            }
            try writer.print(" {s}", .{if (dev.subckt_type.len > 0) dev.subckt_type else "subckt"});
        } else {
            // Standard devices: emit terminals in SPICE-conventional order.
            const order = SW.terminalOrder(dt);
            for (order) |wanted| {
                var found = false;
                for (pins) |pin| {
                    if (pin.device.toInt() > di) break;
                    if (pin.device.toInt() == di and pin.terminal == wanted) {
                        const nidx = pin.net.toInt();
                        const name = if (nidx < net_names.len) net_names[nidx] else "?";
                        try writer.print(" {s}", .{name});
                        found = true;
                        break;
                    }
                }
                if (!found) try writer.print(" ?", .{});
            }
            if (dev.model_name.len > 0) {
                try writer.print(" {s}", .{dev.model_name});
            } else if (!isPassiveDevice(dt)) {
                // Only emit default model for active devices (MOSFETs, BJTs, etc.).
                // Bare R/C/L in SPICE have no model name — adding one (e.g. "cap")
                // changes the NETGEN device class from "c" to "cap", causing mismatch.
                try SW.writeDefaultModel(writer, dt);
            }
            // Use custom MOSFET param writer that skips W=0/L=0 (schematic
            // didn't specify these, emitting them causes NETGEN property errors).
            if (dt == .nmos or dt == .pmos) {
                try writeMosfetParams(writer, dev.params);
            } else {
                try SW.writeParams(writer, dt, dev.params);
            }
        }

        try writer.writeByte('\n');
    }

    try writer.print(".ends {s}\n", .{sc.name});
}

/// Return per-pin connected-component IDs based on physical route connectivity.
/// Unlike spout_run_lvs (which checks schematic-vs-layout correctness), this
/// function unions ALL physically touching elements regardless of net assignment,
/// giving the true layout connectivity for layout SPICE generation.
///
/// Returns a Span of u32 with length num_pins.  Pins with the same value are
/// electrically connected through metal in the layout.
export fn spout_get_layout_connectivity(handle: *anyopaque) Span(u32) {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return .{ .ptr = undefined, .len = 0 };

    const num_pins: usize = @intCast(ctx.pins.len);
    if (num_pins == 0) return .{ .ptr = undefined, .len = 0 };

    // Free previous cached buffer.
    if (ctx.layout_connectivity) |old| {
        ctx.allocator.free(old);
        ctx.layout_connectivity = null;
    }

    if (ctx.routes) |*routes| {
        const num_routes: usize = @intCast(routes.len);
        const total_nodes: u32 = @intCast(num_routes + num_pins);
        if (total_nodes == 0) return .{ .ptr = undefined, .len = 0 };

        var uf = characterize.UnionFind.init(ctx.allocator, total_nodes) catch return .{ .ptr = undefined, .len = 0 };
        defer uf.deinit();

        // Physical proximity tolerance — one design-rule grid step.
        const PHYS_TOL: f32 = 0.1;

        // Step 1: Connect ALL physically overlapping route segments (regardless
        //         of net assignment) — same-layer overlap and adjacent-layer vias.
        for (0..num_routes) |ri| {
            for (ri + 1..num_routes) |rj| {
                const li = routes.layer[ri];
                const lj = routes.layer[rj];
                const layer_diff = if (li > lj) li - lj else lj - li;

                if (layer_diff == 0) {
                    if (segmentRectsOverlap(routes, ri, rj, PHYS_TOL)) {
                        uf.union_(@intCast(ri), @intCast(rj));
                    }
                } else if (layer_diff == 1) {
                    if (segmentViaConnect(routes, ri, rj, PHYS_TOL)) {
                        uf.union_(@intCast(ri), @intCast(rj));
                    }
                }
            }
        }

        // Step 2: Connect each pin to ALL touching M1/LI route segments
        //         (regardless of net — captures shorts at device terminals).
        for (0..num_pins) |pi| {
            const dev_id = ctx.pins.device[pi].toInt();
            const px = ctx.devices.positions[dev_id][0] + ctx.pins.position[pi][0];
            const py = ctx.devices.positions[dev_id][1] + ctx.pins.position[pi][1];
            const pin_node: u32 = @intCast(num_routes + pi);

            for (0..num_routes) |ri| {
                if (routes.layer[ri] > 1) continue; // only M1/LI connect to pins
                const hw = routes.width[ri] * 0.5 + PHYS_TOL;
                if (pointNearSegment(px, py,
                        routes.x1[ri], routes.y1[ri],
                        routes.x2[ri], routes.y2[ri], hw)) {
                    uf.union_(pin_node, @intCast(ri));
                }
            }
        }

        // Extract per-pin component IDs.
        const buf = ctx.allocator.alloc(u32, num_pins) catch return .{ .ptr = undefined, .len = 0 };
        for (0..num_pins) |pi| {
            buf[pi] = uf.find(@intCast(num_routes + pi));
        }
        ctx.layout_connectivity = buf;
        return .{ .ptr = buf.ptr, .len = num_pins };
    } else {
        // No routes — each pin is its own component.
        const buf = ctx.allocator.alloc(u32, num_pins) catch return .{ .ptr = undefined, .len = 0 };
        for (buf, 0..) |*b, i| b.* = @intCast(i);
        ctx.layout_connectivity = buf;
        return .{ .ptr = buf.ptr, .len = num_pins };
    }
}

/// Run in-engine PEX on the current route segments using SKY130 coefficients.
/// Returns 0 on success, -1 invalid handle, -2 no routes, -3 OOM.
export fn spout_run_pex(handle: *anyopaque) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    const routes = if (ctx.routes) |*r| r else return -2;

    if (ctx.pex_result) |prev| { prev.deinit(); ctx.allocator.destroy(prev); ctx.pex_result = null; }

    // Collect body-terminal net IDs (VDD/VSS) for substrate detection.
    var body_ids_list = std.ArrayListUnmanaged(u32){};
    defer body_ids_list.deinit(ctx.allocator);
    {
        var body_seen = std.AutoHashMap(u32, void).init(ctx.allocator);
        defer body_seen.deinit();
        const n_bp: usize = @intCast(ctx.pins.len);
        for (0..n_bp) |bi| {
            if (ctx.pins.terminal[bi] == .body) {
                const raw: u32 = @intCast(ctx.pins.net[bi].toInt());
                if (!(body_seen.getOrPut(raw) catch continue).found_existing) {
                    body_ids_list.append(ctx.allocator, raw) catch {};
                }
            }
        }
    }

    var pex_cfg = characterize.PexConfig.sky130();
    pex_cfg.body_net_ids = if (body_ids_list.items.len > 0) body_ids_list.items else null;

    const p = ctx.allocator.create(characterize.PexResult) catch return -3;
    p.* = characterize.extractFromRoutes(routes, pex_cfg, ctx.allocator) catch {
        ctx.allocator.destroy(p);
        return -3;
    };

    // DEBUG: stage 0 — raw pex.zig output
    {
        var n_sub0: u32 = 0; var n_coup0: u32 = 0;
        for (p.capacitors) |c| { if (c.net_b == characterize.SUBSTRATE_NET) { n_sub0 += 1; } else { n_coup0 += 1; } }
        std.debug.print("PEX_S0: sub={d} coup={d} total={d}\n", .{ n_sub0, n_coup0, @as(u32, @intCast(p.capacitors.len)) });
    }

    // ── Body-terminal substrate detection ─────────────────────────────────
    // Identify VDD/VSS nets from MOSFET body (bulk) terminals.  These are
    // the substrate reference nets — their caps should be absorbed into
    // signal-net substrate caps, matching Magic's substrate convention.
    // This replaces the old size-based heuristic (≥3 merged nets) that
    // incorrectly absorbed internal signal nets on complex circuits.
    {
        const n_pins_body: usize = @intCast(ctx.pins.len);
        var body_set = std.AutoHashMap(u32, void).init(ctx.allocator);
        defer body_set.deinit();
        for (0..n_pins_body) |bi| {
            if (ctx.pins.terminal[bi] == .body) {
                const raw: u32 = @intCast(ctx.pins.net[bi].toInt());
                const merged = p.mergedNet(raw);
                body_set.put(merged, {}) catch {};
            }
        }

        if (body_set.count() > 0) {
            // Don't rewrite caps — VDD/VSS routing-derived caps act as proxies
            // for internal diffusion nodes that Magic creates but Spout can't.
            // Only extend merge map so pin substrate loop and coupling loop
            // skip body nets.
            const n_body = body_set.count();
            const old_mf = p.merge_from;
            const old_mt = p.merge_to;
            const old_len: usize = if (old_mf) |m| m.len else 0;
            const new_mf = ctx.allocator.alloc(u32, old_len + n_body) catch {
                ctx.pex_result = p; return 0;
            };
            const new_mt = ctx.allocator.alloc(u32, old_len + n_body) catch {
                ctx.allocator.free(new_mf);
                ctx.pex_result = p; return 0;
            };
            if (old_mf) |m| @memcpy(new_mf[0..old_len], m);
            if (old_mt) |m| @memcpy(new_mt[0..old_len], m);
            var bi_idx: usize = old_len;
            var body_it = body_set.iterator();
            while (body_it.next()) |entry| {
                new_mf[bi_idx] = entry.key_ptr.*;
                new_mt[bi_idx] = characterize.SUBSTRATE_NET;
                bi_idx += 1;
            }
            if (old_mf) |m| ctx.allocator.free(m);
            if (old_mt) |m| ctx.allocator.free(m);
            p.merge_from = new_mf;
            p.merge_to = new_mt;
        }
    }

    // Add substrate C for nets with device pins but no route segments.
    // Matches Magic's convention: each electrical net with physical presence
    // gets a substrate cap entry, even if it has no routed wire segments.
    {
        const m1w = ctx.pdk.min_width[0];
        const c_pad_af = m1w * m1w * pex_cfg.substrate_cap[1]
                       + 2.0 * m1w * pex_cfg.fringe_cap[1];
        if (c_pad_af > 0.0) {
            var extra: std.ArrayListUnmanaged(characterize.RcElement) = .{};
            defer extra.deinit(ctx.allocator);

            const n_pins: usize = @intCast(ctx.pins.len);
            // DEBUG: pin net analysis
            {
                var raw_set = std.AutoHashMap(u32, void).init(ctx.allocator);
                defer raw_set.deinit();
                var sig_set = std.AutoHashMap(u32, void).init(ctx.allocator);
                defer sig_set.deinit();
                var n_sub_pins: u32 = 0;
                for (0..n_pins) |pi| {
                    const raw: u32 = @intCast(ctx.pins.net[pi].toInt());
                    raw_set.put(raw, {}) catch {};
                    const merged = p.mergedNet(raw);
                    if (merged == characterize.SUBSTRATE_NET) { n_sub_pins += 1; } else { sig_set.put(merged, {}) catch {}; }
                }
                std.debug.print("PEX_PINS: n={d} raw_unique={d} signal_unique={d} sub_pins={d}\n",
                    .{ @as(u32, @intCast(n_pins)), raw_set.count(), sig_set.count(), n_sub_pins });
            }
            pin_loop: for (0..n_pins) |i| {
                const raw_net: u32 = @intCast(ctx.pins.net[i].toInt());
                const net_i: u32 = p.mergedNet(raw_net);
                if (net_i == characterize.SUBSTRATE_NET) continue :pin_loop;
                for (p.capacitors) |c| {
                    if (c.net_a == net_i and c.net_b == characterize.SUBSTRATE_NET)
                        continue :pin_loop;
                }
                for (extra.items) |c| {
                    if (c.net_a == net_i) continue :pin_loop;
                }
                extra.append(ctx.allocator, .{
                    .net_a = net_i,
                    .net_b = characterize.SUBSTRATE_NET,
                    .value = c_pad_af / 1000.0,
                }) catch {};
            }

            if (extra.items.len > 0) {
                const old_len = p.capacitors.len;
                const new_caps = ctx.allocator.alloc(
                    characterize.RcElement, old_len + extra.items.len,
                ) catch {
                    ctx.pex_result = p;
                    return 0;
                };
                @memcpy(new_caps[0..old_len], p.capacitors);
                @memcpy(new_caps[old_len..], extra.items);
                ctx.allocator.free(p.capacitors);
                p.capacitors = new_caps;
            }
        }
    }

    // DEBUG: stage 1 — after device-pin substrate loop
    {
        var n_sub1: u32 = 0; var n_coup1: u32 = 0;
        for (p.capacitors) |c| { if (c.net_b == characterize.SUBSTRATE_NET) { n_sub1 += 1; } else { n_coup1 += 1; } }
        std.debug.print("PEX_S1: sub={d} coup={d} total={d}\n", .{ n_sub1, n_coup1, @as(u32, @intCast(p.capacitors.len)) });
    }

    // ── Device-pin proximity coupling ─────────────────────────────────────
    // Magic counts coupling between adjacent tile regions including device
    // terminals.  Route-only extraction misses these.  Add one coupling C
    // per pair of merged signal nets that have device pins within coupling
    // distance, matching Magic's tile-adjacency behavior.
    {
        const n_dev: usize = @intCast(ctx.devices.len);
        const n_pins2: usize = @intCast(ctx.pins.len);
        const coupling_val_ff: f32 = 0.001; // nominal value (fF)

        var pin_pos = ctx.allocator.alloc([2]f32, n_pins2) catch {
            ctx.pex_result = p;
            return 0;
        };
        defer ctx.allocator.free(pin_pos);
        for (0..n_pins2) |i| {
            const dev: usize = ctx.pins.device[i].toInt();
            if (dev < n_dev) {
                pin_pos[i] = .{
                    ctx.devices.positions[dev][0] + ctx.pins.position[i][0],
                    ctx.devices.positions[dev][1] + ctx.pins.position[i][1],
                };
            } else {
                pin_pos[i] = ctx.pins.position[i];
            }
        }

        // Collect unique merged-signal-net pairs that should couple.
        // Rule 1: pins on the SAME device always couple (intra-device adjacency).
        // Rule 2: pins on DIFFERENT devices couple if within inter_dist µm.
        var coup_set = std.AutoHashMap(u64, void).init(ctx.allocator);
        defer coup_set.deinit();
        const inter_dist: f32 = 15.0; // µm — inter-device coupling threshold
        for (0..n_pins2) |i| {
            const mi = p.mergedNet(@intCast(ctx.pins.net[i].toInt()));
            if (mi == characterize.SUBSTRATE_NET) continue;
            for (i + 1..n_pins2) |j| {
                const mj = p.mergedNet(@intCast(ctx.pins.net[j].toInt()));
                if (mj == characterize.SUBSTRATE_NET or mi == mj) continue;
                const same_dev = ctx.pins.device[i].toInt() == ctx.pins.device[j].toInt();
                if (!same_dev) {
                    const dx = pin_pos[i][0] - pin_pos[j][0];
                    const dy = pin_pos[i][1] - pin_pos[j][1];
                    if (@sqrt(dx * dx + dy * dy) > inter_dist) continue;
                }
                const na = @min(mi, mj);
                const nb = @max(mi, mj);
                const key: u64 = (@as(u64, na) << 32) | nb;
                var exists = false;
                for (p.capacitors) |c| {
                    if (c.net_a == na and c.net_b == nb) { exists = true; break; }
                }
                if (!exists) coup_set.put(key, {}) catch continue;
            }
        }
        if (coup_set.count() > 0) {
            const old_len = p.capacitors.len;
            const new_caps = ctx.allocator.alloc(
                characterize.RcElement, old_len + coup_set.count(),
            ) catch { ctx.pex_result = p; return 0; };
            @memcpy(new_caps[0..old_len], p.capacitors);
            var idx: usize = old_len;
            var cp_it = coup_set.iterator();
            while (cp_it.next()) |entry| {
                const k = entry.key_ptr.*;
                new_caps[idx] = .{
                    .net_a = @intCast(k >> 32),
                    .net_b = @intCast(k & 0xFFFFFFFF),
                    .value = coupling_val_ff,
                };
                idx += 1;
            }
            ctx.allocator.free(p.capacitors);
            p.capacitors = new_caps;
        }
    }

    // DEBUG: stage 2 — after device-pin coupling
    {
        var n_sub2: u32 = 0; var n_coup2: u32 = 0;
        for (p.capacitors) |c| { if (c.net_b == characterize.SUBSTRATE_NET) { n_sub2 += 1; } else { n_coup2 += 1; } }
        std.debug.print("PEX_S2: sub={d} coup={d} total={d}\n", .{ n_sub2, n_coup2, @as(u32, @intCast(p.capacitors.len)) });
    }

    // ── Internal diffusion nodes (shared source/drain junctions) ─────────
    // MAGIC creates internal nodes (a_xxxxx#) at shared source/drain
    // junctions between adjacent MOSFETs on body-terminal nets (VDD/VSS).
    // Each gets a substrate cap and coupling with gate nets of adjacent
    // devices.  Uses pin-level proximity to detect physical sharing.
    {
        const n_pins_sd: usize = @intCast(ctx.pins.len);
        const n_dev_sd: usize = @intCast(ctx.devices.len);
        const pin_dist_thresh: f32 = 5.0; // µm — shared diffusion proximity

        // Identify body-terminal nets (VDD/VSS).
        var body_nets = std.AutoHashMap(u32, void).init(ctx.allocator);
        defer body_nets.deinit();
        for (0..n_pins_sd) |pi| {
            if (ctx.pins.terminal[pi] == .body) {
                body_nets.put(@intCast(ctx.pins.net[pi].toInt()), {}) catch {};
            }
        }

        // Collect S/D pins on body-terminal nets with absolute positions.
        var sd_idx = std.ArrayListUnmanaged(usize){};
        defer sd_idx.deinit(ctx.allocator);
        var sd_pos = std.ArrayListUnmanaged([2]f32){};
        defer sd_pos.deinit(ctx.allocator);

        for (0..n_pins_sd) |pi| {
            const term = ctx.pins.terminal[pi];
            if (term != .source and term != .drain) continue;
            const raw_net: u32 = @intCast(ctx.pins.net[pi].toInt());
            if (!body_nets.contains(raw_net)) continue;
            sd_idx.append(ctx.allocator, pi) catch continue;
            const dev: usize = ctx.pins.device[pi].toInt();
            if (dev < n_dev_sd) {
                sd_pos.append(ctx.allocator, .{
                    ctx.devices.positions[dev][0] + ctx.pins.position[pi][0],
                    ctx.devices.positions[dev][1] + ctx.pins.position[pi][1],
                }) catch continue;
            } else {
                sd_pos.append(ctx.allocator, ctx.pins.position[pi]) catch continue;
            }
        }

        const n_sd = sd_idx.items.len;

        // Union-find: cluster physically adjacent S/D pins on same net.
        const uf_buf = ctx.allocator.alloc(usize, n_sd) catch &.{};
        defer if (n_sd > 0) ctx.allocator.free(uf_buf);
        const uf = @as([]usize, @constCast(uf_buf));
        for (0..n_sd) |i| uf[i] = i;

        for (0..n_sd) |i| {
            const ni = ctx.pins.net[sd_idx.items[i]].toInt();
            const di = ctx.pins.device[sd_idx.items[i]].toInt();
            for (i + 1..n_sd) |j| {
                if (ctx.pins.net[sd_idx.items[j]].toInt() != ni) continue;
                if (ctx.pins.device[sd_idx.items[j]].toInt() == di) continue;
                const dx = sd_pos.items[i][0] - sd_pos.items[j][0];
                const dy = sd_pos.items[i][1] - sd_pos.items[j][1];
                if (@sqrt(dx * dx + dy * dy) > pin_dist_thresh) continue;
                // Union
                var ri = i;
                while (uf[ri] != ri) ri = uf[ri];
                var rj = j;
                while (uf[rj] != rj) rj = uf[rj];
                if (ri != rj) {
                    if (ri < rj) { uf[rj] = ri; } else { uf[ri] = rj; }
                }
            }
        }
        // Path compression.
        for (0..n_sd) |i| {
            var r = i;
            while (uf[r] != r) r = uf[r];
            uf[i] = r;
        }

        // Count cluster sizes; multi-element clusters → virtual nodes.
        var csizes = std.AutoHashMap(usize, u16).init(ctx.allocator);
        defer csizes.deinit();
        for (0..n_sd) |i| {
            const gop = csizes.getOrPut(uf[i]) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }

        var diff_caps: std.ArrayListUnmanaged(characterize.RcElement) = .{};
        defer diff_caps.deinit(ctx.allocator);
        var vnet_id: u32 = characterize.SUBSTRATE_NET - 1000;

        var cs_it = csizes.iterator();
        while (cs_it.next()) |entry| {
            if (entry.value_ptr.* < 2) continue;
            const root = entry.key_ptr.*;

            const vid = vnet_id;
            vnet_id -%= 1;

            // Substrate cap for virtual diffusion node.
            diff_caps.append(ctx.allocator, .{
                .net_a = vid,
                .net_b = characterize.SUBSTRATE_NET,
                .value = 0.01,
            }) catch {};

            // Collect devices in this cluster.
            var devs = std.AutoHashMap(u32, void).init(ctx.allocator);
            for (0..n_sd) |i| {
                if (uf[i] != root) continue;
                devs.put(ctx.pins.device[sd_idx.items[i]].toInt(), {}) catch {};
            }

            // Coupling: virtual node ↔ gate nets of cluster devices.
            var coupled = std.AutoHashMap(u32, void).init(ctx.allocator);
            for (0..n_pins_sd) |pi| {
                if (!devs.contains(ctx.pins.device[pi].toInt())) continue;
                if (ctx.pins.terminal[pi] != .gate) continue;
                const raw: u32 = @intCast(ctx.pins.net[pi].toInt());
                const merged = p.mergedNet(raw);
                if (merged == characterize.SUBSTRATE_NET) continue;
                if ((coupled.getOrPut(merged) catch continue).found_existing) continue;
                diff_caps.append(ctx.allocator, .{
                    .net_a = @min(vid, merged),
                    .net_b = @max(vid, merged),
                    .value = 0.001,
                }) catch {};
            }
            devs.deinit();
            coupled.deinit();
        }

        // DEBUG: diffusion node stats.
        {
            var n_ds: u32 = 0;
            var n_dc: u32 = 0;
            for (diff_caps.items) |c| {
                if (c.net_b == characterize.SUBSTRATE_NET) { n_ds += 1; } else { n_dc += 1; }
            }
            std.debug.print("PEX_DIFF: nodes={d} coup={d}\n", .{ n_ds, n_dc });
        }

        // Append virtual caps to result.
        if (diff_caps.items.len > 0) {
            const old_len = p.capacitors.len;
            const new_caps = ctx.allocator.alloc(
                characterize.RcElement,
                old_len + diff_caps.items.len,
            ) catch {
                ctx.pex_result = p;
                return 0;
            };
            @memcpy(new_caps[0..old_len], p.capacitors);
            @memcpy(new_caps[old_len..], diff_caps.items);
            ctx.allocator.free(p.capacitors);
            p.capacitors = new_caps;
        }
    }

    ctx.pex_result = p;
    return 0;
}

/// Write PEX aggregate totals into caller-provided output pointers.
/// Returns 0 on success, -1 invalid handle, -2 PEX not yet run.
export fn spout_get_pex_totals(
    handle:        *anyopaque,
    out_num_res:   *u32,
    out_num_cap:   *u32,
    out_total_res: *f32,
    out_total_cap: *f32,
) i32 {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;
    const pex = ctx.pex_result orelse return -2;

    out_num_res.* = @intCast(pex.resistors.len);
    out_num_cap.* = @intCast(pex.capacitors.len);

    var total_r: f32 = 0.0;
    for (pex.resistors) |r| total_r += r.value;
    out_total_res.* = total_r;

    var total_c: f32 = 0.0;
    for (pex.capacitors) |c| total_c += c.value;
    out_total_cap.* = total_c;

    return 0;
}

// ─── GDS Template C-ABI ─────────────────────────────────────────────────────

/// Load a GDS template file into the context.
///
/// If `cell_name` is null, auto-detects the largest cell (typical for
/// TinyTapeout wrappers where the top cell is the largest).
///
/// Returns 0 on success, -1 invalid handle, -2 OOM, -3 file/parse error.
export fn spout_load_template_gds(
    handle: *anyopaque,
    gds_path: [*:0]const u8,
    cell_name: ?[*:0]const u8,
) c_int {
    const ctx = SpoutContext.fromHandle(handle);
    if (!ctx.initialized) return -1;

    // Free any previously loaded template.
    if (ctx.template_context) |old| {
        old.deinit();
        ctx.allocator.destroy(old);
        ctx.template_context = null;
    }

    const path_slice = std.mem.span(gds_path);
    const cell_slice: ?[]const u8 = if (cell_name) |cn| std.mem.span(cn) else null;

    const tc_ptr = ctx.allocator.create(template_mod.TemplateContext) catch return -2;
    errdefer ctx.allocator.destroy(tc_ptr);

    tc_ptr.* = template_mod.TemplateContext.loadFromGds(
        path_slice,
        cell_slice,
        ctx.allocator,
    ) catch return -3;

    ctx.template_context = tc_ptr;
    return 0;
}

/// Get the user-area bounding box from the loaded template.
///
/// Writes [xmin, ymin, xmax, ymax] in microns to the provided pointers.
/// Returns 0 on success, -1 invalid handle, -2 no template loaded.
export fn spout_get_template_bounds(
    handle: *const anyopaque,
    out_xmin: *f32,
    out_ymin: *f32,
    out_xmax: *f32,
    out_ymax: *f32,
) c_int {
    const ctx = @as(*const SpoutContext, @ptrCast(@alignCast(handle)));
    if (!ctx.initialized) return -1;
    const tc = ctx.template_context orelse return -2;
    const bounds = tc.getUserAreaBounds();
    out_xmin.* = bounds[0];
    out_ymin.* = bounds[1];
    out_xmax.* = bounds[2];
    out_ymax.* = bounds[3];
    return 0;
}

/// Return the number of pins in the loaded template (0 if none loaded).
export fn spout_get_template_pin_count(handle: *const anyopaque) u32 {
    const ctx = @as(*const SpoutContext, @ptrCast(@alignCast(handle)));
    if (!ctx.initialized) return 0;
    const tc = ctx.template_context orelse return 0;
    return @intCast(tc.getPins().len);
}

/// Copy pin data at index `idx` into the caller-provided TemplatePin struct.
///
/// Returns 0 on success, -1 invalid handle, -2 no template, -3 out of range.
export fn spout_get_template_pin(
    handle: *const anyopaque,
    idx: u32,
    out_pin: *template_mod.TemplatePin,
) c_int {
    const ctx = @as(*const SpoutContext, @ptrCast(@alignCast(handle)));
    if (!ctx.initialized) return -1;
    const tc = ctx.template_context orelse return -2;
    const pins = tc.getPins();
    if (idx >= pins.len) return -3;
    out_pin.* = pins[idx];
    return 0;
}

/// Export GDSII with a template reference hierarchy.
///
/// Writes the user circuit as one GDSII cell named `user_cell_name`, then
/// writes a top cell named `top_cell_name` that references both the loaded
/// template cell and the user circuit cell via SREF records.
///
/// Returns 0 on success, -1 invalid handle, -2 no template loaded,
/// -3 export error.
export fn spout_export_gdsii_with_template(
    handle: *const anyopaque,
    output_path: [*:0]const u8,
    user_cell_name: [*:0]const u8,
    top_cell_name: [*:0]const u8,
) c_int {
    const ctx = @as(*const SpoutContext, @ptrCast(@alignCast(handle)));
    if (!ctx.initialized) return -1;
    const tc = ctx.template_context orelse return -2;

    const path_slice = std.mem.span(output_path);
    const user_name_slice = std.mem.span(user_cell_name);
    const top_name_slice = std.mem.span(top_cell_name);

    // Determine the template cell name for the SREF.
    const tmpl_cell_name: []const u8 = if (tc.user_cell_idx) |idx|
        tc.library.cells[idx].name
    else
        "template_cell";

    var writer = gdsii.GdsiiWriter.init(ctx.allocator);
    defer writer.deinit();

    const routes_ptr: ?*const route_arrays.RouteArrays =
        if (ctx.routes) |*r| r else null;

    // Build net-name slice from parse result for TEXT labels.
    var net_name_buf: ?[]const []const u8 = null;
    defer if (net_name_buf) |buf| ctx.allocator.free(buf);

    if (ctx.parse_result) |pr| {
        if (pr.nets.len > 0) {
            const names = ctx.allocator.alloc([]const u8, pr.nets.len) catch null;
            if (names) |ns| {
                for (pr.nets, 0..) |net, i| ns[i] = net.name;
                net_name_buf = ns;
            }
        }
    }

    const pins_ptr: ?*const pin_edge_arrays.PinEdgeArrays =
        if (ctx.pins.len > 0) &ctx.pins else null;

    // Place user circuit at origin (0, 0) within the template user area.
    const user_origin: [2]f32 = .{ 0.0, 0.0 };

    writer.exportLayoutHierarchical(
        path_slice,
        &ctx.devices,
        routes_ptr,
        &ctx.pdk,
        user_name_slice,
        top_name_slice,
        tmpl_cell_name,
        user_origin,
        net_name_buf,
        pins_ptr,
    ) catch return -3;

    return 0;
}

// ─── Liberty file generation ────────────────────────────────────────────────

const liberty_pdk = @import("liberty/pdk.zig");

/// Map a C integer pdk_id to a liberty PdkCornerSet pointer.
/// Returns null for unrecognised values.
/// Mapping: 0 = sky130, 1 = gf180mcu_3v3, 2 = gf180mcu_1v8.
fn libertyPdkCornerSetFromInt(pdk_id: c_int) ?*const liberty_pdk.PdkCornerSet {
    return switch (pdk_id) {
        0 => &liberty_pdk.sky130,
        1 => &liberty_pdk.gf180mcu_3v3,
        2 => &liberty_pdk.gf180mcu_1v8,
        else => null,
    };
}

/// Generate a Liberty (.lib) file for one PVT corner.
///
/// Parameters:
///   gds_path    – null-terminated path to GDSII input file
///   spice_path  – null-terminated path to SPICE netlist
///   cell_name   – null-terminated cell name (must match .subckt in netlist)
///   pdk_id      – 0 = sky130, 1 = gf180mcu_3v3, 2 = gf180mcu_1v8
///   corner_name – null-terminated corner name, e.g. "tt_025C_1v80"
///   output_path – null-terminated path for the output .lib file
///
/// Returns 0 on success, negative error codes:
///   -1  unknown PDK id or corner not found
///   -3  could not create output file
///   -4  Liberty generation failed
export fn spout_liberty_generate(
    gds_path: [*:0]const u8,
    spice_path: [*:0]const u8,
    cell_name: [*:0]const u8,
    pdk_id: c_int,
    corner_name: [*:0]const u8,
    output_path: [*:0]const u8,
) c_int {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const corner_set = libertyPdkCornerSetFromInt(pdk_id) orelse return -1;

    // Generate all corners for this PDK then find the one matching corner_name.
    const corners = corner_set.generateCorners(allocator) catch return -1;
    defer {
        for (corners) |c| allocator.free(c.name);
        allocator.free(corners);
    }

    const corner_name_span = std.mem.span(corner_name);
    var found_corner: ?liberty.CornerSpec = null;
    for (corners) |c| {
        if (std.mem.eql(u8, c.name, corner_name_span)) {
            found_corner = c;
            break;
        }
    }
    const corner = found_corner orelse return -1;

    const base_cfg = liberty.LibertyConfig{};
    const cfg = liberty.applyCorner(base_cfg, corner);

    const file = std.fs.cwd().createFile(std.mem.span(output_path), .{}) catch return -3;
    defer file.close();

    var write_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    liberty.generateLiberty(
        &file_writer.interface,
        std.mem.span(gds_path),
        std.mem.span(spice_path),
        std.mem.span(cell_name),
        cfg,
        allocator,
    ) catch return -4;

    return 0;
}

/// Generate Liberty (.lib) files for all PVT corners of the given PDK.
///
/// Parameters:
///   gds_path      – null-terminated path to GDSII input file
///   spice_path    – null-terminated path to SPICE netlist
///   cell_name     – null-terminated cell name (must match .subckt in netlist)
///   pdk_id        – 0 = sky130, 1 = gf180mcu_3v3, 2 = gf180mcu_1v8
///   output_dir    – null-terminated path to output directory (must exist)
///   out_num_files – on success, written with the number of .lib files generated
///
/// Returns 0 on success, negative error codes:
///   -1  unknown PDK id
///   -2  Liberty generation failed
export fn spout_liberty_generate_all_corners(
    gds_path: [*:0]const u8,
    spice_path: [*:0]const u8,
    cell_name: [*:0]const u8,
    pdk_id: c_int,
    output_dir: [*:0]const u8,
    out_num_files: *u32,
) c_int {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const corner_set = libertyPdkCornerSetFromInt(pdk_id) orelse return -1;

    const base_cfg = liberty.LibertyConfig{};

    const n = liberty.generateLibertyAllCorners(
        std.mem.span(gds_path),
        std.mem.span(spice_path),
        std.mem.span(cell_name),
        corner_set,
        std.mem.span(output_dir),
        base_cfg,
        allocator,
    ) catch return -2;

    out_num_files.* = n;
    return 0;
}

// ─── Test references ────────────────────────────────────────────────────────

test {
    // Utility
    _ = @import("utility/lib.zig");

    // Core
    _ = @import("core/types.zig");
    _ = @import("core/device_arrays.zig");
    _ = @import("core/net_arrays.zig");
    _ = @import("core/pin_edge_arrays.zig");
    _ = @import("core/constraint_arrays.zig");
    _ = @import("core/route_arrays.zig");
    _ = @import("core/adjacency.zig");
    _ = @import("core/layout_if.zig");

    // Netlist
    _ = @import("netlist/tokenizer.zig");
    _ = @import("netlist/tests.zig");

    // Constraint
    _ = @import("constraint/extract.zig");
    _ = @import("constraint/patterns.zig");
    _ = @import("constraint/tests.zig");

    // Placer
    _ = @import("placer/sa.zig");
    _ = @import("placer/cost.zig");
    _ = @import("placer/rudy.zig");
    _ = @import("placer/tests.zig");

    // Router
    _ = @import("router/maze.zig");
    _ = @import("router/steiner.zig");
    _ = @import("router/lp_sizing.zig");
    _ = @import("router/tests.zig");
    _ = @import("router/pex_feedback.zig");
    _ = @import("router/shield_router.zig");
    _ = @import("router/analog_types.zig");
    _ = @import("router/spatial_grid.zig");
    _ = @import("router/analog_router.zig");
    _ = @import("router/analog_db.zig");
    _ = @import("router/analog_groups.zig");
    _ = @import("router/guard_ring.zig");
    _ = @import("router/matched_router.zig");
    _ = @import("router/thread_pool.zig");

    // Export
    _ = @import("export/gdsii.zig");
    _ = @import("export/records.zig");
    _ = @import("export/tests.zig");

    // Macro / unit-cell recognition
    _ = @import("macro/lib.zig");
    _ = @import("macro/types.zig");
    _ = @import("macro/detect.zig");
    _ = @import("macro/stamp.zig");

    // PDK
    _ = @import("pdk/pdk.zig");

    // Characterize: DRC / LVS / PEX
    _ = @import("characterize/types.zig");
    _ = @import("characterize/drc.zig");
    _ = @import("characterize/lvs.zig");
    _ = @import("characterize/pex.zig");

    // GDS import / template
    _ = @import("import/gdsii.zig");
    _ = @import("import/template.zig");
}
