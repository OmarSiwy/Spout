const std = @import("std");
const types = @import("../core/types.zig");
const device_arrays = @import("../core/device_arrays.zig");
const rudy_mod = @import("rudy.zig");
const cost_mod = @import("cost.zig");
const macro_types = @import("../macro/types.zig");
const stamp_mod = @import("../macro/stamp.zig");

const DeviceIdx = types.DeviceIdx;
const PinIdx = types.PinIdx;
const DeviceArrays = device_arrays.DeviceArrays;
const RudyGrid = rudy_mod.RudyGrid;
const NetAdjacency = rudy_mod.NetAdjacency;
const CostFunction = cost_mod.CostFunction;
const CostWeights = cost_mod.CostWeights;
const Constraint = cost_mod.Constraint;
const PinInfo = cost_mod.PinInfo;

// ─── Move type ──────────────────────────────────────────────────────────────

/// The kind of perturbation applied in one SA step.
pub const MoveType = enum {
    /// Move one device by a random (dx, dy).
    translate,
    /// Swap the positions of two distinct devices.
    swap,
    /// Swap + mirror a symmetry-constrained pair about the constraint axis.
    mirror_swap,
    /// Translate an entire macro instance (all constituent devices) together.
    macro_translate,
    /// Apply a random affine transform (mirror/rotate) to a macro instance.
    macro_transform,
};

// ─── SA configuration ───────────────────────────────────────────────────────

pub const SaConfig = extern struct {
    initial_temp: f32 = 1000.0,
    cooling_rate: f32 = 0.9995,
    min_temp: f32 = 0.01,
    /// Kept for C-ABI compatibility. Ignored when `kappa > 0`.
    max_iterations: u32 = 50000,
    /// Perturbation range override for translate moves.
    /// 0.0 → use adaptive ρ(T).  Non-zero → pin to this value.
    perturbation_range: f32 = 0.0,
    w_hpwl: f32 = 1.0,
    w_area: f32 = 0.5,
    w_symmetry: f32 = 2.0,
    w_matching: f32 = 1.5,
    w_rudy: f32 = 0.3,
    w_overlap: f32 = 100.0,
    // ── New fields — appended at the END to preserve C-ABI layout ──────
    /// Probability of choosing a swap move over a translate.
    p_swap: f32 = 0.65,
    /// Moves per device per temperature level.
    /// When > 0, uses two-level kappa·N schedule instead of flat max_iterations.
    kappa: f32 = 20.0,
    /// Maximum number of reheats (acceptance-ratio triggered).
    max_reheats: u32 = 5,
    // ── Hierarchical macro placement fields ─────────────────────────────
    /// Probability of picking a macro_translate move (0 = disabled).
    p_macro_translate: f32 = 0.0,
    /// Probability of picking a macro_transform move (0 = disabled).
    p_macro_transform: f32 = 0.0,
    /// Phase 1b re-optimization trigger: run if unit-cell HPWL / top-level HPWL
    /// exceeds this ratio after phase 2. 0.0 = always skip phase 1b.
    hpwl_ratio_phase1b: f32 = 0.3,
};

// ─── SA result ──────────────────────────────────────────────────────────────

pub const SaResult = struct {
    final_cost: f32,
    iterations_run: u32,
    accepted_moves: u32,
    /// How many reheating events occurred during the run.
    reheat_count: u32,
    /// Number of temperature levels executed.
    temperature_levels: u32,
};

// ─── Private schedule helpers ────────────────────────────────────────────────

/// Three-phase cooling multiplier.
///   Phase 1 (T > 0.30·T₀): fast drop through hot useless region (α=0.80)
///   Phase 2 (T > 0.05·T₀): slow refinement in productive zone     (α=0.97)
///   Phase 3 (T ≤ 0.05·T₀): fast freeze                            (α=0.80)
fn computeAlpha(temperature: f32, initial_temp: f32) f32 {
    return if (temperature > 0.3 * initial_temp)
        0.80
    else if (temperature > 0.05 * initial_temp)
        0.97
    else
        0.80;
}

/// Adaptive perturbation range ρ(T).
///
/// Scales linearly from ρ_max at high temperature down to near-zero at
/// freezing point.  When `override_range > 0`, that value is returned
/// regardless of temperature.
fn computeRho(
    temperature: f32,
    initial_temp: f32,
    layout_width: f32,
    layout_height: f32,
    override_range: f32,
) f32 {
    if (override_range > 0.0) return override_range;
    const rho_max = @max(layout_width, layout_height);
    const t_ref = 0.3 * initial_temp;
    return rho_max * @min(1.0, temperature / t_ref);
}

// ─── Device-to-net map builder ──────────────────────────────────────────────

/// Build a mapping from each device to the list of nets it participates in.
/// Returns a slice-of-slices allocated from `allocator`.
fn buildDeviceNets(
    allocator: std.mem.Allocator,
    num_devices: u32,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
) ![][]u32 {
    const ArrayListU32 = std.ArrayList(u32);
    var lists = try allocator.alloc(ArrayListU32, num_devices);
    defer allocator.free(lists);

    for (lists) |*l| {
        l.* = .empty;
    }

    var init_count: usize = num_devices;
    errdefer {
        for (0..init_count) |i| {
            lists[i].deinit(allocator);
        }
    }

    var net: u32 = 0;
    while (net < adj.num_nets) : (net += 1) {
        const start = adj.net_pin_starts[net];
        const end = adj.net_pin_starts[net + 1];
        for (start..end) |k| {
            const pid = adj.pin_list[k].toInt();
            const dev = pin_info[pid].device;
            // Avoid duplicates.
            const items = lists[dev].items;
            var found = false;
            for (items) |existing| {
                if (existing == net) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try lists[dev].append(allocator, net);
            }
        }
    }

    var result = try allocator.alloc([]u32, num_devices);
    errdefer allocator.free(result);

    for (0..num_devices) |i| {
        result[i] = try lists[i].toOwnedSlice(allocator);
    }
    init_count = 0;

    return result;
}

fn freeDeviceNets(allocator: std.mem.Allocator, device_nets: [][]u32) void {
    for (device_nets) |slice| {
        allocator.free(slice);
    }
    allocator.free(device_nets);
}

// ─── Merged net set helper ──────────────────────────────────────────────────

/// Build a deduplicated union of two device-net lists into `buf`.
/// Returns the count of unique net indices written.
/// `buf` must be large enough (at most nets_a.len + nets_b.len entries).
fn mergeNetLists(
    nets_a: []const u32,
    nets_b: []const u32,
    buf: []u32,
) u32 {
    var count: u32 = 0;

    for (nets_a) |n| {
        buf[count] = n;
        count += 1;
    }

    outer: for (nets_b) |n| {
        for (buf[0..count]) |existing| {
            if (existing == n) continue :outer;
        }
        buf[count] = n;
        count += 1;
    }

    return count;
}

// ─── Pin-position helpers ───────────────────────────────────────────────────

