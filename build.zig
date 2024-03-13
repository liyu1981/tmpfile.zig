const std = @import("std");

pub const tmpfile = @import("src/tmpfile.zig");

pub fn build(b: *std.Build) void {
    _ = b.addModule("tmpfile", .{
        .root_source_file = .{ .path = "src/tmpfile.zig" },
    });
}
