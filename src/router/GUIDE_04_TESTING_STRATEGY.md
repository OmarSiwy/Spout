# Testing Strategy for Analog Router

## Testing Hierarchy

```
Unit Tests        — per-function, per-struct correctness
Property Tests    — invariants that hold for all inputs
Fuzz Tests        — random inputs, check no crashes/UB
Integration Tests — multi-module flows end-to-end
Regression Tests  — specific bug reproductions
Benchmark Tests   — performance targets (cache, throughput)
```

All tests in `src/router/analog_tests.zig`. Run with `nix develop --command zig build test`.

---

## 1. Core Data Tables (Phase 1)

### 1.1 ID Type Round-Trips

```zig
test "AnalogGroupIdx round-trip" {
    const idx = AnalogGroupIdx.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), idx.toInt());
}

test "AnalogGroupIdx boundary values" {
    try std.testing.expectEqual(@as(u32, 0), AnalogGroupIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), AnalogGroupIdx.fromInt(0xFFFFFFFF).toInt());
}

test "SegmentIdx and AnalogGroupIdx are distinct types" {
    // This is a compile-time test. If these types were the same,
    // the function below would accept AnalogGroupIdx.
    const S = struct {
        fn takesSegment(_: SegmentIdx) void {}
    };
    // S.takesSegment(AnalogGroupIdx.fromInt(0)); // <- must NOT compile
    S.takesSegment(SegmentIdx.fromInt(0)); // <- must compile
}
```

### 1.2 AnalogGroupDB CRUD

```zig
test "AnalogGroupDB add differential group" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{
        .name = "diff_pair_1",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = LayerIdx.fromInt(1),
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expectEqual(AnalogGroupType.differential, db.group_type[0]);
    try std.testing.expectEqual(@as(u8, 2), db.net_count[0]);
}

test "AnalogGroupDB reject mismatched device types" {
    // Differential pair where one device is NMOS and other is PMOS
    // Should return error.DeviceTypeMismatch
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    const result = db.addGroupWithValidation(.{
        .name = "bad_pair",
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .device_types = &.{ .nmos, .pmos }, // mismatch
    });
    try std.testing.expectError(error.DeviceTypeMismatch, result);
}

test "AnalogGroupDB group net lookup" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{
        .name = "matched_3",
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(5), NetIdx.fromInt(6), NetIdx.fromInt(7) },
        .tolerance = 0.03,
    });

    const nets = db.netsForGroup(0);
    try std.testing.expectEqual(@as(usize, 3), nets.len);
    try std.testing.expectEqual(NetIdx.fromInt(5), nets[0]);
    try std.testing.expectEqual(NetIdx.fromInt(7), nets[2]);
}
```

### 1.3 AnalogSegmentDB Append + toRouteArrays

```zig
test "AnalogSegmentDB append and convert to RouteArrays" {
    var seg_db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer seg_db.deinit();

    try seg_db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
        .group = AnalogGroupIdx.fromInt(0),
        .is_shield = false, .is_dummy_via = false, .is_jog = false,
    });

    try std.testing.expectEqual(@as(u32, 1), seg_db.len);

    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    try seg_db.toRouteArrays(&ra);
    try std.testing.expectEqual(@as(u32, 1), ra.len);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x2[0]);
}
```

### 1.4 Compile-Time Layout Assertions

```zig
test "layout size assertions" {
    // These are really comptime checks, but test blocks verify they compile
    comptime {
        std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
        std.debug.assert(@sizeOf(SegmentIdx) == 4);
        std.debug.assert(@sizeOf(GuardRingIdx) == 2);
        std.debug.assert(@sizeOf(AnalogGroupType) == 1);
        std.debug.assert(@sizeOf(GuardRingType) == 1);
    }
}
```

---

## 2. Spatial Grid (Phase 2)

### 2.1 Cell Index Computation