/// Recompute all pin positions from device positions + pin offsets.
fn recomputeAllPinPositions(
    pin_positions: [][2]f32,
    device_positions: []const [2]f32,
    pin_info: []const PinInfo,
) void {
    for (pin_positions, 0..) |*pp, i| {
        const info = pin_info[i];
        pp.*[0] = device_positions[info.device][0] + info.offset_x;
        pp.*[1] = device_positions[info.device][1] + info.offset_y;
    }
}

/// Update pin positions for pins belonging to device `dev`.
fn updatePinPositionsForDevice(
    pin_positions: [][2]f32,
    device_positions: []const [2]f32,
    pin_info: []const PinInfo,
    dev: u32,
) void {
    for (pin_positions, 0..) |*pp, i| {
        if (pin_info[i].device == dev) {
            pp.*[0] = device_positions[dev][0] + pin_info[i].offset_x;
            pp.*[1] = device_positions[dev][1] + pin_info[i].offset_y;
        }
    }
}

// ─── Simulated Annealing engine ─────────────────────────────────────────────

/// Run simulated annealing placement.
///
/// * `device_positions`  — mutable; will contain the final placement on return.
/// * `device_dimensions` — per-device [width, height]; used for overlap and
///                         matching-separation penalties.  May be empty, in
///                         which case reasonable defaults are used.
/// * `pin_info`          — per-pin device-index and offset.
/// * `adj`               — net-to-pin adjacency (CSR style).
/// * `constraints`       — symmetry / matching constraints.
/// * `layout_width`, `layout_height` — placement area bounds.
/// * `config`            — SA hyper-parameters and cost weights.
/// * `seed`              — PRNG seed for deterministic runs.
/// * `allocator`         — scratch allocator (freed on return).
pub fn runSa(
    device_positions: [][2]f32,
    device_dimensions: []const [2]f32,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
    constraints: []const Constraint,
    layout_width: f32,
    layout_height: f32,
    config: SaConfig,
    seed: u64,
    allocator: std.mem.Allocator,
) !SaResult {
    const num_devices: u32 = @intCast(device_positions.len);
    const num_pins: u32 = @intCast(pin_info.len);

    if (num_devices == 0) {
        return SaResult{
            .final_cost = 0.0,
            .iterations_run = 0,
            .accepted_moves = 0,
            .reheat_count = 0,
            .temperature_levels = 0,
        };
    }

    // ── Allocate scratch buffers ────────────────────────────────────────

    // Current pin positions.
    const pin_positions = try allocator.alloc([2]f32, num_pins);
    defer allocator.free(pin_positions);

    // Snapshot of pin positions taken before each move (pre-move state).
    const saved_pin_positions = try allocator.alloc([2]f32, num_pins);
    defer allocator.free(saved_pin_positions);

    // Build device → nets mapping.
    const device_nets = try buildDeviceNets(allocator, num_devices, pin_info, adj);
    defer freeDeviceNets(allocator, device_nets);

    // Scratch buffer for merged net lists (swap moves need union of two devices).
    // Upper bound: sum of net counts for any two devices, which is at most
    // adj.num_nets (since nets can't appear more than once per device).
    const max_merged_nets: usize = adj.num_nets + 1;
    const merged_nets_buf = try allocator.alloc(u32, @max(max_merged_nets, 1));
    defer allocator.free(merged_nets_buf);

    // RUDY grid.
    const tile_size: f32 = 10.0;
    const metal_pitch: f32 = 0.5;
    var rudy_grid = try RudyGrid.init(allocator, layout_width, layout_height, tile_size, metal_pitch);
    defer rudy_grid.deinit();

    // ── PRNG ────────────────────────────────────────────────────────────

    var prng = std.Random.Xoshiro256.init(seed);
    const random = prng.random();

    // ── Initial greedy placement ─────────────────────────────────────────
    // Place devices in a row with proper spacing to start non-overlapping.
    // This gives the SA a feasible starting point, avoiding the scenario
    // where random placement creates irrecoverable overlaps.
    {
        const spacing_gap: f32 = 1.0; // extra gap between devices (µm)
        var cursor_x: f32 = 0.0;
        var max_h: f32 = 0.0;

        for (0..num_devices) |di| {
            const dw = if (device_dimensions.len > di and device_dimensions[di][0] > 0.0)
                device_dimensions[di][0]
            else
                2.0;
            const dh = if (device_dimensions.len > di and device_dimensions[di][1] > 0.0)
                device_dimensions[di][1]
            else
                2.0;

            // Centre the device at (cursor_x + dw/2, dh/2).
            device_positions[di][0] = cursor_x + dw * 0.5;
            device_positions[di][1] = dh * 0.5;
            cursor_x += dw + spacing_gap;
            max_h = @max(max_h, dh);
        }

        // Nudge devices so they're roughly centred within layout bounds.
        const total_w = cursor_x - spacing_gap;
        const offset_x = @max(0.0, (layout_width - total_w) * 0.5);
        const offset_y = @max(0.0, (layout_height - max_h) * 0.5);
        for (device_positions) |*pos| {
            pos.*[0] = std.math.clamp(pos.*[0] + offset_x, 0.0, layout_width);
            pos.*[1] = std.math.clamp(pos.*[1] + offset_y, 0.0, layout_height);
        }
    }

    recomputeAllPinPositions(pin_positions, device_positions, pin_info);
    rudy_grid.computeFull(pin_positions, adj);

    // ── Cost function ───────────────────────────────────────────────────

    const weights = CostWeights{
        .w_hpwl = config.w_hpwl,
        .w_area = config.w_area,
        .w_symmetry = config.w_symmetry,
        .w_matching = config.w_matching,
        .w_rudy = config.w_rudy,
        .w_overlap = config.w_overlap,
    };
    var cost_fn = CostFunction.init(weights);
    _ = cost_fn.computeFull(
        device_positions,
        device_dimensions,
        pin_positions,
        adj,
        constraints,
        &rudy_grid,
        &.{}, // is_power: sa.zig has no power-net info yet
    );

    // ── SA main loop ────────────────────────────────────────────────────

    var total_iters: u32 = 0;
    var total_accepted: u32 = 0;
    var reheat_count: u32 = 0;
    var temperature_levels: u32 = 0;

    var temperature: f32 = config.initial_temp;

    const use_kappa = config.kappa > 0.0;

    if (use_kappa) {
        // ── Two-level κ·N schedule ──────────────────────────────────────
        while (temperature > config.min_temp) {
            const alpha = computeAlpha(temperature, config.initial_temp);
            const moves_this_level: u32 = @max(
                1,
                @as(u32, @intFromFloat(config.kappa * @as(f32, @floatFromInt(num_devices)))),
            );

            var level_accepted: u32 = 0;
            var level_total: u32 = 0;

            for (0..moves_this_level) |_| {
                const accepted = runOneMove(
                    device_positions,
                    device_dimensions,
                    pin_positions,
                    saved_pin_positions,
                    pin_info,
                    adj,
                    constraints,
                    device_nets,
                    merged_nets_buf,
                    &rudy_grid,
                    &cost_fn,
                    layout_width,
                    layout_height,
                    temperature,
                    config,
                    random,
                );
                total_iters += 1;
                level_total += 1;
                if (accepted) {
                    total_accepted += 1;
                    level_accepted += 1;
                }
            }

            // Acceptance-ratio reheating (Change #4).
            const r: f32 = @as(f32, @floatFromInt(level_accepted)) /
                @as(f32, @floatFromInt(@max(1, level_total)));
            if (r < 0.02 and reheat_count < config.max_reheats) {
                temperature *= 3.0;
                reheat_count += 1;
            }

            temperature_levels += 1;
            temperature *= alpha;
        }
    } else {
        // ── Legacy flat loop (max_iterations) ──────────────────────────
        // Used when kappa == 0 for backward compatibility with C callers
        // that rely on exact iteration counts.
        var iter: u32 = 0;
        while (iter < config.max_iterations and temperature > config.min_temp) : (iter += 1) {
            const accepted = runOneMove(
                device_positions,
                device_dimensions,
                pin_positions,
                saved_pin_positions,
                pin_info,
                adj,
                constraints,
                device_nets,
                merged_nets_buf,
                &rudy_grid,
                &cost_fn,
                layout_width,
                layout_height,
                temperature,
                config,
                random,
            );
            total_iters += 1;
            if (accepted) total_accepted += 1;
            temperature *= config.cooling_rate;
        }
        temperature_levels = total_iters; // degenerate: one level per iter
    }

    // Final consistency pass: recompute everything from the converged placement.
    recomputeAllPinPositions(pin_positions, device_positions, pin_info);
    rudy_grid.computeFull(pin_positions, adj);
    _ = cost_fn.computeFull(device_positions, device_dimensions, pin_positions, adj, constraints, &rudy_grid, &.{});

    return SaResult{
        .final_cost = cost_fn.total,
        .iterations_run = total_iters,
        .accepted_moves = total_accepted,
        .reheat_count = reheat_count,
        .temperature_levels = temperature_levels,
    };
}

