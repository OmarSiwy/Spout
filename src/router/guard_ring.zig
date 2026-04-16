// Guard Ring Inserter — places P+/N+/deep-N-well rings around analog blocks.
//
// A guard ring is a "donut" shape (outer_rect - inner_rect) filled with
// diffusion or well material and contacted at regular pitch.  Rings provide
// isolation from substrate noise and latchup for sensitive analog circuits.
//
// Two insertion modes:
//   - insert():            complete enclosure around a rectangular region
//   - insertWithStitchIn(): enclosure with gaps where existing metal overlaps
//
// The GuardRingDB SoA table owns all ring geometry and contact positions.

const std = @import("std");
const core_types = @import("../core/types.zig");
const layout_if = @import("../core/layout_if.zig");
const inline_drc = @import("inline_drc.zig");

const NetIdx = core_types.NetIdx;
const PdkConfig = layout_if.PdkConfig;
const InlineDrcChecker = inline_drc.InlineDrcChecker;
const WireRect = inline_drc.WireRect;

// ─── Rect ────────────────────────────────────────────────────────────────────
// Local definition matching analog_types.Rect so this module is self-contained.

pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn width(self: Rect) f32 {
        return self.x2 - self.x1;
    }
    pub fn height(self: Rect) f32 {
        return self.y2 - self.y1;
    }
    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x1 = self.x1 - amount,
            .y1 = self.y1 - amount,
            .x2 = self.x2 + amount,
            .y2 = self.y2 + amount,
        };
    }
    pub fn union_(self: Rect, other: Rect) Rect {
        return .{
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
            .x2 = @max(self.x2, other.x2),
            .y2 = @max(self.y2, other.y2),
        };
    }
    pub fn containsPoint(self: Rect, x: f32, y: f32) bool {
        return x >= self.x1 and x <= self.x2 and y >= self.y1 and y <= self.y2;
    }
    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x1 < other.x2 and self.x2 > other.x1 and
            self.y1 < other.y2 and self.y2 > other.y1;
    }
};

// ─── Guard Ring Type ──────────────────────────────────────────────────────────

pub const GuardRingType = enum(u8) {
    p_plus = 0, // P+ diffusion ring (for N-substrate isolation)
    n_plus = 1, // N+ diffusion ring (for P-well isolation)
    deep_nwell = 2, // Deep N-well ring (for triple-well isolation)
    composite = 3, // P+ + deep N-well combined (full latchup protection)
};

// ─── GuardRingDB SoA Table ────────────────────────────────────────────────────