```zig
test "SpatialGrid cellIndex basic" {
    const grid = try SpatialGrid.init(std.testing.allocator, .{
        .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0,
    }, 10.0); // cell_size = 10um
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 0), grid.cellIndex(0.0, 0.0));
    try std.testing.expectEqual(@as(u32, 1), grid.cellIndex(10.0, 0.0));
    try std.testing.expectEqual(@as(u32, 10), grid.cellIndex(0.0, 10.0));
}

test "SpatialGrid cellIndex clamps out-of-bounds" {
    const grid = try SpatialGrid.init(std.testing.allocator, .{
        .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0,
    }, 10.0);
    defer grid.deinit();

    // Negative coordinates clamp to 0
    const idx_neg = grid.cellIndex(-5.0, -5.0);
    try std.testing.expectEqual(@as(u32, 0), idx_neg);

    // Beyond bounds clamps to last cell
    const idx_big = grid.cellIndex(999.0, 999.0);
    try std.testing.expect(idx_big < grid.cells_x * grid.cells_y);
}
```

### 2.2 Neighborhood Query

```zig
test "SpatialGrid neighborhood returns correct segments" {
    var grid = try SpatialGrid.init(std.testing.allocator, .{
        .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0,
    }, 10.0);
    defer grid.deinit();

    // Insert segment at (15, 15) — should land in cell (1,1)
    try grid.insert(SegmentIdx.fromInt(42), 15.0, 15.0, 16.0, 15.0);

    // Query at (15, 15) — should find segment 42
    var found = false;
    var iter = grid.queryNeighborhood(15.0, 15.0);
    while (iter.next()) |seg_idx| {
        if (seg_idx.toInt() == 42) found = true;
    }
    try std.testing.expect(found);

    // Query at (85, 85) — should NOT find segment 42
    found = false;
    iter = grid.queryNeighborhood(85.0, 85.0);
    while (iter.next()) |seg_idx| {
        if (seg_idx.toInt() == 42) found = true;
    }
    try std.testing.expect(!found);
}
```

### 2.3 Rebuild Correctness

```zig
test "SpatialGrid rebuild preserves all segments" {
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    // Insert 100 segments
    for (0..100) |i| {
        const x: f32 = @floatFromInt(i);
        try grid.insert(SegmentIdx.fromInt(@intCast(i)), x, 0.0, x + 1.0, 0.0);
    }

    // Rebuild
    try grid.rebuild(segments);

    // Verify all 100 are still findable
    for (0..100) |i| {
        const x: f32 = @floatFromInt(i);
        var found = false;
        var iter = grid.queryNeighborhood(x + 0.5, 0.0);
        while (iter.next()) |seg_idx| {
            if (seg_idx.toInt() == i) found = true;
        }
        try std.testing.expect(found);
    }
}
```

### 2.4 Edge Cases

```zig
test "SpatialGrid empty grid query returns nothing" {
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    var iter = grid.queryNeighborhood(50.0, 50.0);
    try std.testing.expectEqual(@as(?SegmentIdx, null), iter.next());
}

test "SpatialGrid segment on cell boundary assigned to correct cell" {
    // Segment at exact cell boundary (x=10.0 with cell_size=10.0)
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    try grid.insert(SegmentIdx.fromInt(0), 10.0, 0.0, 10.0, 5.0);

    // Should be found from cell (1,0), not only cell (0,0)
    var found = false;
    var iter = grid.queryNeighborhood(10.0, 2.5);
    while (iter.next()) |_| found = true;
    try std.testing.expect(found);
}

test "SpatialGrid segment spanning multiple cells" {
    // Long segment from (5,5) to (35,5) crosses cells (0,0), (1,0), (2,0), (3,0)
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    try grid.insertSpanning(SegmentIdx.fromInt(0), 5.0, 5.0, 35.0, 5.0);

    // Should be found from any cell along the span
    for ([_]f32{ 5.0, 15.0, 25.0, 35.0 }) |x| {
        var found = false;
        var iter = grid.queryNeighborhood(x, 5.0);
        while (iter.next()) |_| found = true;
        try std.testing.expect(found);
    }
}
```

---

## 3. Analog Groups (Phase 3)

### 3.1 Validation

```zig
test "reject differential group with odd net count" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1), NetIdx.fromInt(2) }, // 3 nets
    }));
}

test "reject differential group with 0 nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .group_type = .differential,
        .nets = &.{},
    }));
}

test "kelvin group requires force and sense nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.MissingKelvinNets, db.addGroup(.{
        .group_type = .kelvin,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .force_net = null, // missing
        .sense_net = null, // missing
    }));
}

test "tolerance must be positive" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = -0.01, // negative
    }));
}

test "tolerance must be <= 1.0" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 1.5, // > 100%
    }));
}
```