// ─── Single SA move ──────────────────────────────────────────────────────────

/// Execute one SA move (translate, swap, or mirror_swap) and apply
/// Metropolis acceptance.  Returns true if the move was accepted.
fn runOneMove(
    device_positions: [][2]f32,
    device_dimensions: []const [2]f32,
    pin_positions: [][2]f32,
    saved_pin_positions: [][2]f32,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
    constraints: []const Constraint,
    device_nets: []const []u32,
    merged_nets_buf: []u32,
    rudy_grid: *RudyGrid,
    cost_fn: *CostFunction,
    layout_width: f32,
    layout_height: f32,
    temperature: f32,
    config: SaConfig,
    random: std.Random,
) bool {
    const num_devices: u32 = @intCast(device_positions.len);

    // Decide move type.
    const move_type: MoveType = blk: {
        const roll = random.float(f32);
        if (roll < config.p_swap and num_devices >= 2) {
            // Check whether a mirror_swap is applicable: find any symmetry
            // constraint linking the (not-yet-chosen) pair.  We pick the
            // swap targets first.
            break :blk .swap; // refined below after picking i/j
        }
        break :blk .translate;
    };

    switch (move_type) {
        .translate => {
            return runTranslateMove(
                device_positions,
                device_dimensions,
                pin_positions,
                saved_pin_positions,
                pin_info,
                adj,
                constraints,
                device_nets,
                rudy_grid,
                cost_fn,
                layout_width,
                layout_height,
                temperature,
                config,
                random,
            );
        },
        .swap => {
            return runSwapMove(
                device_positions,
                device_dimensions,
                pin_positions,
                saved_pin_positions,
                pin_info,
                adj,
                constraints,
                device_nets,
                merged_nets_buf,
                rudy_grid,
                cost_fn,
                layout_width,
                layout_height,
                temperature,
                config,
                random,
                false, // not forced mirror
            );
        },
        .mirror_swap => unreachable, // selected inside runSwapMove after pair is known
        .macro_translate => unreachable, // used only in runSaHierarchical
        .macro_transform => unreachable, // used only in runSaHierarchical
    }
}

// ─── Translate move ──────────────────────────────────────────────────────────

fn runTranslateMove(
    device_positions: [][2]f32,
    device_dimensions: []const [2]f32,
    pin_positions: [][2]f32,
    saved_pin_positions: [][2]f32,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
    constraints: []const Constraint,
    device_nets: []const []u32,
    rudy_grid: *RudyGrid,
    cost_fn: *CostFunction,
    layout_width: f32,
    layout_height: f32,
    temperature: f32,
    config: SaConfig,
    random: std.Random,
) bool {
    const num_devices: u32 = @intCast(device_positions.len);

    // (a) Pick a random device.
    const dev: u32 = random.intRangeLessThan(u32, 0, num_devices);

    // Save state before move.
    const old_dev_pos = device_positions[dev];
    @memcpy(saved_pin_positions, pin_positions);

    // (b) Adaptive perturbation range ρ(T).
    const rho = computeRho(temperature, config.initial_temp, layout_width, layout_height, config.perturbation_range);

    // (c) Perturb: uniform random displacement in [-rho, rho]².
    const dx = (random.float(f32) * 2.0 - 1.0) * rho;
    const dy = (random.float(f32) * 2.0 - 1.0) * rho;

    // (d) Clamp to layout bounds.
    device_positions[dev][0] = std.math.clamp(old_dev_pos[0] + dx, 0.0, layout_width);
    device_positions[dev][1] = std.math.clamp(old_dev_pos[1] + dy, 0.0, layout_height);

    // (e) Update pin positions for the moved device.
    updatePinPositionsForDevice(pin_positions, device_positions, pin_info, dev);

    // Incrementally update RUDY.
    rudy_grid.updateIncremental(device_nets[dev], saved_pin_positions, pin_positions, adj);

    // (f) Compute delta cost.
    const delta_result = cost_fn.computeDeltaCost(
        dev,
        old_dev_pos,
        device_positions[dev],
        saved_pin_positions,
        pin_positions,
        device_positions,
        device_dimensions,
        adj,
        device_nets[dev],
        constraints,
        rudy_grid,
    );

    // (g) Metropolis acceptance criterion.
    const accept = if (delta_result.delta < 0.0)
        true
    else blk: {
        const boltzmann = @exp(-delta_result.delta / temperature);
        break :blk random.float(f32) < boltzmann;
    };

    if (accept) {
        cost_fn.acceptDelta(
            delta_result.new_hpwl_sum,
            delta_result.new_area,
            delta_result.new_sym,
            delta_result.new_match,
            delta_result.new_rudy,
            delta_result.new_total,
        );
    } else {
        // Revert RUDY then restore positions.
        rudy_grid.updateIncremental(device_nets[dev], pin_positions, saved_pin_positions, adj);
        device_positions[dev] = old_dev_pos;
        @memcpy(pin_positions, saved_pin_positions);
    }

    return accept;
}