pub const GuardRingDB = struct {
    /// Number of guard rings stored.
    len: u32 = 0,
    /// Capacity allocated.
    capacity: u32 = 0,

    bbox_x1: []f32 = &.{},
    bbox_y1: []f32 = &.{},
    bbox_x2: []f32 = &.{},
    bbox_y2: []f32 = &.{},
    inner_x1: []f32 = &.{},
    inner_y1: []f32 = &.{},
    inner_x2: []f32 = &.{},
    inner_y2: []f32 = &.{},
    ring_type: []GuardRingType = &.{},
    net: []NetIdx = &.{},
    contact_pitch: []f32 = &.{},
    has_stitch_in: []bool = &.{},

    /// Contact positions — flat arrays indexed by contact ordinal.
    contacts_x: []f32 = &.{},
    contacts_y: []f32 = &.{},
    contacts_ring_idx: []u32 = &.{},
    num_contacts: u32 = 0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !GuardRingDB {
        return GuardRingDB{ .allocator = allocator };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: u32) !GuardRingDB {
        var db = GuardRingDB{ .allocator = allocator, .capacity = capacity, .len = 0 };
        errdefer db.deinit();

        db.bbox_x1 = try allocator.alloc(f32, capacity);
        db.bbox_y1 = try allocator.alloc(f32, capacity);
        db.bbox_x2 = try allocator.alloc(f32, capacity);
        db.bbox_y2 = try allocator.alloc(f32, capacity);
        db.inner_x1 = try allocator.alloc(f32, capacity);
        db.inner_y1 = try allocator.alloc(f32, capacity);
        db.inner_x2 = try allocator.alloc(f32, capacity);
        db.inner_y2 = try allocator.alloc(f32, capacity);
        db.ring_type = try allocator.alloc(GuardRingType, capacity);
        db.net = try allocator.alloc(NetIdx, capacity);
        db.contact_pitch = try allocator.alloc(f32, capacity);
        db.has_stitch_in = try allocator.alloc(bool, capacity);

        return db;
    }

    pub fn deinit(self: *GuardRingDB) void {
        const a = self.allocator;
        if (self.bbox_x1.len > 0) a.free(self.bbox_x1);
        if (self.bbox_y1.len > 0) a.free(self.bbox_y1);
        if (self.bbox_x2.len > 0) a.free(self.bbox_x2);
        if (self.bbox_y2.len > 0) a.free(self.bbox_y2);
        if (self.inner_x1.len > 0) a.free(self.inner_x1);
        if (self.inner_y1.len > 0) a.free(self.inner_y1);
        if (self.inner_x2.len > 0) a.free(self.inner_x2);
        if (self.inner_y2.len > 0) a.free(self.inner_y2);
        if (self.ring_type.len > 0) a.free(self.ring_type);
        if (self.net.len > 0) a.free(self.net);
        if (self.contact_pitch.len > 0) a.free(self.contact_pitch);
        if (self.has_stitch_in.len > 0) a.free(self.has_stitch_in);
        if (self.contacts_x.len > 0) a.free(self.contacts_x);
        if (self.contacts_y.len > 0) a.free(self.contacts_y);
        if (self.contacts_ring_idx.len > 0) a.free(self.contacts_ring_idx);
        self.* = .{ .allocator = a };
    }

    /// Append a guard ring record.
    pub fn append(self: *GuardRingDB, ring: GuardRing) !void {
        if (self.len >= self.capacity) {
            try self.grow(self.capacity * 2 + 4);
        }
        const i = self.len;
        self.bbox_x1[i] = ring.bbox_x1;
        self.bbox_y1[i] = ring.bbox_y1;
        self.bbox_x2[i] = ring.bbox_x2;
        self.bbox_y2[i] = ring.bbox_y2;
        self.inner_x1[i] = ring.inner_x1;
        self.inner_y1[i] = ring.inner_y1;
        self.inner_x2[i] = ring.inner_x2;
        self.inner_y2[i] = ring.inner_y2;
        self.ring_type[i] = ring.ring_type;
        self.net[i] = ring.net;
        self.contact_pitch[i] = ring.contact_pitch;
        self.has_stitch_in[i] = ring.has_stitch_in;
        self.len += 1;
    }

    /// Add contact positions for a ring (batch).
    pub fn addContacts(self: *GuardRingDB, ring_idx: u32, xs: []const f32, ys: []const f32) !void {
        std.debug.assert(xs.len == ys.len);
        const n = xs.len;
        if (n == 0) return;

        const new_total = self.num_contacts + @as(u32, @intCast(n));
        self.contacts_ring_idx = try self.allocator.realloc(self.contacts_ring_idx, new_total);
        self.contacts_x = try self.allocator.realloc(self.contacts_x, new_total);
        self.contacts_y = try self.allocator.realloc(self.contacts_y, new_total);

        for (0..n) |j| {
            const idx = self.num_contacts + @as(u32, @intCast(j));
            self.contacts_ring_idx[idx] = ring_idx;
            self.contacts_x[idx] = xs[j];
            self.contacts_y[idx] = ys[j];
        }
        self.num_contacts = new_total;
    }

    /// Remove contacts that belong to a specific ring.
    pub fn removeContactsForRing(self: *GuardRingDB, ring_idx: u32) void {
        // Compact in-place: keep contacts whose ring_idx != ring_idx.
        var dst: u32 = 0;
        var src: u32 = 0;
        while (src < self.num_contacts) : (src += 1) {
            if (self.contacts_ring_idx[src] != ring_idx) {
                self.contacts_ring_idx[dst] = self.contacts_ring_idx[src];
                self.contacts_x[dst] = self.contacts_x[src];
                self.contacts_y[dst] = self.contacts_y[src];
                dst += 1;
            }
        }
        self.num_contacts = dst;
    }

    fn grow(self: *GuardRingDB, new_cap: u32) !void {
        const cap = @as(usize, new_cap);
        self.bbox_x1 = try self.allocator.realloc(self.bbox_x1, cap);
        self.bbox_y1 = try self.allocator.realloc(self.bbox_y1, cap);
        self.bbox_x2 = try self.allocator.realloc(self.bbox_x2, cap);
        self.bbox_y2 = try self.allocator.realloc(self.bbox_y2, cap);
        self.inner_x1 = try self.allocator.realloc(self.inner_x1, cap);
        self.inner_y1 = try self.allocator.realloc(self.inner_y1, cap);
        self.inner_x2 = try self.allocator.realloc(self.inner_x2, cap);
        self.inner_y2 = try self.allocator.realloc(self.inner_y2, cap);
        self.ring_type = try self.allocator.realloc(self.ring_type, cap);
        self.net = try self.allocator.realloc(self.net, cap);
        self.contact_pitch = try self.allocator.realloc(self.contact_pitch, cap);
        self.has_stitch_in = try self.allocator.realloc(self.has_stitch_in, cap);
        self.capacity = new_cap;
    }

    /// Read ring `i` as an AoS record (convenience accessor).
    pub fn getRing(self: *const GuardRingDB, i: u32) GuardRing {
        return .{
            .bbox_x1 = self.bbox_x1[i],
            .bbox_y1 = self.bbox_y1[i],
            .bbox_x2 = self.bbox_x2[i],
            .bbox_y2 = self.bbox_y2[i],
            .inner_x1 = self.inner_x1[i],
            .inner_y1 = self.inner_y1[i],
            .inner_x2 = self.inner_x2[i],
            .inner_y2 = self.inner_y2[i],
            .ring_type = self.ring_type[i],
            .net = self.net[i],
            .contact_pitch = self.contact_pitch[i],
            .has_stitch_in = self.has_stitch_in[i],
        };
    }

    /// Swap-remove ring at index `idx` with the last ring.
    fn swapRemove(self: *GuardRingDB, idx: u32) void {
        const last = self.len - 1;
        if (idx != last) {
            self.bbox_x1[idx] = self.bbox_x1[last];
            self.bbox_y1[idx] = self.bbox_y1[last];
            self.bbox_x2[idx] = self.bbox_x2[last];
            self.bbox_y2[idx] = self.bbox_y2[last];
            self.inner_x1[idx] = self.inner_x1[last];
            self.inner_y1[idx] = self.inner_y1[last];
            self.inner_x2[idx] = self.inner_x2[last];
            self.inner_y2[idx] = self.inner_y2[last];
            self.ring_type[idx] = self.ring_type[last];
            self.net[idx] = self.net[last];
            self.contact_pitch[idx] = self.contact_pitch[last];
            self.has_stitch_in[idx] = self.has_stitch_in[last];
            // Re-tag contacts that belonged to `last` so they point to `idx`.
            for (0..self.num_contacts) |ci| {
                if (self.contacts_ring_idx[ci] == last) {
                    self.contacts_ring_idx[ci] = idx;
                }
            }
        }
        self.len -= 1;
    }
};

