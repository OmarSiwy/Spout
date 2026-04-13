const std = @import("std");

// ─── Rectilinear Steiner Minimum Tree ────────────────────────────────────────
//
// Implements an iterative 1-Steiner heuristic for RSMT construction:
//   1. Start with MST of pin locations (Manhattan / L1 distance).
//   2. Enumerate Hanan grid points (intersections of H/V lines through pins).
//   3. Greedily add the Hanan point that yields the largest wirelength reduction.
//   4. Repeat until no improvement.
//
// For nets with <= 3 pins the optimal topology is trivially an L- or T-shape,
// so we special-case those for speed.

pub const SteinerTree = struct {
    segments: std.ArrayList(Segment),
    allocator: std.mem.Allocator,

    pub const Segment = struct {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,

        pub fn length(self: Segment) f32 {
            return @abs(self.x2 - self.x1) + @abs(self.y2 - self.y1);
        }
    };

    /// Build a rectilinear Steiner tree connecting the given pin positions.
    /// Each position is [x, y].  Returns an RSMT whose segments are
    /// axis-aligned (rectilinear).
    pub fn build(allocator: std.mem.Allocator, pin_positions: []const [2]f32) !SteinerTree {
        var tree = SteinerTree{ .segments = .empty, .allocator = allocator };
        errdefer tree.segments.deinit(allocator);

        if (pin_positions.len == 0) return tree;
        if (pin_positions.len == 1) return tree;

        if (pin_positions.len == 2) {
            // Single L-shape: horizontal then vertical.
            try addLSegment(allocator, &tree.segments, pin_positions[0], pin_positions[1]);
            return tree;
        }

        if (pin_positions.len == 3) {
            try buildThreePin(allocator, &tree.segments, pin_positions);
            return tree;
        }

        // General case: iterative 1-Steiner heuristic.
        try buildGeneral(allocator, &tree.segments, pin_positions);
        return tree;
    }

    /// Sum of Manhattan-distance lengths of all segments.
    pub fn totalLength(self: *const SteinerTree) f32 {
        var total: f32 = 0.0;
        for (self.segments.items) |seg| {
            total += seg.length();
        }
        return total;
    }

    pub fn deinit(self: *SteinerTree) void {
        self.segments.deinit(self.allocator);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Add an L-shaped (two-segment) rectilinear path from `a` to `b`.
    /// Goes horizontal first, then vertical.
    fn addLSegment(allocator: std.mem.Allocator, segments: *std.ArrayList(Segment), a: [2]f32, b: [2]f32) !void {
        const ax = a[0];
        const ay = a[1];
        const bx = b[0];
        const by = b[1];

        if (ax == bx) {
            // Pure vertical segment.
            try segments.append(allocator, .{ .x1 = ax, .y1 = ay, .x2 = bx, .y2 = by });
        } else if (ay == by) {
            // Pure horizontal segment.
            try segments.append(allocator, .{ .x1 = ax, .y1 = ay, .x2 = bx, .y2 = by });
        } else {
            // L-shape: horizontal to (bx, ay), then vertical to (bx, by).
            try segments.append(allocator, .{ .x1 = ax, .y1 = ay, .x2 = bx, .y2 = ay });
            try segments.append(allocator, .{ .x1 = bx, .y1 = ay, .x2 = bx, .y2 = by });
        }
    }

    /// For exactly 3 pins, find the optimal Steiner point (median-based) and
    /// produce a T-shape or degenerate L-shapes.
    fn buildThreePin(
        allocator: std.mem.Allocator,
        segments: *std.ArrayList(Segment),
        pins: []const [2]f32,
    ) !void {
        // The optimal rectilinear Steiner point for 3 pins is
        // (median_x, median_y) of the three pin coordinates.
        const mx = median3(pins[0][0], pins[1][0], pins[2][0]);
        const my = median3(pins[0][1], pins[1][1], pins[2][1]);

        // Connect each pin to the Steiner point via L-segments.
        for (pins) |p| {
            try addLSegment(allocator, segments, p, .{ mx, my });
        }
    }

    fn median3(a: f32, b: f32, c: f32) f32 {
        if ((a >= b and a <= c) or (a <= b and a >= c)) return a;
        if ((b >= a and b <= c) or (b <= a and b >= c)) return b;
        return c;
    }

    /// General iterative 1-Steiner heuristic for 4+ pins.
    fn buildGeneral(
        allocator: std.mem.Allocator,
        segments: *std.ArrayList(Segment),
        pin_positions: []const [2]f32,
    ) !void {
        const n = pin_positions.len;

        // Working set of points (pins + added Steiner points).
        var points: std.ArrayList([2]f32) = .empty;
        defer points.deinit(allocator);
        try points.appendSlice(allocator, pin_positions);

        // Generate Hanan grid candidates from the *original* pins.
        var hanan: std.ArrayList([2]f32) = .empty;
        defer hanan.deinit(allocator);
        try generateHananGrid(allocator, pin_positions, &hanan);

        // Iteratively try adding the best Hanan point.
        var improved = true;
        while (improved) {
            improved = false;
            const current_mst_len = mstLength(points.items);

            var best_reduction: f32 = 0.0;
            var best_idx: ?usize = null;

            for (hanan.items, 0..) |hp, hi| {
                // Skip if this point is already in the working set.
                if (containsPoint(points.items, hp)) continue;

                // Tentatively add.
                try points.append(allocator, hp);
                const new_mst_len = mstLength(points.items);
                const reduction = current_mst_len - new_mst_len;

                if (reduction > best_reduction) {
                    best_reduction = reduction;
                    best_idx = hi;
                }

                // Remove the tentative point.
                _ = points.pop();
            }

            if (best_idx) |bi| {
                if (best_reduction > 1e-6) {
                    try points.append(allocator, hanan.items[bi]);
                    improved = true;
                }
            }
        }

        // Build the MST on the final point set and emit segments.
        try emitMstSegments(allocator, points.items, segments, n);
    }

    /// Generate the Hanan grid: all intersections of horizontal and vertical
    /// lines through the pin set.
    fn generateHananGrid(
        allocator: std.mem.Allocator,
        pins: []const [2]f32,
        out: *std.ArrayList([2]f32),
    ) !void {
        for (pins) |p| {
            for (pins) |q| {
                const candidate = [2]f32{ p[0], q[1] };
                // Only add if it is not already a pin.
                if (!containsPoint(pins, candidate)) {
                    // Avoid duplicates in the Hanan list.
                    if (!containsPoint(out.items, candidate)) {
                        try out.append(allocator, candidate);
                    }
                }
            }
        }
    }

    fn containsPoint(pts: []const [2]f32, needle: [2]f32) bool {
        for (pts) |p| {
            if (p[0] == needle[0] and p[1] == needle[1]) return true;
        }
        return false;
    }

    /// Compute total MST length on a set of points using Manhattan distance.
    /// Uses Prim's algorithm — O(n^2), fine for small pin counts.
    fn mstLength(points: []const [2]f32) f32 {
        const n = points.len;
        if (n <= 1) return 0.0;

        // We cannot use variable-length arrays on the stack in Zig, so we
        // use a fixed buffer for small sizes and fall through for large.
        // For the typical IC net, pin count < 64.
        var in_mst_buf: [256]bool = .{false} ** 256;
        var dist_buf: [256]f32 = .{std.math.inf(f32)} ** 256;

        const in_mst = in_mst_buf[0..n];
        const dist = dist_buf[0..n];

        // Start from point 0.
        dist[0] = 0.0;
        var total: f32 = 0.0;

        for (0..n) |_| {
            // Pick the closest un-visited point.
            var u: usize = 0;
            var min_d: f32 = std.math.inf(f32);
            for (0..n) |i| {
                if (!in_mst[i] and dist[i] < min_d) {
                    min_d = dist[i];
                    u = i;
                }
            }

            in_mst[u] = true;
            total += dist[u];

            // Update distances.
            for (0..n) |v| {
                if (!in_mst[v]) {
                    const d = manhattan(points[u], points[v]);
                    if (d < dist[v]) {
                        dist[v] = d;
                    }
                }
            }
        }
        return total;
    }

    /// Emit MST edges as rectilinear segments (L-shapes).
    /// `n_original` is used to identify which points are original pins vs
    /// Steiner points (both are connected the same way).
    fn emitMstSegments(
        allocator: std.mem.Allocator,
        points: []const [2]f32,
        segments: *std.ArrayList(Segment),
        n_original: usize,
    ) !void {
        _ = n_original;
        const n = points.len;
        if (n <= 1) return;

        var in_mst_buf: [256]bool = .{false} ** 256;
        var dist_buf: [256]f32 = .{std.math.inf(f32)} ** 256;
        var parent_buf: [256]usize = .{0} ** 256;

        const in_mst = in_mst_buf[0..n];
        const dist = dist_buf[0..n];
        const parent = parent_buf[0..n];

        dist[0] = 0.0;

        for (0..n) |_| {
            var u: usize = 0;
            var min_d: f32 = std.math.inf(f32);
            for (0..n) |i| {
                if (!in_mst[i] and dist[i] < min_d) {
                    min_d = dist[i];
                    u = i;
                }
            }

            in_mst[u] = true;

            // Emit the edge from parent[u] -> u (skip the root).
            if (dist[u] > 0.0) {
                try addLSegment(allocator, segments, points[parent[u]], points[u]);
            }

            for (0..n) |v| {
                if (!in_mst[v]) {
                    const d = manhattan(points[u], points[v]);
                    if (d < dist[v]) {
                        dist[v] = d;
                        parent[v] = u;
                    }
                }
            }
        }
    }

    fn manhattan(a: [2]f32, b: [2]f32) f32 {
        return @abs(a[0] - b[0]) + @abs(a[1] - b[1]);
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "SteinerTree 2-pin is single L-segment" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 3.0, 4.0 },
    });
    defer tree.deinit();

    // L-shape from (0,0) to (3,4): horizontal (3,0)→(3,4) = 3 + 4 = 7.
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), tree.totalLength(), 1e-6);
    // Should have exactly 2 segments (horizontal + vertical).
    try std.testing.expectEqual(@as(usize, 2), tree.segments.items.len);
}

