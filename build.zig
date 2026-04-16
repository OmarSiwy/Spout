const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared source module used by the library, unit tests, and e2e tests.
    const spout_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "spout",
        .root_module = spout_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // Also install the shared library into python/ for the Python FFI bindings.
    const install_to_python = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .{ .custom = "../python" },
        "libspout.so",
    );
    b.getInstallStep().dependOn(&install_to_python.step);

    // ── PyOZ Python extension ──────────────────────────────────────────────
    // Builds python/spout.so — a native CPython extension replacing ctypes.
    // Usage: `zig build pyext`
    const pyoz_dep = b.dependency("PyOZ", .{
        .target = target,
        .optimize = optimize,
    });
    const pyoz_mod = pyoz_dep.module("PyOZ");

    const pyext_mod = b.createModule(.{
        .root_source_file = b.path("src/python_ext.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "PyOZ", .module = pyoz_mod },
            .{ .name = "spout", .module = spout_mod },
        },
    });

    const pyext = b.addLibrary(.{
        .name = "spout",
        .root_module = pyext_mod,
        .linkage = .dynamic,
    });
    pyext.linkLibC();

    const install_pyext = b.addInstallFileWithDir(
        pyext.getEmittedBin(),
        .{ .custom = "../python" },
        "spout.so",
    );

    const pyext_step = b.step("pyext", "Build native Python extension (python/spout.so)");
    pyext_step.dependOn(&install_pyext.step);

    // Unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // End-to-end tests (opt-in via "zig build e2e"; tests/e2e_tests.zig may
    // be absent during development, so this step is not wired into "test").
    // Uncomment when tests/e2e_tests.zig is present.
    // const e2e_mod = b.createModule(.{
    //     .root_source_file = b.path("tests/e2e_tests.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .imports = &.{
    //         .{ .name = "spout", .module = spout_mod },
    //     },
    // });
    // const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    // const run_e2e = b.addRunArtifact(e2e_tests);
    // const e2e_step = b.step("e2e", "Run end-to-end tests");
    // e2e_step.dependOn(&run_e2e.step);

    // Liberty-specific unit tests (includes GDS template import tests)
    const liberty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/liberty/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_liberty_tests = b.addRunArtifact(liberty_tests);
    const liberty_test_step = b.step("test-liberty", "Run liberty unit tests");
    liberty_test_step.dependOn(&run_liberty_tests.step);

    // Template import tests
    const template_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/import/template.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_template_tests = b.addRunArtifact(template_tests);
    const template_test_step = b.step("test-template", "Run GDS template import tests");
    template_test_step.dependOn(&run_template_tests.step);

    // Custom test runner (pass/fail display with tick marks)
    const test_runner_tests = b.addTest(.{
        .name = "test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("tests/test_runner.zig"),
            .mode = .simple,
        },
    });
    const run_test_runner = b.addRunArtifact(test_runner_tests);
    const test_runner_step = b.step("test-runner", "Run unit tests with pass/fail display");
    test_runner_step.dependOn(&run_test_runner.step);

    // Size runner (model struct size reporting)
    const size_tests = b.addTest(.{
        .name = "size-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .path = b.path("tests/size_runner.zig"),
            .mode = .simple,
        },
    });
    const run_size = b.addRunArtifact(size_tests);
    run_size.setEnvironmentVariable("SIZE_SOURCE_FILE", "src/lib.zig");
    const size_step = b.step("size", "Report model struct sizes");
    size_step.dependOn(&run_size.step);
}