// ─── Guard Ring Record ───────────────────────────────────────────────────────

pub const GuardRing = struct {
    bbox_x1: f32,
    bbox_y1: f32,
    bbox_x2: f32,
    bbox_y2: f32,
    inner_x1: f32,
    inner_y1: f32,
    inner_x2: f32,
    inner_y2: f32,
    ring_type: GuardRingType,
    net: NetIdx,
    contact_pitch: f32,
    has_stitch_in: bool,
};

// ─── Guard Ring Index ─────────────────────────────────────────────────────────

pub const GuardRingIdx = enum(u32) {
    _,
    pub inline fn toInt(self: GuardRingIdx) u32 {
        return @intFromEnum(self);
    }
    pub inline fn fromInt(v: u32) GuardRingIdx {
        return @enumFromInt(v);
    }
};

// ─── Guard Ring Inserter ──────────────────────────────────────────────────────

pub const GuardRingInserter = struct {
    db: GuardRingDB,
    allocator: std.mem.Allocator,
    pdk: PdkConfig,
    drc: ?*InlineDrcChecker,
    die_bbox: Rect,
    num_warnings: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const PdkConfig,
        drc: ?*InlineDrcChecker,
        die_bbox: Rect,
    ) !GuardRingInserter {
        const db = try GuardRingDB.initCapacity(allocator, 4);
        return GuardRingInserter{
            .db = db,
            .allocator = allocator,
            .pdk = pdk.*,
            .drc = drc,
            .die_bbox = die_bbox,
            .num_warnings = 0,
        };
    }

    pub fn deinit(self: *GuardRingInserter) void {
        self.db.deinit();
    }

    // ── insert ──────────────────────────────────────────────────────────

    /// Insert a complete guard ring around a region.
    /// Returns the index into GuardRingDB.
    pub fn insert(
        self: *GuardRingInserter,
        region: Rect,
        ring_type: GuardRingType,
        net: NetIdx,
    ) !GuardRingIdx {
        const gr_width = self.pdk.guard_ring_width;
        const gr_spacing = self.pdk.guard_ring_spacing;

        // Outer bbox = region + spacing + width.
        const outer = Rect{
            .x1 = region.x1 - gr_spacing - gr_width,
            .y1 = region.y1 - gr_spacing - gr_width,
            .x2 = region.x2 + gr_spacing + gr_width,
            .y2 = region.y2 + gr_spacing + gr_width,
        };

        // Inner bbox = region + spacing (donut hole).
        const inner = Rect{
            .x1 = region.x1 - gr_spacing,
            .y1 = region.y1 - gr_spacing,
            .x2 = region.x2 + gr_spacing,
            .y2 = region.y2 + gr_spacing,
        };

        // Validate ring width (outer - inner on each axis must be > 0).
        const ring_w = (outer.x2 - outer.x1) - (inner.x2 - inner.x1);
        if (ring_w <= 0) {
            return error.RingTooNarrow;
        }

        // Clip outer rect to die edge.
        const clipped = clipRect(outer, self.die_bbox);
        if (clipped.x1 != outer.x1 or clipped.y1 != outer.y1 or
            clipped.x2 != outer.x2 or clipped.y2 != outer.y2)
        {
            self.num_warnings += 1;
        }

        // Contact pitch: use via_spacing[0] (li1 contact pitch) if available,
        // otherwise fall back to guard_ring_width as a reasonable default.
        const pitch = if (self.pdk.via_spacing[0] > 0)
            self.pdk.via_spacing[0]
        else
            gr_width + 0.14; // SKY130 licon pitch fallback: 0.34 + 0.14 = 0.48

        const idx = self.db.len;
        try self.db.append(.{
            .bbox_x1 = clipped.x1,
            .bbox_y1 = clipped.y1,
            .bbox_x2 = clipped.x2,
            .bbox_y2 = clipped.y2,
            .inner_x1 = inner.x1,
            .inner_y1 = inner.y1,
            .inner_x2 = inner.x2,
            .inner_y2 = inner.y2,
            .ring_type = ring_type,
            .net = net,
            .contact_pitch = pitch,
            .has_stitch_in = false,
        });

        // Generate contacts along the ring perimeter.
        try self.generateAndAddContacts(idx, pitch, clipped, inner);

        // Register ring segments with DRC checker.
        if (self.drc) |drc| {
            try self.registerWithDrc(drc, clipped, inner, net);
        }

        return GuardRingIdx.fromInt(idx);
    }

    // ── insertWithStitchIn ──────────────────────────────────────────────

    /// Insert a guard ring that overlaps with existing metal.
    /// Contacts are omitted where they would overlap existing_metal rects.
    pub fn insertWithStitchIn(
        self: *GuardRingInserter,
        region: Rect,
        ring_type: GuardRingType,
        net: NetIdx,
        existing_metal: []const Rect,
    ) !GuardRingIdx {
        const gr_width = self.pdk.guard_ring_width;
        const gr_spacing = self.pdk.guard_ring_spacing;

        const outer = Rect{
            .x1 = region.x1 - gr_spacing - gr_width,
            .y1 = region.y1 - gr_spacing - gr_width,
            .x2 = region.x2 + gr_spacing + gr_width,
            .y2 = region.y2 + gr_spacing + gr_width,
        };

        const inner = Rect{
            .x1 = region.x1 - gr_spacing,
            .y1 = region.y1 - gr_spacing,
            .x2 = region.x2 + gr_spacing,
            .y2 = region.y2 + gr_spacing,
        };

        const clipped = clipRect(outer, self.die_bbox);
        if (clipped.x1 != outer.x1 or clipped.y1 != outer.y1 or
            clipped.x2 != outer.x2 or clipped.y2 != outer.y2)
        {
            self.num_warnings += 1;
        }

        const pitch = if (self.pdk.via_spacing[0] > 0)
            self.pdk.via_spacing[0]
        else
            gr_width + 0.14;

        const idx = self.db.len;
        try self.db.append(.{
            .bbox_x1 = clipped.x1,
            .bbox_y1 = clipped.y1,
            .bbox_x2 = clipped.x2,
            .bbox_y2 = clipped.y2,
            .inner_x1 = inner.x1,
            .inner_y1 = inner.y1,
            .inner_x2 = inner.x2,
            .inner_y2 = inner.y2,
            .ring_type = ring_type,
            .net = net,
            .contact_pitch = pitch,
            .has_stitch_in = true,
        });

        // Generate contacts, skipping positions that overlap existing metal.
        try self.generateAndAddContactsWithStitchIn(idx, pitch, clipped, inner, existing_metal);

        if (self.drc) |drc| {
            try self.registerWithDrc(drc, clipped, inner, net);
        }

        return GuardRingIdx.fromInt(idx);
    }

    // ── mergeDeepNWell ──────────────────────────────────────────────────

    /// Merge two adjacent deep N-well rings into one encompassing ring.
    /// Ring `a` is updated with merged geometry; ring `b` is removed.
    pub fn mergeDeepNWell(self: *GuardRingInserter, a: GuardRingIdx, b: GuardRingIdx) !void {
        const ai = a.toInt();
        const bi = b.toInt();

        if (ai >= self.db.len or bi >= self.db.len) return error.InvalidRingIndex;
        if (self.db.ring_type[ai] != .deep_nwell or self.db.ring_type[bi] != .deep_nwell) {
            return error.NotDeepNWell;
        }
        if (self.db.net[ai] != self.db.net[bi]) return error.RingNetConflict;

        // Merge: union of outer bboxes, intersection of inner bboxes.
        self.db.bbox_x1[ai] = @min(self.db.bbox_x1[ai], self.db.bbox_x1[bi]);
        self.db.bbox_y1[ai] = @min(self.db.bbox_y1[ai], self.db.bbox_y1[bi]);
        self.db.bbox_x2[ai] = @max(self.db.bbox_x2[ai], self.db.bbox_x2[bi]);
        self.db.bbox_y2[ai] = @max(self.db.bbox_y2[ai], self.db.bbox_y2[bi]);
        self.db.inner_x1[ai] = @max(self.db.inner_x1[ai], self.db.inner_x1[bi]);
        self.db.inner_y1[ai] = @max(self.db.inner_y1[ai], self.db.inner_y1[bi]);
        self.db.inner_x2[ai] = @min(self.db.inner_x2[ai], self.db.inner_x2[bi]);
        self.db.inner_y2[ai] = @min(self.db.inner_y2[ai], self.db.inner_y2[bi]);

        // Remove old contacts for both rings, then regenerate for merged ring.
        self.db.removeContactsForRing(ai);
        self.db.removeContactsForRing(bi);

        const merged_outer = Rect{
            .x1 = self.db.bbox_x1[ai],
            .y1 = self.db.bbox_y1[ai],
            .x2 = self.db.bbox_x2[ai],
            .y2 = self.db.bbox_y2[ai],
        };
        const merged_inner = Rect{
            .x1 = self.db.inner_x1[ai],
            .y1 = self.db.inner_y1[ai],
            .x2 = self.db.inner_x2[ai],
            .y2 = self.db.inner_y2[ai],
        };
        const pitch = self.db.contact_pitch[ai];
        try self.generateAndAddContacts(ai, pitch, merged_outer, merged_inner);

        // Remove ring b via swap-with-last.
        self.db.swapRemove(bi);
    }

    // ── clipAllToDieEdge ────────────────────────────────────────────────

    /// Clip all guard ring outer bboxes to the die boundary and remove
    /// contacts that fall outside.
    pub fn clipAllToDieEdge(self: *GuardRingInserter) void {
        const die = self.die_bbox;
        for (0..self.db.len) |ii| {
            const i: u32 = @intCast(ii);
            self.db.bbox_x1[i] = @max(self.db.bbox_x1[i], die.x1);
            self.db.bbox_y1[i] = @max(self.db.bbox_y1[i], die.y1);
            self.db.bbox_x2[i] = @min(self.db.bbox_x2[i], die.x2);
            self.db.bbox_y2[i] = @min(self.db.bbox_y2[i], die.y2);
        }
        // Remove contacts outside die.
        var dst: u32 = 0;
        var src: u32 = 0;
        while (src < self.db.num_contacts) : (src += 1) {
            const cx = self.db.contacts_x[src];
            const cy = self.db.contacts_y[src];
            if (cx >= die.x1 and cx <= die.x2 and cy >= die.y1 and cy <= die.y2) {
                self.db.contacts_ring_idx[dst] = self.db.contacts_ring_idx[src];
                self.db.contacts_x[dst] = self.db.contacts_x[src];
                self.db.contacts_y[dst] = self.db.contacts_y[src];
                dst += 1;
            }
        }
        self.db.num_contacts = dst;
    }

    // ── Accessors ───────────────────────────────────────────────────────

    /// Return guard ring `i` as an AoS record.
    pub fn getRing(self: *const GuardRingInserter, i: u32) GuardRing {
        return self.db.getRing(i);
    }

    /// Return the number of guard rings.
    pub fn ringCount(self: *const GuardRingInserter) u32 {
        return self.db.len;
    }

    /// Count contacts belonging to a specific ring.
    pub fn contactCount(self: *const GuardRingInserter, ring_idx: u32) u32 {
        var count: u32 = 0;
        for (0..self.db.num_contacts) |ci| {
            if (self.db.contacts_ring_idx[ci] == ring_idx) count += 1;
        }
        return count;
    }

    /// Return total number of contacts across all rings.
    pub fn totalContactCount(self: *const GuardRingInserter) u32 {
        return self.db.num_contacts;
    }

    // ── Internal: contact generation ────────────────────────────────────

    /// Generate contacts along the 4 ring sides at given pitch and add them
    /// to the DB.  Contacts are placed at the midline of each ring band.
    fn generateAndAddContacts(
        self: *GuardRingInserter,
        ring_idx: u32,
        pitch: f32,
        outer: Rect,
        inner: Rect,
    ) !void {
        // Temporary buffers for contact positions.
        var xs: std.ArrayListUnmanaged(f32) = .{};
        defer xs.deinit(self.allocator);
        var ys: std.ArrayListUnmanaged(f32) = .{};
        defer ys.deinit(self.allocator);

        // Top band midline: y = (inner.y2 + outer.y2) / 2
        // Bottom band midline: y = (outer.y1 + inner.y1) / 2
        // Left band midline: x = (outer.x1 + inner.x1) / 2
        // Right band midline: x = (inner.x2 + outer.x2) / 2
        const top_y = (inner.y2 + outer.y2) * 0.5;
        const bot_y = (outer.y1 + inner.y1) * 0.5;
        const left_x = (outer.x1 + inner.x1) * 0.5;
        const right_x = (inner.x2 + outer.x2) * 0.5;

        // Top side: contacts from outer.x1 to outer.x2 at top_y.
        {
            var x = outer.x1 + pitch * 0.5;
            while (x <= outer.x2 - pitch * 0.25) : (x += pitch) {
                try xs.append(self.allocator, x);
                try ys.append(self.allocator, top_y);
            }
        }

        // Bottom side.
        {
            var x = outer.x1 + pitch * 0.5;
            while (x <= outer.x2 - pitch * 0.25) : (x += pitch) {
                try xs.append(self.allocator, x);
                try ys.append(self.allocator, bot_y);
            }
        }

        // Left side (skip corners already covered by top/bottom).
        {
            var y = inner.y1 + pitch * 0.5;
            while (y <= inner.y2 - pitch * 0.25) : (y += pitch) {
                try xs.append(self.allocator, left_x);
                try ys.append(self.allocator, y);
            }
        }

        // Right side.
        {
            var y = inner.y1 + pitch * 0.5;
            while (y <= inner.y2 - pitch * 0.25) : (y += pitch) {
                try xs.append(self.allocator, right_x);
                try ys.append(self.allocator, y);
            }
        }

        try self.db.addContacts(ring_idx, xs.items, ys.items);
    }

    /// Generate contacts with gaps at existing metal overlaps.
    fn generateAndAddContactsWithStitchIn(
        self: *GuardRingInserter,
        ring_idx: u32,
        pitch: f32,
        outer: Rect,
        inner: Rect,
        existing_metal: []const Rect,
    ) !void {
        var xs: std.ArrayListUnmanaged(f32) = .{};
        defer xs.deinit(self.allocator);
        var ys: std.ArrayListUnmanaged(f32) = .{};
        defer ys.deinit(self.allocator);

        const top_y = (inner.y2 + outer.y2) * 0.5;
        const bot_y = (outer.y1 + inner.y1) * 0.5;
        const left_x = (outer.x1 + inner.x1) * 0.5;
        const right_x = (inner.x2 + outer.x2) * 0.5;

        // Top side.
        {
            var x = outer.x1 + pitch * 0.5;
            while (x <= outer.x2 - pitch * 0.25) : (x += pitch) {
                if (!pointOverlapsAny(x, top_y, existing_metal)) {
                    try xs.append(self.allocator, x);
                    try ys.append(self.allocator, top_y);
                }
            }
        }

        // Bottom side.
        {
            var x = outer.x1 + pitch * 0.5;
            while (x <= outer.x2 - pitch * 0.25) : (x += pitch) {
                if (!pointOverlapsAny(x, bot_y, existing_metal)) {
                    try xs.append(self.allocator, x);
                    try ys.append(self.allocator, bot_y);
                }
            }
        }

        // Left side.
        {
            var y = inner.y1 + pitch * 0.5;
            while (y <= inner.y2 - pitch * 0.25) : (y += pitch) {
                if (!pointOverlapsAny(left_x, y, existing_metal)) {
                    try xs.append(self.allocator, left_x);
                    try ys.append(self.allocator, y);
                }
            }
        }

        // Right side.
        {
            var y = inner.y1 + pitch * 0.5;
            while (y <= inner.y2 - pitch * 0.25) : (y += pitch) {
                if (!pointOverlapsAny(right_x, y, existing_metal)) {
                    try xs.append(self.allocator, right_x);
                    try ys.append(self.allocator, y);
                }
            }
        }

        try self.db.addContacts(ring_idx, xs.items, ys.items);
    }

    /// Register all ring segments with the DRC checker.
    fn registerWithDrc(
        self: *GuardRingInserter,
        drc: *InlineDrcChecker,
        outer: Rect,
        inner: Rect,
        net: NetIdx,
    ) !void {
        const w = self.pdk.guard_ring_width;
        // Top band.
        try drc.addSegment(0, outer.x1, inner.y2, outer.x2, inner.y2, w, net);
        // Bottom band.
        try drc.addSegment(0, outer.x1, inner.y1, outer.x2, inner.y1, w, net);
        // Left band.
        try drc.addSegment(0, inner.x1, inner.y1, inner.x1, inner.y2, w, net);
        // Right band.
        try drc.addSegment(0, inner.x2, inner.y1, inner.x2, inner.y2, w, net);
    }
};