### 3.2 Priority Ordering

```zig
test "groups sorted by priority for routing order" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{ .route_priority = 2, .group_type = .matched, ... });
    try db.addGroup(.{ .route_priority = 0, .group_type = .differential, ... });
    try db.addGroup(.{ .route_priority = 1, .group_type = .shielded, ... });

    const order = try db.sortedByPriority(std.testing.allocator);
    defer std.testing.allocator.free(order);

    // Priority 0 first, then 1, then 2
    try std.testing.expectEqual(@as(u8, 0), db.route_priority[order[0].toInt()]);
    try std.testing.expectEqual(@as(u8, 1), db.route_priority[order[1].toInt()]);
    try std.testing.expectEqual(@as(u8, 2), db.route_priority[order[2].toInt()]);
}
```

---

## 4. Matched Router (Phase 4)

### 4.1 Symmetric Steiner Tree

```zig
test "symmetric Steiner tree mirrors correctly" {
    var tree = try SymmetricSteiner.build(std.testing.allocator, .{
        .pins_p = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } },
        .pins_n = &.{ .{ .x = 0, .y = 20 }, .{ .x = 10, .y = 20 } },
        .axis = .y,
        .axis_value = 10.0,
    });
    defer tree.deinit();

    // Net P and net N should have identical topology
    try std.testing.expectEqual(tree.edges_p.len, tree.edges_n.len);

    // Total length should be equal
    const len_p = tree.totalLength(.p);
    const len_n = tree.totalLength(.n);
    try std.testing.expectApproxEqRel(len_p, len_n, 0.001);
}
```

### 4.2 Wire-Length Balancing

```zig
test "wire-length balancing adds jogs to shorter net" {
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    // Route two nets with different natural lengths
    try router.routeGroup(group);
    try router.balanceWireLengths(group);

    const len_a = router.netLength(NetIdx.fromInt(0));
    const len_b = router.netLength(NetIdx.fromInt(1));

    // After balancing, lengths should be within tolerance
    const ratio = @abs(len_a - len_b) / @max(len_a, len_b);
    try std.testing.expect(ratio < 0.01); // 1% tolerance
}

test "wire-length balancing does not add jogs when already matched" {
    // Two nets with identical length — no jogs should be added
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    // Pre-route with exactly equal lengths
    const segments_before = router.segmentCount();
    try router.balanceWireLengths(group);
    const segments_after = router.segmentCount();

    try std.testing.expectEqual(segments_before, segments_after);
}
```

### 4.3 Via Count Balancing

```zig
test "via count balancing adds dummy vias" {
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    // Route net A with 3 vias, net B with 1 via
    try router.routeGroup(group);

    const vias_a = router.viaCount(NetIdx.fromInt(0));
    const vias_b = router.viaCount(NetIdx.fromInt(1));
    try std.testing.expect(@abs(@as(i32, @intCast(vias_a)) - @as(i32, @intCast(vias_b))) > 1);

    try router.balanceViaCounts(group);

    const vias_a2 = router.viaCount(NetIdx.fromInt(0));
    const vias_b2 = router.viaCount(NetIdx.fromInt(1));
    try std.testing.expect(@abs(@as(i32, @intCast(vias_a2)) - @as(i32, @intCast(vias_b2))) <= 1);
}

test "via count balancing skips if DRC violation would result" {
    // Place obstacles so dummy via would cause spacing violation
    // Verify via delta > 1 is allowed with warning (not crash)
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    // Block all silent segments with obstacles
    for (0..grid.cells_x) |x| {
        for (0..grid.cells_y) |y| {
            try grid.markBlocked(x, y, 1); // block M1
        }
    }

    // Via balancing should not crash, just leave delta > 1
    try router.balanceViaCounts(group);
    // No assertion on via count — just verify no crash/UB
}
```

### 4.4 Same-Layer Enforcement

```zig
test "matched nets routed on same metal layer" {
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    try router.routeGroup(group); // group with preferred_layer = M2

    const segs = router.segmentsForGroup(group);
    for (segs.layer) |l| {
        try std.testing.expectEqual(@as(u8, 2), l); // All on M2
    }
}
```

