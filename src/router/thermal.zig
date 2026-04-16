// Thermal Router — isotherm-aware thermal map for analog circuits.
const std = @import("std");

pub const Rect = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,
    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
};

pub const ThermalMap = struct {
    allocator: std.mem.Allocator,
    temps: []f32,
    rows: u32,
    cols: u32,
    cell_size: f32,
    bbox_x1: f32,
    bbox_y1: f32,
    bbox_x2: f32,
    bbox_y2: f32,
    ambient: f32,

    pub fn init(allocator: std.mem.Allocator, bbox: Rect, cell_size: f32, ambient: f32) !ThermalMap {
        const cols = @as(u32, @intFromFloat(@ceil(bbox.width() / cell_size)));
        const rows = @as(u32, @intFromFloat(@ceil(bbox.height() / cell_size)));
        const temps = try allocator.alloc(f32, cols * rows);
        @memset(temps, ambient);
        return .{
            .allocator = allocator, .temps = temps, .rows = rows, .cols = cols,
            .cell_size = cell_size, .bbox_x1 = bbox.x1, .bbox_y1 = bbox.y1,
            .bbox_x2 = bbox.x2, .bbox_y2 = bbox.y2, .ambient = ambient,
        };
    }

    pub fn deinit(self: *ThermalMap) void {
        self.allocator.free(self.temps);
    }

    pub fn query(self: *const ThermalMap, x: f32, y: f32) f32 {
        if (x < self.bbox_x1 or x > self.bbox_x2 or y < self.bbox_y1 or y > self.bbox_y2) return self.ambient;
        const col = @min(@max(@as(u32, @intFromFloat((x - self.bbox_x1) / self.cell_size)), 0), self.cols - 1);
        const row = @min(@max(@as(u32, @intFromFloat((y - self.bbox_y1) / self.cell_size)), 0), self.rows - 1);
        return self.temps[row * self.cols + col];
    }

    pub fn addHotspot(self: *ThermalMap, x: f32, y: f32, delta_T: f32, radius: f32) !void {
        if (radius <= 0) {
            const col = @min(@max(@as(u32, @intFromFloat((x - self.bbox_x1) / self.cell_size)), 0), self.cols - 1);
            const row = @min(@max(@as(u32, @intFromFloat((y - self.bbox_y1) / self.cell_size)), 0), self.rows - 1);
            if (col < self.cols and row < self.rows) self.temps[row * self.cols + col] += delta_T;
            return;
        }
        const rf = radius / self.cell_size;
        const cc = (x - self.bbox_x1) / self.cell_size;
        const cr = (y - self.bbox_y1) / self.cell_size;
        const raw_cmin = @floor(cc - rf);
        const raw_cmax = @ceil(cc + rf);
        const raw_rmin = @floor(cr - rf);
        const raw_rmax = @ceil(cr + rf);
        const cmin = @as(u32, @intFromFloat(@max(raw_cmin, 0.0)));
        const cmax = @as(u32, @intFromFloat(@min(raw_cmax, @as(f32, @floatFromInt(self.cols)) - 1.0)));
        const rmin = @as(u32, @intFromFloat(@max(raw_rmin, 0.0)));
        const rmax = @as(u32, @intFromFloat(@min(raw_rmax, @as(f32, @floatFromInt(self.rows)) - 1.0)));
        const sigma_sq = 2.0 * radius * radius;
        var row_i: u32 = rmin;
        while (row_i <= rmax) : (row_i += 1) {
            var col_i: u32 = cmin;
            while (col_i <= cmax) : (col_i += 1) {
                if (row_i >= self.rows or col_i >= self.cols) continue;
                const cx = self.bbox_x1 + (@as(f32, @floatFromInt(col_i)) + 0.5) * self.cell_size;
                const cy = self.bbox_y1 + (@as(f32, @floatFromInt(row_i)) + 0.5) * self.cell_size;
                const dx = cx - x; const dy = cy - y;
                const inf = delta_T * @exp(-(dx*dx + dy*dy) / sigma_sq);
                self.temps[row_i * self.cols + col_i] += inf;
            }
        }
    }
};

test "ThermalMap query returns ambient" {
    const alloc = std.testing.allocator;
    var map = try ThermalMap.init(alloc, Rect{ .x1=0,.y1=0,.x2=100,.y2=100 }, 10.0, 25.0);
    defer map.deinit();
    try std.testing.expectEqual(@as(f32, 25.0), map.query(50.0, 50.0));
}

test "ThermalMap hotspot raises temperature" {
    const alloc = std.testing.allocator;
    var map = try ThermalMap.init(alloc, Rect{ .x1=0,.y1=0,.x2=100,.y2=100 }, 10.0, 25.0);
    defer map.deinit();
    try map.addHotspot(50.0, 50.0, 10.0, 20.0);
    try std.testing.expect(map.query(50.0, 50.0) > 25.0);
}

test "ThermalMap query OOB returns ambient" {
    const alloc = std.testing.allocator;
    var map = try ThermalMap.init(alloc, Rect{ .x1=0,.y1=0,.x2=100,.y2=100 }, 10.0, 25.0);
    defer map.deinit();
    try std.testing.expectEqual(@as(f32, 25.0), map.query(-1.0, 50.0));
}
