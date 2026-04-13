const std = @import("std");
const core_types = @import("../core/types.zig");
const types = @import("types.zig");

const DeviceType = core_types.DeviceType;
const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const PinIdx = core_types.PinIdx;
const TerminalType = core_types.TerminalType;

// Re-export parse types so callers can import from one place.
pub const ParseError = types.ParseError;
pub const PinEdge = types.PinEdge;
pub const NetInfo = types.NetInfo;
pub const DeviceInfo = types.DeviceInfo;
pub const FlatAdjList = types.FlatAdjList;
pub const Subcircuit = types.Subcircuit;
pub const ParseResult = types.ParseResult;

// ─── Static lookup maps ─────────────────────────────────────────────────────

// ─── Cross-PDK device model map ─────────────────────────────────────────────
//
// Maps known PDK model names → DeviceType subtype.
// Covers SKY130, GF180MCU, and IHP SG13G2.  Model names are globally unique
// across these three PDKs so a single combined map is safe.
// Used by resolveResistorModel() and resolveCapacitorModel() for exact-match
// lookup; substring heuristics provide a fallback for unlisted names.

const device_model_map = std.StaticStringMap(DeviceType).initComptime(.{
    // ── SKY130 resistors ─────────────────────────────────────────────────────
    .{ "sky130_fd_pr__res_high_po_0p35",  .res_poly   },
    .{ "sky130_fd_pr__res_high_po_0p69",  .res_poly   },
    .{ "sky130_fd_pr__res_high_po_1p41",  .res_poly   },
    .{ "sky130_fd_pr__res_high_po_2p85",  .res_poly   },
    .{ "sky130_fd_pr__res_high_po_5p73",  .res_poly   },
    .{ "sky130_fd_pr__res_xhigh_po_0p35", .res_poly   },
    .{ "sky130_fd_pr__res_xhigh_po_0p69", .res_poly   },
    .{ "sky130_fd_pr__res_generic_po",    .res_poly   },
    .{ "sky130_fd_pr__res_generic_nd",    .res_diff_n },
    .{ "sky130_fd_pr__res_generic_pd",    .res_diff_p },
    .{ "sky130_fd_pr__res_iso_pw",        .res_well_p },
    .{ "sky130_fd_pr__res_generic_l1",    .res_metal  },
    // ── SKY130 capacitors ────────────────────────────────────────────────────
    .{ "sky130_fd_pr__cap_mim_m3_1",      .cap_mim    },
    .{ "sky130_fd_pr__cap_mim_m3_2",      .cap_mim    },
    // ── GF180MCU resistors ───────────────────────────────────────────────────
    .{ "nplus_u",    .res_diff_n },
    .{ "pplus_u",    .res_diff_p },
    .{ "nplus_s",    .res_diff_n },
    .{ "pplus_s",    .res_diff_p },
    .{ "nwell",      .res_well_n },
    .{ "pwell",      .res_well_p },
    .{ "ppolyf_u",   .res_poly   },
    .{ "npolyf_u",   .res_poly   },
    .{ "ppolyf_s",   .res_poly   },
    .{ "npolyf_s",   .res_poly   },
    .{ "rm1",        .res_metal  },
    .{ "rm2",        .res_metal  },
    .{ "rm3",        .res_metal  },
    .{ "rm4",        .res_metal  },
    .{ "rm5",        .res_metal  },
    // ── GF180MCU capacitors ──────────────────────────────────────────────────
    .{ "mimcap",     .cap_mim    },
    .{ "mimcap_2",   .cap_mim    },
    .{ "cap_nmos",   .cap_gate   },
    .{ "cap_pmos",   .cap_gate   },
    .{ "cap_nmos_b", .cap_gate   },
    .{ "cap_pmos_b", .cap_gate   },
    // ── IHP SG13G2 resistors ─────────────────────────────────────────────────
    .{ "rsil",   .res_poly   },  // silicided poly
    .{ "rhigh",  .res_poly   },  // high-sheet-resistance poly
    .{ "rppd",   .res_diff_p },  // p+ diffusion
    .{ "rnpd",   .res_diff_n },  // n+ diffusion
    // ── IHP SG13G2 capacitors ────────────────────────────────────────────────
    .{ "cmim",   .cap_mim    },
    .{ "cmim2",  .cap_mim    },
});

/// Resolve a resistor model name → DeviceType subtype.
/// Exact PDK LUT match first; substring heuristics as fallback.
fn resolveResistorModel(model: []const u8) DeviceType {
    if (device_model_map.get(model)) |dt| return dt;
    var buf: [64]u8 = undefined;
    const n = @min(model.len, 64);
    for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..n];
    if (std.mem.indexOf(u8, lower, "poly") != null or
        std.mem.indexOf(u8, lower, "_po")  != null) return .res_poly;
    if (std.mem.indexOf(u8, lower, "nwell") != null) return .res_well_n;
    if (std.mem.indexOf(u8, lower, "pwell") != null or
        std.mem.indexOf(u8, lower, "iso_pw") != null) return .res_well_p;
    if (std.mem.indexOf(u8, lower, "ndiff") != null or
        std.mem.indexOf(u8, lower, "nplus") != null or
        std.mem.indexOf(u8, lower, "_nd")   != null) return .res_diff_n;
    if (std.mem.indexOf(u8, lower, "pdiff") != null or
        std.mem.indexOf(u8, lower, "pplus") != null or
        std.mem.indexOf(u8, lower, "_pd")   != null) return .res_diff_p;
    if (std.mem.indexOf(u8, lower, "metal") != null or
        std.mem.indexOf(u8, lower, "_l1")   != null) return .res_metal;
    return .res;
}