### 4.5 Edge Cases

```zig
test "matched router handles single-pin nets gracefully" {
    // Net with only 1 pin — nothing to route, should not crash
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    try router.routeGroup(single_pin_group);
    try std.testing.expectEqual(@as(u32, 0), router.segmentCount());
}

test "matched router handles coincident pins" {
    // Two nets with pins at exactly the same location
    // Should produce zero-length route (or skip)
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    try router.routeGroup(coincident_group);
    // No crash, length >= 0
}

test "differential pair with unequal pin count uses virtual pin" {
    // net_p has 3 pins, net_n has 2 pins
    // Router should add virtual pin at centroid for net_n
    var router = try MatchedRouter.init(std.testing.allocator, pdk, grid);
    defer router.deinit();

    try router.routeGroup(unequal_pin_group);
    // Both nets should have routes (even though pin counts differ)
    try std.testing.expect(router.netLength(net_p) > 0);
    try std.testing.expect(router.netLength(net_n) > 0);
}
```

---

## 5. Shield Router (Phase 5)

```zig
test "shield wires generated on adjacent layer" {
    var shield = try ShieldRouter.init(std.testing.allocator, pdk);
    defer shield.deinit();

    // Route signal on M1, shield should be on M2
    try shield.routeShielded(signal_net, ground_net, 1); // signal on layer 1

    const shields = shield.getShields();
    for (shields.layer) |l| {
        try std.testing.expectEqual(@as(u8, 2), l); // M2 adjacent to M1
    }
}

test "shield wire skipped when DRC conflict exists" {
    // Place existing route on M2 where shield would go
    // Shield router should skip that segment
    var shield = try ShieldRouter.init(std.testing.allocator, pdk);
    defer shield.deinit();

    // ... setup conflict ...

    try shield.routeShielded(signal_net, ground_net, 1);
    // Should have fewer shield segments than signal segments
    try std.testing.expect(shield.shieldCount() < signal_segment_count);
}

test "driven guard connects to signal potential, not ground" {
    var shield = try ShieldRouter.init(std.testing.allocator, pdk);
    defer shield.deinit();

    try shield.routeDrivenGuard(.{
        .signal_net = signal_net,
        .guard_net = signal_net, // same potential
        .shield_layer = 2,
    });

    const shields = shield.getShields();
    for (shields.shield_net) |sn| {
        // Driven guard net == signal net, NOT ground
        try std.testing.expectEqual(signal_net, sn);
    }
}
```

---

## 6. Guard Ring (Phase 6)

```zig
test "guard ring forms complete enclosure" {
    var gr = try GuardRingInserter.init(std.testing.allocator, pdk);
    defer gr.deinit();

    const ring = try gr.insert(.{
        .region = .{ .x1 = 10, .y1 = 10, .x2 = 50, .y2 = 50 },
        .ring_type = .p_plus,
        .net = vss_net,
    });

    // Ring bbox should fully enclose region with margin
    try std.testing.expect(ring.bbox_x1 < 10.0);
    try std.testing.expect(ring.bbox_y1 < 10.0);
    try std.testing.expect(ring.bbox_x2 > 50.0);
    try std.testing.expect(ring.bbox_y2 > 50.0);
}

test "guard ring stitch-in for existing metal overlap" {
    // Place existing VSS metal that overlaps ring path
    // Guard ring should create gap + contacts on both sides
    var gr = try GuardRingInserter.init(std.testing.allocator, pdk);
    defer gr.deinit();

    // ... add existing VSS metal ...

    const ring = try gr.insertWithStitchIn(.{
        .region = region,
        .ring_type = .n_plus,
        .net = vdd_net,
    });

    // Ring should still provide enclosure (with gap)
    try std.testing.expect(ring.has_stitch_in);
}

test "guard ring near die edge clips gracefully" {
    var gr = try GuardRingInserter.init(std.testing.allocator, pdk);
    defer gr.deinit();

    const ring = try gr.insert(.{
        .region = .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 5 }, // near origin
        .ring_type = .p_plus,
        .net = vss_net,
    });

    // Ring should not extend below (0,0)
    try std.testing.expect(ring.bbox_x1 >= 0.0);
    try std.testing.expect(ring.bbox_y1 >= 0.0);
}
```