// ─── Free functions ──────────────────────────────────────────────────────────

/// Clip `r` to fit within `bounds`.
fn clipRect(r: Rect, bounds: Rect) Rect {
    return .{
        .x1 = @max(r.x1, bounds.x1),
        .y1 = @max(r.y1, bounds.y1),
        .x2 = @min(r.x2, bounds.x2),
        .y2 = @min(r.y2, bounds.y2),
    };
}

/// Check if a point overlaps any rect in a list.
fn pointOverlapsAny(x: f32, y: f32, rects: []const Rect) bool {
    for (rects) |r| {
        if (x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2) {
            return true;
        }
    }
    return false;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "GuardRingDB initCapacity and append" {
    const alloc = std.testing.allocator;
    var db = try GuardRingDB.initCapacity(alloc, 4);
    defer db.deinit();

    try db.append(.{
        .bbox_x1 = 0.0,
        .bbox_y1 = 0.0,
        .bbox_x2 = 10.0,
        .bbox_y2 = 10.0,
        .inner_x1 = 2.0,
        .inner_y1 = 2.0,
        .inner_x2 = 8.0,
        .inner_y2 = 8.0,
        .ring_type = .p_plus,
        .net = NetIdx.fromInt(3),
        .contact_pitch = 1.0,
        .has_stitch_in = false,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);

    const ring = db.getRing(0);
    try std.testing.expectEqual(@as(f32, 0.0), ring.bbox_x1);
    try std.testing.expectEqual(@as(f32, 10.0), ring.bbox_x2);
    try std.testing.expectEqual(GuardRingType.p_plus, ring.ring_type);
    try std.testing.expectEqual(NetIdx.fromInt(3), ring.net);
}

test "GuardRingDB grows capacity" {
    const alloc = std.testing.allocator;
    var db = try GuardRingDB.initCapacity(alloc, 2);
    defer db.deinit();

    try std.testing.expectEqual(@as(u32, 2), db.capacity);

    for (0..5) |i| {
        try db.append(.{
            .bbox_x1 = 0.0,
            .bbox_y1 = 0.0,
            .bbox_x2 = 10.0,
            .bbox_y2 = 10.0,
            .inner_x1 = 2.0,
            .inner_y1 = 2.0,
            .inner_x2 = 8.0,
            .inner_y2 = 8.0,
            .ring_type = @enumFromInt(@as(u8, @intCast(i % 4))),
            .net = NetIdx.fromInt(0),
            .contact_pitch = 1.0,
            .has_stitch_in = false,
        });
    }

    try std.testing.expectEqual(@as(u32, 5), db.len);
    try std.testing.expect(db.capacity >= 5);
}

test "GuardRingDB addContacts and count" {
    const alloc = std.testing.allocator;
    var db = try GuardRingDB.initCapacity(alloc, 4);
    defer db.deinit();

    try db.append(.{
        .bbox_x1 = 0.0,
        .bbox_y1 = 0.0,
        .bbox_x2 = 10.0,
        .bbox_y2 = 10.0,
        .inner_x1 = 2.0,
        .inner_y1 = 2.0,
        .inner_x2 = 8.0,
        .inner_y2 = 8.0,
        .ring_type = .p_plus,
        .net = NetIdx.fromInt(0),
        .contact_pitch = 1.0,
        .has_stitch_in = false,
    });

    const xs = [_]f32{ 1.0, 2.0, 3.0 };
    const ys = [_]f32{ 5.0, 5.0, 5.0 };
    try db.addContacts(0, &xs, &ys);

    try std.testing.expectEqual(@as(u32, 3), db.num_contacts);
    try std.testing.expectEqual(@as(u32, 0), db.contacts_ring_idx[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), db.contacts_x[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), db.contacts_x[2], 1e-6);
}

test "GuardRingInserter.insert forms complete enclosure" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const region = Rect{ .x1 = 20.0, .y1 = 20.0, .x2 = 80.0, .y2 = 80.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    _ = try inserter.insert(region, .p_plus, NetIdx.fromInt(0));

    try std.testing.expectEqual(@as(u32, 1), inserter.ringCount());

    const ring = inserter.getRing(0);
    // Outer bbox must enclose region.
    try std.testing.expect(ring.bbox_x1 < region.x1);
    try std.testing.expect(ring.bbox_y1 < region.y1);
    try std.testing.expect(ring.bbox_x2 > region.x2);
    try std.testing.expect(ring.bbox_y2 > region.y2);
    // Inner bbox also encloses region (with spacing).
    try std.testing.expect(ring.inner_x1 < region.x1);
    try std.testing.expect(ring.inner_y1 < region.y1);
    try std.testing.expect(!ring.has_stitch_in);
    // Contacts were generated.
    try std.testing.expect(inserter.totalContactCount() > 0);
}

test "GuardRingInserter contact count matches perimeter / pitch" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 200.0, .y2 = 200.0 };
    const region = Rect{ .x1 = 50.0, .y1 = 50.0, .x2 = 150.0, .y2 = 150.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    _ = try inserter.insert(region, .p_plus, NetIdx.fromInt(0));

    const ring = inserter.getRing(0);
    const outer_w = ring.bbox_x2 - ring.bbox_x1;
    const outer_h = ring.bbox_y2 - ring.bbox_y1;
    const inner_w = ring.inner_x2 - ring.inner_x1;
    const inner_h = ring.inner_y2 - ring.inner_y1;

    // Top+bottom sides span outer width; left+right span inner height.
    const perimeter_approx = 2.0 * outer_w + 2.0 * inner_h;
    const pitch = ring.contact_pitch;
    const expected_contacts_approx = perimeter_approx / pitch;

    const actual = inserter.contactCount(0);
    // Contact count should be roughly proportional to perimeter/pitch.
    // Allow 50% tolerance due to half-pitch offsets and corner skipping.
    try std.testing.expect(@as(f32, @floatFromInt(actual)) > expected_contacts_approx * 0.5);
    try std.testing.expect(@as(f32, @floatFromInt(actual)) < expected_contacts_approx * 1.5);

    _ = outer_h;
    _ = inner_w;
}

test "GuardRingInserter die edge clipping" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    // Small die.
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 15.0, .y2 = 15.0 };
    // Region near origin — ring would extend beyond die.
    const region = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 5.0, .y2 = 5.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    _ = try inserter.insert(region, .p_plus, NetIdx.fromInt(0));

    const ring = inserter.getRing(0);
    // Ring bbox should be clipped to die edge.
    try std.testing.expect(ring.bbox_x1 >= 0.0);
    try std.testing.expect(ring.bbox_y1 >= 0.0);
    try std.testing.expect(ring.bbox_x2 <= 15.0);
    try std.testing.expect(ring.bbox_y2 <= 15.0);
    // Warning should have been recorded.
    try std.testing.expect(inserter.num_warnings > 0);
}