/// Resolve a capacitor model name → DeviceType subtype.
fn resolveCapacitorModel(model: []const u8) DeviceType {
    if (device_model_map.get(model)) |dt| return dt;
    var buf: [64]u8 = undefined;
    const n = @min(model.len, 64);
    for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..n];
    if (std.mem.indexOf(u8, lower, "mim")    != null) return .cap_mim;
    if (std.mem.indexOf(u8, lower, "mom")    != null or
        std.mem.indexOf(u8, lower, "fringe") != null) return .cap_mom;
    if (std.mem.indexOf(u8, lower, "pip")    != null) return .cap_pip;
    if (std.mem.indexOf(u8, lower, "gate")   != null or
        std.mem.indexOf(u8, lower, "nmos")   != null or
        std.mem.indexOf(u8, lower, "pmos")   != null) return .cap_gate;
    return .cap;
}

const si_suffix_map = std.StaticStringMap(f64).initComptime(.{
    .{ "f",   1e-15 },
    .{ "p",   1e-12 },
    .{ "n",   1e-9  },
    .{ "u",   1e-6  },
    .{ "m",   1e-3  },
    .{ "k",   1e3   },
    .{ "meg", 1e6   },
    .{ "g",   1e9   },
    .{ "t",   1e12  },
});

const mos_exact_map = std.StaticStringMap(DeviceType).initComptime(.{
    .{ "nmos", .nmos },
    .{ "pmos", .pmos },
    .{ "nch",  .nmos },
    .{ "pch",  .pmos },
    .{ "n",    .nmos },
    .{ "p",    .pmos },
    .{ "nfet", .nmos },
    .{ "pfet", .pmos },
});

const power_net_map = std.StaticStringMap(bool).initComptime(.{
    .{ "vdd", true },
    .{ "vcc", true },
    .{ "vss", true },
    .{ "gnd", true },
});

// ─── SI suffix parsing ──────────────────────────────────────────────────────

/// Parse a SPICE numeric value with optional SI suffix.
/// Supports: f=1e-15, p=1e-12, n=1e-9, u=1e-6, m=1e-3, k=1e3, meg=1e6, g=1e9, t=1e12
/// Returns null on parse failure.
pub fn parseSiValue(raw: []const u8) ?f64 {
    if (raw.len == 0) return null;

    var num_end: usize = raw.len;
    for (raw, 0..) |c, i| {
        if (c == '+' or c == '-' or c == '.' or (c >= '0' and c <= '9')) continue;
        if ((c == 'e' or c == 'E') and i > 0 and (raw[i - 1] >= '0' and raw[i - 1] <= '9')) continue;
        num_end = i;
        break;
    }

    if (num_end == 0) return null;

    const base = std.fmt.parseFloat(f64, raw[0..num_end]) catch return null;

    const suffix = raw[num_end..];
    if (suffix.len == 0) return base;

    const multiplier = siMultiplier(suffix) orelse return null;
    return base * multiplier;
}