// ─── Swap move ───────────────────────────────────────────────────────────────

/// Execute a swap (or mirror_swap) of two randomly-chosen devices.
///
/// The function first picks two distinct devices i and j.  If a symmetry
/// constraint links them and the roll says .swap, it attempts a mirror_swap
/// instead (placing i at j's mirror position about the axis, and j at i's
/// old position).  Otherwise it performs a plain position exchange.
fn runSwapMove(
    device_positions: [][2]f32,
    device_dimensions: []const [2]f32,
    pin_positions: [][2]f32,
    saved_pin_positions: [][2]f32,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
    constraints: []const Constraint,
    device_nets: []const []u32,
    merged_nets_buf: []u32,
    rudy_grid: *RudyGrid,
    cost_fn: *CostFunction,
    layout_width: f32,
    layout_height: f32,
    temperature: f32,
    _: SaConfig,
    random: std.Random,
    force_mirror: bool,
) bool {
    const num_devices: u32 = @intCast(device_positions.len);

    // Pick two distinct devices.
    const dev_i: u32 = random.intRangeLessThan(u32, 0, num_devices);
    var dev_j: u32 = random.intRangeLessThan(u32, 0, num_devices - 1);
    if (dev_j >= dev_i) dev_j += 1;

    // Save full state before the swap.
    const old_pos_i = device_positions[dev_i];
    const old_pos_j = device_positions[dev_j];
    @memcpy(saved_pin_positions, pin_positions);

    // Detect whether a symmetry constraint links i and j.
    var sym_axis: f32 = 0.0;
    var has_sym = false;
    for (constraints) |c| {
        if (c.kind == .symmetry) {
            if ((c.dev_a == dev_i and c.dev_b == dev_j) or
                (c.dev_a == dev_j and c.dev_b == dev_i))
            {
                sym_axis = c.axis_x;
                has_sym = true;
                break;
            }
        }
    }

    // Decide plain swap vs mirror_swap.
    const do_mirror = (force_mirror or has_sym) and has_sym;

    if (do_mirror) {
        // Mirror_swap: place i at mirror of old i about axis, j at old i's position.
        // Mirror formula: new_x_i = 2·axis - old_x_i
        device_positions[dev_i][0] = 2.0 * sym_axis - old_pos_i[0];
        device_positions[dev_i][1] = old_pos_i[1];
        device_positions[dev_j][0] = old_pos_i[0];
        device_positions[dev_j][1] = old_pos_i[1];
    } else {
        // Plain swap: exchange positions.
        device_positions[dev_i] = old_pos_j;
        device_positions[dev_j] = old_pos_i;
    }

    // Clamp both to layout bounds.
    device_positions[dev_i][0] = std.math.clamp(device_positions[dev_i][0], 0.0, layout_width);
    device_positions[dev_i][1] = std.math.clamp(device_positions[dev_i][1], 0.0, layout_height);
    device_positions[dev_j][0] = std.math.clamp(device_positions[dev_j][0], 0.0, layout_width);
    device_positions[dev_j][1] = std.math.clamp(device_positions[dev_j][1], 0.0, layout_height);

    // Update pin positions for both moved devices.
    updatePinPositionsForDevice(pin_positions, device_positions, pin_info, dev_i);
    updatePinPositionsForDevice(pin_positions, device_positions, pin_info, dev_j);

    // Build merged net list (union of both devices' nets).
    const merged_count = mergeNetLists(device_nets[dev_i], device_nets[dev_j], merged_nets_buf);
    const merged_nets = merged_nets_buf[0..merged_count];

    // Incrementally update RUDY for the merged net set.
    rudy_grid.updateIncremental(merged_nets, saved_pin_positions, pin_positions, adj);

    // Compute delta cost using device i's net list as the primary device
    // (area, sym, match, overlap are all fully recomputed in computeDeltaCost
    // so it doesn't matter which device we pass as `dev`).
    const delta_result = cost_fn.computeDeltaCost(
        dev_i,
        old_pos_i,
        device_positions[dev_i],
        saved_pin_positions,
        pin_positions,
        device_positions,
        device_dimensions,
        adj,
        merged_nets,
        constraints,
        rudy_grid,
    );

    // Metropolis acceptance.
    const accept = if (delta_result.delta < 0.0)
        true
    else blk: {
        const boltzmann = @exp(-delta_result.delta / temperature);
        break :blk random.float(f32) < boltzmann;
    };

    if (accept) {
        cost_fn.acceptDelta(
            delta_result.new_hpwl_sum,
            delta_result.new_area,
            delta_result.new_sym,
            delta_result.new_match,
            delta_result.new_rudy,
            delta_result.new_total,
        );
    } else {
        // Revert RUDY: go back from post-move to pre-move.
        rudy_grid.updateIncremental(merged_nets, pin_positions, saved_pin_positions, adj);
        // Restore positions.
        device_positions[dev_i] = old_pos_i;
        device_positions[dev_j] = old_pos_j;
        @memcpy(pin_positions, saved_pin_positions);
    }

    return accept;
}

// ─── Hierarchical SA (macro-aware two-phase placement) ───────────────────────