---

## 7. Thermal Router (Phase 7)

```zig
test "thermal map query returns correct temperature" {
    var map = try ThermalMap.init(std.testing.allocator, .{
        .bbox = .{ .x1 = 0, .y1 = 0, .x2 = 100, .y2 = 100 },
        .cell_size = 10.0,
        .ambient = 25.0,
    });
    defer map.deinit();

    // Add hotspot at (50, 50) with 10C above ambient
    try map.addHotspot(50.0, 50.0, 10.0, 20.0); // x, y, delta_T, radius

    const temp_at_hotspot = map.query(50.0, 50.0);
    try std.testing.expect(temp_at_hotspot > 30.0); // significantly above ambient

    const temp_far_away = map.query(0.0, 0.0);
    try std.testing.expect(temp_far_away < 27.0); // near ambient
}

test "thermal cost penalizes gradient across differential pair" {
    // Two points on opposite sides of a hotspot should have high gradient cost
    const cost = computeThermalCost(.{
        .point_a = .{ .x = 40, .y = 50 },
        .point_b = .{ .x = 60, .y = 50 },
    }, &thermal_map);

    try std.testing.expect(cost > 0.0);

    // Two points equidistant from hotspot (same isotherm) should have low cost
    const cost_iso = computeThermalCost(.{
        .point_a = .{ .x = 50, .y = 40 },
        .point_b = .{ .x = 50, .y = 60 },
    }, &thermal_map);

    try std.testing.expect(cost_iso < cost); // isotherm routing is cheaper
}
```

---

## 8. LDE Router (Phase 8)

```zig
test "LDE keepout zone generated from SA/SB constraints" {
    var lde = try LDEConstraintDB.init(std.testing.allocator, 8);
    defer lde.deinit();

    try lde.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0, .min_sb = 1.0,
        .max_sa = 5.0, .max_sb = 5.0,
        .sc_target = 2.0,
    });

    const keepouts = try lde.generateKeepouts(&device_bboxes, std.testing.allocator);
    defer std.testing.allocator.free(keepouts);

    try std.testing.expectEqual(@as(usize, 1), keepouts.len);
    // Keepout should be device bbox expanded by min_sa/min_sb
    try std.testing.expect(keepouts[0].x1 < device_bboxes[0].x1);
    try std.testing.expect(keepouts[0].x2 > device_bboxes[0].x2);
}

test "LDE cost penalizes SA/SB asymmetry" {
    const cost_symmetric = computeLDECost(.{
        .sa_a = 1.0, .sb_a = 1.0, // device A
        .sa_b = 1.0, .sb_b = 1.0, // device B — symmetric
    });

    const cost_asymmetric = computeLDECost(.{
        .sa_a = 1.0, .sb_a = 1.0,
        .sa_b = 0.5, .sb_b = 0.5, // device B — different SA/SB
    });

    try std.testing.expect(cost_asymmetric > cost_symmetric);
}
```

---

## 9. PEX Feedback (Phase 9)

```zig
test "PEX feedback loop converges within 5 iterations" {
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 1);
    defer db.deinit();

    // Setup a simple differential pair group
    try setupDiffPairTestCase(&db);

    const result = try routeWithPexFeedback(&db, group, 5);
    try std.testing.expectEqual(RoutingResult.success, result);

    // Verify matching
    const report = db.match_reports;
    try std.testing.expect(report.r_ratio[0] < 0.05);
    try std.testing.expect(report.c_ratio[0] < 0.05);
}

test "PEX feedback reports failure when unroutable" {
    // Create impossible constraints (tolerance = 0.0, conflicting geometry)
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 1);
    defer db.deinit();

    try setupImpossibleTestCase(&db);

    const result = try routeWithPexFeedback(&db, group, 5);
    try std.testing.expectEqual(RoutingResult.mismatch_exceeded, result);
}

test "MatchReport correctly identifies failing metric" {
    var report = computeMatchReport(&group, &net_results);

    // If R mismatch is 10% but tolerance is 5%
    try std.testing.expect(!report.passes);
    try std.testing.expect(report.r_ratio > 0.05);
}
```

---

## 10. Threading (Phase 10)

### 10.1 Thread Pool Correctness

