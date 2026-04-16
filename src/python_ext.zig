/// PyOZ-based Python extension module for Spout.
///
/// Wraps the Zig core (lib.zig) as a native CPython extension so Python
/// callers import `spout` directly instead of going through ctypes.
///
/// Build: `zig build pyext`   →  python/spout.so
const std = @import("std");
const pyoz = @import("PyOZ");
const lib = @import("spout");

// ── Layout class ─────────────────────────────────────────────────────────────

/// Opaque handle wrapping a SpoutContext.  The leading underscore on `_handle`
/// keeps it private (not exposed as a Python attribute).
const Layout = struct {
    _handle: *anyopaque,

    pub fn __new__(backend: u8, pdk_id: u8) !Layout {
        const handle = lib.spout_init_layout(backend, pdk_id) orelse
            return error.InitFailed;
        return .{ ._handle = handle };
    }

    pub fn __del__(self: *Layout) void {
        lib.spout_destroy(self._handle);
    }

    // ── PDK ────────────────────────────────────────────────────────────

    pub fn load_pdk_from_file(self: *Layout, path: []const u8) !void {
        if (lib.spout_load_pdk_from_file(self._handle, path.ptr, path.len) != 0)
            return error.PdkLoadFailed;
    }

    // ── Netlist / constraints ──────────────────────────────────────────

    pub fn parse_netlist(self: *Layout, path: []const u8) !void {
        if (lib.spout_parse_netlist(self._handle, path.ptr, path.len) != 0)
            return error.ParseFailed;
    }

    pub fn extract_constraints(self: *Layout) !void {
        if (lib.spout_extract_constraints(self._handle) != 0)
            return error.ConstraintFailed;
    }

    pub fn get_num_devices(self: *const Layout) u32 {
        return lib.spout_get_num_devices(self._handle);
    }

    pub fn get_num_nets(self: *const Layout) u32 {
        return lib.spout_get_num_nets(self._handle);
    }

    pub fn get_num_pins(self: *const Layout) u32 {
        return lib.spout_get_num_pins(self._handle);
    }

    // ── Placement ─────────────────────────────────────────────────────

    /// `config` must be a Python `bytes` object containing a raw SaConfig
    /// C struct (produced by `SaConfig.to_ffi_bytes()`).
    pub fn run_sa_placement(self: *Layout, config: pyoz.Bytes) !void {
        if (lib.spout_run_sa_placement(self._handle, config.data.ptr, config.data.len) != 0)
            return error.PlacementFailed;
    }

    pub fn get_placement_cost(self: *const Layout) f32 {
        return lib.spout_get_placement_cost(self._handle);
    }

    // ── Routing ───────────────────────────────────────────────────────

    pub fn run_routing(self: *Layout) !void {
        if (lib.spout_run_routing(self._handle) != 0)
            return error.RoutingFailed;
    }

    pub fn get_num_routes(self: *const Layout) u32 {
        return lib.spout_get_num_routes(self._handle);
    }

    // ── GDSII export ──────────────────────────────────────────────────

    pub fn export_gdsii(self: *Layout, path: []const u8) !void {
        if (lib.spout_export_gdsii(self._handle, path.ptr, path.len) != 0)
            return error.ExportFailed;
    }

    pub fn export_gdsii_named(self: *Layout, path: []const u8, name: ?[]const u8) !void {
        const name_ptr: ?[*]const u8 = if (name) |n| n.ptr else null;
        const name_len: usize = if (name) |n| n.len else 0;
        if (lib.spout_export_gdsii_named(self._handle, path.ptr, path.len, name_ptr, name_len) != 0)
            return error.ExportFailed;
    }

    // ── DRC ───────────────────────────────────────────────────────────

    pub fn run_drc(self: *Layout) !void {
        if (lib.spout_run_drc(self._handle) != 0)
            return error.DrcFailed;
    }

    pub fn get_num_violations(self: *const Layout) u32 {
        return lib.spout_get_num_violations(self._handle);
    }

    // ── LVS ───────────────────────────────────────────────────────────

    pub fn run_lvs(self: *Layout) !void {
        if (lib.spout_run_lvs(self._handle) != 0)
            return error.LvsFailed;
    }

    pub fn get_lvs_match(self: *const Layout) bool {
        return lib.spout_get_lvs_match(self._handle);
    }

    pub fn get_lvs_mismatch_count(self: *const Layout) u32 {
        return lib.spout_get_lvs_mismatch_count(self._handle);
    }

    // ── PEX / SPICE ───────────────────────────────────────────────────

    pub fn ext2spice(self: *Layout, path: []const u8) !void {
        if (lib.spout_ext2spice(self._handle, path.ptr, path.len) != 0)
            return error.Ext2SpiceFailed;
    }

    pub fn run_pex(self: *Layout) !void {
        if (lib.spout_run_pex(self._handle) != 0)
            return error.PexFailed;
    }

    /// Returns `(num_res, num_cap, total_res_ohm, total_cap_ff)` as a Python tuple.
    pub fn get_pex_totals(self: *const Layout) !struct { u32, u32, f32, f32 } {
        var num_res: u32 = 0;
        var num_cap: u32 = 0;
        var total_res: f32 = 0;
        var total_cap: f32 = 0;
        if (lib.spout_get_pex_totals(self._handle, &num_res, &num_cap, &total_res, &total_cap) != 0)
            return error.PexResultFailed;
        return .{ num_res, num_cap, total_res, total_cap };
    }

    pub fn generate_layout_spice(self: *Layout, path: []const u8) !void {
        if (lib.spout_generate_layout_spice(self._handle, path.ptr, path.len) != 0)
            return error.GenerateFailed;
    }

    // ── GDS template ──────────────────────────────────────────────────

    /// Load a GDS template.  `cell_name` may be `None` to auto-detect.
    pub fn load_template_gds(self: *Layout, gds_path: []const u8, cell_name: ?[]const u8) !void {
        const alloc = std.heap.c_allocator;
        const gds_z = try alloc.dupeZ(u8, gds_path);
        defer alloc.free(gds_z);

        var cell_z: ?[:0]u8 = null;
        if (cell_name) |cn| cell_z = try alloc.dupeZ(u8, cn);
        defer if (cell_z) |cz| alloc.free(cz);

        const cell_ptr: ?[*:0]const u8 = if (cell_z) |cz| cz.ptr else null;
        if (lib.spout_load_template_gds(self._handle, gds_z.ptr, cell_ptr) != 0)
            return error.TemplateLoadFailed;
    }

    /// Returns `(xmin, ymin, xmax, ymax)` in microns as a Python tuple.
    pub fn get_template_bounds(self: *const Layout) !struct { f32, f32, f32, f32 } {
        var xmin: f32 = 0;
        var ymin: f32 = 0;
        var xmax: f32 = 0;
        var ymax: f32 = 0;
        if (lib.spout_get_template_bounds(self._handle, &xmin, &ymin, &xmax, &ymax) != 0)
            return error.TemplateBoundsFailed;
        return .{ xmin, ymin, xmax, ymax };
    }

    pub fn export_gdsii_with_template(
        self: *const Layout,
        output_path: []const u8,
        user_cell_name: []const u8,
        top_cell_name: []const u8,
    ) !void {
        const alloc = std.heap.c_allocator;
        const out_z = try alloc.dupeZ(u8, output_path);
        defer alloc.free(out_z);
        const user_z = try alloc.dupeZ(u8, user_cell_name);
        defer alloc.free(user_z);
        const top_z = try alloc.dupeZ(u8, top_cell_name);
        defer alloc.free(top_z);
        if (lib.spout_export_gdsii_with_template(self._handle, out_z.ptr, user_z.ptr, top_z.ptr) != 0)
            return error.ExportFailed;
    }
};