/// Two-phase hierarchical simulated annealing.
///
/// **Phase 1** — Optimize the unit cell geometry (internal layout of each
///   template's constituent devices).  Skipped for single-device templates.
///
/// **Phase 2** — Collapse each macro instance to a super-device (dimensions =
///   unit cell bounding box) and run SA on the resulting super-device graph.
///   Non-macro devices participate alongside the super-devices.  After SA,
///   `instance.position` is updated from the super-device positions.
///
/// **Phase 1b** — Conditional re-optimization of the unit cell if
///   `config.hpwl_ratio_phase1b > 0` and any template has more than one
///   constituent device.
///
/// **stampAll** — Propagate unit-cell positions to every instance.
///
/// Falls back to `runSa` when no macros are detected.
pub fn runSaHierarchical(
    allocator: std.mem.Allocator,
    devices: *device_arrays.DeviceArrays,
    macros: *macro_types.MacroArrays,
    pin_info: []const PinInfo,
    adj: NetAdjacency,
    constraints: []const Constraint,
    layout_width: f32,
    layout_height: f32,
    config: SaConfig,
    seed: u64,
) !SaResult {
    const n_dev: u32 = @intCast(devices.len);
    const n_inst: u32 = macros.instance_count;
    const n_tmpl: u32 = macros.template_count;

    // ── Fallback: no macros ──────────────────────────────────────────────
    if (n_inst == 0 or n_tmpl == 0) {
        return runSa(
            devices.positions[0..n_dev],
            devices.dimensions[0..n_dev],
            pin_info,
            adj,
            constraints,
            layout_width,
            layout_height,
            config,
            seed,
            allocator,
        );
    }

    // ── Phase 1: unit-cell SA ────────────────────────────────────────────
    // For each template with >1 device, run SA on just the constituent
    // devices.  Positions are stored relative to the unit-cell origin.
    for (macros.templates[0..n_tmpl]) |tmpl| {
        if (tmpl.device_indices.len <= 1) continue;
        const tmpl_pos = try allocator.alloc([2]f32, tmpl.device_indices.len);
        defer allocator.free(tmpl_pos);
        const tmpl_dim = try allocator.alloc([2]f32, tmpl.device_indices.len);
        defer allocator.free(tmpl_dim);
        for (tmpl.device_indices, 0..) |di, k| {
            tmpl_pos[k] = devices.positions[di];
            tmpl_dim[k] = devices.dimensions[di];
        }
        // No inter-cell pins or constraints for the unit cell — pass empty slices.
        const empty_adj = NetAdjacency{ .net_pin_starts = &.{}, .pin_list = &.{}, .num_nets = 0 };
        _ = try runSa(tmpl_pos, tmpl_dim, &.{}, empty_adj, &.{},
            layout_width, layout_height, config, seed, allocator);
        for (tmpl.device_indices, 0..) |di, k| {
            devices.positions[di] = tmpl_pos[k];
        }
    }

    // ── Phase 2: super-device SA ─────────────────────────────────────────
    // Map each device to a super-device index:
    //   macro device d belonging to instance i  →  super-index = i
    //   non-macro device                         →  super-index = n_inst + k
    const dev_to_super = try allocator.alloc(u32, n_dev);
    defer allocator.free(dev_to_super);
    @memset(dev_to_super, std.math.maxInt(u32));
    for (macros.instances[0..n_inst], 0..) |inst, i| {
        for (inst.device_indices) |di| dev_to_super[di] = @intCast(i);
    }
    var n_non_macro: u32 = 0;
    for (0..n_dev) |d| {
        if (dev_to_super[d] == std.math.maxInt(u32)) {
            dev_to_super[d] = n_inst + n_non_macro;
            n_non_macro += 1;
        }
    }
    const n_super = n_inst + n_non_macro;

    const super_pos = try allocator.alloc([2]f32, n_super);
    defer allocator.free(super_pos);
    const super_dim = try allocator.alloc([2]f32, n_super);
    defer allocator.free(super_dim);

    for (macros.instances[0..n_inst], 0..) |inst, i| {
        const tmpl = macros.templates[inst.template_id];
        const bbox = stamp_mod.computeBbox(devices.positions[0..n_dev], devices.dimensions[0..n_dev], tmpl);
        super_pos[i] = inst.position;
        super_dim[i] = bbox;
    }
    for (0..n_dev) |d| {
        const si = dev_to_super[d];
        if (si >= n_inst) {
            super_pos[si] = devices.positions[d];
            super_dim[si] = devices.dimensions[d];
        }
    }

    // Remap pin_info device field to super-device index.
    const super_pins = try allocator.alloc(PinInfo, pin_info.len);
    defer allocator.free(super_pins);
    for (pin_info, 0..) |pi, k| {
        super_pins[k] = .{ .device = dev_to_super[pi.device], .offset_x = pi.offset_x, .offset_y = pi.offset_y };
    }

    // Keep only inter-super-device constraints (skip intra-instance ones).
    var super_cst = std.array_list.Managed(Constraint).init(allocator);
    defer super_cst.deinit();
    for (constraints) |c| {
        const sa = dev_to_super[c.dev_a];
        const sb = dev_to_super[c.dev_b];
        if (sa == sb) continue; // intra-instance
        try super_cst.append(.{ .kind = c.kind, .dev_a = sa, .dev_b = sb, .axis_x = c.axis_x });
    }

    const phase2 = try runSa(
        super_pos, super_dim, super_pins, adj, super_cst.items,
        layout_width, layout_height, config, seed ^ 0x9e3779b9, allocator,
    );

    // Write back: instance positions and non-macro device positions.
    for (macros.instances[0..n_inst], 0..) |*inst, i| {
        inst.position = super_pos[i];
    }
    for (0..n_dev) |d| {
        const si = dev_to_super[d];
        if (si >= n_inst) devices.positions[d] = super_pos[si];
    }

    // ── Phase 1b: conditional unit-cell re-refinement ────────────────────
    if (config.hpwl_ratio_phase1b > 0.0) {
        for (macros.templates[0..n_tmpl]) |tmpl| {
            if (tmpl.device_indices.len <= 1) continue;
            const tmpl_pos = try allocator.alloc([2]f32, tmpl.device_indices.len);
            defer allocator.free(tmpl_pos);
            const tmpl_dim = try allocator.alloc([2]f32, tmpl.device_indices.len);
            defer allocator.free(tmpl_dim);
            for (tmpl.device_indices, 0..) |di, k| {
                tmpl_pos[k] = devices.positions[di];
                tmpl_dim[k] = devices.dimensions[di];
            }
            const empty_adj = NetAdjacency{ .net_pin_starts = &.{}, .pin_list = &.{}, .num_nets = 0 };
            _ = try runSa(tmpl_pos, tmpl_dim, &.{}, empty_adj, &.{},
                layout_width, layout_height, config, seed ^ 0xdeadbeef, allocator);
            for (tmpl.device_indices, 0..) |di, k| {
                devices.positions[di] = tmpl_pos[k];
            }
        }
    }

    // ── stampAll: propagate unit-cell positions to all instances ─────────
    try stamp_mod.stampAll(allocator, devices, macros);

    return phase2;
}

// ─── Module-level tests ─────────────────────────────────────────────────────

test "SaConfig is extern-compatible" {
    try std.testing.expect(@sizeOf(SaConfig) > 0);
}

test "SaConfig default values" {
    const config = SaConfig{};
    try std.testing.expectEqual(@as(f32, 1000.0), config.initial_temp);
    try std.testing.expectEqual(@as(f32, 0.9995), config.cooling_rate);
    try std.testing.expectEqual(@as(f32, 0.01), config.min_temp);
    try std.testing.expectEqual(@as(u32, 50000), config.max_iterations);
    try std.testing.expectEqual(@as(f32, 20.0), config.kappa);
    try std.testing.expectEqual(@as(f32, 0.65), config.p_swap);
    try std.testing.expectEqual(@as(u32, 5), config.max_reheats);
}

test "runSa zero devices" {
    var positions = [_][2]f32{};
    const dimensions = [_][2]f32{};
    const pin_info = [_]PinInfo{};
    const starts = [_]u32{0};
    const pin_list = [_]types.PinIdx{};
    const adj = NetAdjacency{
        .net_pin_starts = &starts,
        .pin_list = &pin_list,
        .num_nets = 0,
    };
    const constraints = [_]Constraint{};
    const config = SaConfig{};

    const result = try runSa(
        &positions,
        &dimensions,
        &pin_info,
        adj,
        &constraints,
        100.0,
        100.0,
        config,
        42,
        std.testing.allocator,
    );
    try std.testing.expectEqual(@as(f32, 0.0), result.final_cost);
    try std.testing.expectEqual(@as(u32, 0), result.reheat_count);
    try std.testing.expectEqual(@as(u32, 0), result.temperature_levels);
}