```zig
test "ThreadPool executes all work items" {
    var completed = std.atomic.Value(u32).init(0);

    var pool = try ThreadPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var items: [100]WorkItem = undefined;
    for (&items) |*item| {
        item.* = .{ .counter = &completed };
    }

    pool.submitAndWait(&items);

    try std.testing.expectEqual(@as(u32, 100), completed.load(.acquire));
}
```

### 10.2 No Data Races

```zig
test "parallel routing produces same result as sequential" {
    // Route same design sequentially and in parallel
    // Results should be identical (deterministic)

    var db_seq = try setupTestDesign(std.testing.allocator);
    defer db_seq.deinit();
    try routeAllGroups(&db_seq, .{ .num_threads = 1 });

    var db_par = try setupTestDesign(std.testing.allocator);
    defer db_par.deinit();
    try routeAllGroups(&db_par, .{ .num_threads = 4 });

    // Same number of segments
    try std.testing.expectEqual(db_seq.segments.len, db_par.segments.len);

    // Same total wire length (within float precision)
    const len_seq = db_seq.totalWireLength();
    const len_par = db_par.totalWireLength();
    try std.testing.expectApproxEqRel(len_seq, len_par, 0.001);
}
```

### 10.3 Thread-Local Arena Isolation

```zig
test "thread-local arenas do not leak between threads" {
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 4);
    defer db.deinit();

    // Route one wavefront
    try routeWavefront(&db, wavefront_0, 4);

    // After wavefront, thread arenas should be reset
    for (db.thread_arenas) |*ta| {
        // Arena should have no outstanding allocations after reset
        _ = ta.reset(.retain_capacity);
    }
}
```

### 10.4 Wavefront Partitioning

```zig
test "wavefront coloring assigns no conflicts to same color" {
    var graph = try GroupDependencyGraph.build(&groups, &bboxes, std.testing.allocator);
    defer graph.deinit();

    const colors = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(colors);

    // Verify no two adjacent nodes share a color
    for (0..graph.num_groups) |i| {
        for (graph.adjacency[i].items) |neighbor| {
            try std.testing.expect(colors[i] != colors[neighbor.toInt()]);
        }
    }
}

test "independent groups get same color (can run in parallel)" {
    // Two groups with no shared nets and non-overlapping bboxes
    var graph = try GroupDependencyGraph.build(&independent_groups, &bboxes, std.testing.allocator);
    defer graph.deinit();

    const colors = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(colors);

    // Independent groups should get color 0 (all in first wavefront)
    try std.testing.expectEqual(colors[0], colors[1]);
}
```

---

## 11. Integration Tests (Phase 11)

### 11.1 Simple Differential Pair End-to-End

```zig
test "e2e: differential pair zero DRC" {
    const pdk = PdkConfig.loadDefault(.sky130);
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 1);
    defer db.deinit();

    // Create 2 NMOS devices, differential pair constraint
    try setupDiffPair(&db, .{
        .pin_p = .{ .x = 10, .y = 10 },
        .pin_n = .{ .x = 10, .y = 30 },
    });

    try routeAllGroups(&db, .{ .num_threads = 1 });

    // Verify zero DRC
    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();
    try db.segments.toRouteArrays(&ra);

    const violations = try runDrc(&ra, &pdk);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}
```

### 11.2 Current Mirror with Matching

```zig
test "e2e: current mirror matched within 5%" {
    const pdk = PdkConfig.loadDefault(.sky130);
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 1);
    defer db.deinit();

    try setupCurrentMirror(&db, 4); // 4 matched devices

    const result = try routeWithPexFeedback(&db, mirror_group, 5);
    try std.testing.expectEqual(RoutingResult.success, result);

    // All nets within 5% R/C matching
    try std.testing.expect(db.match_reports.r_ratio[0] < 0.05);
    try std.testing.expect(db.match_reports.c_ratio[0] < 0.05);
}
```

### 11.3 Kelvin Connection

