// Public netlist module API.
// Re-exports from types.zig and tokenizer.zig with backward-compat aliases.

const tokenizer_mod = @import("tokenizer.zig");
const types_mod = @import("types.zig");

// ── Parse types ───────────────────────────────────────────────────────────
pub const ParseError = types_mod.ParseError;
pub const PinEdge = types_mod.PinEdge;
pub const NetInfo = types_mod.NetInfo;
pub const DeviceInfo = types_mod.DeviceInfo;
pub const FlatAdjList = types_mod.FlatAdjList;
pub const Subcircuit = types_mod.Subcircuit;
pub const ParseResult = types_mod.ParseResult;

// ── Tokenizer ─────────────────────────────────────────────────────────────
pub const Token = tokenizer_mod.Token;
pub const Param = tokenizer_mod.Param;
pub const Tokenizer = tokenizer_mod.Tokenizer;
pub const parseSiValue = tokenizer_mod.parseSiValue;
pub const isPowerNet = tokenizer_mod.isPowerNet;
pub const parseMosType = tokenizer_mod.parseMosType;

// ── Backward-compat aliases ───────────────────────────────────────────────
pub const LineType = Token.Tag;
pub const Line = Token;
pub const Parser = Tokenizer;