// ── Module-level liberty functions ───────────────────────────────────────────

fn liberty_generate(
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_id: i32,
    corner_name: []const u8,
    output_path: []const u8,
) !void {
    const alloc = std.heap.c_allocator;
    const gds_z = try alloc.dupeZ(u8, gds_path);
    defer alloc.free(gds_z);
    const spice_z = try alloc.dupeZ(u8, spice_path);
    defer alloc.free(spice_z);
    const cell_z = try alloc.dupeZ(u8, cell_name);
    defer alloc.free(cell_z);
    const corner_z = try alloc.dupeZ(u8, corner_name);
    defer alloc.free(corner_z);
    const out_z = try alloc.dupeZ(u8, output_path);
    defer alloc.free(out_z);
    if (lib.spout_liberty_generate(gds_z.ptr, spice_z.ptr, cell_z.ptr, pdk_id, corner_z.ptr, out_z.ptr) != 0)
        return error.LibertyFailed;
}

/// Returns the number of generated `.lib` files.
fn liberty_generate_all_corners(
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_id: i32,
    output_dir: []const u8,
) !u32 {
    const alloc = std.heap.c_allocator;
    const gds_z = try alloc.dupeZ(u8, gds_path);
    defer alloc.free(gds_z);
    const spice_z = try alloc.dupeZ(u8, spice_path);
    defer alloc.free(spice_z);
    const cell_z = try alloc.dupeZ(u8, cell_name);
    defer alloc.free(cell_z);
    const out_z = try alloc.dupeZ(u8, output_dir);
    defer alloc.free(out_z);
    var num_files: u32 = 0;
    if (lib.spout_liberty_generate_all_corners(gds_z.ptr, spice_z.ptr, cell_z.ptr, pdk_id, out_z.ptr, &num_files) != 0)
        return error.LibertyFailed;
    return num_files;
}

// ── Module definition ────────────────────────────────────────────────────────

pub const SpoutPythonModule = pyoz.module(.{
    .name = "spout",
    .doc = "Spout analog IC layout automation — native Python extension",
    .classes = &.{
        pyoz.class("Layout", Layout),
    },
    .funcs = &.{
        pyoz.func("liberty_generate", liberty_generate,
            "Generate a Liberty (.lib) file for one PVT corner"),
        pyoz.func("liberty_generate_all_corners", liberty_generate_all_corners,
            "Generate Liberty files for all PVT corners; returns file count"),
    },
});
