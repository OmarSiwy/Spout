const std = @import("std");

/// Generic 2D tile grid backed by a flat row-major array.
///
/// `TileGrid(T)` is a pure DOD flat-array wrapper.  It owns the backing
/// allocation but does NOT store the allocator — the caller passes it to
/// `init` and `deinit`, matching the `Csr` pattern used elsewhere in this
/// module.
///
/// Coordinate mapping (spatial → tile index) is provided as static helpers
/// `rowOf` / `colOf` so callers can use them without a live grid instance.
///
/// Layout: `data[row * cols + col]` (row-major, C order).
///
/// Zero-size element types are rejected at comptime because they carry no
/// useful data and would make size/index arithmetic meaningless.
pub fn TileGrid(comptime T: type) type {
    comptime {
        if (@sizeOf(T) == 0) {
            @compileError("TileGrid: element type " ++ @typeName(T) ++ " has size 0; zero-size types are not useful in a tile grid");
        }
    }

    return struct {
        const Self = @This();

        /// Flat row-major storage: `data[row * cols + col]`.
        data: []T,
        rows: u32,
        cols: u32,

        // ── Lifecycle ────────────────────────────────────────────────────

        /// Allocate a `rows × cols` grid and fill every cell with `fill_value`.
        ///
        /// Caller owns the returned value and must call `deinit` with the
        /// same allocator.
        pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32, fill_value: T) !Self {
            const total: usize = @as(usize, rows) * @as(usize, cols);
            const data = try allocator.alloc(T, total);
            errdefer allocator.free(data);
            @memset(data, fill_value);
            return Self{ .data = data, .rows = rows, .cols = cols };
        }

        /// Free the backing allocation.  Does NOT store the allocator; caller
        /// must pass the same allocator used in `init`.
        /// Poisons `self` with `undefined` after freeing (matches CSR pattern).
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.data);
            self.* = undefined;
        }

        // ── Access ───────────────────────────────────────────────────────

        /// Return a mutable pointer to the cell at `(row, col)`.
        ///
        /// Bounds are checked with `std.debug.assert` — no overhead in
        /// ReleaseFast / ReleaseSmall builds.
        pub fn at(self: *Self, row: u32, col: u32) *T {
            std.debug.assert(row < self.rows);
            std.debug.assert(col < self.cols);
            return &self.data[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
        }

        /// Return a read-only value copy of the cell at `(row, col)`.
        ///
        /// Bounds are checked with `std.debug.assert`.
        pub fn get(self: *const Self, row: u32, col: u32) T {
            std.debug.assert(row < self.rows);
            std.debug.assert(col < self.cols);
            return self.data[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
        }

        // ── Bulk ops ─────────────────────────────────────────────────────

        /// Set every cell to `value` using a single `@memset` call.
        pub fn fill(self: *Self, value: T) void {
            @memset(self.data, value);
        }

        /// Total number of cells (`rows * cols`).
        pub fn len(self: *const Self) usize {
            return @as(usize, self.rows) * @as(usize, self.cols);
        }

        // ── Coordinate helpers (static/free) ─────────────────────────────
        //
        // These do NOT require a grid instance.  They map a spatial
        // floating-point coordinate to a tile index, clamped to [0, max-1].
        //
        // Formula: floor((coord - origin) / tile_size), clamped.

        /// Map y-coordinate `y` to a row index in [0, max_row-1].
        pub fn rowOf(y: f32, origin_y: f32, tile_size: f32, max_row: u32) u32 {
            if (y <= origin_y) return 0;
            const r = @as(u32, @intFromFloat(@floor((y - origin_y) / tile_size)));
            return @min(r, max_row - 1);
        }

        /// Map x-coordinate `x` to a column index in [0, max_col-1].
        pub fn colOf(x: f32, origin_x: f32, tile_size: f32, max_col: u32) u32 {
            if (x <= origin_x) return 0;
            const c = @as(u32, @intFromFloat(@floor((x - origin_x) / tile_size)));
            return @min(c, max_col - 1);
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// 1. init/deinit roundtrip — 4×5 f32 grid, fill=0.0; verify len=20, all zero.
test "TileGrid(f32) init/deinit roundtrip" {
    var g = try TileGrid(f32).init(testing.allocator, 4, 5, 0.0);
    defer g.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), g.len());
    for (g.data) |v| {
        try testing.expectEqual(@as(f32, 0.0), v);
    }
}

// 2. at() read/write — write known values, read them back.
test "TileGrid(f32) at() read/write" {
    var g = try TileGrid(f32).init(testing.allocator, 3, 4, 0.0);
    defer g.deinit(testing.allocator);

    g.at(0, 0).* = 1.0;
    g.at(1, 2).* = 7.5;
    g.at(2, 3).* = -3.14;

    try testing.expectEqual(@as(f32, 1.0), g.data[0 * 4 + 0]);
    try testing.expectEqual(@as(f32, 7.5), g.data[1 * 4 + 2]);
    try testing.expectEqual(@as(f32, -3.14), g.data[2 * 4 + 3]);
}

// 3. get() read — verify read-only accessor returns correct values.
test "TileGrid(f32) get() read" {
    var g = try TileGrid(f32).init(testing.allocator, 2, 3, 0.0);
    defer g.deinit(testing.allocator);

    g.at(0, 1).* = 42.0;
    g.at(1, 0).* = -1.0;

    try testing.expectEqual(@as(f32, 42.0), g.get(0, 1));
    try testing.expectEqual(@as(f32, -1.0), g.get(1, 0));
    // Untouched cell still zero.
    try testing.expectEqual(@as(f32, 0.0), g.get(0, 0));
}

// 4. fill() after init — fill with 99.0; verify every cell via get().
test "TileGrid(f32) fill() sets all cells" {
    var g = try TileGrid(f32).init(testing.allocator, 3, 3, 0.0);
    defer g.deinit(testing.allocator);

    g.fill(99.0);
    var r: u32 = 0;
    while (r < 3) : (r += 1) {
        var c: u32 = 0;
        while (c < 3) : (c += 1) {
            try testing.expectEqual(@as(f32, 99.0), g.get(r, c));
        }
    }
}

// 5. fill() reset — fill 5.0, then 0.0; verify all zero.
test "TileGrid(f32) fill() reset to zero" {
    var g = try TileGrid(f32).init(testing.allocator, 2, 4, 5.0);
    defer g.deinit(testing.allocator);

    g.fill(5.0);
    g.fill(0.0);
    for (g.data) |v| {
        try testing.expectEqual(@as(f32, 0.0), v);
    }
}

// 6. rowOf/colOf basic — known coordinate → known tile index.
test "TileGrid rowOf/colOf basic mapping" {
    const G = TileGrid(f32);
    // x=15.0, origin=0, tile_size=10 → floor(15/10)=1 → col 1
    try testing.expectEqual(@as(u32, 1), G.colOf(15.0, 0.0, 10.0, 5));
    // x=25.0 → floor(25/10)=2 → col 2
    try testing.expectEqual(@as(u32, 2), G.colOf(25.0, 0.0, 10.0, 5));
    // y=35.0, origin=10, tile_size=5 → floor((35-10)/5)=5 → row 5
    try testing.expectEqual(@as(u32, 5), G.rowOf(35.0, 10.0, 5.0, 8));
}

// 7. rowOf/colOf clamping — negative coordinate → 0; past-edge → max-1.
test "TileGrid rowOf/colOf clamping" {
    const G = TileGrid(f32);
    // Negative coordinate clamps to 0.
    try testing.expectEqual(@as(u32, 0), G.colOf(-5.0, 0.0, 10.0, 4));
    try testing.expectEqual(@as(u32, 0), G.rowOf(-100.0, 0.0, 10.0, 4));
    // Way past the edge clamps to max-1.
    try testing.expectEqual(@as(u32, 3), G.colOf(9999.0, 0.0, 10.0, 4));
    try testing.expectEqual(@as(u32, 3), G.rowOf(9999.0, 0.0, 10.0, 4));
}

// 8. rowOf/colOf boundary — exactly on a tile boundary maps to correct tile.
test "TileGrid rowOf/colOf tile boundary" {
    const G = TileGrid(f32);
    // x=10.0 exactly at boundary between tile 0 and tile 1 → tile 1
    // floor((10.0 - 0.0) / 10.0) = 1
    try testing.expectEqual(@as(u32, 1), G.colOf(10.0, 0.0, 10.0, 5));
    // x=0.0 exactly at origin (≤ origin_x branch) → tile 0
    try testing.expectEqual(@as(u32, 0), G.colOf(0.0, 0.0, 10.0, 5));
    // y=20.0 with tile_size=10 → floor(20/10)=2 → row 2
    try testing.expectEqual(@as(u32, 2), G.rowOf(20.0, 0.0, 10.0, 5));
}

// 9. single-cell grid — 1×1; at(0,0) works; rowOf/colOf always return 0.
test "TileGrid single-cell grid" {
    var g = try TileGrid(f32).init(testing.allocator, 1, 1, 7.0);
    defer g.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), g.len());
    try testing.expectEqual(@as(f32, 7.0), g.get(0, 0));
    g.at(0, 0).* = 3.0;
    try testing.expectEqual(@as(f32, 3.0), g.get(0, 0));

    // Any coordinate should clamp to 0 for a 1-tile grid.
    try testing.expectEqual(@as(u32, 0), TileGrid(f32).colOf(500.0, 0.0, 10.0, 1));
    try testing.expectEqual(@as(u32, 0), TileGrid(f32).rowOf(500.0, 0.0, 10.0, 1));
    try testing.expectEqual(@as(u32, 0), TileGrid(f32).colOf(-50.0, 0.0, 10.0, 1));
}