fn siMultiplier(suffix: []const u8) ?f64 {
    if (suffix.len == 0) return null;
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    const n = @min(suffix.len, 4);
    for (suffix[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    // "meg" takes priority over "m"
    if (n >= 3) if (si_suffix_map.get(buf[0..3])) |m| return m;
    return si_suffix_map.get(buf[0..1]);
}

// ─── Power net detection ────────────────────────────────────────────────────

pub fn isPowerNet(name: []const u8) bool {
    if (std.mem.eql(u8, name, "0")) return true;
    var buf: [8]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return power_net_map.get(buf[0..name.len]) != null;
}

// ─── MOS type parsing ───────────────────────────────────────────────────────

pub fn parseMosType(s: []const u8) ?DeviceType {
    if (s.len == 0) return null;

    var lower_buf: [32]u8 = undefined;
    const cmp_len = @min(s.len, 32);
    for (s[0..cmp_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..cmp_len];

    // Exact match via static map
    if (mos_exact_map.get(lower)) |dt| return dt;

    // PDK-qualified prefix matches: nmos_rvt, nfet_lvt, pmos_lvt, pfet_hvt
    if (lower.len >= 5) {
        if (std.mem.startsWith(u8, lower, "nmos_") or std.mem.startsWith(u8, lower, "nfet_")) return .nmos;
        if (std.mem.startsWith(u8, lower, "pmos_") or std.mem.startsWith(u8, lower, "pfet_")) return .pmos;
    }
    if (lower.len >= 4) {
        if (std.mem.startsWith(u8, lower, "nch_")) return .nmos;
        if (std.mem.startsWith(u8, lower, "pch_")) return .pmos;
    }

    // Substring: "nfet"/"pfet"/"nmos"/"pmos" anywhere in the name
    if (std.mem.indexOf(u8, lower, "nfet") != null) return .nmos;
    if (std.mem.indexOf(u8, lower, "pfet") != null) return .pmos;
    if (std.mem.indexOf(u8, lower, "nmos") != null) return .nmos;
    if (std.mem.indexOf(u8, lower, "pmos") != null) return .pmos;

    // VT-suffix patterns: nlvt, plvt, nhvt, phvt, nrvt, prvt, nsvt, psvt, pulvt
    if (lower.len >= 3) {
        const has_vt = std.mem.indexOf(u8, lower, "lvt") != null or
            std.mem.indexOf(u8, lower, "hvt") != null or
            std.mem.indexOf(u8, lower, "rvt") != null or
            std.mem.indexOf(u8, lower, "svt") != null or
            std.mem.indexOf(u8, lower, "vt") != null;
        if (has_vt) {
            if (lower[0] == 'n') return .nmos;
            if (lower[0] == 'p') return .pmos;
        }
    }

    // nch*/pch* 3-char prefix
    if (lower.len >= 3) {
        if (std.mem.startsWith(u8, lower, "nch")) return .nmos;
        if (std.mem.startsWith(u8, lower, "pch")) return .pmos;
    }

    return null;
}

// ─── Parsed parameter (key=value) ───────────────────────────────────────────

pub const Param = struct {
    key: []const u8,
    value: []const u8,
    numeric: ?f64,
};

// ─── Token ──────────────────────────────────────────────────────────────────
//
// A Token represents one logical SPICE statement (a physical line or a group
// of continuation lines merged into one).  The Tag classifies the statement
// type; `tokens` holds the whitespace-delimited words; `params` holds all
// key=value pairs parsed from those words.

pub const Token = struct {
    pub const Tag = enum {
        mosfet,
        resistor,
        capacitor,
        inductor,
        diode,
        bjt,
        jfet,
        subckt_begin,
        subckt_end,
        subckt_inst,
        comment,
        blank,
        dot_param,
        dot_global,
        dot_model,
        dot_include,
        dot_lib,
        source,
        other,
    };

    /// Maps lowercase dot-directive strings to their Tag.
    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ ".subckt",  .subckt_begin },
        .{ ".ends",    .subckt_end   },
        .{ ".param",   .dot_param    },
        .{ ".global",  .dot_global   },
        .{ ".model",   .dot_model    },
        .{ ".include", .dot_include  },
        .{ ".lib",     .dot_lib      },
    });

    /// Look up a dot-directive by name (case-insensitive).
    pub fn getKeyword(bytes: []const u8) ?Tag {
        var buf: [16]u8 = undefined;
        if (bytes.len > buf.len) return null;
        for (bytes, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return keywords.get(buf[0..bytes.len]);
    }

    tag: Tag,
    tokens: []const []const u8,
    params: []const Param,
    raw: []const u8,

    pub fn getParam(self: *const Token, key: []const u8) ?f64 {
        for (self.params) |p| {
            if (std.ascii.eqlIgnoreCase(p.key, key)) return p.numeric;
        }
        return null;
    }

    pub fn getParamStr(self: *const Token, key: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
        }
        return null;
    }
};

// Backward-compatible aliases (old code used LineType / Line).
pub const LineType = Token.Tag;
pub const Line = Token;