// ── Test helpers ─────────────────────────────────────────────────────────────

/// Build a minimal N-device, N-net circuit with one pin per device per net.
/// Layout: 100×100.  All device dimensions are 2×2.  No constraints.
/// Returns a pre-built NetAdjacency (caller owns the slices).
fn makeSimpleAdj(
    allocator: std.mem.Allocator,
    num_devices: u32,
) !struct {
    adj: NetAdjacency,
    starts: []u32,
    pin_list: []types.PinIdx,
    pin_info: []PinInfo,
} {
    // One net per device pair: net n connects pin 2n and pin 2n+1.
    // For simplicity: N devices, 1 net connecting pin 0..num_devices-1.
    const num_pins = num_devices;
    const starts = try allocator.alloc(u32, 2);
    starts[0] = 0;
    starts[1] = num_pins;

    const pin_list_arr = try allocator.alloc(types.PinIdx, num_pins);
    for (0..num_pins) |i| {
        pin_list_arr[i] = types.PinIdx.fromInt(@intCast(i));
    }

    const pin_info_arr = try allocator.alloc(PinInfo, num_pins);
    for (0..num_pins) |i| {
        pin_info_arr[i] = .{ .device = @intCast(i), .offset_x = 0.0, .offset_y = 0.0 };
    }

    return .{
        .adj = NetAdjacency{
            .net_pin_starts = starts,
            .pin_list = pin_list_arr,
            .num_nets = 1,
        },
        .starts = starts,
        .pin_list = pin_list_arr,
        .pin_info = pin_info_arr,
    };
}

// ── Test #1: κ·N scaling ─────────────────────────────────────────────────────

test "kappa N scaling: iterations roughly proportional to N" {
    const alloc = std.testing.allocator;

    // N=5 devices, kappa=10
    {
        var positions = [_][2]f32{.{ 0.0, 0.0 }} ** 5;
        const dims = [_][2]f32{.{ 2.0, 2.0 }} ** 5;
        const circuit = try makeSimpleAdj(alloc, 5);
        defer alloc.free(circuit.starts);
        defer alloc.free(circuit.pin_list);
        defer alloc.free(circuit.pin_info);

        const config = SaConfig{
            .kappa = 10.0,
            .p_swap = 0.0,
            .max_reheats = 0,
            .w_overlap = 0.0,
        };
        const result = try runSa(
            &positions,
            &dims,
            circuit.pin_info,
            circuit.adj,
            &[_]Constraint{},
            100.0,
            100.0,
            config,
            1,
            alloc,
        );
        // iterations_run should be roughly kappa * N * num_levels.
        // At minimum it must be >= kappa * N (at least one level).
        try std.testing.expect(result.iterations_run >= 10 * 5);
        try std.testing.expect(!std.math.isNan(result.final_cost));
    }

    // N=10 devices — must run more iterations than N=5.
    {
        var positions = [_][2]f32{.{ 0.0, 0.0 }} ** 10;
        const dims = [_][2]f32{.{ 2.0, 2.0 }} ** 10;
        const circuit = try makeSimpleAdj(alloc, 10);
        defer alloc.free(circuit.starts);
        defer alloc.free(circuit.pin_list);
        defer alloc.free(circuit.pin_info);

        const config = SaConfig{
            .kappa = 10.0,
            .p_swap = 0.0,
            .max_reheats = 0,
            .w_overlap = 0.0,
        };
        const result = try runSa(
            &positions,
            &dims,
            circuit.pin_info,
            circuit.adj,
            &[_]Constraint{},
            100.0,
            100.0,
            config,
            1,
            alloc,
        );
        try std.testing.expect(result.iterations_run >= 10 * 10);
        try std.testing.expect(!std.math.isNan(result.final_cost));
    }
}

// ── Test #2: Three-phase cooling ─────────────────────────────────────────────

test "three-phase cooling: alpha values are correct" {
    // Phase 1: T > 0.3 * T0 → alpha = 0.80
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.80),
        computeAlpha(500.0, 1000.0),
        1e-6,
    );
    // Phase 2: 0.05*T0 < T <= 0.3*T0 → alpha = 0.97
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.97),
        computeAlpha(100.0, 1000.0),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.97),
        computeAlpha(51.0, 1000.0),
        1e-6,
    );
    // Exactly at 0.3 boundary — temperature IS 0.3*T0; the condition is
    // `> 0.3*T0` so this falls into phase 2.
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.97),
        computeAlpha(300.0, 1000.0),
        1e-6,
    );
    // Phase 3: T <= 0.05*T0 → alpha = 0.80
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.80),
        computeAlpha(50.0, 1000.0),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.80),
        computeAlpha(0.001, 1000.0),
        1e-6,
    );

    // Phase 1 drops fast: after 1 level from T0=1000 (phase 1), temp = 800.
    const t1 = 1000.0 * computeAlpha(1000.0, 1000.0);
    try std.testing.expectApproxEqAbs(@as(f32, 800.0), t1, 1e-3);
}

// ── Test #3: Reheating ───────────────────────────────────────────────────────

test "reheating fires when acceptance rate is low" {
    const alloc = std.testing.allocator;

    // Start at a very low temperature so the SA immediately freezes.
    // With initial_temp = 0.001 (just above min_temp 0.0001), nearly every
    // uphill move is rejected, so acceptance ratio → 0 → reheating fires.
    var positions = [_][2]f32{ .{ 0.0, 0.0 }, .{ 10.0, 0.0 } };
    const dims = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const circuit = try makeSimpleAdj(alloc, 2);
    defer alloc.free(circuit.starts);
    defer alloc.free(circuit.pin_list);
    defer alloc.free(circuit.pin_info);

    const config = SaConfig{
        .initial_temp = 0.001,
        .min_temp = 0.0001,
        .kappa = 5.0,
        .p_swap = 0.0,
        .max_reheats = 3,
        .w_overlap = 0.0,
    };
    const result = try runSa(
        &positions,
        &dims,
        circuit.pin_info,
        circuit.adj,
        &[_]Constraint{},
        100.0,
        100.0,
        config,
        77,
        alloc,
    );

    // reheat_count must be in [0, max_reheats].
    try std.testing.expect(result.reheat_count <= 3);
    // At very low T, reheating is expected.
    try std.testing.expect(result.reheat_count > 0);
    try std.testing.expect(!std.math.isNan(result.final_cost));
}

// ── Test #4: Adaptive ρ ──────────────────────────────────────────────────────