// 10. modify via at() pointer — `grid.at(r,c).* += 1.0`, verify get() reflects it.
test "TileGrid at() pointer mutation is visible via get()" {
    var g = try TileGrid(f32).init(testing.allocator, 3, 3, 10.0);
    defer g.deinit(testing.allocator);

    g.at(1, 1).* += 1.0;
    try testing.expectEqual(@as(f32, 11.0), g.get(1, 1));
    // Neighbours unchanged.
    try testing.expectEqual(@as(f32, 10.0), g.get(1, 0));
    try testing.expectEqual(@as(f32, 10.0), g.get(0, 1));
}

// 11. large grid — 64×64, fill=1.0; len=4096; spot-check corners.
test "TileGrid large grid spot-check" {
    var g = try TileGrid(f32).init(testing.allocator, 64, 64, 1.0);
    defer g.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4096), g.len());
    try testing.expectEqual(@as(f32, 1.0), g.get(0, 0));
    try testing.expectEqual(@as(f32, 1.0), g.get(0, 63));
    try testing.expectEqual(@as(f32, 1.0), g.get(63, 0));
    try testing.expectEqual(@as(f32, 1.0), g.get(63, 63));

    // Write to middle, verify.
    g.at(32, 32).* = 255.0;
    try testing.expectEqual(@as(f32, 255.0), g.get(32, 32));
    // Surrounding cells still 1.0.
    try testing.expectEqual(@as(f32, 1.0), g.get(32, 31));
    try testing.expectEqual(@as(f32, 1.0), g.get(31, 32));
}