// ─── Tokenizer ──────────────────────────────────────────────────────────────

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,

    // ── Tokenization state ──
    tok_lines: std.ArrayList(Token),
    token_store: std.ArrayList([]const u8),
    param_store: std.ArrayList(Param),

    // ── Parser accumulation state ──
    devices: std.ArrayList(DeviceInfo),
    net_names: std.ArrayList([]const u8),
    net_is_power: std.ArrayList(bool),
    pins: std.ArrayList(PinEdge),
    subcircuits: std.ArrayList(Subcircuit),
    net_table: std.StringHashMap(NetIdx),
    pin_count: u32,

    pub fn init(allocator: std.mem.Allocator) Tokenizer {
        return .{
            .allocator = allocator,
            .tok_lines = .empty,
            .token_store = .empty,
            .param_store = .empty,
            .devices = .empty,
            .net_names = .empty,
            .net_is_power = .empty,
            .pins = .empty,
            .subcircuits = .empty,
            .net_table = std.StringHashMap(NetIdx).init(allocator),
            .pin_count = 0,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.tok_lines.deinit(self.allocator);
        self.token_store.deinit(self.allocator);
        self.param_store.deinit(self.allocator);
        self.devices.deinit(self.allocator);
        self.net_names.deinit(self.allocator);
        self.net_is_power.deinit(self.allocator);
        self.pins.deinit(self.allocator);
        self.subcircuits.deinit(self.allocator);
        self.net_table.deinit();
    }

    // ── Tokenization ────────────────────────────────────────────────────────

    /// Tokenize `source` into logical SPICE statements (continuation lines merged).
    /// Returns a slice owned by the Tokenizer — valid until the next tokenize() call
    /// or deinit().
    pub fn tokenize(self: *Tokenizer, source: []const u8) ![]const Token {
        self.tok_lines.clearRetainingCapacity();
        self.token_store.clearRetainingCapacity();
        self.param_store.clearRetainingCapacity();

        const LineRange = struct {
            tok_start: usize,
            tok_end: usize,
            param_start: usize,
            param_end: usize,
            tag: Token.Tag,
            raw: []const u8,
        };

        var line_ranges: std.ArrayList(LineRange) = .empty;
        defer line_ranges.deinit(self.allocator);

        var raw_lines: std.ArrayList([]const u8) = .empty;
        defer raw_lines.deinit(self.allocator);

        // Split into physical lines, stripping trailing \r.
        var iter = std.mem.splitScalar(u8, source, '\n');
        while (iter.next()) |raw_line| {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            try raw_lines.append(self.allocator, line);
        }

        var i: usize = 0;
        while (i < raw_lines.items.len) {
            const base_line = raw_lines.items[i];
            i += 1;

            const trimmed = std.mem.trimLeft(u8, base_line, " \t");

            if (trimmed.len == 0) {
                try line_ranges.append(self.allocator, .{
                    .tok_start = 0, .tok_end = 0,
                    .param_start = 0, .param_end = 0,
                    .tag = .blank,
                    .raw = base_line,
                });
                continue;
            }

            if (trimmed[0] == '*' or
                (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/'))
            {
                try line_ranges.append(self.allocator, .{
                    .tok_start = 0, .tok_end = 0,
                    .param_start = 0, .param_end = 0,
                    .tag = .comment,
                    .raw = base_line,
                });
                continue;
            }

            const tok_start = self.token_store.items.len;
            const param_start = self.param_store.items.len;

            const base_eff = stripTrailingBackslash(stripInlineComment(base_line));
            try self.tokenizeSingleLine(base_eff);

            var prev_had_backslash = hasTrailingBackslash(stripInlineComment(base_line));
            while (i < raw_lines.items.len) {
                const next = raw_lines.items[i];
                const next_trimmed = std.mem.trimLeft(u8, next, " \t");
                if (next_trimmed.len > 0 and next_trimmed[0] == '+') {
                    const cont = if (next_trimmed.len > 1) next_trimmed[1..] else "";
                    try self.tokenizeSingleLine(stripTrailingBackslash(stripInlineComment(cont)));
                    prev_had_backslash = hasTrailingBackslash(stripInlineComment(cont));
                    i += 1;
                } else if (prev_had_backslash) {
                    try self.tokenizeSingleLine(stripTrailingBackslash(stripInlineComment(next)));
                    prev_had_backslash = hasTrailingBackslash(stripInlineComment(next));
                    i += 1;
                } else {
                    break;
                }
            }

            const tok_end = self.token_store.items.len;
            const param_end = self.param_store.items.len;

            const tag = classifyLine(self.token_store.items[tok_start..tok_end], trimmed);

            try line_ranges.append(self.allocator, .{
                .tok_start = tok_start,
                .tok_end = tok_end,
                .param_start = param_start,
                .param_end = param_end,
                .tag = tag,
                .raw = base_line,
            });
        }

        // Third pass: resolve index ranges into stable slices (stores fully populated).
        for (line_ranges.items) |range| {
            const toks = if (range.tok_start == range.tok_end)
                &[_][]const u8{}
            else
                self.token_store.items[range.tok_start..range.tok_end];
            const pars = if (range.param_start == range.param_end)
                &[_]Param{}
            else
                self.param_store.items[range.param_start..range.param_end];

            try self.tok_lines.append(self.allocator, .{
                .tag = range.tag,
                .tokens = toks,
                .params = pars,
                .raw = range.raw,
            });
        }

        return self.tok_lines.items;
    }

    fn tokenizeSingleLine(self: *Tokenizer, line: []const u8) !void {
        var start: usize = 0;
        var in_token = false;

        var idx: usize = 0;
        while (idx < line.len) : (idx += 1) {
            const is_ws = (line[idx] == ' ' or line[idx] == '\t');
            if (is_ws) {
                if (in_token) {
                    try self.addToken(line[start..idx]);
                    in_token = false;
                }
            } else {
                if (!in_token) {
                    start = idx;
                    in_token = true;
                }
            }
        }
        if (in_token) try self.addToken(line[start..idx]);
    }

    fn addToken(self: *Tokenizer, token: []const u8) !void {
        try self.token_store.append(self.allocator, token);
        if (std.mem.indexOfScalar(u8, token, '=')) |eq_pos| {
            if (eq_pos > 0 and eq_pos < token.len - 1) {
                const val = token[eq_pos + 1 ..];
                try self.param_store.append(self.allocator, .{
                    .key = token[0..eq_pos],
                    .value = val,
                    .numeric = parseSiValue(val),
                });
            }
        }
    }

    fn classifyLine(tokens: []const []const u8, raw: []const u8) Token.Tag {
        if (tokens.len == 0) return .blank;
        const first = tokens[0];
        if (first.len == 0) return .other;

        if (first[0] == '.') return Token.getKeyword(first) orelse .other;

        if (raw.len > 0 and raw[0] == '*') return .comment;
        if (raw.len >= 2 and raw[0] == '/' and raw[1] == '/') return .comment;

        const fc = if (first[0] >= 'a' and first[0] <= 'z') first[0] - 32 else first[0];
        return switch (fc) {
            'M' => .mosfet,
            'R' => .resistor,
            'C' => .capacitor,
            'L' => .inductor,
            'D' => .diode,
            'Q' => .bjt,
            'J' => .jfet,
            'X' => .subckt_inst,
            // V/I: independent sources — no layout footprint, skip
            'V', 'I' => .source,
            // E/F/G/H: dependent sources — no layout footprint, skip
            // B: behavioral source (ngspice/Xyce) — skip
            // K: mutual inductance coupling — skip
            // S/W: voltage/current-controlled switches — skip
            // T/U: transmission lines — skip
            // Y: Xyce interface elements — skip
            // Z: MESFET (no target PDK support) — skip
            else => .other,
        };
    }

    fn stripInlineComment(line: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, line, '$')) |pos| return line[0..pos];
        return line;
    }

    fn hasTrailingBackslash(line: []const u8) bool {
        const t = std.mem.trimRight(u8, line, " \t");
        return t.len > 0 and t[t.len - 1] == '\\';
    }

    fn stripTrailingBackslash(line: []const u8) []const u8 {
        const t = std.mem.trimRight(u8, line, " \t");
        return if (t.len > 0 and t[t.len - 1] == '\\') t[0 .. t.len - 1] else line;
    }

    // ── Full parse ──────────────────────────────────────────────────────────

    /// Parse `source` from memory and return a ParseResult.
    /// Replaces the old Parser.parseBuffer().
    pub fn parse(self: *Tokenizer, source: []const u8) !ParseResult {
        const stmts = try self.tokenize(source);

        for (stmts) |stmt| {
            switch (stmt.tag) {
                .mosfet       => try self.parseMosfet(&stmt),
                .resistor     => try self.parseResistor(&stmt),
                .capacitor    => try self.parseCapacitor(&stmt),
                .inductor     => try self.parseInductor(&stmt),
                .diode        => try self.parseDiode(&stmt),
                .bjt          => try self.parseBjt(&stmt),
                .jfet         => try self.parseJfet(&stmt),
                .subckt_begin => try self.parseSubcktBegin(&stmt),
                .subckt_end   => self.parseSubcktEnd(),
                .subckt_inst  => try self.parseSubcktInst(&stmt),
                .dot_param, .dot_global, .dot_model, .dot_include, .dot_lib => {},
                .source, .comment, .blank, .other => {},
            }
        }

        return try self.finalize();
    }

    /// Parse from a file path.
    pub fn parseFile(self: *Tokenizer, path: []const u8) !ParseResult {
        const file = std.fs.cwd().openFile(path, .{}) catch return ParseError.FileNotFound;
        defer file.close();
        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return ParseError.IoError;
        defer self.allocator.free(source);
        return self.parse(source);
    }

    /// Backward-compatible alias for parse().
    pub fn parseBuffer(self: *Tokenizer, source: []const u8) !ParseResult {
        return self.parse(source);
    }

    // ── Net interning ────────────────────────────────────────────────────────

    fn internNet(self: *Tokenizer, name: []const u8) !NetIdx {
        if (self.net_table.get(name)) |idx| return idx;
        const owned = try self.allocator.dupe(u8, name);
        const idx = NetIdx.fromInt(@intCast(self.net_names.items.len));
        try self.net_table.put(owned, idx);
        try self.net_names.append(self.allocator, owned);
        try self.net_is_power.append(self.allocator, isPowerNet(owned));
        return idx;
    }

    fn addPin(self: *Tokenizer, dev: DeviceIdx, net: NetIdx, terminal: TerminalType) !void {
        const pin = PinIdx.fromInt(self.pin_count);
        self.pin_count += 1;
        try self.pins.append(self.allocator, .{
            .pin = pin,
            .device = dev,
            .net = net,
            .terminal = terminal,
        });
    }

    // ── Device-line parsers ──────────────────────────────────────────────────

    fn parseMosfet(self: *Tokenizer, stmt: *const Token) !void {
        // M<name> <drain> <gate> <source> <body> <type> [params...]
        if (stmt.tokens.len < 6) return ParseError.MalformedMosfet;

        const dev_type = parseMosType(stmt.tokens[5]) orelse return ParseError.UnknownDeviceType;

        const w_val: f32 = if (stmt.getParam("w")) |v| @floatCast(v) else 0.0;
        const l_val: f32 = if (stmt.getParam("l")) |v| @floatCast(v) else 0.0;
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));
        const nf_raw: f64 = stmt.getParam("nf") orelse (stmt.getParam("nfin") orelse 1.0);
        const fingers: u16 = @intFromFloat(@max(1.0, @min(65535.0, nf_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = dev_type,
            .params = .{ .w = w_val, .l = l_val, .fingers = fingers, .mult = mult, .value = 0.0 },
            .model_name = try self.allocator.dupe(u8, stmt.tokens[5]),
        });

        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .drain);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .gate);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[3]), .source);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[4]), .body);
    }

    fn parseResistor(self: *Tokenizer, stmt: *const Token) !void {
        if (stmt.tokens.len < 3) return ParseError.MalformedResistor;

        var dev_type: DeviceType = .res;
        var value: f32 = 0.0;
        var model_str: []const u8 = &.{};
        if (stmt.tokens.len >= 4 and std.mem.indexOfScalar(u8, stmt.tokens[3], '=') == null) {
            if (parseSiValue(stmt.tokens[3])) |v| {
                value = @floatCast(v);
            } else {
                // Non-numeric token → physical model name
                dev_type = resolveResistorModel(stmt.tokens[3]);
                model_str = stmt.tokens[3];
            }
        }
        if (stmt.getParam("r")) |v| value = @floatCast(v);

        const w_val: f32 = if (stmt.getParam("w")) |v| @floatCast(v) else 0.0;
        const l_val: f32 = if (stmt.getParam("l")) |v| @floatCast(v) else 0.0;
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = dev_type,
            .params = .{ .w = w_val, .l = l_val, .fingers = 1, .mult = mult, .value = value },
            .model_name = if (model_str.len > 0) try self.allocator.dupe(u8, model_str) else &.{},
        });
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .anode);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .cathode);
    }

    fn parseCapacitor(self: *Tokenizer, stmt: *const Token) !void {
        if (stmt.tokens.len < 3) return ParseError.MalformedCapacitor;

        var dev_type: DeviceType = .cap;
        var value: f32 = 0.0;
        var model_str: []const u8 = &.{};
        if (stmt.tokens.len >= 4 and std.mem.indexOfScalar(u8, stmt.tokens[3], '=') == null) {
            if (parseSiValue(stmt.tokens[3])) |v| {
                value = @floatCast(v);
            } else {
                // Non-numeric token → physical model name
                dev_type = resolveCapacitorModel(stmt.tokens[3]);
                model_str = stmt.tokens[3];
            }
        }
        if (stmt.getParam("c")) |v| value = @floatCast(v);

        const w_val: f32 = if (stmt.getParam("w")) |v| @floatCast(v) else 0.0;
        const l_val: f32 = if (stmt.getParam("l")) |v| @floatCast(v) else 0.0;
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = dev_type,
            .params = .{ .w = w_val, .l = l_val, .fingers = 1, .mult = mult, .value = value },
            .model_name = if (model_str.len > 0) try self.allocator.dupe(u8, model_str) else &.{},
        });
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .anode);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .cathode);
    }

    fn parseInductor(self: *Tokenizer, stmt: *const Token) !void {
        if (stmt.tokens.len < 3) return ParseError.MalformedInductor;

        var value: f32 = 0.0;
        if (stmt.tokens.len >= 4 and std.mem.indexOfScalar(u8, stmt.tokens[3], '=') == null) {
            if (parseSiValue(stmt.tokens[3])) |v| value = @floatCast(v);
        }

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = .ind,
            .params = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = value },
        });
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .anode);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .cathode);
    }

    fn parseDiode(self: *Tokenizer, stmt: *const Token) !void {
        // D<name> <anode> <cathode> <model> [area=N] [m=N] [params...]
        if (stmt.tokens.len < 4) return ParseError.MalformedDiode;

        const area_val: f32 = blk: {
            if (stmt.getParam("area")) |v| break :blk @floatCast(v);
            if (stmt.tokens.len >= 5 and std.mem.indexOfScalar(u8, stmt.tokens[4], '=') == null) {
                if (parseSiValue(stmt.tokens[4])) |v| break :blk @floatCast(v);
            }
            break :blk 1.0;
        };
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = .diode,
            .params = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = mult, .value = area_val },
            .model_name = try self.allocator.dupe(u8, stmt.tokens[3]),
        });
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .anode);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .cathode);
    }

    fn parseBjt(self: *Tokenizer, stmt: *const Token) !void {
        // Q<name> <C> <B> <E> [<S>] <model> [area=N] [m=N] [params...]
        // Collect positional (non key=value) tokens; last one is the model name.
        var pos: std.ArrayList([]const u8) = .empty;
        defer pos.deinit(self.allocator);
        for (stmt.tokens) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') == null)
                try pos.append(self.allocator, tok);
        }
        // pos[0]=name, pos[1]=C, pos[2]=B, pos[3]=E, pos[4]=(S or model), pos[5]=model
        if (pos.items.len < 5) return ParseError.MalformedBjt;

        const model = pos.items[pos.items.len - 1];
        const has_substrate = pos.items.len >= 6;

        const dev_type = parseBjtType(model);
        const area_val: f32 = if (stmt.getParam("area")) |v| @floatCast(v) else 1.0;
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));
        const ne_raw: f64 = stmt.getParam("ne") orelse (stmt.getParam("nf") orelse 1.0);
        const fingers: u16 = @intFromFloat(@max(1.0, @min(65535.0, ne_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = dev_type,
            .params = .{ .w = 0.0, .l = 0.0, .fingers = fingers, .mult = mult, .value = area_val },
            .model_name = try self.allocator.dupe(u8, model),
        });
        try self.addPin(dev_idx, try self.internNet(pos.items[1]), .collector);
        try self.addPin(dev_idx, try self.internNet(pos.items[2]), .base);
        try self.addPin(dev_idx, try self.internNet(pos.items[3]), .emitter);
        if (has_substrate)
            try self.addPin(dev_idx, try self.internNet(pos.items[4]), .body);
    }

    fn parseBjtType(model: []const u8) DeviceType {
        var buf: [32]u8 = undefined;
        const n = @min(model.len, 32);
        for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];
        if (std.mem.indexOf(u8, lower, "pnp") != null) return .bjt_pnp;
        return .bjt_npn;
    }

    fn parseJfet(self: *Tokenizer, stmt: *const Token) !void {
        // J<name> <drain> <gate> <source> <model> [area=N] [m=N] [params...]
        if (stmt.tokens.len < 5) return ParseError.MalformedJfet;

        const model = stmt.tokens[4];
        const dev_type = parseJfetType(model);
        const area_val: f32 = if (stmt.getParam("area")) |v| @floatCast(v) else 1.0;
        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = dev_type,
            .params = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = mult, .value = area_val },
            .model_name = try self.allocator.dupe(u8, model),
        });
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[1]), .drain);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[2]), .gate);
        try self.addPin(dev_idx, try self.internNet(stmt.tokens[3]), .source);
    }

    fn parseJfetType(model: []const u8) DeviceType {
        if (model.len == 0) return .jfet_n;
        return if (std.ascii.toLower(model[0]) == 'p') .jfet_p else .jfet_n;
    }

    fn parseSubcktBegin(self: *Tokenizer, stmt: *const Token) !void {
        if (stmt.tokens.len < 2) return ParseError.MalformedSubckt;

        var ports: std.ArrayList([]const u8) = .empty;
        defer ports.deinit(self.allocator);

        for (stmt.tokens[2..]) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            try ports.append(self.allocator, tok);
        }

        const ports_owned = try self.allocator.dupe([]const u8, ports.items);
        try self.subcircuits.append(self.allocator, .{
            .name = stmt.tokens[1],
            .ports = ports_owned,
            .device_start = @intCast(self.devices.items.len),
        });
        for (ports_owned) |port| _ = try self.internNet(port);
    }

    fn parseSubcktEnd(self: *Tokenizer) void {
        const n = self.subcircuits.items.len;
        if (n > 0) {
            self.subcircuits.items[n - 1].device_end = @intCast(self.devices.items.len);
        }
    }

    fn parseSubcktInst(self: *Tokenizer, stmt: *const Token) !void {
        if (stmt.tokens.len < 2) return;

        var non_param: std.ArrayList([]const u8) = .empty;
        defer non_param.deinit(self.allocator);

        for (stmt.tokens[1..]) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            try non_param.append(self.allocator, tok);
        }
        if (non_param.items.len < 1) return;

        const subckt_name = non_param.items[non_param.items.len - 1];
        const port_tokens = non_param.items[0 .. non_param.items.len - 1];

        const mult_raw: f64 = stmt.getParam("m") orelse 1.0;
        const mult: u16 = @intFromFloat(@max(1.0, @min(65535.0, mult_raw)));

        const dev_idx = DeviceIdx.fromInt(@intCast(self.devices.items.len));
        try self.devices.append(self.allocator, .{
            .name = stmt.tokens[0],
            .device_type = .subckt,
            .params = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = mult, .value = 0.0 },
            .subckt_type = subckt_name,
        });
        // Note: subckt_name is the cell type, not a circuit net — do not intern it
        for (port_tokens, 0..) |tok, port_idx| {
            const pin = PinIdx.fromInt(self.pin_count);
            self.pin_count += 1;
            try self.pins.append(self.allocator, .{
                .pin = pin,
                .device = dev_idx,
                .net = try self.internNet(tok),
                .terminal = .anode,
                .port_order = @intCast(port_idx),
            });
        }
    }

    // ── Finalize ─────────────────────────────────────────────────────────────

    fn finalize(self: *Tokenizer) !ParseResult {
        // Close any unclosed subcircuit (e.g., file ends with .END instead of .ends).
        const total_devs: u32 = @intCast(self.devices.items.len);
        for (self.subcircuits.items) |*sc| {
            if (sc.device_end <= sc.device_start and total_devs > sc.device_start) {
                sc.device_end = total_devs;
            }
        }

        const num_nets: u32 = @intCast(self.net_names.items.len);
        const num_pins: u32 = @intCast(self.pins.items.len);

        // Sort pins by (device, terminal_type) for deterministic layout.
        std.mem.sort(PinEdge, self.pins.items, {}, struct {
            fn lessThan(_: void, a: PinEdge, b: PinEdge) bool {
                if (a.device.toInt() != b.device.toInt())
                    return a.device.toInt() < b.device.toInt();
                if (@intFromEnum(a.terminal) != @intFromEnum(b.terminal))
                    return @intFromEnum(a.terminal) < @intFromEnum(b.terminal);
                return a.port_order < b.port_order;
            }
        }.lessThan);

        // Re-assign PinIdx after sorting.
        for (self.pins.items, 0..) |*pin, i| pin.pin = PinIdx.fromInt(@intCast(i));

        // Build CSR adjacency (net → pins).
        const row_ptr = try self.allocator.alloc(u32, num_nets + 1);
        @memset(row_ptr, 0);
        for (self.pins.items) |pin| row_ptr[pin.net.toInt() + 1] += 1;
        var ii: u32 = 0;
        while (ii < num_nets) : (ii += 1) row_ptr[ii + 1] += row_ptr[ii];

        const col_idx = try self.allocator.alloc(PinIdx, num_pins);
        const write_pos = try self.allocator.alloc(u32, num_nets);
        defer self.allocator.free(write_pos);
        @memcpy(write_pos, row_ptr[0..num_nets]);
        for (self.pins.items) |pin| {
            const n = pin.net.toInt();
            col_idx[write_pos[n]] = pin.pin;
            write_pos[n] += 1;
        }

        // Build NetInfo array with fanout.
        const nets = try self.allocator.alloc(NetInfo, num_nets);
        for (nets, 0..) |*net, ni| {
            const ni32: u32 = @intCast(ni);
            net.name = self.net_names.items[ni];
            net.is_power = self.net_is_power.items[ni];
            net.fanout = row_ptr[ni32 + 1] - row_ptr[ni32];
        }

        const devices = try self.allocator.dupe(DeviceInfo, self.devices.items);
        for (devices) |*dev| {
            if (dev.name.len > 0) dev.name = try self.allocator.dupe(u8, dev.name);
            if (dev.subckt_type.len > 0) dev.subckt_type = try self.allocator.dupe(u8, dev.subckt_type);
            // model_name is already an owned allocation from parseMosfet/etc — ownership transfers to ParseResult
        }
        const pins = try self.allocator.dupe(PinEdge, self.pins.items);
        const subcircuits = try self.allocator.dupe(Subcircuit, self.subcircuits.items);
        for (subcircuits) |*sc| {
            sc.name = try self.allocator.dupe(u8, sc.name);
            const old_ports = sc.ports;
            const new_ports = try self.allocator.alloc([]const u8, sc.ports.len);
            for (old_ports, 0..) |port, i| {
                new_ports[i] = try self.allocator.dupe(u8, port);
            }
            sc.ports = new_ports;
            self.allocator.free(old_ports);
        }

        var net_table = std.StringHashMap(NetIdx).init(self.allocator);
        var it = self.net_table.iterator();
        while (it.next()) |entry| try net_table.put(entry.key_ptr.*, entry.value_ptr.*);

        return ParseResult{
            .devices = devices,
            .nets = nets,
            .pins = pins,
            .adj = .{ .row_ptr = row_ptr, .col_idx = col_idx, .num_nets = num_nets },
            .subcircuits = subcircuits,
            .allocator = self.allocator,
            .net_table = net_table,
        };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "parseSiValue - basic integers" {
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), parseSiValue("42").?, 1e-12);
}