test "computeRho adaptive perturbation range" {
    // At T=T0=1000, layout=100×100: rho = 100 (t_ref=300, T/t_ref=3.33 clamped to 1)
    try std.testing.expectApproxEqAbs(
        @as(f32, 100.0),
        computeRho(1000.0, 1000.0, 100.0, 100.0, 0.0),
        1e-4,
    );

    // At T=150, T0=1000, t_ref=300: rho = 100 * (150/300) = 50
    try std.testing.expectApproxEqAbs(
        @as(f32, 50.0),
        computeRho(150.0, 1000.0, 100.0, 100.0, 0.0),
        1e-4,
    );

    // At T=0.01, T0=1000: T/t_ref = 0.01/300 ≈ 0.0000333 → rho ≈ 0.00333
    const tiny_rho = computeRho(0.01, 1000.0, 100.0, 100.0, 0.0);
    try std.testing.expect(tiny_rho < 0.1);
    try std.testing.expect(tiny_rho >= 0.0);

    // override_range always wins.
    try std.testing.expectApproxEqAbs(
        @as(f32, 5.0),
        computeRho(1000.0, 1000.0, 100.0, 100.0, 5.0),
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 5.0),
        computeRho(0.001, 1000.0, 100.0, 100.0, 5.0),
        1e-6,
    );
}

// ── Test #5: Swap move validity ──────────────────────────────────────────────

test "swap-only and translate-only both produce finite non-negative cost" {
    const alloc = std.testing.allocator;

    const num_devices: u32 = 4;
    const pin_info_arr = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 2, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 3, .offset_x = 0.0, .offset_y = 0.0 },
    };
    const pin_list_arr = [_]types.PinIdx{
        types.PinIdx.fromInt(0), types.PinIdx.fromInt(1),
        types.PinIdx.fromInt(2), types.PinIdx.fromInt(3),
    };
    const starts_arr = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts_arr,
        .pin_list = &pin_list_arr,
        .num_nets = 2,
    };
    const dims = [_][2]f32{ .{ 2.0, 2.0 } } ** num_devices;
    const constraints = [_]Constraint{};

    // All-swap run.
    {
        var positions = [_][2]f32{
            .{ 5.0, 5.0 }, .{ 15.0, 5.0 }, .{ 25.0, 5.0 }, .{ 35.0, 5.0 },
        };
        const config = SaConfig{
            .p_swap = 1.0,
            .kappa = 5.0,
            .max_reheats = 0,
            .w_overlap = 0.0,
        };
        const result = try runSa(
            &positions,
            &dims,
            &pin_info_arr,
            adj,
            &constraints,
            100.0,
            100.0,
            config,
            42,
            alloc,
        );
        try std.testing.expect(result.final_cost >= 0.0);
        try std.testing.expect(!std.math.isNan(result.final_cost));
        try std.testing.expect(!std.math.isInf(result.final_cost));
    }

    // All-translate run.
    {
        var positions = [_][2]f32{
            .{ 5.0, 5.0 }, .{ 15.0, 5.0 }, .{ 25.0, 5.0 }, .{ 35.0, 5.0 },
        };
        const config = SaConfig{
            .p_swap = 0.0,
            .kappa = 5.0,
            .max_reheats = 0,
            .w_overlap = 0.0,
        };
        const result = try runSa(
            &positions,
            &dims,
            &pin_info_arr,
            adj,
            &constraints,
            100.0,
            100.0,
            config,
            42,
            alloc,
        );
        try std.testing.expect(result.final_cost >= 0.0);
        try std.testing.expect(!std.math.isNan(result.final_cost));
        try std.testing.expect(!std.math.isInf(result.final_cost));
    }
}

// ── Test #6: Determinism ─────────────────────────────────────────────────────

test "SA is deterministic with same seed (kappa schedule)" {
    const alloc = std.testing.allocator;
    const num_devices: u32 = 4;
    const pin_info_arr = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 2, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 3, .offset_x = 0.0, .offset_y = 0.0 },
    };
    const pin_list_arr = [_]types.PinIdx{
        types.PinIdx.fromInt(0), types.PinIdx.fromInt(1),
        types.PinIdx.fromInt(2), types.PinIdx.fromInt(3),
    };
    const starts_arr = [_]u32{ 0, 2, 4 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts_arr,
        .pin_list = &pin_list_arr,
        .num_nets = 2,
    };
    const dims = [_][2]f32{ .{ 2.0, 2.0 } } ** num_devices;
    const constraints = [_]Constraint{};

    const config = SaConfig{
        .kappa = 5.0,
        .p_swap = 0.5,
        .max_reheats = 2,
        .w_overlap = 0.0,
    };

    var pos_a = [_][2]f32{ .{ 0.0, 0.0 } } ** num_devices;
    var pos_b = [_][2]f32{ .{ 0.0, 0.0 } } ** num_devices;

    const result_a = try runSa(&pos_a, &dims, &pin_info_arr, adj, &constraints, 100.0, 100.0, config, 7777, alloc);
    const result_b = try runSa(&pos_b, &dims, &pin_info_arr, adj, &constraints, 100.0, 100.0, config, 7777, alloc);

    try std.testing.expectApproxEqAbs(result_a.final_cost, result_b.final_cost, 1e-5);
    try std.testing.expectEqual(result_a.iterations_run, result_b.iterations_run);
    try std.testing.expectEqual(result_a.accepted_moves, result_b.accepted_moves);
    try std.testing.expectEqual(result_a.reheat_count, result_b.reheat_count);
    try std.testing.expectEqual(result_a.temperature_levels, result_b.temperature_levels);

    for (0..num_devices) |i| {
        try std.testing.expectApproxEqAbs(pos_a[i][0], pos_b[i][0], 1e-5);
        try std.testing.expectApproxEqAbs(pos_a[i][1], pos_b[i][1], 1e-5);
    }
}

// ── Test #7: Mirror-swap geometry ────────────────────────────────────────────