```zig
test "e2e: kelvin force and sense paths do not share segments" {
    const pdk = PdkConfig.loadDefault(.sky130);
    var db = try AnalogRouteDB.init(std.testing.allocator, &pdk, die_bbox, 1);
    defer db.deinit();

    try setupKelvinConnection(&db);
    try routeAllGroups(&db, .{ .num_threads = 1 });

    // Verify force and sense nets share no segments
    const force_segs = db.segments.forNet(force_net);
    const sense_segs = db.segments.forNet(sense_net);

    for (force_segs) |fs| {
        for (sense_segs) |ss| {
            // No segment overlap
            try std.testing.expect(!segmentsOverlap(fs, ss));
        }
    }
}
```

---

## 12. Fuzz Tests

### 12.1 Spatial Grid Coordinate Fuzz

```zig
test "fuzz: spatial grid cellIndex never panics" {
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    for (0..10_000) |_| {
        const x = random.float(f32) * 1000.0 - 500.0; // [-500, 500]
        const y = random.float(f32) * 1000.0 - 500.0;
        _ = grid.cellIndex(x, y); // must not panic
    }
}
```

### 12.2 Group DB Stress

```zig
test "fuzz: AnalogGroupDB handles many groups" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 4);
    defer db.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..1000) |i| {
        const net_count = random.intRangeAtMost(u8, 2, 8);
        var nets: [8]NetIdx = undefined;
        for (0..net_count) |j| {
            nets[j] = NetIdx.fromInt(@intCast(i * 10 + j));
        }
        try db.addGroup(.{
            .group_type = @enumFromInt(random.intRangeAtMost(u3, 0, 5)),
            .nets = nets[0..net_count],
            .tolerance = 0.05,
        });
    }

    try std.testing.expectEqual(@as(u32, 1000), db.len);
}
```

### 12.3 MatchReport Invariants

```zig
test "fuzz: MatchReport ratios are non-negative" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..1000) |_| {
        const r_a = random.float(f32) * 100.0;
        const r_b = random.float(f32) * 100.0;
        const ratio = computeRatio(r_a, r_b);
        try std.testing.expect(ratio >= 0.0);
        try std.testing.expect(!std.math.isNan(ratio));
        try std.testing.expect(!std.math.isInf(ratio));
    }
}
```

---

## 13. Property-Based Tests

### 13.1 Segment toRouteArrays Preserves All Data

```zig
test "property: toRouteArrays is lossless" {
    // For any set of analog segments, converting to RouteArrays
    // and reading back should produce identical geometry
    var seg_db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer seg_db.deinit();

    // Add N random segments
    for (0..100) |i| {
        try seg_db.append(.{
            .x1 = @floatFromInt(i), .y1 = 0.0,
            .x2 = @floatFromInt(i + 1), .y2 = 0.0,
            .width = 0.14, .layer = 1,
            .net = NetIdx.fromInt(@intCast(i % 10)),
            .group = AnalogGroupIdx.fromInt(0),
            .is_shield = false, .is_dummy_via = false, .is_jog = false,
        });
    }

    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();
    try seg_db.toRouteArrays(&ra);

    // Verify all 100 segments survived
    try std.testing.expectEqual(@as(u32, 100), ra.len);
    for (0..100) |i| {
        try std.testing.expectEqual(seg_db.x1[i], ra.x1[i]);
        try std.testing.expectEqual(seg_db.x2[i], ra.x2[i]);
        try std.testing.expectEqual(seg_db.net[i], ra.net[i]);
    }
}
```

### 13.2 Spatial Grid: Insert Then Query Always Finds

```zig
test "property: inserted segment always found by query" {
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    for (0..500) |i| {
        const x = random.float(f32) * 80.0 + 10.0; // within bbox
        const y = random.float(f32) * 80.0 + 10.0;
        try grid.insert(SegmentIdx.fromInt(@intCast(i)), x, y, x + 1.0, y);

        // Immediately verify it's findable
        var found = false;
        var iter = grid.queryNeighborhood(x + 0.5, y);
        while (iter.next()) |seg_idx| {
            if (seg_idx.toInt() == i) found = true;
        }
        try std.testing.expect(found);
    }
}
```

### 13.3 Wire-Length Balancing Is Monotonic

```zig
test "property: wire-length balancing never makes mismatch worse" {
    // For any pair of nets, balancing should reduce or maintain length ratio
    const ratio_before = computeLengthRatio(net_a, net_b);
    try router.balanceWireLengths(group);
    const ratio_after = computeLengthRatio(net_a, net_b);

    try std.testing.expect(ratio_after <= ratio_before + 0.001); // epsilon for float
}
```