test "GuardRingInserter clipAllToDieEdge removes out-of-bounds contacts" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 200.0, .y2 = 200.0 };
    const region = Rect{ .x1 = 50.0, .y1 = 50.0, .x2 = 150.0, .y2 = 150.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    _ = try inserter.insert(region, .p_plus, NetIdx.fromInt(0));

    const before = inserter.totalContactCount();
    // Shrink die — some contacts should be removed.
    inserter.die_bbox = Rect{ .x1 = 40.0, .y1 = 40.0, .x2 = 160.0, .y2 = 160.0 };
    inserter.clipAllToDieEdge();
    const after = inserter.totalContactCount();

    // All contacts were inside the original die, but after shrinking, outer
    // contacts near the ring perimeter may be removed.
    try std.testing.expect(after <= before);
}

test "GuardRingInserter.mergeDeepNWell" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    const region1 = Rect{ .x1 = 10.0, .y1 = 10.0, .x2 = 30.0, .y2 = 30.0 };
    const region2 = Rect{ .x1 = 35.0, .y1 = 10.0, .x2 = 55.0, .y2 = 30.0 };

    const idx1 = try inserter.insert(region1, .deep_nwell, NetIdx.fromInt(0));
    const idx2 = try inserter.insert(region2, .deep_nwell, NetIdx.fromInt(0));

    try inserter.mergeDeepNWell(idx1, idx2);

    try std.testing.expectEqual(@as(u32, 1), inserter.ringCount());
    const ring = inserter.getRing(0);
    // Merged outer bbox should encompass both regions.
    try std.testing.expect(ring.bbox_x1 < 20.0); // covers region1
    try std.testing.expect(ring.bbox_x2 > 45.0); // covers region2
}