test "SteinerTree 3-pin via Steiner point" {
    // Three corners of a right triangle.
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 4.0, 0.0 },
        .{ 4.0, 3.0 },
    });
    defer tree.deinit();

    // Optimal RSMT for these 3 points: 4 + 3 = 7 (a single L connecting them
    // through the corner at (4,0) which is the median Steiner point).
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), tree.totalLength(), 1e-6);
}

test "SteinerTree single pin — no segments" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 5.0, 5.0 },
    });
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tree.totalLength(), 1e-6);
}

test "SteinerTree empty pin list" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{});
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.segments.items.len);
}

test "SteinerTree 4-pin" {
    // Square: (0,0), (10,0), (0,10), (10,10).
    // Optimal RSMT wirelength = 20 (not 30 for pairwise).
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 10.0, 0.0 },
        .{ 0.0, 10.0 },
        .{ 10.0, 10.0 },
    });
    defer tree.deinit();

    // The MST of 4 corners of a 10x10 square has length 30 (3 edges of 10).
    // With a Steiner point the heuristic should do at most 30, often 20.
    try std.testing.expect(tree.totalLength() <= 30.0 + 1e-6);
    try std.testing.expect(tree.totalLength() >= 20.0 - 1e-6);
}

test "SteinerTree collinear pins" {
    var tree = try SteinerTree.build(std.testing.allocator, &.{
        .{ 0.0, 0.0 },
        .{ 5.0, 0.0 },
        .{ 10.0, 0.0 },
    });
    defer tree.deinit();

    // Should be exactly 10 (straight line).
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), tree.totalLength(), 1e-6);
}