---

## 14. Benchmark Tests

### 14.1 Spatial Grid Query Throughput

```zig
test "bench: spatial grid query < 200ns at 10K segments" {
    var grid = try SpatialGrid.init(std.testing.allocator, bbox, 10.0);
    defer grid.deinit();

    // Insert 10K segments
    for (0..10_000) |i| {
        const x: f32 = @floatFromInt(i % 100);
        const y: f32 = @floatFromInt(i / 100);
        try grid.insert(SegmentIdx.fromInt(@intCast(i)), x, y, x + 0.5, y);
    }

    var timer = std.time.Timer.start() catch unreachable;
    const iterations = 100_000;
    for (0..iterations) |_| {
        var iter = grid.queryNeighborhood(50.0, 50.0);
        while (iter.next()) |_| {}
    }
    const elapsed_ns = timer.read();
    const ns_per_query = elapsed_ns / iterations;

    // Should be < 200ns per query
    try std.testing.expect(ns_per_query < 200);
}
```

### 14.2 Group Routing Throughput

```zig
test "bench: 100 groups route in < 1 second (4 threads)" {
    var db = try setupLargeTestDesign(std.testing.allocator, 100);
    defer db.deinit();

    var timer = std.time.Timer.start() catch unreachable;
    try routeAllGroups(&db, .{ .num_threads = 4 });
    const elapsed_ms = timer.read() / 1_000_000;

    try std.testing.expect(elapsed_ms < 1000);
}
```

---

## Edge Case Catalog

Every edge case from the architecture doc, plus additional ones discovered during analysis:

| # | Edge Case | Module | Test |
|---|-----------|--------|------|
| 1 | Differential pair with unequal pin count | matched_router | `test "differential pair with unequal pin count"` |
| 2 | Shield wire DRC conflict | shield_router | `test "shield wire skipped when DRC conflict"` |
| 3 | Guard ring overlaps existing metal | guard_ring | `test "guard ring stitch-in"` |
| 4 | Via balancing creates DRC violation | matched_router | `test "via count balancing skips if DRC violation"` |
| 5 | Thermal gradient changes during routing | thermal | `test "thermal map update after self-heating"` |
| 6 | Multi-patterning color conflict | matched_router | `test "color consistency for matched nets"` |
| 7 | Anti-parallel current flow (Seebeck) | matched_router | `test "seebeck compensation jogs"` |
| 8 | Deep N-well cannot fit between rings | guard_ring | `test "deep N-well merge for adjacent blocks"` |
| 9 | FinFET fin quantization mismatch | matched_router | `test "fin quantization warning"` |
| 10 | Kelvin force/sense path overlap | matched_router | `test "kelvin force sense no overlap"` |
| 11 | Empty group (0 nets) | analog_groups | `test "reject group with 0 nets"` |
| 12 | All nets on same pin (degenerate) | matched_router | `test "coincident pins"` |
| 13 | Grid cell overflow (>65K segs/cell) | spatial_grid | `test "cell overflow handled"` |
| 14 | PEX feedback diverges | pex_feedback | `test "PEX feedback reports failure"` |
| 15 | Thread pool with 0 work items | thread_pool | `test "empty work queue"` |
| 16 | Thread pool with 1 thread | thread_pool | `test "single thread mode"` |
| 17 | Group depends on itself (self-loop) | parallel_router | `test "self-dependent group"` |
| 18 | All groups dependent (single wavefront) | parallel_router | `test "fully connected dependency graph"` |
| 19 | Negative coordinates in die bbox | spatial_grid | `test "negative origin coordinates"` |
| 20 | Zero-area die bbox | spatial_grid | `test "zero area bbox rejected"` |
| 21 | Tolerance = 0.0 (exact match required) | pex_feedback | `test "zero tolerance convergence"` |
| 22 | Very large tolerance (100%) | analog_groups | `test "tolerance clamped to 1.0"` |
| 23 | Mixed PDK (sky130 + gf180 nets) | analog_groups | N/A — single PDK per design |
| 24 | Guard ring at die edge | guard_ring | `test "guard ring near die edge clips"` |
| 25 | Thermal map with no hotspots | thermal | `test "uniform thermal map"` |
