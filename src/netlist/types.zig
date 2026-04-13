const std = @import("std");
const core_types = @import("../core/types.zig");

const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const PinIdx = core_types.PinIdx;
const DeviceType = core_types.DeviceType;
const DeviceParams = core_types.DeviceParams;
const TerminalType = core_types.TerminalType;

// ─── Errors ─────────────────────────────────────────────────────────────────

pub const ParseError = error{
    MalformedMosfet,
    MalformedResistor,
    MalformedCapacitor,
    MalformedInductor,
    MalformedSubckt,
    MalformedDiode,
    MalformedBjt,
    MalformedJfet,
    UnknownDeviceType,
    OutOfMemory,
    FileNotFound,
    IoError,
};

// ─── Pin Edge ───────────────────────────────────────────────────────────────

pub const PinEdge = struct {
    pin: PinIdx,
    device: DeviceIdx,
    net: NetIdx,
    terminal: TerminalType,
    port_order: u16 = 0,
};

// ─── Net Info ───────────────────────────────────────────────────────────────

pub const NetInfo = struct {
    name: []const u8,
    is_power: bool,
    fanout: u32,
};

// ─── Device Info ────────────────────────────────────────────────────────────

pub const DeviceInfo = struct {
    name: []const u8,
    device_type: DeviceType,
    params: DeviceParams,
    subckt_type: []const u8 = &.{},  // only set for .subckt devices; borrowed from intern pool
    model_name: []const u8 = &.{},   // SPICE model string (e.g. "sky130_fd_pr__nfet_01v8")
};

// ─── CSR Flat Adjacency List ────────────────────────────────────────────────

/// Compressed Sparse Row adjacency list.
/// row_ptr[net] .. row_ptr[net+1] gives the range into col_idx for all pins on that net.
pub const FlatAdjList = struct {
    row_ptr: []u32,
    col_idx: []PinIdx,
    num_nets: u32,

    pub fn pinsOnNet(self: *const FlatAdjList, net: NetIdx) []const PinIdx {
        const n = net.toInt();
        if (n >= self.num_nets) return &.{};
        return self.col_idx[self.row_ptr[n]..self.row_ptr[n + 1]];
    }

    pub fn deinit(self: *FlatAdjList, allocator: std.mem.Allocator) void {
        allocator.free(self.row_ptr);
        allocator.free(self.col_idx);
    }
};

// ─── Subcircuit ─────────────────────────────────────────────────────────────

pub const Subcircuit = struct {
    name: []const u8,
    ports: []const []const u8,
    device_start: u32 = 0,
    device_end: u32 = 0,
};

// ─── Parse Result ───────────────────────────────────────────────────────────

pub const ParseResult = struct {
    devices: []DeviceInfo,
    nets: []NetInfo,
    pins: []PinEdge,
    adj: FlatAdjList,
    subcircuits: []Subcircuit,
    allocator: std.mem.Allocator,
    net_table: std.StringHashMap(NetIdx),

    pub fn deinit(self: *ParseResult) void {
        for (self.nets) |net| {
            if (net.name.len > 0) self.allocator.free(net.name);
        }
        for (self.devices) |dev| {
            if (dev.name.len > 0) self.allocator.free(dev.name);
            if (dev.subckt_type.len > 0) self.allocator.free(dev.subckt_type);
            if (dev.model_name.len > 0) self.allocator.free(dev.model_name);
        }
        self.allocator.free(self.devices);
        self.allocator.free(self.nets);
        self.allocator.free(self.pins);
        self.adj.deinit(self.allocator);
        for (self.subcircuits) |s| {
            if (s.name.len > 0) self.allocator.free(s.name);
            for (s.ports) |port| {
                if (port.len > 0) self.allocator.free(port);
            }
            self.allocator.free(s.ports);
        }
        self.allocator.free(self.subcircuits);
        self.net_table.deinit();
    }

    pub fn getNetIdx(self: *const ParseResult, name: []const u8) ?NetIdx {
        return self.net_table.get(name);
    }

    pub fn pinsOnNet(self: *const ParseResult, net: NetIdx) []const PinIdx {
        return self.adj.pinsOnNet(net);
    }
};
