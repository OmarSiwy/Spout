// characterize/lib.zig
//
// Public API surface for the DRC / LVS / PEX characterization subsystem.
// Re-exports the most commonly used types and functions so callers can write:
//
//   const characterize = @import("characterize/lib.zig");
//   const viols = try characterize.runDrc(&shapes, &pdk, alloc);
//   const report = characterize.LvsChecker.compareDeviceLists(&lay, &schem);
//   var pex = try characterize.extractFromRoutes(&routes, characterize.PexConfig.sky130(), alloc);

const std = @import("std");

pub const types      = @import("types.zig");
pub const drc        = @import("drc.zig");
pub const lvs        = @import("lvs.zig");
pub const pex        = @import("pex.zig");
pub const ext2spice  = @import("ext2spice.zig");

// ─── Type re-exports ─────────────────────────────────────────────────────────

pub const DrcViolation = types.DrcViolation;
pub const DrcRule      = types.DrcRule;

pub const LvsReport    = types.LvsReport;
pub const LvsStatus    = types.LvsStatus;

pub const PexConfig    = types.PexConfig;
pub const PexResult    = types.PexResult;
pub const RcElement    = types.RcElement;
pub const SUBSTRATE_NET = types.SUBSTRATE_NET;

// ─── Function re-exports ─────────────────────────────────────────────────────

pub const runDrc         = drc.runDrc;
pub const runDrcOnSlices = drc.runDrcOnSlices;

pub const UnionFind      = lvs.UnionFind;
pub const LvsChecker     = lvs.LvsChecker;

pub const extractFromRoutes = pex.extractFromRoutes;

pub const SpiceWriter = ext2spice.SpiceWriter;

// ─── Pull in all sub-module tests ────────────────────────────────────────────

comptime {
    _ = @import("types.zig");
    _ = @import("drc.zig");
    _ = @import("lvs.zig");
    _ = @import("pex.zig");
    _ = @import("ext2spice.zig");
}