// 12. integer type — TileGrid(u32) with fill=42.
test "TileGrid(u32) integer element type" {
    var g = try TileGrid(u32).init(testing.allocator, 3, 3, 42);
    defer g.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 9), g.len());
    for (g.data) |v| {
        try testing.expectEqual(@as(u32, 42), v);
    }

    g.at(0, 2).* = 100;
    try testing.expectEqual(@as(u32, 100), g.get(0, 2));
    try testing.expectEqual(@as(u32, 42), g.get(0, 1));

    g.fill(0);
    for (g.data) |v| {
        try testing.expectEqual(@as(u32, 0), v);
    }
}

// 13. bool type — TileGrid(bool) with fill=false; set some true.
test "TileGrid(bool) boolean element type" {
    var g = try TileGrid(bool).init(testing.allocator, 4, 4, false);
    defer g.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 16), g.len());
    // All false initially.
    for (g.data) |v| {
        try testing.expect(!v);
    }

    // Set a diagonal.
    g.at(0, 0).* = true;
    g.at(1, 1).* = true;
    g.at(2, 2).* = true;
    g.at(3, 3).* = true;

    try testing.expect(g.get(0, 0));
    try testing.expect(g.get(1, 1));
    try testing.expect(g.get(2, 2));
    try testing.expect(g.get(3, 3));
    // Off-diagonal still false.
    try testing.expect(!g.get(0, 1));
    try testing.expect(!g.get(3, 2));

    // fill(true) then fill(false) resets everything.
    g.fill(true);
    for (g.data) |v| {
        try testing.expect(v);
    }
    g.fill(false);
    for (g.data) |v| {
        try testing.expect(!v);
    }
}
