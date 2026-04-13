//! Custom test runner for struct size reporting.
//!
//! Used as the --test-runner for `zig build get_size`.
//! Each test binary receives SIZE_SOURCE_FILE via the environment.
//! The runner suppresses individual struct lines, computes the total, and
//! writes exactly one line to stdout:
//!
//!   <bytes>\t<basename>: <bytes>B (<KiB> KiB)
//!
//! build.zig captures these stdout files, passes them all to `sort -rn`,
//! and prints the final sorted list.

const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const source_file = std.process.getEnvVarOwned(alloc, "SIZE_SOURCE_FILE") catch "unknown";
    defer alloc.free(source_file);
    const name = std.fs.path.stem(std.fs.path.basename(source_file));

    // Redirect stderr into a pipe so test output is suppressed.
    const real_err = try std.posix.dup(std.posix.STDERR_FILENO);
    defer std.posix.close(real_err);
    const pipe_fds = try std.posix.pipe();
    try std.posix.dup2(pipe_fds[1], std.posix.STDERR_FILENO);
    std.posix.close(pipe_fds[1]);

    for (builtin.test_functions) |t| {
        t.func() catch {};
    }

    // Restore stderr (closes last write-end → EOF on read side).
    try std.posix.dup2(real_err, std.posix.STDERR_FILENO);

    var buf: [16384]u8 = undefined;
    const pipe_read = std.fs.File{ .handle = pipe_fds[0] };
    const n = try pipe_read.readAll(&buf);
    pipe_read.close();

    // Sum all trailing "<digits>B" values.
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimRight(u8, line, " \t\r");
        if (t.len == 0 or t[t.len - 1] != 'B') continue;
        const de = t.len - 1;
        var ds = de;
        while (ds > 0 and std.ascii.isDigit(t[ds - 1])) ds -= 1;
        if (ds < de) {
            const bytes = std.fmt.parseInt(usize, t[ds..de], 10) catch continue;
            total += bytes;
        }
    }

    // One sortable line to stdout: "<bytes>\t<display>"
    var out_buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&out_buf, "{d}\t{s}: {d}B ({d:.1} KiB)\n", .{
        total, name, total, @as(f64, @floatFromInt(total)) / 1024.0,
    });
    _ = try std.posix.write(std.posix.STDOUT_FILENO, out);
}

/// Minimal fuzz support so that fuzz tests compile under this runner.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), []const u8) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        try testOne(context, input);
    }
    try testOne(context, "");
}