test "parseSiValue - SI suffixes" {
    try std.testing.expectApproxEqAbs(@as(f64, 2e-6), parseSiValue("2u").?, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 0.13e-6), parseSiValue("0.13u").?, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 100e-9), parseSiValue("100n").?, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-12), parseSiValue("1p").?, 1e-24);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-15), parseSiValue("1f").?, 1e-27);
    try std.testing.expectApproxEqAbs(@as(f64, 10e3), parseSiValue("10k").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2e-3), parseSiValue("2.2m").?, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1e6), parseSiValue("1meg").?, 1e-6);
}

test "parseSiValue - returns null for non-numeric" {
    try std.testing.expectEqual(@as(?f64, null), parseSiValue("abc"));
    try std.testing.expectEqual(@as(?f64, null), parseSiValue(""));
}

test "isPowerNet" {
    try std.testing.expect(isPowerNet("VDD"));
    try std.testing.expect(isPowerNet("vdd"));
    try std.testing.expect(isPowerNet("VSS"));
    try std.testing.expect(isPowerNet("vss"));
    try std.testing.expect(isPowerNet("VCC"));
    try std.testing.expect(isPowerNet("GND"));
    try std.testing.expect(isPowerNet("gnd"));
    try std.testing.expect(isPowerNet("0"));
    try std.testing.expect(!isPowerNet("OUT"));
    try std.testing.expect(!isPowerNet("diff_a"));
}