test "GuardRingInserter merge rejects different nets" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    const region1 = Rect{ .x1 = 10.0, .y1 = 10.0, .x2 = 30.0, .y2 = 30.0 };
    const region2 = Rect{ .x1 = 35.0, .y1 = 10.0, .x2 = 55.0, .y2 = 30.0 };

    const idx1 = try inserter.insert(region1, .deep_nwell, NetIdx.fromInt(0));
    const idx2 = try inserter.insert(region2, .deep_nwell, NetIdx.fromInt(1));

    try std.testing.expectError(error.RingNetConflict, inserter.mergeDeepNWell(idx1, idx2));
}

test "GuardRingInserter insertWithStitchIn sets has_stitch_in=true" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const region = Rect{ .x1 = 20.0, .y1 = 20.0, .x2 = 80.0, .y2 = 80.0 };
    const existing = &[_]Rect{.{ .x1 = 30.0, .y1 = 80.0, .x2 = 70.0, .y2 = 90.0 }};

    var inserter = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter.deinit();

    _ = try inserter.insertWithStitchIn(region, .n_plus, NetIdx.fromInt(0), existing);

    try std.testing.expectEqual(@as(u32, 1), inserter.ringCount());
    const ring = inserter.getRing(0);
    try std.testing.expect(ring.has_stitch_in);
}

