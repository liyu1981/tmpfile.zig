const std = @import("std");

pub const tmpfile = @import("src/tmpfile.zig");

pub fn build(b: *std.Build) void {
    _ = b.addModule("tmpfile", .{
        .root_source_file = b.path("src/tmpfile.zig"),
    });
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tmpfile.zig"),
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