test "Tokenizer - comment and blank lines" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    const lines = try tok.tokenize("* This is a comment\n\n* Another comment\n");
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(Token.Tag.comment, lines[0].tag);
    try std.testing.expectEqual(Token.Tag.blank, lines[1].tag);
    try std.testing.expectEqual(Token.Tag.comment, lines[2].tag);
    try std.testing.expectEqual(Token.Tag.blank, lines[3].tag);
}

test "Tokenizer - MOSFET line with params" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    const lines = try tok.tokenize("M1 drain gate source body nmos w=2u l=0.13u m=1");
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(Token.Tag.mosfet, lines[0].tag);
    try std.testing.expectEqual(@as(usize, 9), lines[0].tokens.len);
    try std.testing.expectEqual(@as(usize, 3), lines[0].params.len);

    try std.testing.expectApproxEqAbs(@as(f64, 2e-6), lines[0].getParam("w").?, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 0.13e-6), lines[0].getParam("l").?, 1e-18);
}

test "Tokenizer - continuation lines" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    const lines = try tok.tokenize("M1 drain gate source body nmos\n+ w=2u l=0.13u m=1");
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(Token.Tag.mosfet, lines[0].tag);
    try std.testing.expectEqual(@as(usize, 9), lines[0].tokens.len);
    try std.testing.expectEqual(@as(usize, 3), lines[0].params.len);
}