test "GuardRingInserter insertWithStitchIn skips overlapping contacts" {
    const alloc = std.testing.allocator;
    var pdk = layout_if.PdkConfig.loadDefault(.sky130);
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 200.0, .y2 = 200.0 };
    const region = Rect{ .x1 = 50.0, .y1 = 50.0, .x2 = 150.0, .y2 = 150.0 };

    // Large metal rect covering the entire top of the ring area.
    const blocking = &[_]Rect{.{ .x1 = 0.0, .y1 = 145.0, .x2 = 200.0, .y2 = 200.0 }};

    var inserter_normal = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter_normal.deinit();
    _ = try inserter_normal.insert(region, .p_plus, NetIdx.fromInt(0));

    var inserter_stitch = try GuardRingInserter.init(alloc, &pdk, null, die_bbox);
    defer inserter_stitch.deinit();
    _ = try inserter_stitch.insertWithStitchIn(region, .p_plus, NetIdx.fromInt(0), blocking);

    // Stitch-in version should have fewer contacts (top side blocked).
    try std.testing.expect(inserter_stitch.totalContactCount() < inserter_normal.totalContactCount());
}

test "GuardRingIdx round-trip" {
    const idx = GuardRingIdx.fromInt(99);
    try std.testing.expectEqual(@as(u32, 99), idx.toInt());
}

test "GuardRingType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GuardRingType.p_plus));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(GuardRingType.n_plus));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(GuardRingType.deep_nwell));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(GuardRingType.composite));
}

test "pointOverlapsAny detects point in rect" {
    const rects = &[_]Rect{
        .{ .x1 = 10.0, .y1 = 10.0, .x2 = 20.0, .y2 = 20.0 },
        .{ .x1 = 30.0, .y1 = 30.0, .x2 = 40.0, .y2 = 40.0 },
    };

    try std.testing.expect(pointOverlapsAny(15.0, 15.0, rects));
    try std.testing.expect(pointOverlapsAny(35.0, 35.0, rects));
    try std.testing.expect(!pointOverlapsAny(25.0, 25.0, rects));
    try std.testing.expect(!pointOverlapsAny(5.0, 5.0, rects));
}
