// Utility module — generic, domain-agnostic data-oriented primitives.

pub const Csr = @import("csr.zig").Csr;
pub const TileGrid = @import("grid.zig").TileGrid;

test {
    _ = @import("csr.zig");
    _ = @import("grid.zig");
}