test "Tokenizer - subckt begin/end" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    const lines = try tok.tokenize(".subckt ota VDD VSS INP INN OUT\nM1 a b c d nmos\n.ends ota");
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(Token.Tag.subckt_begin, lines[0].tag);
    try std.testing.expectEqual(Token.Tag.mosfet, lines[1].tag);
    try std.testing.expectEqual(Token.Tag.subckt_end, lines[2].tag);
}

test "Tokenizer - resistor and capacitor" {
    var tok = Tokenizer.init(std.testing.allocator);
    defer tok.deinit();

    const lines = try tok.tokenize("R1 n1 n2 10k\nC1 n1 n2 1p");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(Token.Tag.resistor, lines[0].tag);
    try std.testing.expectEqual(Token.Tag.capacitor, lines[1].tag);
}

test "Tokenizer - Token.getKeyword case insensitive" {
    try std.testing.expectEqual(Token.Tag.subckt_begin, Token.getKeyword(".SUBCKT").?);
    try std.testing.expectEqual(Token.Tag.subckt_end, Token.getKeyword(".ENDS").?);
    try std.testing.expectEqual(Token.Tag.dot_model, Token.getKeyword(".Model").?);
    try std.testing.expectEqual(@as(?Token.Tag, null), Token.getKeyword(".unknown"));
}