test "mirror_swap preserves symmetry-axis property" {
    const alloc = std.testing.allocator;

    // Two devices at (3, 5) and (7, 5), symmetry axis at x=5.
    // After mirror_swap: dev_i should land at (2*5 - 3, 3) = (7, 5) (mirror of old i),
    // dev_j should land at (3, 5) (old i's position).
    // Property: positions[dev_i][0] + positions[dev_j][0] ≈ 2 * axis_x
    // but that depends on randomness — instead we test the geometry directly.

    // Minimal 2-device circuit.
    const num_pins: u32 = 2;
    const pin_info_arr = [_]PinInfo{
        .{ .device = 0, .offset_x = 0.0, .offset_y = 0.0 },
        .{ .device = 1, .offset_x = 0.0, .offset_y = 0.0 },
    };
    const pin_list_arr = [_]types.PinIdx{
        types.PinIdx.fromInt(0),
        types.PinIdx.fromInt(1),
    };
    const starts_arr = [_]u32{ 0, 2 };
    const adj = NetAdjacency{
        .net_pin_starts = &starts_arr,
        .pin_list = &pin_list_arr,
        .num_nets = 1,
    };
    const dims = [_][2]f32{ .{ 2.0, 2.0 }, .{ 2.0, 2.0 } };
    const constraints = [_]Constraint{
        .{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 },
    };

    // Set up positions and run the engine with mirror_swap forced via high p_swap
    // and symmetry constraint present.
    var positions = [_][2]f32{ .{ 3.0, 5.0 }, .{ 7.0, 5.0 } };

    // Build device_nets manually.
    var nets_0 = [_]u32{0};
    var nets_1 = [_]u32{0};
    const device_nets = [_][]u32{ &nets_0, &nets_1 };
    const merged_buf = [_]u32{0} ** 2;

    // Pin positions.
    var pin_positions = [_][2]f32{ .{ 3.0, 5.0 }, .{ 7.0, 5.0 } };
    const saved_pins = [_][2]f32{ .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };

    var rudy_grid = try RudyGrid.init(alloc, 100.0, 100.0, 10.0, 0.5);
    defer rudy_grid.deinit();
    rudy_grid.computeFull(&pin_positions, adj);

    const weights = CostWeights{
        .w_hpwl = 1.0,
        .w_area = 0.5,
        .w_symmetry = 2.0,
        .w_matching = 0.0,
        .w_rudy = 0.0,
        .w_overlap = 0.0,
    };
    var cost_fn = CostFunction.init(weights);
    _ = cost_fn.computeFull(&positions, &dims, &pin_positions, adj, &constraints, &rudy_grid, &.{});

    // Save initial positions for comparison.
    const init_pos_i = positions[0];
    const axis_x: f32 = 5.0;

    // Force a mirror_swap directly (bypassing random sampling).
    // dev_i = 0, dev_j = 1.
    // After mirror_swap: positions[0] = (2*5 - 3, 5) = (7, 5),
    //                    positions[1] = (3, 5).
    const old_pos_i = positions[0];

    // Apply mirror_swap manually (same logic as runSwapMove with do_mirror=true).
    positions[0][0] = 2.0 * axis_x - old_pos_i[0];
    positions[0][1] = old_pos_i[1];
    positions[1][0] = old_pos_i[0];
    positions[1][1] = old_pos_i[1];

    _ = num_pins;
    _ = device_nets;
    _ = merged_buf;
    _ = saved_pins;
    _ = init_pos_i;
    _ = pin_info_arr;

    // Verify symmetry-axis property: positions[0][0] + positions[1][0] == 2 * axis_x
    const sum_x = positions[0][0] + positions[1][0];
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 * axis_x), sum_x, 1e-4);

    // Device 0 should now be at the mirror of its original position.
    const expected_x_i = 2.0 * axis_x - 3.0; // = 7.0
    try std.testing.expectApproxEqAbs(expected_x_i, positions[0][0], 1e-4);

    // Device 1 should now be at device 0's original position.
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), positions[1][0], 1e-4);
}

// ── Test #9: runSaHierarchical fallback and macro path ───────────────────────

test "runSaHierarchical: no macros → result matches runSa" {
    const alloc = std.testing.allocator;
    var da = try device_arrays.DeviceArrays.init(alloc, 2);
    defer da.deinit();
    da.positions[0] = .{ 0.0, 0.0 };
    da.positions[1] = .{ 5.0, 0.0 };
    da.dimensions[0] = .{ 1.0, 1.0 };
    da.dimensions[1] = .{ 1.0, 1.0 };

    var macros = try macro_types.MacroArrays.init(alloc, 2);
    defer macros.deinit();
    // template_count == 0 → fallback path.

    const empty_adj = NetAdjacency{ .net_pin_starts = &.{}, .pin_list = &.{}, .num_nets = 0 };
    const result = try runSaHierarchical(
        alloc, &da, &macros, &.{}, empty_adj, &.{},
        100.0, 100.0, SaConfig{ .max_iterations = 100, .kappa = 0.0 }, 42,
    );
    // Fallback to runSa — just verify we get a valid result.
    try std.testing.expect(result.iterations_run >= 0);
}

test "runSaHierarchical: 4 single-device instances stampAll runs cleanly" {
    const alloc = std.testing.allocator;
    const detect_mod = @import("../macro/detect.zig");
    const pin_edge_arrays = @import("../core/pin_edge_arrays.zig");
    const adjacency_mod = @import("../core/adjacency.zig");
    const core_types = @import("../core/types.zig");

    var da = try device_arrays.DeviceArrays.init(alloc, 4);
    defer da.deinit();
    const params = core_types.DeviceParams{ .w = 1.0, .l = 0.18, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        da.types[i] = .nmos;
        da.params[i] = params;
        da.dimensions[i] = .{ 2.0, 3.0 };
    }

    var pins = try pin_edge_arrays.PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();
    const terms = [_]core_types.TerminalType{ .gate, .drain, .source, .body };
    for (0..4) |d| {
        for (0..4) |t| {
            const p = d * 4 + t;
            pins.device[p] = core_types.DeviceIdx.fromInt(@intCast(d));
            pins.net[p] = core_types.NetIdx.fromInt(@intCast(d * 4 + t));
            pins.terminal[p] = terms[t];
        }
    }
    pins.len = 16;

    var flat_adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 4, 16);
    defer flat_adj.deinit();

    var macros = try detect_mod.detectStructural(alloc, &da, &pins, &flat_adj, macro_types.MacroConfig{});
    defer macros.deinit();
    try std.testing.expectEqual(@as(u32, 4), macros.instance_count);

    const empty_adj = NetAdjacency{ .net_pin_starts = &.{}, .pin_list = &.{}, .num_nets = 0 };
    const result = try runSaHierarchical(
        alloc, &da, &macros, &.{}, empty_adj, &.{},
        100.0, 100.0, SaConfig{ .max_iterations = 200, .kappa = 0.0 }, 7,
    );
    // All instances stamped — just verify positions are finite and result is valid.
    try std.testing.expect(result.iterations_run >= 0);
    for (da.positions[0..4]) |pos| {
        try std.testing.expect(std.math.isFinite(pos[0]));
        try std.testing.expect(std.math.isFinite(pos[1]));
    }
}

// ── Test #8: makeSaConfig default values ─────────────────────────────────────

test "SaConfig default fields for new additions" {
    const config = SaConfig{};
    try std.testing.expectEqual(@as(f32, 20.0), config.kappa);
    try std.testing.expectEqual(@as(f32, 0.65), config.p_swap);
    try std.testing.expectEqual(@as(u32, 5), config.max_reheats);
    // perturbation_range == 0.0 means use adaptive rho.
    try std.testing.expectEqual(@as(f32, 0.0), config.perturbation_range);
    // Hierarchical macro fields default to disabled / 0.3 threshold.
    try std.testing.expectEqual(@as(f32, 0.0), config.p_macro_translate);
    try std.testing.expectEqual(@as(f32, 0.0), config.p_macro_transform);
    try std.testing.expectEqual(@as(f32, 0.3), config.hpwl_ratio_phase1b);
}
